#!/usr/bin/env bash
#MISE alias="codex"
#MISE description="Launch Codex through the LiteLLM gateway via the committed .config/bin/codex wrapper (full provider/-c overrides, real TTY)."
#MISE raw=true
# raw=true connects stdin/stdout/stderr straight to the terminal. Codex is an interactive
# TUI and `mise run` does NOT wire a task's stdin by default (mise docs: "Stdin is not read
# by default. To enable this, set raw = true") — without it the exec'd codex sees a non-TTY
# stdin and drops into headless/--print mode.
# .config/mise/tasks/codex/launch.sh — thin delegator to the committed codex wrapper.
#
# All gateway/provider wiring + fnox secret sourcing now lives in ONE place: the
# .config/bin/codex wrapper (also reachable as a bare `codex` on PATH via 10-env.toml
# `_.path`). This task records the mise handoff and exec's that wrapper, so
# `mise run codex[:launch]` and a bare `codex` behave identically.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
mise_log_handoff codex
exec "${REPO_ROOT}/.config/bin/codex" "$@"
