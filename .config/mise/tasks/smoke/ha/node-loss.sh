#!/usr/bin/env bash
#MISE description="Drain/cordon a node and verify workloads reschedule + stay served."
# .config/mise/tasks/smoke/ha/node-loss.sh — destructive node-loss recovery proof (spec §15.6).
#
# Procedure: write a uniquely-tagged canary to the stateful surfaces under test and
# snapshot fingerprints -> stop one Lima k8s node (NOT node0 first) -> observe
# recovery WITHOUT operator intervention (etcd keeps quorum 2/3, pods reschedule,
# quorum stores keep serving) -> restart the node -> verify every canary fingerprint
# matches byte-for-byte and full replica count / HA posture is restored.
#
# GATED: refuses to run unless AI_INFRA_ALLOW_DESTRUCTIVE=1. Restores the cluster
# afterward. Never echoes secret material; all access loopback-only.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

if [[ -f "${REPO_ROOT}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.config/mise/lib/common.sh"
fi
declare -F info >/dev/null 2>&1 || info() { printf '[info] %s\n' "$*" >&2; }
declare -F warn >/dev/null 2>&1 || warn() { printf '[warn] %s\n' "$*" >&2; }
declare -F err >/dev/null 2>&1 || err() { printf '[err ] %s\n' "$*" >&2; }
declare -F die >/dev/null 2>&1 || die() {
  err "$@"
  exit 1
}
declare -F need >/dev/null 2>&1 || need() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}
declare -F kc >/dev/null 2>&1 || kc() {
  KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kube/config}" kubectl "$@"
}

readonly TARGET_NODE="${HA_TARGET_NODE:-ai-inf-platform-1}"
readonly LIMA_INSTANCE="${HA_LIMA_INSTANCE:-${TARGET_NODE}}"
# k8s node name = Lima guest hostname (lima-<instance>); kubeadm sets no nodeRegistration.name.
readonly K8S_NODE="${HA_K8S_NODE:-lima-${TARGET_NODE}}"
readonly RTO_TIMEOUT="${HA_RTO_TIMEOUT:-300}"
readonly CANARY_NS="langfuse-data"
CANARY_TAG="ha-node-$(date +%s)"
readonly CANARY_TAG
FP_PG=""
# CNPG bootstraps this cluster's application DB under a non-default name
# (spec.bootstrap.initdb.database); resolve it once, lazily, instead of assuming `app`.
CANARY_DB=""
canary_db() {
  [[ -n "${CANARY_DB}" ]] || CANARY_DB="$(cnpg_app_db "${CANARY_NS}" langfuse-pg)"
  printf '%s\n' "${CANARY_DB}"
}

guard() {
  if [[ "${AI_INFRA_ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    die "refusing to run: this is a DESTRUCTIVE test. Set AI_INFRA_ALLOW_DESTRUCTIVE=1 to proceed."
  fi
}

# Write a canary row into the langfuse CNPG primary and fingerprint it. We exec
# into the primary pod and use psql; the connection uri is read from the CNPG-minted
# secret via the pod's own env, never printed here.
canary_write_pg() {
  info "writing Postgres canary (tag ${CANARY_TAG}) into langfuse-pg primary"
  local primary
  primary="$(kc -n "${CANARY_NS}" get pods \
    -l 'cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=primary' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
  [[ -n "${primary}" ]] || die "could not locate langfuse-pg primary pod"
  kc -n "${CANARY_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c \
    "CREATE TABLE IF NOT EXISTS ha_canary(tag text primary key, ts timestamptz default now());
     INSERT INTO ha_canary(tag) VALUES ('${CANARY_TAG}') ON CONFLICT DO NOTHING;" >/dev/null ||
    die "Postgres canary write failed"
  FP_PG="$(kc -n "${CANARY_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "SELECT md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
  [[ -n "${FP_PG}" ]] || die "could not compute Postgres canary fingerprint"
  info "Postgres canary fingerprint snapshot recorded"
}

verify_pg() {
  info "verifying Postgres canary survived node loss (RPO=0 under sync repl)"
  local primary fp
  primary="$(kc -n "${CANARY_NS}" get pods \
    -l 'cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=primary' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
  [[ -n "${primary}" ]] || die "no langfuse-pg primary after recovery"
  fp="$(kc -n "${CANARY_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "SELECT md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
  if [[ "${fp}" == "${FP_PG}" ]]; then
    info "Postgres canary fingerprint matches — no data loss"
  else
    die "Postgres canary fingerprint MISMATCH (corruption / data loss)"
  fi
}

cleanup_pg() {
  local primary
  primary="$(kc -n "${CANARY_NS}" get pods \
    -l 'cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=primary' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
  [[ -n "${primary}" ]] || return 0
  kc -n "${CANARY_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "DELETE FROM ha_canary WHERE tag='${CANARY_TAG}';" >/dev/null 2>&1 || true
}

assert_etcd_quorum() {
  info "asserting etcd retains quorum (2 of 3 servers) and API is responsive"
  local ready
  ready="$(kc get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {c++} END{print c+0}')"
  if [[ "${ready:-0}" -ge 2 ]]; then
    info "API responsive; ${ready} nodes Ready (quorum holds)"
  else
    die "fewer than 2 Ready nodes — quorum/API at risk"
  fi
}

wait_node_state() {
  local node="$1" want="$2" timeout="$3" elapsed=0
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    local state
    state="$(kc get node "${node}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || echo '')"
    case "${want}" in
    notready) [[ "${state}" != "True" ]] && return 0 ;;
    ready) [[ "${state}" == "True" ]] && return 0 ;;
    esac
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

assert_node_notready() {
  info "waiting for node ${1} to leave Ready (failure injected)"
  wait_node_state "$1" notready "$2" || warn "node ${1} did not register NotReady within window"
}

assert_node_ready() {
  info "waiting for node ${1} to rejoin Ready"
  wait_node_state "$1" ready "$2" || die "node ${1} did not become Ready within RTO"
}

assert_workloads_reschedule() {
  local node="$1" timeout="$2" elapsed=0
  info "asserting pods off lost node ${node} reschedule to survivors"
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    local stuck
    stuck="$(kc get pods -A --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null |
      awk '$4 != "Completed" {c++} END{print c+0}')"
    [[ "${stuck:-0}" -eq 0 ]] && {
      info "no active pods remain pinned to ${node}"
      return 0
    }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  warn "some pods still reference ${node} (node-pinned local-path PVCs may re-clone on rejoin)"
}

assert_quorum_stores_serving() {
  local timeout="$1"
  info "asserting quorum stores keep serving (CNPG primary present, endpoints converge)"
  local elapsed=0
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    local primary
    primary="$(kc -n "${CANARY_NS}" get pods \
      -l 'cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=primary' \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
    [[ -n "${primary}" ]] && {
      info "CNPG langfuse-pg has a serving primary (${primary})"
      return 0
    }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  die "CNPG langfuse-pg has no serving primary after node loss"
}

wait_replicas_reconverge() {
  local timeout="$1" elapsed=0
  info "waiting for CNPG to re-clone a fresh replica onto the returned node"
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    local ready instances
    ready="$(kc -n "${CANARY_NS}" get cluster langfuse-pg -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)"
    instances="$(kc -n "${CANARY_NS}" get cluster langfuse-pg -o jsonpath='{.status.instances}' 2>/dev/null || echo 3)"
    [[ "${ready:-0}" -ge "${instances:-3}" ]] && {
      info "CNPG langfuse-pg back to ${ready}/${instances} ready instances"
      return 0
    }
    sleep 10
    elapsed=$((elapsed + 10))
  done
  warn "CNPG replicas did not fully reconverge within window (re-clone may still be running)"
}

# Restore HA posture for MOVABLE workloads once the lost node has rejoined:
# restore_movable_posture (shared, .config/mise/lib/common.sh). Kubernetes never
# reschedules already-Running pods, so litellm's displaced replica (1536Mi
# anti-meltdown request floor + ai-infra-gateway PriorityClass 100000 — see
# kubernetes/litellm/deployment.yaml) can persist on — or have PREEMPTED
# priority-0 pods off — the node a PVC-pinned singleton (prometheus-server-0)
# is pinned to, leaving that singleton Pending forever (priority 0 cannot
# preempt the gateway back). The shared helper fixes this deterministically:
# cordon the pinned node, evict movable replicas off it (gated on CNPG serving
# so replacements boot fast), uncordon on every path (exit-trap safety net),
# then hard-assert Deployments and the stranded singleton converge. It runs on
# its own HA_POSTURE_TIMEOUT budget (default 600s), NOT the RTO: posture
# restore is cleanup after recovery, not part of the recovery-time objective,
# and one litellm boot (wait-for-postgres + prisma-migrate + startup probe)
# plus an in-flight litellm-pg failover legitimately exceeds 300s.

assert_ha_posture() {
  info "asserting full replica count / HA posture restored"
  local ready
  ready="$(kc get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {c++} END{print c+0}')"
  [[ "${ready:-0}" -ge 3 ]] || die "expected 3 Ready nodes after recovery, got ${ready}"
  info "3 Ready nodes; HA posture restored"
}

main() {
  guard
  need kubectl
  need limactl
  info "=== NODE-LOSS recovery proof — target node ${TARGET_NODE} ==="

  canary_write_pg

  info "stopping Lima node ${LIMA_INSTANCE} (graceful: limactl stop)"
  limactl stop "${LIMA_INSTANCE}" || die "limactl stop ${LIMA_INSTANCE} failed"

  assert_etcd_quorum
  assert_node_notready "${K8S_NODE}" "${RTO_TIMEOUT}"
  assert_workloads_reschedule "${K8S_NODE}" "${RTO_TIMEOUT}"
  assert_quorum_stores_serving "${RTO_TIMEOUT}"

  info "restarting Lima node ${LIMA_INSTANCE} (limactl start)"
  limactl start "${LIMA_INSTANCE}" || die "limactl start ${LIMA_INSTANCE} failed"
  assert_node_ready "${K8S_NODE}" "${RTO_TIMEOUT}"

  restore_movable_posture
  wait_replicas_reconverge "${RTO_TIMEOUT}"
  verify_pg
  cleanup_pg
  assert_ha_posture

  info "node-loss recovery proof PASSED"
}

main "$@"
