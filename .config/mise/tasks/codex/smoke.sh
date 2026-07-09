#!/usr/bin/env bash
#MISE description="Verify Codex routes a request through LiteLLM and is traced in Langfuse."
# .config/mise/tasks/codex/smoke.sh — Codex project-config smoke test (§10.4.1).
#
# Asserts the committed Codex layer is present, valid, free of ignored keys, and
# carries no scrub-list token. Then performs a live Codex CLI canary through the
# LiteLLM gateway using gpt-5.5 at low reasoning and verifies the response.
# The config root is resolvable so this can test the SANDBOX copy as well as the
# published repo root.
set -euo pipefail

# Resolve and source the shared helper library defensively.
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap

# Config root: default to the repo root, override to point at the sandbox.
config_root="${AI_INFRA_CONFIG_ROOT:-$(repo_root)}"
cfg="${config_root}/.codex/config.toml"
agents_md="${config_root}/AGENTS.md"
smoke_tmpdir=""

fail() {
  err "$1"
  exit 1
}

cleanup_codex_smoke() {
  if [[ -n "${smoke_tmpdir}" && -d "${smoke_tmpdir}" ]]; then
    rm -rf "${smoke_tmpdir}"
  fi
}
add_exit_trap cleanup_codex_smoke

redacted_excerpt() {
  local file="$1"
  if [[ -s "${file}" ]]; then
    ai_infra_redact_log <"${file}" | tail -n 20
  fi
  return 0
}

run_live_gpt55_smoke() {
  if [[ "${AI_INFRA_CODEX_SKIP_LIVE_SMOKE:-0}" == "1" ]]; then
    warn "SKIP: AI_INFRA_CODEX_SKIP_LIVE_SMOKE=1 — skipping live gpt-5.5 Codex smoke"
    return 0
  fi

  require_cmd codex fnox
  [[ -f "${REPO_ROOT}/fnox.local.toml" ]] ||
    fail "FAIL: fnox.local.toml missing at repo root; live Codex smoke needs CODEX_LITELLM_VIRTUAL_KEY"

  local codex_key reply_file stdout_file stderr_file diagnostics_file rc reply_text prompt
  codex_key="$(fnox_decrypt CODEX_LITELLM_VIRTUAL_KEY)"
  [[ -n "${codex_key}" ]] || fail "FAIL: CODEX_LITELLM_VIRTUAL_KEY resolved empty"

  smoke_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/codex-smoke.XXXXXX")"
  reply_file="${smoke_tmpdir}/reply.txt"
  stdout_file="${smoke_tmpdir}/stdout.txt"
  stderr_file="${smoke_tmpdir}/stderr.txt"
  diagnostics_file="${smoke_tmpdir}/diagnostics.txt"
  prompt='Reply with exactly pong. Do not include quotes, punctuation, markdown, or any other text. Do not call tools.'

  info "live Codex smoke: gpt-5.5 via LiteLLM at low reasoning"
  set +e
  (
    cd "${smoke_tmpdir}" || exit 1
    codex exec \
      --skip-git-repo-check \
      --ignore-user-config \
      --ignore-rules \
      --ephemeral \
      --sandbox read-only \
      --color never \
      --output-last-message "${reply_file}" \
      --config 'model="gpt-5.5"' \
      --config 'model_reasoning_effort="low"' \
      --config 'model_provider="litellm_local"' \
      --config 'model_providers.litellm_local.name="LiteLLM Local"' \
      --config "model_providers.litellm_local.base_url=\"http://${AI_INFRA_LITELLM_VIP:-192.168.105.200}:4000/v1\"" \
      --config 'model_providers.litellm_local.requires_openai_auth=true' \
      --config 'model_providers.litellm_local.wire_api="responses"' \
      --config 'model_providers.litellm_local.supports_websockets=false' \
      --config 'model_providers.litellm_local.stream_idle_timeout_ms=900000' \
      --config "model_providers.litellm_local.http_headers={ \"X-Litellm-Api-Key\" = \"Bearer ${codex_key}\" }" \
      "${prompt}"
  ) >"${stdout_file}" 2>"${stderr_file}"
  rc=$?
  set -e
  codex_key=""

  if [[ "${rc}" -ne 0 ]]; then
    err "FAIL: live Codex smoke exited ${rc}"
    redacted_excerpt "${stderr_file}" | while IFS= read -r line; do err "codex stderr: ${line}"; done
    redacted_excerpt "${stdout_file}" | while IFS= read -r line; do err "codex stdout: ${line}"; done
    exit 1
  fi

  if [[ ! -s "${reply_file}" ]]; then
    fail "FAIL: live Codex smoke produced no final response"
  fi
  reply_text="$(tr -d '\r' <"${reply_file}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if ! grep -Eiq '(^|[^[:alnum:]_])pong([^[:alnum:]_]|$)' <<<"${reply_text}"; then
    err "FAIL: live Codex smoke response did not contain pong"
    redacted_excerpt "${reply_file}" | while IFS= read -r line; do err "codex reply: ${line}"; done
    exit 1
  fi

  cat "${stdout_file}" "${stderr_file}" >"${diagnostics_file}"
  # Codex >=0.144 polls <base_url>/models expecting the codex model-catalog schema
  # ({"models":[...]}); LiteLLM serves the OpenAI list schema ({"data":[...]}), so a
  # "failed to refresh available models" warning is expected and benign through the
  # gateway (upstream: openai/codex model-discovery vs OpenAI-compatible providers).
  # Strip ONLY those lines; any other warn/error below must still fail the smoke.
  grep -Fv 'failed to refresh available models' "${diagnostics_file}" \
    >"${diagnostics_file}.filtered" || true
  mv "${diagnostics_file}.filtered" "${diagnostics_file}"
  if grep -Eiq '(^|[^[:alpha:]])(warn|warning|err|error|fail|failed|failure|panic|traceback|exception)([^[:alpha:]]|$)' "${diagnostics_file}"; then
    err "FAIL: live Codex smoke emitted warning/error diagnostics"
    redacted_excerpt "${diagnostics_file}" | while IFS= read -r line; do err "codex diagnostic: ${line}"; done
    exit 1
  fi

  info "live Codex smoke PASSED (gpt-5.5 low reasoning returned pong cleanly)"
}

# 1. Required files exist.
test -f "${cfg}" || fail "FAIL: .codex/config.toml missing at ${cfg}"
test -f "${agents_md}" || fail "FAIL: root AGENTS.md missing at ${agents_md}"

# 2. Honored keys present.
for k in model model_reasoning_effort approval_policy sandbox_mode \
  project_doc_fallback_filenames; do
  grep -Eq "^${k}[[:space:]]*=" "${cfg}" ||
    fail "FAIL: missing honored key ${k}"
done
grep -q 'mcp_servers.grafana' "${cfg}" || fail "FAIL: grafana MCP def missing"
grep -q 'mcp_servers.langfuse' "${cfg}" || fail "FAIL: langfuse MCP def missing"

# 3. IGNORED keys MUST be absent (Codex warns on these at the project layer).
for k in openai_base_url chatgpt_base_url apps_mcp_product_sku model_provider \
  model_providers notify profile profiles experimental_realtime_ws_base_url otel; do
  if grep -Eq "^${k}([.[:space:]=]|s?[[:space:]]*[=.[])" "${cfg}"; then
    fail "FAIL: ignored key '${k}' present in project config"
  fi
done
if grep -Eq '^model_catalog_json[[:space:]]*=' "${cfg}"; then
  fail "FAIL: model_catalog_json must not be set in project config"
fi

# 4. Strict parse with the installed CLI (catches typos / stale keys). The Codex
#    CLI may be absent in CI; SKIP this step rather than fail when it is missing.
if command -v codex >/dev/null 2>&1; then
  if codex --strict-config -c 'sandbox_mode="read-only"' exec --help >/dev/null 2>&1; then
    info "codex --strict-config accepted the committed config"
  else
    fail "FAIL: codex --strict-config rejected the committed config"
  fi
else
  warn "SKIP: codex CLI not on PATH; skipping --strict-config parse"
fi

# 5. Publication safety: no scrub-list token, no tailnet host, no real home path.
# (Org/customer literals are covered repo-wide by validate:private-names via the
# gitignored forbidden-names.txt; this fast check keeps only generic shapes.)
if grep -Eiq '\.ts\.net|/Users/[a-z]' "${cfg}"; then
  fail "FAIL: scrub-list token in .codex/config.toml"
fi

run_live_gpt55_smoke

info "OK: codex config smoke passed (${cfg})"
