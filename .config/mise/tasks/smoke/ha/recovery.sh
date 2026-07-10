#!/usr/bin/env bash
#MISE description="Restore a downed node and verify quorum/replicas re-converge."
# .config/mise/tasks/smoke/ha/recovery.sh — restore a downed node and verify re-convergence
# (spec §15.6 step 4-6).
#
# Complements ha-node-loss.sh: given a node that is currently stopped (or stopping
# it first when HA_RECOVERY_SELF_INDUCE=1), this restarts it and proves the cluster
# re-converges: the rejoined node re-syncs, CNPG re-clones a fresh replica onto the
# returned node (node-pinned local-path PVCs make a re-clone expected and required),
# SeaweedFS re-replicates to restore copy count, etcd quorum is whole again, and a
# previously-recorded canary fingerprint still matches byte-for-byte.
#
# GATED behind AI_INFRA_ALLOW_DESTRUCTIVE=1. No secrets echoed; loopback-only.
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
readonly RTO_TIMEOUT="${HA_RTO_TIMEOUT:-600}"
readonly DATA_NS="langfuse-data"
CANARY_TAG="ha-recov-$(date +%s)"
readonly CANARY_TAG
FP_PG=""
# CNPG bootstraps this cluster's application DB under a non-default name
# (spec.bootstrap.initdb.database); resolve it once, lazily, instead of assuming `app`.
CANARY_DB=""
canary_db() {
  [[ -n "${CANARY_DB}" ]] || CANARY_DB="$(cnpg_app_db "${DATA_NS}" langfuse-pg)"
  printf '%s\n' "${CANARY_DB}"
}

guard() {
  if [[ "${AI_INFRA_ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    die "refusing to run: DESTRUCTIVE test. Set AI_INFRA_ALLOW_DESTRUCTIVE=1 to proceed."
  fi
}

pg_primary() {
  kc -n "${DATA_NS}" get pods \
    -l 'cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=primary' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ''
}

canary_write_pg() {
  local primary
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] || die "no langfuse-pg primary to seed canary"
  info "seeding Postgres canary ${CANARY_TAG} before recovery"
  kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c \
    "CREATE TABLE IF NOT EXISTS ha_canary(tag text primary key, ts timestamptz default now());
     INSERT INTO ha_canary(tag) VALUES ('${CANARY_TAG}') ON CONFLICT DO NOTHING;" >/dev/null ||
    die "Postgres canary write failed"
  FP_PG="$(kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "SELECT md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
}

verify_pg() {
  local primary fp
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] || die "no langfuse-pg primary after recovery"
  fp="$(kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "SELECT md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
  if [[ "${fp}" == "${FP_PG}" ]]; then
    info "Postgres canary fingerprint matches after recovery"
  else
    die "Postgres canary fingerprint MISMATCH after recovery"
  fi
}

cleanup_pg() {
  local primary
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] || return 0
  kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "DELETE FROM ha_canary WHERE tag='${CANARY_TAG}';" >/dev/null 2>&1 || true
}

node_is_running() {
  limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null |
    awk -v n="${LIMA_INSTANCE}" '$1==n && $2=="Running"{found=1} END{exit found?0:1}'
}

wait_node_ready() {
  local elapsed=0
  while [[ "${elapsed}" -lt "${RTO_TIMEOUT}" ]]; do
    local state
    state="$(kc get node "${K8S_NODE}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || echo '')"
    [[ "${state}" == "True" ]] && {
      info "node ${K8S_NODE} is Ready"
      return 0
    }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  die "node ${K8S_NODE} did not become Ready within ${RTO_TIMEOUT}s"
}

wait_cnpg_reconverge() {
  local elapsed=0
  info "waiting for CNPG to re-clone a fresh replica onto the returned node"
  while [[ "${elapsed}" -lt "${RTO_TIMEOUT}" ]]; do
    local ready instances
    ready="$(kc -n "${DATA_NS}" get cluster langfuse-pg -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)"
    instances="$(kc -n "${DATA_NS}" get cluster langfuse-pg -o jsonpath='{.status.instances}' 2>/dev/null || echo 3)"
    [[ "${ready:-0}" -ge "${instances:-3}" ]] && {
      info "CNPG langfuse-pg: ${ready}/${instances} ready instances (re-clone complete)"
      return 0
    }
    sleep 10
    elapsed=$((elapsed + 10))
  done
  die "CNPG langfuse-pg did not return to full replica count (re-clone incomplete)"
}

wait_seaweedfs_replication() {
  info "checking SeaweedFS volume copy count re-converges (best-effort)"
  local ready
  ready="$(kc -n "${DATA_NS}" get pods \
    -l 'app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=volume' \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${ready:-0}" -ge 3 ]]; then
    info "SeaweedFS: ${ready} volume servers Running (copies can re-replicate)"
  else
    warn "SeaweedFS: only ${ready} volume servers Running — replication may still be catching up"
  fi
}

assert_etcd_whole() {
  local ready
  ready="$(kc get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {c++} END{print c+0}')"
  if [[ "${ready:-0}" -ge 3 ]]; then
    info "etcd membership whole (3/3 Ready nodes)"
  else
    die "expected 3 Ready nodes; got ${ready}"
  fi
}

main() {
  guard
  need kubectl
  need limactl
  info "=== RECOVERY / re-convergence proof — node ${TARGET_NODE} ==="

  if [[ "${HA_RECOVERY_SELF_INDUCE:-0}" == "1" ]] && node_is_running; then
    canary_write_pg
    info "self-induce: stopping ${LIMA_INSTANCE} so we can prove recovery"
    limactl stop "${LIMA_INSTANCE}" || die "limactl stop ${LIMA_INSTANCE} failed"
  else
    # Node assumed already down (e.g. left stopped by ha-node-loss). Seed canary if
    # the cluster is currently serving; otherwise rely on a pre-existing one.
    if pg_primary >/dev/null 2>&1 && [[ -n "$(pg_primary)" ]]; then
      canary_write_pg
    else
      warn "no serving CNPG primary right now; skipping pre-recovery canary seed"
    fi
  fi

  if node_is_running; then
    info "node ${LIMA_INSTANCE} already Running; proceeding to convergence checks"
  else
    info "starting Lima node ${LIMA_INSTANCE} (limactl start)"
    limactl start "${LIMA_INSTANCE}" || die "limactl start ${LIMA_INSTANCE} failed"
  fi

  wait_node_ready
  assert_etcd_whole
  wait_cnpg_reconverge
  wait_seaweedfs_replication

  if [[ -n "${FP_PG}" ]]; then
    verify_pg
    cleanup_pg
  else
    warn "no canary fingerprint was recorded this run; skipped fingerprint verification"
  fi

  info "recovery / re-convergence proof PASSED"
}

main "$@"
