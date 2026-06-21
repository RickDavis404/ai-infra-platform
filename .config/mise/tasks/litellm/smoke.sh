#!/usr/bin/env bash
#MISE description="Verify LiteLLM `/health` and a model-list call via a virtual key."
# .config/mise/tasks/litellm/smoke.sh — LiteLLM chat smoke (spec §15.4).
#
# Asserts:
#   - 127.0.0.1:4000/health OK after a loopback port-forward;
#   - a chat completion against the local route (mac-local/<default-chat-model> ->
#     host.lima.internal:8080/v1) returns a valid response, authenticated with the
#     `smoke-test` virtual key via the DEFAULT `x-litellm-api-key` header;
#   - the `claude-*` wildcard alias resolves to anthropic/claude-* (model present
#     in /v1/models);
#   - NO ANTHROPIC_API_KEY is set on the LiteLLM deployment.
#
# The smoke-test virtual key is resolved at runtime from the in-cluster
# `litellm-key-smoke-test` Secret (authoritative; fnox is a best-effort fallback)
# and never echoed. All access is loopback-only.
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

readonly NS="litellm"
readonly LOCAL_PORT="${LITELLM_LOCAL_PORT:-4000}"
readonly BASE="http://127.0.0.1:${LITELLM_LOCAL_PORT:-4000}"
# Default chat model alias (spec §3 identity taxonomy / locked constant).
readonly DEFAULT_CHAT_MODEL="${AI_INFRA_DEFAULT_CHAT_MODEL:-mac-local/unsloth/qwen3.5-4b-mtp-ud-q8-k-xl-gguf}"
# In-cluster Secret carrying the smoke-test virtual key minted by the key Job — the
# AUTHORITATIVE source (its `key` field is what the LiteLLM DB actually holds).
readonly SMOKE_KEY_SECRET="${LITELLM_SMOKE_KEY_SECRET:-litellm-key-smoke-test}"
readonly CLAUDE_KEY_SECRET="${LITELLM_CLAUDE_KEY_SECRET:-litellm-key-claude-code}"
# fnox key holding the smoke-test virtual key — best-effort FALLBACK only. The fnox
# store addresses secrets by their FLAT key name (see fnox.toml [secrets]);
# there is no slash-path namespace, so this is the bare key, not a path.
readonly SMOKE_KEY_REF="${LITELLM_SMOKE_KEY_REF:-SMOKE_TEST_LITELLM_VIRTUAL_KEY}"

fail=0
PF_PID=""
SMOKE_KEY=""
CLAUDE_KEY=""

cleanup() {
  SMOKE_KEY=""
  CLAUDE_KEY=""
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

start_pf() {
  info "port-forward svc/litellm -n ${NS} -> 127.0.0.1:${LOCAL_PORT} (loopback only)"
  kc -n "${NS}" port-forward --address 127.0.0.1 \
    svc/litellm "${LOCAL_PORT}:4000" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "${BASE}/health/liveliness" 2>/dev/null ||
      curl -fsS -o /dev/null "${BASE}/health/readiness" 2>/dev/null; then
      return 0
    fi
    kill -0 "${PF_PID}" 2>/dev/null || die "port-forward exited prematurely"
    sleep 1
  done
  return 1
}

check_health() {
  info "GET ${BASE}/health (authenticated with smoke-test key)"
  # /health enumerates configured model endpoints; requires the key.
  if curl -fsS -o /dev/null \
    -H "x-litellm-api-key: ${SMOKE_KEY}" "${BASE}/health"; then
    info "/health OK"
  else
    note_fail "/health did not return OK"
  fi
}

check_models_alias() {
  info "GET ${BASE}/v1/models — assert claude-* alias resolves for Claude Code key"
  local models
  models="$(curl -fsS -H "x-litellm-api-key: ${CLAUDE_KEY}" "${BASE}/v1/models" 2>/dev/null || echo '')"
  if [[ -z "${models}" ]]; then
    note_fail "could not list models"
    return
  fi
  # A claude-* alias (e.g. claude-sonnet / claude-*) must be present.
  if grep -qE '"id"[[:space:]]*:[[:space:]]*"claude' <<<"${models}"; then
    info "claude-* alias present in /v1/models"
  else
    note_fail "no claude-* model alias found in /v1/models"
  fi
}

check_chat_completion() {
  info "POST ${BASE}/v1/chat/completions via local route ${DEFAULT_CHAT_MODEL}"
  local resp http
  resp="$(curl -sS -w '\n%{http_code}' \
    -H "x-litellm-api-key: ${SMOKE_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"'"${DEFAULT_CHAT_MODEL}"'","messages":[{"role":"user","content":"reply with the single word: pong"}],"max_tokens":16,"temperature":0}' \
    "${BASE}/v1/chat/completions" 2>/dev/null || echo $'\n000')"
  http="$(tail -n1 <<<"${resp}")"
  if [[ "${http}" == "200" ]]; then
    local body
    body="$(sed '$d' <<<"${resp}")"
    if grep -q '"choices"' <<<"${body}"; then
      info "chat completion returned a valid response (http 200, choices present)"
    else
      note_fail "chat completion returned 200 but no 'choices' in body"
    fi
  else
    note_fail "chat completion failed (http ${http}) — is the host llama-swap upstream serving the default model?"
  fi
}

check_no_anthropic_key() {
  info "assert no ANTHROPIC_API_KEY on the LiteLLM deployment"
  local present
  present="$(kc -n "${NS}" get deploy/litellm \
    -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="ANTHROPIC_API_KEY")].name}' 2>/dev/null || echo '')"
  local from_ref
  from_ref="$(kc -n "${NS}" get deploy/litellm \
    -o jsonpath='{.spec.template.spec.containers[*].envFrom[*]}' 2>/dev/null || echo '')"
  if [[ -n "${present}" ]]; then
    note_fail "ANTHROPIC_API_KEY is set on the LiteLLM deployment (must be absent)"
  else
    info "no explicit ANTHROPIC_API_KEY env on the deployment"
  fi
  # Best-effort: if an envFrom secret could inject it, warn (cannot assert keys here).
  # NOTE: this is the function's last statement, so it must not return non-zero under
  # `set -e` (an empty from_ref makes the `[[ ]]` test false -> exit 1 -> aborts main).
  if [[ -n "${from_ref}" ]]; then
    warn "deployment uses envFrom; ensure the referenced sources carry no ANTHROPIC_API_KEY"
  fi
}

main() {
  need kubectl
  need curl

  check_no_anthropic_key

  # Resolve the smoke-test virtual key. The AUTHORITATIVE source is the in-cluster
  # Secret `litellm-key-smoke-test`, whose `key` field is what the key-provision Job
  # actually minted into the LiteLLM DB. (The smoke-test Job — unlike the codex Job —
  # does NOT pin a fixed KEY_VALUE, so LiteLLM auto-generates the token; the fnox
  # SMOKE_TEST_LITELLM_VIRTUAL_KEY is only a best-effort mirror and may be stale, so
  # it must NOT be the primary source or the smoke 401s on a fresh cold cluster.)
  # Fall back to fnox only if the Secret is unreadable (e.g. keys layer not applied).
  SMOKE_KEY="$(kc -n "${NS}" get secret "${SMOKE_KEY_SECRET}" \
    -o jsonpath='{.data.key}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -z "${SMOKE_KEY}" ]]; then
    warn "secret ${SMOKE_KEY_SECRET} unreadable; falling back to fnox ${SMOKE_KEY_REF}"
    if [[ -f "${REPO_ROOT}/fnox.toml" ]]; then
      # fnox.toml now lives at the repo ROOT; fnox_decrypt resolves it via walk-up.
      SMOKE_KEY="$(fnox_decrypt "${SMOKE_KEY_REF}")" || SMOKE_KEY=""
    fi
  fi
  [[ -n "${SMOKE_KEY}" ]] ||
    die "could not resolve the smoke-test virtual key (secret ${SMOKE_KEY_SECRET} or fnox ${SMOKE_KEY_REF})"

  CLAUDE_KEY="$(kc -n "${NS}" get secret "${CLAUDE_KEY_SECRET}" \
    -o jsonpath='{.data.key}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "${CLAUDE_KEY}" ]] ||
    die "could not resolve the Claude Code virtual key (secret ${CLAUDE_KEY_SECRET})"

  if start_pf; then
    check_health
    check_models_alias
    check_chat_completion
  else
    note_fail "could not establish loopback port-forward to svc/litellm"
  fi

  if [[ "${fail}" -ne 0 ]]; then
    die "litellm smoke FAILED — see failures above"
  fi
  info "litellm smoke PASSED"
}

main "$@"
