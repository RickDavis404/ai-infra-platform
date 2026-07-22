#!/usr/bin/env bash
#MISE description="Verify Claude Code routes through LiteLLM (mise+fnox env) and commits no secrets."
# .config/mise/tasks/claude/smoke.sh — Claude Code env + publication-safety smoke test.
#
# Post-consolidation the agent env is owned by mise+fnox (conf.d/10-env.toml [env] +
# secret-env.sh via _.source), NOT by .claude/settings*.json (whose env block was removed).
# So this runs as a mise task and checks: (1) the RESOLVED non-secret routing env this task
# inherits from mise; (2) the fnox-composed proxy-hop header shape (only when fnox/age is
# available — warn, don't fail, otherwise so publication/CI runs stay green); (3) the Max
# OAuth invariant; and (4) that the committed files carry no secrets. No model call is made.
# Run via `mise run claude:smoke` so the mise [env] is loaded.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
require_cmd jq
root="$(repo_root)"

fail() {
  err "$1"
  exit 1
}

# --- 1. Non-secret routing env, resolved by mise [env] (this task inherits it) ----------
litellm_vip="${AI_INFRA_LITELLM_VIP:-192.168.105.200}"
otel_vip="${AI_INFRA_OTEL_VIP:-192.168.105.203}"
[[ "${ANTHROPIC_BASE_URL:-}" == "http://${litellm_vip}:4000" ]] ||
  fail "FAIL: ANTHROPIC_BASE_URL is '${ANTHROPIC_BASE_URL:-<unset>}', not the LiteLLM VIP gateway — is the mise env loaded (run via 'mise run claude:smoke')?"
[[ "${CLAUDE_CODE_ENABLE_TELEMETRY:-}" == "1" ]] || fail "FAIL: telemetry not enabled"
[[ "${OTEL_LOG_USER_PROMPTS:-}" == "1" && "${OTEL_LOG_TOOL_DETAILS:-}" == "1" && "${OTEL_LOG_TOOL_CONTENT:-}" == "1" &&
  "${OTEL_LOG_ASSISTANT_RESPONSES:-}" == "1" && "${CLAUDE_CODE_PROPAGATE_TRACEPARENT:-}" == "1" &&
  "${OTEL_LOG_RAW_API_BODIES:-}" == file:*/.local/logs/claude/otel-raw-bodies ]] ||
  fail "FAIL: full-capture flags not all enabled"
[[ "${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:-}" == *"${otel_vip}:4318/v1/traces" ]] ||
  fail "FAIL: OTLP traces endpoint not the OTel collector VIP /v1/traces"
[[ "${OTEL_RESOURCE_ATTRIBUTES:-}" == "deployment.environment=ai-infra-platform-local" ]] ||
  fail "FAIL: deployment.environment not canonical"

# --- 2. Proxy-hop auth header from fnox (secret-env.sh) — shape only, NEVER print value --
# Warn (don't fail) when unresolved so publication/CI runs without an age identity stay green.
if [[ -n "${ANTHROPIC_CUSTOM_HEADERS:-}" ]]; then
  [[ "${ANTHROPIC_CUSTOM_HEADERS}" == "x-litellm-api-key: Bearer "* ]] ||
    fail "FAIL: ANTHROPIC_CUSTOM_HEADERS not shaped 'x-litellm-api-key: Bearer <key>'"
  # secret-env.sh appends a newline-separated spend-tag header (x-litellm-spend-logs-metadata:
  # <JSON>) that LiteLLM promotes to spend TAGS — assert it rode along with the resolved key.
  [[ "${ANTHROPIC_CUSTOM_HEADERS}" == *"x-litellm-spend-logs-metadata:"* ]] ||
    fail "FAIL: ANTHROPIC_CUSTOM_HEADERS missing the appended 'x-litellm-spend-logs-metadata:' tag header"
else
  warn "ANTHROPIC_CUSTOM_HEADERS unset — secret-env.sh could not resolve the virtual key (fnox/age unavailable?); skipping shape check"
fi

# --- 3. Max/OAuth invariant: these auth vars MUST be unset (they'd override the OAuth session) --
for k in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL; do
  [[ -z "${!k:-}" ]] || fail "FAIL: ${k} is set — it breaks the Max/OAuth passthrough"
done

# --- 4. Publication safety: committed settings.json carries NO env secrets --------------
s="${root}/.claude/settings.json"
test -f "${s}" || fail "FAIL: settings.json missing at ${s}"
jq -e . "${s}" >/dev/null || fail "FAIL: settings.json is not valid JSON"
jq -e '((.env // {}) | (has("ANTHROPIC_CUSTOM_HEADERS") or has("ANTHROPIC_API_KEY") or has("ANTHROPIC_AUTH_TOKEN"))) | not' \
  "${s}" >/dev/null || fail "FAIL: settings.json .env carries a secret/auth var (env is mise-owned now)"
git -C "${root}" check-ignore -q .claude/settings.local.json ||
  fail "FAIL: .claude/settings.local.json is not gitignored"
git -C "${root}" check-ignore -q .local/logs/claude/otel-raw-bodies/ ||
  fail "FAIL: .local/logs/claude/otel-raw-bodies/ is not gitignored"
if grep -Eiq '\.ts\.net|/Users/[a-z]|local-dev' "${s}"; then
  fail "FAIL: scrub-list token in settings.json"
fi

# --- 5. Project MCP config (.mcp.json): valid JSON, expected servers, no secret literals -
m="${root}/.mcp.json"
test -f "${m}" || fail "FAIL: .mcp.json missing at ${m}"
jq -e . "${m}" >/dev/null || fail "FAIL: .mcp.json is not valid JSON"
for srv in grafana langfuse kubernetes postgres-langfuse postgres-litellm clickhouse; do
  jq -e --arg srv "${srv}" '.mcpServers | has($srv)' "${m}" >/dev/null ||
    fail "FAIL: .mcp.json missing MCP server '${srv}'"
done
if grep -Eiq '\.ts\.net|/Users/[a-z]|-dev-2026|sk-lf-|pk-lf-|sk-litellm-' "${m}"; then
  fail "FAIL: scrub-list / secret-shaped token in .mcp.json"
fi

info "OK: claude env + publication-safety smoke passed (mise+fnox env; no secrets committed)"
