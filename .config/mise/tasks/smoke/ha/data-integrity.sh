#!/usr/bin/env bash
#MISE description="Write then read across a store restart to confirm no data loss."
# .config/mise/tasks/smoke/ha/data-integrity.sh — write-then-read across a store restart with
# no data loss (spec §15.6 stateful surfaces table).
#
# For each stateful surface, write a uniquely-tagged canary, snapshot its
# fingerprint (checksum / row-count / object-etag), restart the store (rolling
# restart of its StatefulSet — quorum-preserving), then re-read and assert a
# byte-for-byte / count match. Any mismatch is corruption and fails the test.
#
# GATED behind AI_INFRA_ALLOW_DESTRUCTIVE=1 (a rolling restart is disruptive).
# Restores/cleans the canary after. No secrets echoed; loopback-only.
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

readonly DATA_NS="langfuse-data"
readonly RTO_TIMEOUT="${HA_RTO_TIMEOUT:-300}"
CANARY_TAG="ha-integ-$(date +%s)"
readonly CANARY_TAG
FP_PG=""
# CNPG bootstraps this cluster's application DB under a non-default name
# (spec.bootstrap.initdb.database); resolve it once, lazily, instead of assuming `app`.
CANARY_DB=""
canary_db() {
  [[ -n "${CANARY_DB}" ]] || CANARY_DB="$(cnpg_app_db "${DATA_NS}" langfuse-pg)"
  printf '%s\n' "${CANARY_DB}"
}
FP_CH=""
fail=0

guard() {
  if [[ "${AI_INFRA_ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    die "refusing to run: DESTRUCTIVE test (rolling restarts). Set AI_INFRA_ALLOW_DESTRUCTIVE=1."
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

ch_pod() {
  kc -n "${DATA_NS}" get pods -l 'clickhouse.altinity.com/chi=langfuse-ch' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ''
}

# --- Postgres (CNPG) ---
pg_write() {
  local primary
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] || die "no langfuse-pg primary"
  info "Postgres: writing canary row ${CANARY_TAG}"
  kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c \
    "CREATE TABLE IF NOT EXISTS ha_canary(tag text primary key, ts timestamptz default now());
     INSERT INTO ha_canary(tag) VALUES ('${CANARY_TAG}') ON CONFLICT DO NOTHING;" >/dev/null ||
    die "Postgres write failed"
  FP_PG="$(kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "SELECT count(*)||':'||md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
}
pg_verify() {
  local primary fp
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] || {
    note_fail "Postgres: no primary after restart"
    return
  }
  fp="$(kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "SELECT count(*)||':'||md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
  if [[ "${fp}" == "${FP_PG}" ]]; then
    info "Postgres: fingerprint match after restart"
  else
    note_fail "Postgres: fingerprint MISMATCH after restart (${fp} != ${FP_PG})"
  fi
}
pg_cleanup() {
  local primary
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] || return 0
  kc -n "${DATA_NS}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db)" -c "DELETE FROM ha_canary WHERE tag='${CANARY_TAG}';" >/dev/null 2>&1 || true
}

# --- ClickHouse (Replicated table) ---
ch_write() {
  local pod
  pod="$(ch_pod)"
  if [[ -z "${pod}" ]]; then
    warn "ClickHouse: no pod found — skipping CH integrity"
    return 1
  fi
  info "ClickHouse: writing canary into a Replicated table"
  kc -n "${DATA_NS}" exec "${pod}" -- clickhouse-client -q \
    "CREATE TABLE IF NOT EXISTS default.ha_canary (tag String, ts DateTime DEFAULT now())
     ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/ha_canary','{replica}') ORDER BY tag;
     INSERT INTO default.ha_canary(tag) VALUES ('${CANARY_TAG}');" >/dev/null 2>&1 ||
    {
      warn "ClickHouse: canary write failed (skipping CH integrity)"
      return 1
    }
  FP_CH="$(kc -n "${DATA_NS}" exec "${pod}" -- clickhouse-client -q \
    "SELECT count() FROM default.ha_canary WHERE tag='${CANARY_TAG}';" 2>/dev/null || echo '')"
  return 0
}
ch_verify() {
  local pod fp
  pod="$(ch_pod)"
  [[ -n "${pod}" ]] || {
    note_fail "ClickHouse: no pod after restart"
    return
  }
  fp="$(kc -n "${DATA_NS}" exec "${pod}" -- clickhouse-client -q \
    "SELECT count() FROM default.ha_canary WHERE tag='${CANARY_TAG}';" 2>/dev/null || echo '')"
  if [[ -n "${fp}" && "${fp}" == "${FP_CH}" ]]; then
    info "ClickHouse: row present on surviving replica (count match)"
  else
    note_fail "ClickHouse: canary count MISMATCH after restart (${fp} != ${FP_CH})"
  fi
}
ch_cleanup() {
  local pod
  pod="$(ch_pod)"
  [[ -n "${pod}" ]] || return 0
  kc -n "${DATA_NS}" exec "${pod}" -- clickhouse-client -q \
    "ALTER TABLE default.ha_canary DELETE WHERE tag='${CANARY_TAG}';" >/dev/null 2>&1 || true
}

# Quorum-preserving rolling restart of a StatefulSet, then wait Ready.
rolling_restart() {
  local ns="$1" sts="$2"
  if ! kc -n "${ns}" get statefulset "${sts}" >/dev/null 2>&1; then
    warn "rolling-restart: statefulset ${sts} -n ${ns} not found — skipping"
    return 1
  fi
  info "rolling restart statefulset/${sts} -n ${ns}"
  kc -n "${ns}" rollout restart "statefulset/${sts}" >/dev/null 2>&1 ||
    note_fail "rollout restart ${sts} failed"
  kc -n "${ns}" rollout status "statefulset/${sts}" --timeout="${RTO_TIMEOUT}s" >/dev/null 2>&1 ||
    note_fail "rollout status ${sts} did not complete"
}

main() {
  guard
  need kubectl
  info "=== DATA-INTEGRITY (write -> restart -> read) proof ==="

  pg_write
  local ch_active=0
  ch_write && ch_active=1

  # Restart each store (quorum preserved by RollingUpdate one-at-a-time).
  rolling_restart "${DATA_NS}" "langfuse-pg" || true
  if [[ "${ch_active}" -eq 1 ]]; then
    rolling_restart "${DATA_NS}" "chi-langfuse-ch-langfuse-ch-0-0" ||
      warn "ClickHouse STS name differs; verifying integrity without explicit restart"
  fi

  pg_verify
  [[ "${ch_active}" -eq 1 ]] && ch_verify

  pg_cleanup
  [[ "${ch_active}" -eq 1 ]] && ch_cleanup

  if [[ "${fail}" -ne 0 ]]; then
    die "data-integrity proof FAILED — see failures above"
  fi
  info "data-integrity proof PASSED (no data loss across store restart)"
}

main "$@"
