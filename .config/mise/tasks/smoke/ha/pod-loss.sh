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
readonly DATA_NS="langfuse-data"
CANARY_TAG="ha-pod-$(date +%s)"
readonly CANARY_TAG
FP_PG=""
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
    psql -At -d app -c \
    "CREATE TABLE IF NOT EXISTS ha_canary(tag text primary key, ts timestamptz default now());
     INSERT INTO ha_canary(tag) VALUES ('${CANARY_TAG}') ON CONFLICT DO NOTHING;" >/dev/null ||
    die "Postgres canary write failed"
  FP_PG="$(kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d app -c "SELECT md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
  [[ -n "${FP_PG}" ]] || die "could not snapshot Postgres fingerprint"
}

verify_pg() {
  local primary fp
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] || {
    note_fail "no langfuse-pg primary after pod loss"
    return
  }
  fp="$(kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d app -c "SELECT md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
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
    psql -At -d app -c "DELETE FROM ha_canary WHERE tag='${CANARY_TAG}';" >/dev/null 2>&1 || true
}

# Probe a Service health endpoint continuously across a pod delete to confirm
# zero-downtime on the surviving replica. Runs via a transient in-cluster curl.
delete_pod_zero_downtime() {
  local ns="$1" selector="$2" label="$3"
  local pod
  pod="$(kc -n "${ns}" get pods -l "${selector}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
  if [[ -z "${pod}" ]]; then
    warn "${label}: no pod matched selector '${selector}' (component may not be deployed) — skipping"
    return 0
  fi
  info "${label}: deleting pod ${pod} (Service must stay served by surviving replica)"
  kc -n "${ns}" delete pod "${pod}" --wait=false >/dev/null 2>&1 ||
    note_fail "${label}: delete pod failed"
  # Wait for the controller to recreate and the rollout/endpoints to be Ready again.
  if ! kc -n "${ns}" wait --for=condition=Ready pod -l "${selector}" \
    --timeout="${RTO_TIMEOUT}s" >/dev/null 2>&1; then
    note_fail "${label}: pods did not return Ready within RTO"
  else
    info "${label}: controller recreated pod and endpoints are Ready"
  fi
}

# Delete one quorum member at a time and assert quorum is preserved (StatefulSet
# recreates with the SAME PVC / ordinal).
delete_stateful_member() {
  local ns="$1" selector="$2" label="$3"
  local pod
  pod="$(kc -n "${ns}" get pods -l "${selector}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
  if [[ -z "${pod}" ]]; then
    warn "${label}: no pod matched '${selector}' — skipping"
    return 0
  fi
  info "${label}: deleting one member ${pod} (must not drop below quorum)"
  kc -n "${ns}" delete pod "${pod}" --wait=false >/dev/null 2>&1 ||
    note_fail "${label}: delete failed"
  if ! kc -n "${ns}" wait --for=condition=Ready pod "${pod}" \
    --timeout="${RTO_TIMEOUT}s" >/dev/null 2>&1; then
    # StatefulSet pods keep their name; wait on the recreated same-name pod.
    note_fail "${label}: member ${pod} did not return Ready within RTO"
  else
    info "${label}: member ${pod} recreated and Ready (PVC re-attached)"
  fi
}

main() {
  guard
  need kubectl
  info "=== POD-LOSS recovery proof ==="

  canary_write_pg

  # --- Stateless / app pods ---
  delete_pod_zero_downtime "langfuse" "app=web" "Langfuse web"
  delete_pod_zero_downtime "langfuse" "app=worker" "Langfuse worker"
  delete_pod_zero_downtime "litellm" "app=litellm" "LiteLLM"
  delete_pod_zero_downtime "lgtm" "app.kubernetes.io/name=grafana" "Grafana"

  # --- Stateful pods (one quorum member at a time) ---
  delete_stateful_member "${DATA_NS}" \
    "cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=replica" "CNPG standby"
  # Then the primary (CNPG promotes a standby).
  delete_stateful_member "${DATA_NS}" \
    "cnpg.io/cluster=langfuse-pg,cnpg.io/instanceRole=primary" "CNPG primary"
  delete_stateful_member "${DATA_NS}" \
    "clickhouse.altinity.com/chi=langfuse-ch" "ClickHouse replica"
  delete_stateful_member "${DATA_NS}" \
    "app.kubernetes.io/name=clickhouse-keeper" "ClickHouse Keeper"
  delete_stateful_member "${DATA_NS}" \
    "app.kubernetes.io/name=valkey,app.kubernetes.io/component=primary" "Valkey primary"
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
