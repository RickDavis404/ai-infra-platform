#!/usr/bin/env bash
# .config/mise/secret-env.sh — mise-owned fnox secret loader (sourced via [env]._.source).
#
# mise sources this on `cd` into the repo (mise is already activated in the shell) and
# captures the exported vars, so `claude`/`codex` and every MCP child they spawn inherit
# the fnox-decrypted credentials. This is the SOLE owner of the project's secret env;
# app config (.claude/settings*.json, .mcp.json) carries no secrets.
#
# DEFENSIVE BY DESIGN: no `set -e`, no `die`. A missing fnox binary, a locked age
# identity, or an unresolved key must degrade gracefully (var skipped, warning to
# stderr) and NEVER break the interactive shell that sourced this file.
#
# The committed repo-root fnox.toml is a marker-only template; real ciphertext lives
# in the GITIGNORED fnox.local.toml beside it. fnox discovers both by walking up from
# $_repo and merges hierarchically (local wins), so `fnox get` resolves real values.
# FNOX_AGE_KEY_FILE is set explicitly (absolute) for headless/non-login use. Plaintext
# secrets in the process env are accepted for this single-user local lab.

_repo="${MISE_PROJECT_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"

# _fx <KEY> — print one fnox-decrypted value (empty on any failure; never throws).
_fx() {
  command -v fnox >/dev/null 2>&1 || return 0
  (cd "$_repo" && FNOX_AGE_KEY_FILE="$_repo/secrets/age/key.txt" fnox get "$1" 2>/dev/null) </dev/null || true
}

# _exp <NAME> <VALUE> — export NAME=VALUE only when VALUE is non-empty; else warn+skip.
_exp() {
  if [ -n "$2" ]; then
    export "$1=$2"
  else
    printf 'mise env: secret %s unresolved — skipped\n' "$1" >&2
  fi
}

# Claude Code proxy-hop header: compose only when the virtual key resolves.
_vk=$(_fx CLAUDE_CODE_LITELLM_VIRTUAL_KEY)
_exp ANTHROPIC_CUSTOM_HEADERS "${_vk:+x-litellm-api-key: Bearer $_vk}"

# Codex proxy-hop virtual key (passed straight through).
_exp CODEX_LITELLM_VIRTUAL_KEY "$(_fx CODEX_LITELLM_VIRTUAL_KEY)"

# Grafana MCP password (NAME-MAP: fnox key is GRAFANA_ADMIN_PASSWORD).
_exp GRAFANA_PASSWORD "$(_fx GRAFANA_ADMIN_PASSWORD)"

# Langfuse MCP API key pair.
_exp LANGFUSE_PUBLIC_KEY "$(_fx LANGFUSE_PUBLIC_KEY)"
_exp LANGFUSE_SECRET_KEY "$(_fx LANGFUSE_SECRET_KEY)"

# ClickHouse MCP password.
_exp CLICKHOUSE_PASSWORD "$(_fx CLICKHOUSE_PASSWORD)"

# Postgres MCP read-only DSNs — composed against the CNPG `-ro` LoadBalancer VIPs.
_lfpg=$(_fx LANGFUSE_PG_PASSWORD)
_exp LANGFUSE_PG_MCP_URI "${_lfpg:+postgresql://langfuse:$_lfpg@${AI_INFRA_LANGFUSE_PG_VIP:-192.168.105.205}:5432/postgres_langfuse}"
_llpg=$(_fx LITELLM_PG_PASSWORD)
_exp LITELLM_PG_MCP_URI "${_llpg:+postgresql://litellm:$_llpg@${AI_INFRA_LITELLM_PG_VIP:-192.168.105.206}:5432/litellm}"

unset -f _fx _exp
unset _repo _vk _lfpg _llpg
