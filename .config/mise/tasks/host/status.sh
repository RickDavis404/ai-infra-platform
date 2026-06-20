#!/usr/bin/env bash
#MISE description="Show host-service (brew services + launchd) status."
# .config/mise/tasks/host/status.sh — report Mac-side host-service state (spec §8.4 / §9.1).
#
# Shows each launchd agent's load state plus a quick loopback reachability probe of
# llama-swap (127.0.0.1:38080) and the macmon exporter (127.0.0.1:39300). Read-only;
# exits non-zero if any expected agent is not loaded.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
if [[ -f "${REPO_ROOT}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/.config/mise/lib/common.sh"
fi
if ! declare -F info >/dev/null 2>&1; then
  info() { printf '[info] %s\n' "$*" >&2; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '[warn] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() {
    printf '[err ] %s\n' "$*" >&2
    exit 1
  }
fi

readonly -a LABELS=(
  com.ai-infra.llama-swap
  com.ai-infra.otelcol
  com.ai-infra.macmon-exporter
)

fail=0

agent_state() {
  local label="$1"
  local uid domain
  uid="$(id -u)"
  domain="gui/${uid}"
  if launchctl print "${domain}/${label}" >/dev/null 2>&1; then
    info "agent ${label}: loaded"
  else
    warn "agent ${label}: NOT loaded"
    fail=1
  fi
}

probe() {
  local name="$1" url="$2"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 3 "${url}" >/dev/null 2>&1; then
      info "endpoint ${name}: reachable (${url})"
    else
      warn "endpoint ${name}: not responding (${url})"
      fail=1
    fi
  else
    warn "curl not found; skipping ${name} probe"
  fi
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || die "host:status targets macOS (Darwin) only"
  local label
  for label in "${LABELS[@]}"; do
    agent_state "${label}"
  done
  probe llama-swap "http://127.0.0.1:38080/v1/models"
  probe macmon "http://127.0.0.1:39300/metrics"
  if [[ "${fail}" -ne 0 ]]; then
    die "host status: one or more services not healthy (see warnings above)"
  fi
  info "host status: all services loaded and responding"
}

main "$@"
