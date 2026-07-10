#!/usr/bin/env bash
#MISE description="Launch Codex with NO gateway overrides — built-in ChatGPT subscription provider — telemetry still captured (canary)."
#MISE raw=true
# .config/mise/tasks/codex/no-gateway.sh — subscription-OAuth canary (codex:no-gateway).
#
# Injects NO provider `-c` overrides, so codex uses its BUILT-IN ChatGPT provider (OAuth
# via ~/.codex/auth.json), NOT the LiteLLM gateway. All OTEL_* env (the shared mise env)
# is kept, and the USER-layer [otel] block (installed by `mise run codex:global-config`)
# keeps exporting to the collector — the project-layer otel denylist strips otel only from
# .codex/config.toml, never from ~/.codex. Proves the telemetry pipeline still captures
# when LiteLLM is scaled down (DoD-3).
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
require_cmd mise

# Resolve the REAL mise-managed codex — NOT the .config/bin/codex wrapper, which would
# re-inject the gateway `-c` overrides. `mise which` queries the tool registry, never PATH.
real_codex="$(mise --cd "${REPO_ROOT}" which codex)"
[[ -n "${real_codex}" && -x "${real_codex}" ]] ||
  die "could not resolve the mise-managed codex binary (run 'mise install')"

info "launching codex with NO gateway overrides (built-in ChatGPT subscription provider; telemetry retained)"
mise_log_handoff codex
exec "${real_codex}" "$@"
