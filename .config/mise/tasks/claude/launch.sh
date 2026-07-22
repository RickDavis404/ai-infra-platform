#!/usr/bin/env bash
#MISE alias="claude"
#MISE raw=true
#MISE description="Launch Claude Code through the LiteLLM gateway (full telemetry, real TTY)."
# raw=true connects stdin/stdout/stderr straight to the terminal. Claude Code is an
# interactive TUI and `mise run` does NOT wire stdin to tasks by default (mise docs:
# "Stdin is not read by default. To enable this, set raw = true") — without it the
# exec'd claude sees a non-TTY stdin and drops into headless/--print mode.
# .config/mise/tasks/claude/launch.sh — launch Claude Code against the LiteLLM gateway.
#
# The gateway + full telemetry env (ANTHROPIC_BASE_URL, ANTHROPIC_CUSTOM_HEADERS, the
# OTEL_* capture vars) is already wired by mise+fnox on `cd` (conf.d/10-env.toml +
# secret-env.sh), so this task adds nothing but the real TTY and the raw-bodies dir.
set -euo pipefail

# Resolve and source the shared helper library defensively.
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
require_cmd claude

# OTEL_LOG_RAW_API_BODIES target (conf.d/10-env.toml) — claude does not create it.
mkdir -p "${REPO_ROOT}/.local/logs/claude/otel-raw-bodies"

mise_log_handoff claude
exec claude "$@"
