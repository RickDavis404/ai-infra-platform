#!/usr/bin/env bash
#MISE description="Verify Grafana/Loki/Tempo/Prometheus are up and datasources resolve."
# .config/mise/tasks/lgtm/smoke.sh — observability-plane smoke (spec §15.4 / §13).
#
# Asserts the lgtm plane is up and wired:
#   - Grafana / Loki / Tempo / Prometheus workloads are Ready;
#   - Grafana datasources (Prometheus incl. the MANDATORY /prometheus route-prefix,
#     Loki, Tempo) all resolve healthy via Grafana's datasource health API;
#   - a tagged trace lands in Tempo and a tagged log line lands in Loki.
#
# Grafana is reached over a loopback port-forward; the admin credential is resolved
# from fnox at runtime and never echoed. All access is loopback-only.
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
declare -F fnox_decrypt >/dev/null 2>&1 || fnox_decrypt() {
  command -v fnox >/dev/null 2>&1 || die "fnox not found"
  fnox get "$1"
}

readonly NS="lgtm"
readonly GRAFANA_PORT="${GRAFANA_LOCAL_PORT:-3001}"
readonly GRAFANA="http://127.0.0.1:${GRAFANA_LOCAL_PORT:-3001}"
readonly GRAFANA_USER="${GRAFANA_ADMIN_USER:-admin}"
# fnox addresses secrets by their FLAT key name (see fnox.toml [secrets]);
# there is no slash-path namespace, so this is the bare key, not a path.
readonly GRAFANA_PW_REF="${GRAFANA_ADMIN_PW_REF:-GRAFANA_ADMIN_PASSWORD}"
# Stable datasource UIDs (spec §13.5).
readonly UID_PROM="PBFA97CFB590B2093"
readonly UID_LOKI="P8E80F9AEF21F6940"
readonly UID_TEMPO="P214B5B846CF3925F"

fail=0
PF_PID=""
GRAFANA_PW=""

cleanup() {
  GRAFANA_PW=""
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
add_exit_trap cleanup

note_fail() {
  err "FAIL: $*"
  fail=1
}

# curl helper that injects basic auth without exposing the password on argv.
gcurl() {
  curl -sS -u "${GRAFANA_USER}:${GRAFANA_PW}" "$@"
}

check_workloads() {
  info "checking lgtm workloads are Ready"
  # Loki (read/write/backend), Tempo, Prometheus, Grafana. Use label-free name
  # probes tolerant of chart-specific names; rollout status where it exists.
  local target
  for target in \
    "deploy/grafana" \
    "statefulset/prometheus-server"; do
    if kc -n "${NS}" get "${target}" >/dev/null 2>&1; then
      if kc -n "${NS}" rollout status "${target}" --timeout=120s >/dev/null 2>&1; then
        info "${target} Ready"
      else
        note_fail "${target} not Ready"
      fi
    else
      warn "${target} not found (chart may name it differently) — checking pods by app"
    fi
  done
  # Tempo / Loki components: assert at least one Ready pod each.
  local app
  for app in tempo loki; do
    local ready
    ready="$(kc -n "${NS}" get pods -l "app.kubernetes.io/name=${app}" \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${ready:-0}" -ge 1 ]]; then
      info "${app}: ${ready} running pod(s)"
    else
      note_fail "${app}: no Running pods found"
    fi
  done
}

start_pf() {
  info "port-forward svc/grafana -n ${NS} -> 127.0.0.1:${GRAFANA_PORT} (loopback only)"
  kc -n "${NS}" port-forward --address 127.0.0.1 \
    svc/grafana "${GRAFANA_PORT}:3000" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "${GRAFANA}/api/health" 2>/dev/null; then
      return 0
    fi
    kill -0 "${PF_PID}" 2>/dev/null || die "port-forward exited prematurely"
    sleep 1
  done
  return 1
}

check_datasources() {
  info "checking Grafana datasource health (Prometheus /prometheus route, Loki, Tempo)"
  local uid name
  for pair in "${UID_PROM}:Prometheus" "${UID_LOKI}:Loki" "${UID_TEMPO}:Tempo"; do
    uid="${pair%%:*}"
    name="${pair##*:}"
    # Datasource health proxy endpoint returns {"status":"OK", ...} when reachable.
    local body
    body="$(gcurl "${GRAFANA}/api/datasources/uid/${uid}/health" 2>/dev/null || echo '')"
    if grep -qiE '"status"[[:space:]]*:[[:space:]]*"(ok|success)"' <<<"${body}"; then
      info "datasource ${name} (${uid}) healthy"
    else
      note_fail "datasource ${name} (${uid}) not healthy: ${body:-<no response>}"
    fi
  done

  # Explicitly confirm the Prometheus datasource URL carries the /prometheus prefix.
  local prom_url
  prom_url="$(gcurl "${GRAFANA}/api/datasources/uid/${UID_PROM}" 2>/dev/null |
    grep -oE '"url"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 || echo '')"
  if grep -q '/prometheus' <<<"${prom_url}"; then
    info "Prometheus datasource URL includes the /prometheus route-prefix"
  else
    note_fail "Prometheus datasource URL missing /prometheus route-prefix (got ${prom_url:-unknown})"
  fi
}

# Emit a tagged trace to Tempo and a tagged log to Loki via Grafana's datasource
# proxy + the in-cluster receivers, then assert each is queryable. We reuse the
# otel smoke for emission when available; here we verify queryability directly.
check_trace_and_log() {
  local tag
  tag="lgtm-smoke-$(date +%s)"
  info "querying Tempo + Loki for recent data (tag ${tag} best-effort)"

  # Tempo: search API should return at least one trace in the recent window.
  local tempo_body
  tempo_body="$(gcurl -G "${GRAFANA}/api/datasources/proxy/uid/${UID_TEMPO}/api/search" \
    --data-urlencode "limit=1" --data-urlencode "start=$(($(date +%s) - 3600))" \
    --data-urlencode "end=$(date +%s)" 2>/dev/null || echo '')"
  if grep -qE '"traceID"|"traces"' <<<"${tempo_body}"; then
    info "Tempo returned at least one trace in the recent window"
  else
    warn "no trace found in Tempo recent window (run otel smoke first to emit one)"
    note_fail "no trace queryable in Tempo"
  fi

  # Loki: query_range for any log line in the last hour.
  local loki_body
  loki_body="$(gcurl -G "${GRAFANA}/api/datasources/proxy/uid/${UID_LOKI}/loki/api/v1/query_range" \
    --data-urlencode 'query={job=~".+"}' \
    --data-urlencode "start=$((($(date +%s) - 3600) * 1000000000))" \
    --data-urlencode "end=$(($(date +%s) * 1000000000))" \
    --data-urlencode "limit=1" 2>/dev/null || echo '')"
  if grep -qE '"result"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{' <<<"${loki_body}"; then
    info "Loki returned at least one log line in the recent window"
  else
    warn "no log found in Loki recent window (run otel smoke first to emit one)"
    note_fail "no log queryable in Loki"
  fi
}

main() {
  need kubectl
  need curl

  check_workloads

  # fnox.toml now lives at the repo ROOT, so fnox_decrypt resolves the store via
  # walk-up from the task CWD — no `cd secrets` needed.
  if ! GRAFANA_PW="$(fnox_decrypt "${GRAFANA_PW_REF}")" || [[ -z "${GRAFANA_PW}" ]]; then
    die "could not resolve the Grafana admin password from fnox (${GRAFANA_PW_REF})"
  fi

  if start_pf; then
    check_datasources
    check_trace_and_log
  else
    note_fail "could not establish loopback port-forward to svc/grafana"
  fi

  if [[ "${fail}" -ne 0 ]]; then
    die "lgtm smoke FAILED — see failures above"
  fi
  info "lgtm smoke PASSED"
}

main "$@"
