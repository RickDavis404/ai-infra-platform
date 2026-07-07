#!/usr/bin/env bash
#MISE description="Stop the Mac-side host services."
# .config/mise/tasks/host/down.sh — stop the Mac-side host services (spec §8.4 / §9.1).
#
# Unloads the launchd user agents (llama-swap, the Grafana Alloy telemetry shipper,
# the macmon exporter). Staged scripts and configs under ~/.local/bin and
# ~/.config/ai-infra are left in place (re-running host:up reloads them). Idempotent
# and re-runnable.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
if [[ -f "${REPO_ROOT}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/.config/mise/lib/common.sh"
fi
if ! declare -F info >/dev/null 2>&1; then
  info() { printf '[info] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() {
    printf '[err ] %s\n' "$*" >&2
    exit 1
  }
fi

readonly -a LABELS=(
  com.ai-infra.macmon-exporter
  com.ai-infra.alloy
  com.ai-infra.llama-swap
)

main() {
  [[ "$(uname -s)" == "Darwin" ]] || die "host:down targets macOS (Darwin) only"
  local uid domain label
  uid="$(id -u)"
  domain="gui/${uid}"
  for label in "${LABELS[@]}"; do
    if launchctl bootout "${domain}/${label}" 2>/dev/null; then
      info "stopped ${label}"
    else
      info "${label} not loaded (nothing to stop)"
    fi
  done
  info "host services stopped"
}

main "$@"
