#!/usr/bin/env bash
#MISE raw=true
#MISE description="Launch Claude Code on its DIRECT provider (bypass the gateway) — telemetry still captured."
# raw=true connects stdin/stdout/stderr straight to the terminal (see claude/launch.sh).
# .config/mise/tasks/claude/no-gateway.sh — bare-provider Claude Code canary.
#
# Canary for the collector-outage / gateway-down drill: unset ONLY the gateway routing
# env so claude talks straight to the Anthropic API (subscription OAuth), while every
# OTEL_* capture var stays set — proving telemetry still flows with LiteLLM scaled down.
set -euo pipefail

# Resolve and source the shared helper library defensively.
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
require_cmd claude

# OTEL_LOG_RAW_API_BODIES target (conf.d/10-env.toml) — claude does not create it.
mkdir -p "${REPO_ROOT}/.local/logs/claude/otel-raw-bodies"

# Drop ONLY the gateway routing; ALL telemetry env is deliberately kept.
unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS

mise_log_handoff claude
exec claude "$@"
