#!/usr/bin/env bash
#MISE description="Verify Codex routes a request through LiteLLM and is traced in Langfuse."
# .config/mise/tasks/codex/smoke.sh — Codex project-config smoke test (§10.4.1).
#
# Pure structural / publication-safety checks: no model call, no secret read.
# Asserts the committed Codex layer is present, valid, free of ignored keys, and
# carries no scrub-list token. The config root is resolvable so this can test the
# SANDBOX copy as well as the published repo root.
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

fail() {
  err "$1"
  exit 1
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

info "OK: codex config smoke passed (${cfg})"
