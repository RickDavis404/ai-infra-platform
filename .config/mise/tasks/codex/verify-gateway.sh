#!/usr/bin/env bash
#MISE description="end-to-end per-model gateway verification: codex exec canary + LiteLLM spend-log row + Langfuse trace assertions."
# .config/mise/tasks/codex/verify-gateway.sh — per-model gateway verification.
#
# For each model under test (CODEX_VERIFY_MODELS, default the gpt-5.6-* dynamic
# passthrough set) this runs the SAME non-interactive Codex CLI canary shape as
# codex/smoke.sh (run_live_gpt55_smoke) through the LiteLLM gateway VIP, then makes
# two independent downstream assertions that the request actually traversed the
# stack:
#
#   (a) LiteLLM spend log — a `/spend/logs` row whose `model` is `chatgpt/<model>`
#       appeared since the canary started (GET via a loopback port-forward of
#       svc/litellm:4000, authenticated with the in-cluster master key); and
#   (b) Langfuse trace — a trace named like "codex <model>" appears at the Langfuse
#       VIP (ingestion is async, so this polls up to 60s).
#
# Emits a per-model PASS/FAIL line and a final summary table; exits non-zero if any
# model fails any of its three checks. Secrets (codex virtual key, master key,
# Langfuse keys) are captured into locals and never echoed; canary output excerpts
# are passed through the shared redaction filter.
#
# NOTE: this verifies whatever cluster the CURRENT shell env / KUBECONFIG points at
# (the gateway VIP + the port-forwarded svc/litellm). It performs NO mutations.
set -euo pipefail

# Resolve and source the shared helper library defensively.
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

# --- Constants (env-overridable; defaults match conf.d/10-env) -----------------
readonly NS="${LITELLM_NAMESPACE:-litellm}"
readonly LOCAL_PORT="${LITELLM_LOCAL_PORT:-4000}"
readonly BASE="http://127.0.0.1:${LOCAL_PORT}"
readonly LITELLM_VIP="${AI_INFRA_LITELLM_VIP:-192.168.105.200}"
readonly LANGFUSE_VIP="${AI_INFRA_LANGFUSE_VIP:-192.168.105.201}"
# In-cluster Secret carrying the LiteLLM master/admin key (authoritative source used
# by the deployment itself — see kubernetes/litellm/deployment.yaml).
readonly MASTER_KEY_SECRET="${LITELLM_MASTER_KEY_SECRET:-litellm-app-secrets}"
# Models under test — space-separated. Default = the gpt-5.6-* dynamic passthrough set.
readonly VERIFY_MODELS="${CODEX_VERIFY_MODELS:-gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna}"
# Poll budgets (seconds) for the async downstream assertions.
readonly SPEND_TIMEOUT="${CODEX_VERIFY_SPEND_TIMEOUT:-45}"
readonly LANGFUSE_TIMEOUT="${CODEX_VERIFY_LANGFUSE_TIMEOUT:-60}"
readonly POLL_INTERVAL="${CODEX_VERIFY_POLL_INTERVAL:-3}"

# --- Mutable globals (initialized before the cleanup trap is registered) -------
PF_PID=""
TMPROOT=""
CODEX_KEY=""
MASTER_KEY=""
LF_PUBLIC_KEY=""
LF_SECRET_KEY=""
SPEND_START_DATE=""
SPEND_END_DATE=""

cleanup_verify() {
  CODEX_KEY=""
  MASTER_KEY=""
  LF_PUBLIC_KEY=""
  LF_SECRET_KEY=""
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
  if [[ -n "${TMPROOT}" && -d "${TMPROOT}" ]]; then
    rm -rf "${TMPROOT}"
  fi
}
add_exit_trap cleanup_verify

redacted_excerpt() {
  local file="$1"
  if [[ -s "${file}" ]]; then
    ai_infra_redact_log <"${file}" | tail -n 20
  fi
  return 0
}

# _utc_date_shift <bsd-shift> <gnu-spec> <fmt> — print a shifted UTC date, trying
# BSD `date -v` first then GNU `date -d`. Returns non-zero if neither flavor works.
_utc_date_shift() {
  local bsd="$1" gnu="$2" fmt="$3" out
  out="$(date -u -v"${bsd}" "${fmt}" 2>/dev/null)" && {
    printf '%s' "${out}"
    return 0
  }
  out="$(date -u -d "${gnu}" "${fmt}" 2>/dev/null)" && {
    printf '%s' "${out}"
    return 0
  }
  return 1
}

# --- Loopback port-forward to svc/litellm (litellm/smoke.sh start_pf pattern) ---
start_pf() {
  info "port-forward svc/litellm -n ${NS} -> 127.0.0.1:${LOCAL_PORT} (loopback only)"
  # Background kubectl DIRECTLY (inlining the kc wrapper's KUBECONFIG resolution)
  # rather than as a backgrounded `kc` function call: a backgrounded function runs
  # in a subshell, so $! captures that wrapper subshell's PID — not kubectl's — and
  # the exec'd kubectl child survives `kill "${PF_PID}"` as an orphan, leaking the
  # loopback forward past teardown. Backgrounding kubectl here makes $! == kubectl.
  local kubeconfig="${KUBECONFIG:-${REPO_ROOT}/.local/kube/config}"
  KUBECONFIG="${kubeconfig}" kubectl -n "${NS}" port-forward --address 127.0.0.1 \
    svc/litellm "${LOCAL_PORT}:4000" >/dev/null 2>&1 &
  PF_PID=$!
  local _
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "${BASE}/health/liveliness" 2>/dev/null ||
      curl -fsS -o /dev/null "${BASE}/health/readiness" 2>/dev/null; then
      return 0
    fi
    kill -0 "${PF_PID}" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

# --- Live Codex CLI canary (codex/smoke.sh run_live_gpt55_smoke shape) ----------
# run_canary <model> <workdir> — returns 0 iff the model returns exactly `pong`
# through the gateway with no non-benign warning/error diagnostics.
run_canary() {
  local model="$1" work="$2"
  local reply_file stdout_file stderr_file diagnostics_file rc reply_text prompt key
  reply_file="${work}/reply.txt"
  stdout_file="${work}/stdout.txt"
  stderr_file="${work}/stderr.txt"
  diagnostics_file="${work}/diagnostics.txt"
  prompt='Reply with exactly pong. Do not include quotes, punctuation, markdown, or any other text. Do not call tools.'
  key="${CODEX_KEY}"

  info "canary: codex exec ${model} via LiteLLM at low reasoning"
  set +e
  (
    cd "${work}" || exit 1
    codex exec \
      --skip-git-repo-check \
      --ignore-user-config \
      --ignore-rules \
      --ephemeral \
      --sandbox read-only \
      --color never \
      --output-last-message "${reply_file}" \
      --config "model=\"${model}\"" \
      --config 'model_reasoning_effort="low"' \
      --config 'model_provider="litellm_local"' \
      --config 'model_providers.litellm_local.name="LiteLLM Local"' \
      --config "model_providers.litellm_local.base_url=\"http://${LITELLM_VIP}:4000/v1\"" \
      --config 'model_providers.litellm_local.requires_openai_auth=true' \
      --config 'model_providers.litellm_local.wire_api="responses"' \
      --config 'model_providers.litellm_local.supports_websockets=false' \
      --config 'model_providers.litellm_local.stream_idle_timeout_ms=900000' \
      --config "model_providers.litellm_local.http_headers={ \"X-Litellm-Api-Key\" = \"Bearer ${key}\", \"x-litellm-spend-logs-metadata\" = \"{\\\"source\\\":\\\"codex-verify\\\",\\\"host\\\":\\\"$(hostname -s)\\\"}\" }" \
      "${prompt}"
  ) >"${stdout_file}" 2>"${stderr_file}"
  rc=$?
  set -e
  key=""

  if [[ "${rc}" -ne 0 ]]; then
    err "FAIL: canary for ${model} exited ${rc}"
    redacted_excerpt "${stderr_file}" | while IFS= read -r line; do err "codex stderr: ${line}"; done
    redacted_excerpt "${stdout_file}" | while IFS= read -r line; do err "codex stdout: ${line}"; done
    return 1
  fi

  if [[ ! -s "${reply_file}" ]]; then
    err "FAIL: canary for ${model} produced no final response"
    return 1
  fi
  reply_text="$(tr -d '\r' <"${reply_file}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if ! grep -Eiq '(^|[^[:alnum:]_])pong([^[:alnum:]_]|$)' <<<"${reply_text}"; then
    err "FAIL: canary for ${model} response did not contain pong"
    redacted_excerpt "${reply_file}" | while IFS= read -r line; do err "codex reply: ${line}"; done
    return 1
  fi

  cat "${stdout_file}" "${stderr_file}" >"${diagnostics_file}"
  # Codex >=0.144 polls <base_url>/models expecting the codex model-catalog schema
  # ({"models":[...]}); LiteLLM serves the OpenAI list schema ({"data":[...]}), so a
  # "failed to refresh available models" warning is expected and benign through the
  # gateway. Strip ONLY those lines; any other warn/error below must still fail.
  grep -Fv 'failed to refresh available models' "${diagnostics_file}" \
    >"${diagnostics_file}.filtered" || true
  mv "${diagnostics_file}.filtered" "${diagnostics_file}"
  if grep -Eiq '(^|[^[:alpha:]])(warn|warning|err|error|fail|failed|failure|panic|traceback|exception)([^[:alpha:]]|$)' "${diagnostics_file}"; then
    err "FAIL: canary for ${model} emitted warning/error diagnostics"
    redacted_excerpt "${diagnostics_file}" | while IFS= read -r line; do err "codex diagnostic: ${line}"; done
    return 1
  fi

  info "canary PASSED for ${model} (returned pong cleanly)"
  return 0
}

# --- Downstream assertion: LiteLLM spend-log row -------------------------------
# _expected_spend_model <model> — the `model` value LiteLLM records in the
# /spend/logs row for <model>. Normally the verbatim chatgpt/<model>, but the
# proxy rewrites a few codex slugs to a different upstream model before logging:
# gpt-5.3-codex is served as gpt-5.3-codex-spark, so its row reads
# chatgpt/gpt-5.3-codex-spark rather than chatgpt/gpt-5.3-codex. Add further
# rewrites here as the passthrough gains them; everything else stays verbatim.
_expected_spend_model() {
  case "$1" in
  gpt-5.3-codex) printf 'chatgpt/gpt-5.3-codex-spark' ;;
  *) printf 'chatgpt/%s' "$1" ;;
  esac
}

# _check_spend_row <model> <since-compact> — one-shot probe (called under poll_until).
_check_spend_row() {
  local model="$1" since="$2" resp full
  full="$(_expected_spend_model "${model}")"
  resp="$(curl -fsS \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -G "${BASE}/spend/logs" \
    --data-urlencode "start_date=${SPEND_START_DATE}" \
    --data-urlencode "end_date=${SPEND_END_DATE}" \
    --data-urlencode "summarize=false" \
    2>/dev/null || true)"
  [[ -n "${resp}" ]] || return 1
  jq -e --arg m "${full}" --arg since "${since}" '
    (if type == "array" then . else (.data // []) end) as $rows
    | [ $rows[]?
        | select(.model == $m)
        | ((.startTime // .startTimestamp // "") | tostring | sub("Z$"; "") | .[0:19]) as $st
        | select($st == "" or $st >= $since) ]
    | length > 0
  ' <<<"${resp}" >/dev/null 2>&1
}

# --- Downstream assertion: Langfuse trace --------------------------------------
# _check_langfuse_trace <model> <since-iso> — one-shot probe (called under poll_until).
_check_langfuse_trace() {
  local model="$1" since="$2" resp
  resp="$(curl -fsS \
    -u "${LF_PUBLIC_KEY}:${LF_SECRET_KEY}" \
    -G "http://${LANGFUSE_VIP}:3000/api/public/traces" \
    --data-urlencode "fromTimestamp=${since}" \
    --data-urlencode "limit=100" \
    2>/dev/null || true)"
  [[ -n "${resp}" ]] || return 1
  jq -e --arg m "${model}" '
    [ .data[]?
      | (.name // "" | ascii_downcase) as $n
      | select(($n | contains("codex")) and ($n | contains($m | ascii_downcase))) ]
    | length > 0
  ' <<<"${resp}" >/dev/null 2>&1
}

# poll_until <timeout-s> <interval-s> <fn> [args...] — return 0 as soon as <fn>
# succeeds, else 1 after the timeout. <fn> must be side-effect-free on failure.
poll_until() {
  local timeout="$1" interval="$2"
  shift 2
  local deadline
  deadline=$(($(date +%s) + timeout))
  while :; do
    if "$@"; then
      return 0
    fi
    [[ "$(date +%s)" -ge "${deadline}" ]] && return 1
    sleep "${interval}"
  done
}

main() {
  require_cmd codex fnox kubectl curl jq
  [[ -f "${REPO_ROOT}/fnox.local.toml" ]] ||
    die "fnox.local.toml missing at repo root; the canary needs CODEX_LITELLM_VIRTUAL_KEY"

  # Codex proxy-hop virtual key (fnox+age; reused across every model in the run).
  CODEX_KEY="$(fnox_decrypt CODEX_LITELLM_VIRTUAL_KEY)"
  [[ -n "${CODEX_KEY}" ]] || die "CODEX_LITELLM_VIRTUAL_KEY resolved empty"

  # LiteLLM master key — authoritative source is the in-cluster Secret consumed by
  # the deployment itself (jsonpath + base64 -d).
  MASTER_KEY="$(kc -n "${NS}" get secret "${MASTER_KEY_SECRET}" \
    -o jsonpath='{.data.LITELLM_MASTER_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "${MASTER_KEY}" ]] ||
    die "could not read LITELLM_MASTER_KEY from secret ${MASTER_KEY_SECRET} in ns ${NS}"

  # Langfuse project keys — prefer the shell env (exported by conf.d/secret-env on
  # `cd` into the repo); fall back to fnox+age when unset.
  LF_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-$(fnox_decrypt LANGFUSE_PUBLIC_KEY)}"
  LF_SECRET_KEY="${LANGFUSE_SECRET_KEY:-$(fnox_decrypt LANGFUSE_SECRET_KEY)}"
  [[ -n "${LF_PUBLIC_KEY}" && -n "${LF_SECRET_KEY}" ]] ||
    die "could not resolve Langfuse public/secret keys (env or fnox)"

  # Coarse spend-log date window (client-side jq narrows to the exact canary time).
  SPEND_START_DATE="$(date -u '+%Y-%m-%d')"
  SPEND_END_DATE="$(_utc_date_shift '+1d' 'tomorrow' '+%Y-%m-%d')" ||
    SPEND_END_DATE="${SPEND_START_DATE}"

  TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-verify-gateway.XXXXXX")"

  start_pf ||
    die "could not establish loopback port-forward to svc/litellm — cannot assert spend logs"

  local models_arr=()
  read -ra models_arr <<<"${VERIFY_MODELS}"
  [[ "${#models_arr[@]}" -gt 0 ]] || die "CODEX_VERIFY_MODELS resolved to no models"

  local overall_fail=0
  local summary=()
  local model safe_model work since_iso since_compact
  local canary_res spend_res lf_res model_res

  for model in "${models_arr[@]}"; do
    info "=== verifying ${model} ==="
    safe_model="$(printf '%s' "${model}" | tr -c 'A-Za-z0-9._-' '_')"
    work="${TMPROOT}/${safe_model}"
    mkdir -p "${work}"

    # Buffer the start 30s to absorb minor host/cluster clock skew.
    since_iso="$(_utc_date_shift '-30S' '30 seconds ago' '+%Y-%m-%dT%H:%M:%SZ')" ||
      since_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    since_compact="${since_iso%Z}"

    canary_res="FAIL"
    spend_res="SKIP"
    lf_res="SKIP"

    if run_canary "${model}" "${work}"; then
      canary_res="PASS"

      local expected_spend_model
      expected_spend_model="$(_expected_spend_model "${model}")"
      if poll_until "${SPEND_TIMEOUT}" "${POLL_INTERVAL}" _check_spend_row "${model}" "${since_compact}"; then
        spend_res="PASS"
        info "spend-log row present for ${expected_spend_model}"
      else
        spend_res="FAIL"
        err "FAIL: no /spend/logs row with model ${expected_spend_model} since ${since_iso}"
      fi

      if poll_until "${LANGFUSE_TIMEOUT}" "${POLL_INTERVAL}" _check_langfuse_trace "${model}" "${since_iso}"; then
        lf_res="PASS"
        info "Langfuse trace present for codex ${model}"
      else
        lf_res="FAIL"
        err "FAIL: no Langfuse trace named like 'codex ${model}' since ${since_iso}"
      fi
    fi

    if [[ "${canary_res}" == "PASS" && "${spend_res}" == "PASS" && "${lf_res}" == "PASS" ]]; then
      model_res="PASS"
      info "MODEL PASS: ${model}"
    else
      model_res="FAIL"
      overall_fail=1
      err "MODEL FAIL: ${model} (canary=${canary_res} spend=${spend_res} langfuse=${lf_res})"
    fi

    summary+=("$(printf '%-16s  %-7s  %-7s  %-9s  %-7s' \
      "${model}" "${canary_res}" "${spend_res}" "${lf_res}" "${model_res}")")
  done

  {
    printf '\n=== codex:verify-gateway summary ===\n'
    printf '%-16s  %-7s  %-7s  %-9s  %-7s\n' "MODEL" "CANARY" "SPEND" "LANGFUSE" "RESULT"
    local line
    for line in "${summary[@]}"; do
      printf '%s\n' "${line}"
    done
  } >&2

  if [[ "${overall_fail}" -ne 0 ]]; then
    die "codex:verify-gateway FAILED — one or more models did not pass all checks"
  fi
  info "codex:verify-gateway PASSED (all ${#models_arr[@]} models)"
}

main "$@"
