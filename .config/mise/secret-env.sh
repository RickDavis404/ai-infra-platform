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

# fnox is mise-managed (mise.toml [tools]) and is NOT on PATH yet when mise evaluates
# this file via [env]._.source — mise prepends its tool-shim dir to PATH only AFTER
# running the _.source hook (confirmed: `command -v fnox` fails here even in an
# interactive mise-activated login shell, and under `mise exec`). The old
# `command -v fnox` guard therefore silently skipped EVERY secret, so
# ANTHROPIC_CUSTOM_HEADERS / the Codex auth header ended up UNSET and a bare agent hit
# LiteLLM with no virtual key. Resolve the binary explicitly: PATH first, else the
# mise install dir (version-agnostic; the [ -x ] test also no-ops an unmatched glob).
_fnox_bin="$(command -v fnox 2>/dev/null || true)"
if [ -z "$_fnox_bin" ]; then
  for _d in "${MISE_DATA_DIR:-$HOME/.local/share/mise}"/installs/fnox/*/fnox; do
    [ -x "$_d" ] && _fnox_bin="$_d" && break
  done
fi

# _fx <KEY> — print one fnox-decrypted value (empty on any failure; never throws).
_fx() {
  [ -n "$_fnox_bin" ] || return 0
  (cd "$_repo" && FNOX_AGE_KEY_FILE="$_repo/secrets/age/key.txt" "$_fnox_bin" get "$1" 2>/dev/null) </dev/null || true
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

# Codex proxy-hop virtual key: export the raw key (still passed straight through)
# AND a composed `Bearer <key>` header value. The repo-local $CODEX_HOME user-layer
# config (.config/codex/config.toml) references CODEX_LITELLM_AUTH_HEADER via
# env_http_headers, so a bare `codex` routes through the gateway with no secret
# committed to the file (mirrors LANGFUSE_MCP_AUTH_HEADER below).
_codex_vk=$(_fx CODEX_LITELLM_VIRTUAL_KEY)
_exp CODEX_LITELLM_VIRTUAL_KEY "$_codex_vk"
_exp CODEX_LITELLM_AUTH_HEADER "${_codex_vk:+Bearer $_codex_vk}"

# Grafana MCP password (NAME-MAP: fnox key is GRAFANA_ADMIN_PASSWORD).
_exp GRAFANA_PASSWORD "$(_fx GRAFANA_ADMIN_PASSWORD)"

# Langfuse API key pair plus native MCP Basic-auth header.
_lf_public=$(_fx LANGFUSE_PUBLIC_KEY)
_lf_secret=$(_fx LANGFUSE_SECRET_KEY)
_exp LANGFUSE_PUBLIC_KEY "$_lf_public"
_exp LANGFUSE_SECRET_KEY "$_lf_secret"
_lf_mcp_auth=""
if [ -n "$_lf_public" ] && [ -n "$_lf_secret" ]; then
  _lf_mcp_auth="Basic $(printf '%s:%s' "$_lf_public" "$_lf_secret" | base64 | tr -d '\n')"
fi
_exp LANGFUSE_MCP_AUTH_HEADER "$_lf_mcp_auth"

# ClickHouse MCP password.
_exp CLICKHOUSE_PASSWORD "$(_fx CLICKHOUSE_PASSWORD)"

# Postgres MCP read-only DSNs — composed against the CNPG `-ro` LoadBalancer VIPs.
_lfpg=$(_fx LANGFUSE_PG_PASSWORD)
_exp LANGFUSE_PG_MCP_URI "${_lfpg:+postgresql://langfuse:$_lfpg@${AI_INFRA_LANGFUSE_PG_VIP:-192.168.105.205}:5432/postgres_langfuse}"
_llpg=$(_fx LITELLM_PG_PASSWORD)
_exp LITELLM_PG_MCP_URI "${_llpg:+postgresql://litellm:$_llpg@${AI_INFRA_LITELLM_PG_VIP:-192.168.105.206}:5432/litellm}"

unset -f _fx _exp
unset _repo _fnox_bin _d _vk _codex_vk _lf_public _lf_secret _lf_mcp_auth _lfpg _llpg
