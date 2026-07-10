#!/usr/bin/env bash
#MISE description="Send a test OTLP span/metric and confirm it lands in Tempo/Prometheus."
# .config/mise/tasks/otel/smoke.sh — OTLP trace/log/metric smoke (spec §15.4 / §12.x).
#
# Emits one OTLP trace, one log, and one metric over plain 127.0.0.1:4318 using the
# /v1/{traces,logs,metrics} paths (NO /otel prefix), each tagged with the identity
# taxonomy:
#   deployment.environment=ai-infra-platform-local
#   host.id=mac-local
#   ai.client.name=smoke-test
#   session.id=<generated join key>
#
# Then asserts end-to-end fan-out:
#   - the trace lands in Tempo (queryable by trace id);
#   - the log lands in Loki;
#   - the metric lands in Prometheus (via remote-write).
#
# A second claude-code-tagged trace probe exercises the GenAI-OTTL service.name
# path. The OTel Collector is reached via a loopback port-forward; Tempo/Loki/
# Prometheus are queried through Grafana's datasource proxy (admin cred from fnox,
# never echoed). All access is loopback-only.
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
readonly OTEL_PORT="${OTEL_LOCAL_PORT:-4318}"
readonly OTLP="http://127.0.0.1:${OTEL_LOCAL_PORT:-4318}"
readonly GRAFANA_PORT="${GRAFANA_LOCAL_PORT:-3001}"
readonly GRAFANA="http://127.0.0.1:${GRAFANA_LOCAL_PORT:-3001}"
readonly GRAFANA_USER="${GRAFANA_ADMIN_USER:-admin}"
# fnox addresses secrets by their FLAT key name (see fnox.toml [secrets]);
# there is no slash-path namespace, so this is the bare key, not a path.
readonly GRAFANA_PW_REF="${GRAFANA_ADMIN_PW_REF:-GRAFANA_ADMIN_PASSWORD}"
readonly UID_PROM="PBFA97CFB590B2093"
readonly UID_LOKI="P8E80F9AEF21F6940"
readonly UID_TEMPO="P214B5B846CF3925F"

# Identity taxonomy (spec §3 locked constants).
readonly ENVIRONMENT="ai-infra-platform-local"
readonly HOST_ID="mac-local"
readonly AI_CLIENT="smoke-test"
SESSION_ID="smoke-$(date +%s)-$$"
# 32 hex chars = 16-byte trace id; 16 hex = 8-byte span id. Read raw bytes from
# /dev/urandom via od (POSIX): fixed-length, always-valid hex. The previous
# arithmetic approach concatenated $((RANDOM*RANDOM*RANDOM)) with `date +%N`;
# wherever %N yields real nanoseconds (GNU/uutils date, e.g. the mise-pinned
# toolchain) the decimal exceeds 64-bit and `printf %x` aborts with
# "Result too large" — it only "worked" on stock BSD date where %N is unsupported.
TRACE_ID="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
SPAN_ID="$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
readonly SESSION_ID TRACE_ID SPAN_ID
readonly METRIC_NAME="smoke_test_canary_total"
readonly LOG_BODY="otel-smoke log ${SESSION_ID}"

fail=0
PF_OTEL_PID=""
PF_GRAF_PID=""
GRAFANA_PW=""

cleanup() {
  GRAFANA_PW=""
  local pid
  for pid in "${PF_OTEL_PID}" "${PF_GRAF_PID}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
}
add_exit_trap cleanup

note_fail() {
  err "FAIL: $*"
  fail=1
}

gcurl() { curl -sS -u "${GRAFANA_USER}:${GRAFANA_PW}" "$@"; }

# Nanosecond timestamp (date %N may be missing on macOS BSD date; fall back).
now_nanos() {
  local n
  n="$(date +%s%N 2>/dev/null || echo '')"
  if [[ "${n}" == *N || -z "${n}" ]]; then
    printf '%s000000000' "$(date +%s)"
  else
    printf '%s' "${n}"
  fi
}

start_pf() {
  local target="$1" local_port="$2" remote_port="$3" probe="$4" __pidvar="$5"
  info "port-forward ${target} -n ${NS} -> 127.0.0.1:${local_port} (loopback only)"
  kc -n "${NS}" port-forward --address 127.0.0.1 \
    "${target}" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  local pid=$!
  printf -v "${__pidvar}" '%s' "${pid}"
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "${probe}" 2>/dev/null; then
      return 0
    fi
    kill -0 "${pid}" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

# Shared resource attributes block (OTLP/JSON keyvalue list).
resource_attrs() {
  local svc="$1"
  cat <<JSON
{"key":"service.name","value":{"stringValue":"${svc}"}},
{"key":"deployment.environment","value":{"stringValue":"${ENVIRONMENT}"}},
{"key":"host.id","value":{"stringValue":"${HOST_ID}"}},
{"key":"ai.client.name","value":{"stringValue":"${AI_CLIENT}"}},
{"key":"session.id","value":{"stringValue":"${SESSION_ID}"}}
JSON
}

emit_trace() {
  local svc="$1" trace_id="$2" span_id="$3"
  local start end
  start="$(now_nanos)"
  end="$((start + 1000000))"
  local payload
  payload="$(
    cat <<JSON
{"resourceSpans":[{"resource":{"attributes":[$(resource_attrs "${svc}")]},
"scopeSpans":[{"scope":{"name":"smoke-test"},"spans":[
{"traceId":"${trace_id}","spanId":"${span_id}","name":"otel-smoke-span",
"kind":1,"startTimeUnixNano":"${start}","endTimeUnixNano":"${end}",
"attributes":[{"key":"gen_ai.request.model","value":{"stringValue":"smoke/none"}}]}
]}]}]}
JSON
  )"
  local http
  http="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -X POST "${OTLP}/v1/traces" -d "${payload}" 2>/dev/null || echo 000)"
  if [[ "${http}" == "200" ]]; then
    info "emitted trace (service.name=${svc}, traceId=${trace_id}) -> /v1/traces (http 200)"
  else
    note_fail "trace emit to /v1/traces failed (http ${http})"
  fi
}

emit_log() {
  local ts
  ts="$(now_nanos)"
  local payload
  payload="$(
    cat <<JSON
{"resourceLogs":[{"resource":{"attributes":[$(resource_attrs "smoke-test")]},
"scopeLogs":[{"scope":{"name":"smoke-test"},"logRecords":[
{"timeUnixNano":"${ts}","severityNumber":9,"severityText":"INFO",
"body":{"stringValue":"${LOG_BODY}"},
"attributes":[{"key":"session.id","value":{"stringValue":"${SESSION_ID}"}}]}
]}]}]}
JSON
  )"
  local http
  http="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -X POST "${OTLP}/v1/logs" -d "${payload}" 2>/dev/null || echo 000)"
  if [[ "${http}" == "200" ]]; then
    info "emitted log -> /v1/logs (http 200)"
  else
    note_fail "log emit to /v1/logs failed (http ${http})"
  fi
}

emit_metric() {
  local ts
  ts="$(now_nanos)"
  local payload
  payload="$(
    cat <<JSON
{"resourceMetrics":[{"resource":{"attributes":[$(resource_attrs "smoke-test")]},
"scopeMetrics":[{"scope":{"name":"smoke-test"},"metrics":[
{"name":"${METRIC_NAME}","sum":{"aggregationTemporality":2,"isMonotonic":true,
"dataPoints":[{"asInt":"1","timeUnixNano":"${ts}",
"attributes":[{"key":"session.id","value":{"stringValue":"${SESSION_ID}"}}]}]}}
]}]}]}
JSON
  )"
  local http
  http="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -X POST "${OTLP}/v1/metrics" -d "${payload}" 2>/dev/null || echo 000)"
  if [[ "${http}" == "200" ]]; then
    info "emitted metric ${METRIC_NAME} -> /v1/metrics (http 200)"
  else
    note_fail "metric emit to /v1/metrics failed (http ${http})"
  fi
}

# Poll Grafana datasource proxy until the signal appears (or timeout).
assert_trace_in_tempo() {
  info "asserting trace ${TRACE_ID} landed in Tempo"
  local body
  for _ in $(seq 1 20); do
    body="$(gcurl "${GRAFANA}/api/datasources/proxy/uid/${UID_TEMPO}/api/traces/${TRACE_ID}" 2>/dev/null || echo '')"
    if grep -qE '"traceID"|"batches"|"resourceSpans"' <<<"${body}"; then
      info "trace ${TRACE_ID} found in Tempo"
      return 0
    fi
    sleep 3
  done
  note_fail "trace ${TRACE_ID} did not appear in Tempo within timeout"
}

assert_log_in_loki() {
  info "asserting smoke log landed in Loki"
  local body start end
  for _ in $(seq 1 20); do
    start="$((($(date +%s) - 600) * 1000000000))"
    end="$(($(date +%s) * 1000000000))"
    body="$(gcurl -G "${GRAFANA}/api/datasources/proxy/uid/${UID_LOKI}/loki/api/v1/query_range" \
      --data-urlencode "query={ai_client_name=\"${AI_CLIENT}\"} |= \"${SESSION_ID}\"" \
      --data-urlencode "start=${start}" --data-urlencode "end=${end}" \
      --data-urlencode "limit=5" 2>/dev/null || echo '')"
    if grep -q "${SESSION_ID}" <<<"${body}"; then
      info "log with session.id=${SESSION_ID} found in Loki"
      return 0
    fi
    sleep 3
  done
  note_fail "smoke log did not appear in Loki within timeout"
}

assert_metric_in_prometheus() {
  info "asserting metric ${METRIC_NAME} landed in Prometheus (via remote-write)"
  local body
  for _ in $(seq 1 20); do
    # Prometheus served under the /prometheus route-prefix; the Grafana proxy URL
    # already points at .../prometheus, so query api path is api/v1/query.
    body="$(gcurl -G "${GRAFANA}/api/datasources/proxy/uid/${UID_PROM}/api/v1/query" \
      --data-urlencode "query=${METRIC_NAME}" 2>/dev/null || echo '')"
    if grep -qE '"result"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{' <<<"${body}"; then
      info "metric ${METRIC_NAME} present in Prometheus"
      return 0
    fi
    sleep 3
  done
  note_fail "metric ${METRIC_NAME} did not appear in Prometheus within timeout"
}

main() {
  need kubectl
  need curl

  # Loopback forward to the in-cluster OTel Collector OTLP/HTTP receiver.
  if ! start_pf "svc/otel-collector" "${OTEL_PORT}" 4318 \
    "${OTLP}/v1/traces" PF_OTEL_PID; then
    # The receiver may reject a bare GET probe; verify the forward is alive anyway.
    if [[ -z "${PF_OTEL_PID}" ]] || ! kill -0 "${PF_OTEL_PID}" 2>/dev/null; then
      die "could not establish loopback port-forward to svc/otel-collector"
    fi
    warn "OTLP receiver did not answer GET probe (expected for POST-only endpoint); continuing"
  fi

  # Emit the primary (smoke-test) trace, plus a claude-code-tagged probe to
  # exercise the GenAI-OTTL service.name==claude-code path.
  emit_trace "smoke-test" "${TRACE_ID}" "${SPAN_ID}"
  local claude_trace claude_span
  claude_trace="$(printf '%032x' "$((RANDOM * RANDOM * RANDOM))$$" | tail -c 32)"
  claude_span="$(printf '%016x' "$((RANDOM * RANDOM))$$" | tail -c 16)"
  emit_trace "claude-code" "${claude_trace}" "${claude_span}"
  emit_log
  emit_metric

  # Query side requires Grafana (datasource proxy). Resolve admin cred from fnox.
  # fnox.toml now lives at the repo ROOT, so fnox_decrypt resolves the store via
  # walk-up from the task CWD — no `cd secrets` needed.
  if ! GRAFANA_PW="$(fnox_decrypt "${GRAFANA_PW_REF}")" || [[ -z "${GRAFANA_PW}" ]]; then
    die "could not resolve the Grafana admin password from fnox (${GRAFANA_PW_REF})"
  fi
  if ! start_pf "svc/grafana" "${GRAFANA_PORT}" 3000 \
    "${GRAFANA}/api/health" PF_GRAF_PID; then
    die "could not establish loopback port-forward to svc/grafana"
  fi

  assert_trace_in_tempo
  assert_log_in_loki
  assert_metric_in_prometheus

  if [[ "${fail}" -ne 0 ]]; then
    die "otel smoke FAILED — see failures above"
  fi
  info "otel smoke PASSED (trace/log/metric fanned out to Tempo/Loki/Prometheus)"
}

main "$@"
