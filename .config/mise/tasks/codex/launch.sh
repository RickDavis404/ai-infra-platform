#!/usr/bin/env bash
#MISE description="Launch Codex with LiteLLM provider overrides (ignored keys injected)."
#MISE raw=true
# raw=true connects stdin/stdout/stderr straight to the terminal. Codex is an interactive
# TUI, and `mise run` does NOT wire stdin to tasks by default (mise docs: "Stdin is not read
# by default. To enable this, set raw = true") — without this the exec'd codex sees a non-TTY
# stdin and drops into headless/--print mode. (Claude has no launcher anymore: run `claude`
# directly — the mise+fnox `cd`-env routes it through the gateway with a real TTY.)
# .config/mise/tasks/codex/launch.sh — launch Codex against the local LiteLLM gateway.
#
# Wires Codex to the LiteLLM gateway VIP via `-c/--config` overrides (the
# strongest precedence layer), which inject the provider keys Codex ignores at the
# committed project layer (§10.1.2). Secrets are sourced from fnox+age at launch and
# are never written to a committed or persisted file, nor echoed to stdout/logs.
set -euo pipefail

# Resolve and source the shared helper library defensively.
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
require_cmd codex fnox

# --- Secrets from fnox+age (captured into locals, never logged) --------------
# fnox addresses secrets by their FLAT key name (see fnox.toml [secrets]); there is
# no slash-path namespace. The committed fnox.toml is a marker-only template; real
# ciphertext lives in the GITIGNORED fnox.local.toml, which fnox's hierarchical
# merge overlays automatically during walk-up — no `cd secrets` needed.
[[ -f "${REPO_ROOT}/fnox.local.toml" ]] || die "fnox.local.toml not found at repo root — run 'mise run secrets:keygen' then 'mise run secrets:seal' first."
# Proxy-hop virtual key for the LiteLLM gateway (default `x-litellm-api-key`).
CODEX_LITELLM_VIRTUAL_KEY="$(fnox_decrypt CODEX_LITELLM_VIRTUAL_KEY)"
# MCP server credentials, injected over the non-secret committed env tables.
GRAFANA_USERNAME="${GRAFANA_USERNAME:-admin}"
GRAFANA_PASSWORD="$(fnox_decrypt GRAFANA_ADMIN_PASSWORD)"
LANGFUSE_PUBLIC_KEY="$(fnox_decrypt LANGFUSE_PUBLIC_KEY)"
LANGFUSE_SECRET_KEY="$(fnox_decrypt LANGFUSE_SECRET_KEY)"
LANGFUSE_MCP_AUTH_HEADER="Basic $(printf '%s:%s' "${LANGFUSE_PUBLIC_KEY}" "${LANGFUSE_SECRET_KEY}" | base64 | tr -d '\n')"
export LANGFUSE_MCP_AUTH_HEADER

# Default to Codex's bundled OpenAI/Codex model catalog; CODEX_MODEL may still
# override this for one-off operator checks.
model="${CODEX_MODEL:-gpt-5.5}"

info "launching codex against the LiteLLM gateway VIP (${AI_INFRA_LITELLM_VIP:-192.168.105.200}:4000)"

# `codex -c key=value` parses value as TOML (string values must be inner-quoted;
# inline tables use TOML inline syntax). The provider keys below are ignored at
# the project layer and so can only arrive via -c.
mise_log_handoff codex
exec codex \
  --config model="\"${model}\"" \
  --config model_provider='"litellm_local"' \
  --config 'model_providers.litellm_local.name="LiteLLM Local"' \
  --config "model_providers.litellm_local.base_url=\"http://${AI_INFRA_LITELLM_VIP:-192.168.105.200}:4000/v1\"" \
  --config 'model_providers.litellm_local.requires_openai_auth=true' \
  --config 'model_providers.litellm_local.wire_api="responses"' \
  --config 'model_providers.litellm_local.supports_websockets=false' \
  --config 'model_providers.litellm_local.stream_idle_timeout_ms=900000' \
  --config "model_providers.litellm_local.http_headers={ \"X-Litellm-Api-Key\" = \"Bearer ${CODEX_LITELLM_VIRTUAL_KEY}\" }" \
  --config "mcp_servers.grafana.env.GRAFANA_USERNAME=\"${GRAFANA_USERNAME}\"" \
  --config "mcp_servers.grafana.env.GRAFANA_PASSWORD=\"${GRAFANA_PASSWORD}\"" \
  --config 'mcp_servers.langfuse.enabled=false' \
  --config "mcp_servers.langfuse_http.url=\"http://${AI_INFRA_LANGFUSE_VIP:-192.168.105.201}:3000/api/public/mcp\"" \
  --config 'mcp_servers.langfuse_http.env_http_headers={ Authorization = "LANGFUSE_MCP_AUTH_HEADER" }' \
  "$@"
