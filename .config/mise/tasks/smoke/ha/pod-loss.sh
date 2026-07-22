#!/usr/bin/env bash
#MISE description="Delete a primary pod and verify failover + continued service."
# .config/mise/tasks/smoke/ha/pod-loss.sh — destructive pod-loss recovery proof (spec §15.6).
#
# For each target class, write a canary, delete a pod (kubectl delete pod), and
# assert the controller recreates it and the data/service recovers WITHOUT
# corruption — never dropping a quorum store below quorum (one member at a time):
#   - stateless/app pods (Langfuse web/worker, LiteLLM, Grafana): Service stays
#     served by the surviving replica; recreated pod rejoins;
#   - stateful pods (CNPG standby + primary, ClickHouse replica, Keeper, Valkey,
#     SeaweedFS): quorum-preserving recovery, correct PVC re-attach (or re-clone
#     where node-pinned), post-recovery fingerprint match.
#
# GATED behind AI_INFRA_ALLOW_DESTRUCTIVE=1. Restores after. No secrets echoed.
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

readonly RTO_TIMEOUT="${HA_RTO_TIMEOUT:-300}"
# langfuse web/worker have a documented ~10-min cold start (Prisma + 34 ClickHouse
# ON CLUSTER migrations + ~4 min app init) — the platform gives them a 1200s
# startupProbe budget (kubernetes/langfuse/patches/startup-probe-web.yaml). A deleted
# langfuse pod re-runs the (idempotent, so fast) migrations + the full app init, which
# routinely exceeds the generic 300s RTO under HA-chaos memory pressure. Give ONLY
# these two components their own readiness budget; everything else stays at RTO_TIMEOUT
# so a genuine slow-recovery regression in a fast component still fails the phase.
readonly LANGFUSE_RTO="${HA_LANGFUSE_RTO:-900}"
# litellm's boot chain (wait-for-postgres init + prisma-migrate + app init) carries a
# declared 1200s startupProbe budget (kubernetes/litellm/deployment.yaml, 120x10s), so
# holding its pod-loss recovery to the generic 300s would contradict the platform's own
# recovery envelope. Same reasoning as LANGFUSE_RTO; normal boots finish in minutes.
readonly LITELLM_RTO="${HA_LITELLM_RTO:-900}"
readonly DATA_NS="langfuse-data"
CANARY_TAG="ha-pod-$(date +%s)"
readonly CANARY_TAG
FP_PG=""
# CNPG bootstraps this cluster's application DB under a non-default name
# (spec.bootstrap.initdb.database); resolve it once, lazily, instead of assuming `app`.
CANARY_DB=""
canary_db() {
  [[ -n "${CANARY_DB}" ]] || CANARY_DB="$(cnpg_app_db "${DATA_NS}" langfuse-pg)"
  printf '%s\n' "${CANARY_DB}"
}
fail=0

guard() {
  if [[ "${AI_INFRA_ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    die "refusing to run: DESTRUCTIVE test. Set AI_INFRA_ALLOW_DESTRUCTIVE=1 to proceed."
  fi
}
note_fail() {
  err "FAIL: $*"
  fail=1
}

pg_primary() {
  kc -n "${DATA_NS}" get pods \
    -l 'cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=primary' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ''
}

canary_write_pg() {
  info "writing Postgres canary (tag ${CANARY_TAG})"
  local primary
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] || die "no langfuse-pg primary pod"
  kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c \
    "CREATE TABLE IF NOT EXISTS ha_canary(tag text primary key, ts timestamptz default now());
     INSERT INTO ha_canary(tag) VALUES ('${CANARY_TAG}') ON CONFLICT DO NOTHING;" >/dev/null ||
    die "Postgres canary write failed"
  FP_PG="$(kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "SELECT md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
  [[ -n "${FP_PG}" ]] || die "could not snapshot Postgres fingerprint"
}

# After the CNPG primary pod is deleted, failover is not instantaneous: the old
# primary lingers in Terminating while the operator promotes a standby, so a single
# sample can momentarily see zero pods labelled instanceRole=primary. Wait (bounded
# by RTO) for BOTH a freshly promoted primary AND the operator to report the cluster
# healthy again. This does NOT weaken the assertion — if no primary appears and the
# cluster is not healthy within the RTO it still fails. Prints the primary on stdout.
wait_pg_primary_healthy() {
  local elapsed=0 primary phase
  info "waiting for CNPG failover to complete (new primary + healthy cluster, RTO ${RTO_TIMEOUT}s)"
  while [[ "${elapsed}" -lt "${RTO_TIMEOUT}" ]]; do
    primary="$(pg_primary)"
    phase="$(kc -n "${DATA_NS}" get cluster langfuse-pg \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    if [[ -n "${primary}" && "${phase}" == "Cluster in healthy state" ]]; then
      info "CNPG langfuse-pg failed over: primary ${primary}, cluster healthy"
      printf '%s\n' "${primary}"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

verify_pg() {
  local primary fp
  if ! primary="$(wait_pg_primary_healthy)"; then
    note_fail "no langfuse-pg primary after pod loss (failover did not complete within RTO)"
    return
  fi
  fp="$(kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "SELECT md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
  if [[ "${fp}" == "${FP_PG}" ]]; then
    info "Postgres canary fingerprint matches after pod loss"
  else
    note_fail "Postgres canary fingerprint MISMATCH after pod loss"
  fi
}

cleanup_pg() {
  local primary
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] || return 0
  kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "DELETE FROM ha_canary WHERE tag='${CANARY_TAG}';" >/dev/null 2>&1 || true
}

# --- Recovery wait (race-free) ---------------------------------------------------
# `kubectl wait --for=condition=Ready` is the WRONG primitive right after a pod
# delete: the just-deleted pod still matches the label selector (and, for
# StatefulSets, the pod name) while it terminates. If its Ready condition has not
# flipped yet, the wait returns immediately (a VACUOUS pass asserting nothing about
# the replacement — observed as 0-1s "recreated and Ready" claims for CNPG members);
# once kubelet marks it NotReady, the watch instead errors the moment the object is
# deleted (a SPURIOUS fail long before the deadline — observed 19-41s into a 300s
# budget, mislabeled as an RTO timeout, on the 2026-07-10 fresh-cluster runs).
# Poll instead until (a) the deleted incarnation's UID is gone from the selector
# set, (b) the controller restored the pre-delete count of non-terminating pods,
# and (c) every one of them is Ready — bounded by the same deadline, so a genuine
# non-recovery still fails the phase.

# _pods_state <ns> <selector> — one line per matching pod:
#   "<uid> <phase> <T|-> <Ready-status|''>"   (T = deletionTimestamp set)
_pods_state() {
  local ns="$1" selector="$2"
  kc -n "${ns}" get pods -l "${selector}" -o go-template='{{range .items}}{{.metadata.uid}} {{.status.phase}} {{if .metadata.deletionTimestamp}}T{{else}}-{{end}} {{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{end}}{{end}}{{"\n"}}{{end}}' 2>/dev/null || true
}

# _live_ready_counts <old_uid> — reads _pods_state lines on stdin; prints
# "<live> <ready> <old_seen>". "Live" = not terminating and not Succeeded/Failed
# (completed Job pods share app labels in some namespaces and must not count).
_live_ready_counts() {
  local old_uid="$1" uid phase term ready live=0 ok=0 old_seen=0
  while read -r uid phase term ready; do
    [[ -n "${uid}" ]] || continue
    if [[ -n "${old_uid}" && "${uid}" == "${old_uid}" ]]; then
      old_seen=1
    fi
    [[ "${term}" == "-" ]] || continue
    case "${phase}" in Succeeded | Failed) continue ;; esac
    live=$((live + 1))
    if [[ "${ready}" == "True" ]]; then
      ok=$((ok + 1))
    fi
  done
  printf '%s %s %s\n' "${live}" "${ok}" "${old_seen}"
}

# wait_pods_recovered <ns> <selector> <old_uid> <want> <deadline_s> <label>
wait_pods_recovered() {
  local ns="$1" selector="$2" old_uid="$3" want="$4" deadline="$5" label="$6"
  local elapsed=0 live ready old_seen
  while :; do
    read -r live ready old_seen < <(_pods_state "${ns}" "${selector}" | _live_ready_counts "${old_uid}")
    if [[ "${old_seen}" -eq 0 && "${live}" -ge "${want}" && "${ready}" -eq "${live}" ]]; then
      return 0
    fi
    if [[ "${elapsed}" -ge "${deadline}" ]]; then
      err "${label}: recovery state after ${deadline}s: live=${live}/${want} ready=${ready} deleted-pod-still-present=${old_seen}"
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

# Delete one replica of a stateless/app component and assert the controller
# restores the full pre-delete Ready replica count (Service stays served by the
# surviving replica(s) meanwhile).
delete_pod_zero_downtime() {
  local ns="$1" selector="$2" label="$3" timeout="${4:-${RTO_TIMEOUT}}"
  local pod uid want
  pod="$(kc -n "${ns}" get pods -l "${selector}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
  if [[ -z "${pod}" ]]; then
    warn "${label}: no Running pod matched selector '${selector}' (component may not be deployed) — skipping"
    return 0
  fi
  uid="$(kc -n "${ns}" get pod "${pod}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo '')"
  read -r want _ _ < <(_pods_state "${ns}" "${selector}" | _live_ready_counts '')
  info "${label}: deleting pod ${pod} (Service must stay served by surviving replica)"
  kc -n "${ns}" delete pod "${pod}" --wait=false >/dev/null 2>&1 ||
    note_fail "${label}: delete pod failed"
  if ! wait_pods_recovered "${ns}" "${selector}" "${uid}" "${want}" "${timeout}" "${label}"; then
    note_fail "${label}: controller did not restore ${want} Ready replica(s) within ${timeout}s"
  else
    info "${label}: controller recreated pod; ${want}/${want} replicas Ready"
  fi
}

# Delete one quorum member at a time and assert quorum is preserved: the deleted
# incarnation is gone and the full pre-delete member count is back Ready
# (StatefulSet recreates with the SAME PVC/ordinal; CNPG may re-clone under a new
# instance name — both satisfy the selector-count assertion).
delete_stateful_member() {
  local ns="$1" selector="$2" label="$3"
  local pod uid want
  pod="$(kc -n "${ns}" get pods -l "${selector}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
  if [[ -z "${pod}" ]]; then
    warn "${label}: no Running pod matched '${selector}' — skipping"
    return 0
  fi
  uid="$(kc -n "${ns}" get pod "${pod}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo '')"
  read -r want _ _ < <(_pods_state "${ns}" "${selector}" | _live_ready_counts '')
  info "${label}: deleting one member ${pod} (must not drop below quorum)"
  kc -n "${ns}" delete pod "${pod}" --wait=false >/dev/null 2>&1 ||
    note_fail "${label}: delete failed"
  if ! wait_pods_recovered "${ns}" "${selector}" "${uid}" "${want}" "${RTO_TIMEOUT}" "${label}"; then
    note_fail "${label}: quorum not restored (${want} Ready members) within ${RTO_TIMEOUT}s"
  else
    info "${label}: member recreated; ${want}/${want} members Ready (quorum preserved)"
  fi
}

main() {
  guard
  need kubectl
  info "=== POD-LOSS recovery proof ==="

  canary_write_pg

  # --- Stateless / app pods ---
  # langfuse web/worker get the longer cold-start budget (see LANGFUSE_RTO note above).
  delete_pod_zero_downtime "langfuse" "app=web" "Langfuse web" "${LANGFUSE_RTO}"
  delete_pod_zero_downtime "langfuse" "app=worker" "Langfuse worker" "${LANGFUSE_RTO}"
  # component=gateway excludes the Completed key-provisioner Job pods, which share
  # app.kubernetes.io/name=litellm (the old `app=litellm` selector matched nothing
  # and silently skipped this target).
  delete_pod_zero_downtime "litellm" \
    "app.kubernetes.io/name=litellm,app.kubernetes.io/component=gateway" "LiteLLM" "${LITELLM_RTO}"
  delete_pod_zero_downtime "lgtm" "app.kubernetes.io/name=grafana" "Grafana"

  # --- Stateful pods (one quorum member at a time) ---
  delete_stateful_member "${DATA_NS}" \
    "cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=replica" "CNPG standby"
  # Then the primary (CNPG promotes a standby).
  delete_stateful_member "${DATA_NS}" \
    "cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=primary" "CNPG primary"
  delete_stateful_member "${DATA_NS}" \
    "clickhouse.altinity.com/chi=langfuse-ch" "ClickHouse replica"
  # Altinity CHK pods carry clickhouse-keeper.altinity.com/* labels, not
  # app.kubernetes.io/name (the old selector matched nothing and silently skipped).
  delete_stateful_member "${DATA_NS}" \
    "clickhouse-keeper.altinity.com/chk=langfuse-keeper" "ClickHouse Keeper"
  # The valkey-io chart labels no component=primary; all 3 members (1 primary +
  # 2 replicas) live in one StatefulSet under the release-instance label.
  delete_stateful_member "${DATA_NS}" \
    "app.kubernetes.io/name=valkey,app.kubernetes.io/instance=langfuse-valkey" "Valkey member"
  delete_stateful_member "${DATA_NS}" \
    "app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=master" "SeaweedFS master"
  delete_stateful_member "${DATA_NS}" \
    "app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=volume" "SeaweedFS volume"

  # --- Observability pods ---
  delete_pod_zero_downtime "lgtm" "app.kubernetes.io/component=write" "Loki write"
  delete_stateful_member "lgtm" "app.kubernetes.io/name=tempo" "Tempo"
  delete_stateful_member "lgtm" "app.kubernetes.io/name=prometheus" "Prometheus"
  delete_pod_zero_downtime "lgtm" "app.kubernetes.io/name=opentelemetry-collector" "OTel Collector"

  # Post-recovery consistency.
  verify_pg
  cleanup_pg

  if [[ "${fail}" -ne 0 ]]; then
    die "pod-loss recovery proof FAILED — see failures above"
  fi
  info "pod-loss recovery proof PASSED"
}

main "$@"
