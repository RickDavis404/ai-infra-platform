#!/usr/bin/env bash
#MISE description="Start the Mac-side host services via brew services."
# .config/mise/tasks/host/up.sh — start the Mac-side host services (spec §8.4 / §9.1).
#
# Stages the runnable host-service scripts to ~/.local/bin (TCC constraint: never
# run them from ~/Documents), copies the configs to ~/.config/ai-infra, installs the
# launchd user agents (substituting __HOME__ -> $HOME), and loads them via launchctl.
# Idempotent and re-runnable.
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

readonly MAC_SIDE="${REPO_ROOT}/setup/mac-side"
readonly BIN_DIR="${HOME}/.local/bin"
readonly CFG_DIR="${HOME}/.config/ai-infra"
readonly LOG_DIR="${HOME}/Library/Logs/ai-infra"
readonly AGENTS_DIR="${HOME}/Library/LaunchAgents"

# Agent labels and their source plist templates.
readonly -a LABELS=(
  com.ai-infra.llama-swap
  com.ai-infra.otelcol
  com.ai-infra.macmon-exporter
)

stage_scripts() {
  info "staging host-service scripts to ${BIN_DIR} (TCC: outside ~/Documents)"
  install -d "${BIN_DIR}" "${CFG_DIR}" "${LOG_DIR}" "${AGENTS_DIR}"

  install -m 0755 "${MAC_SIDE}/llama-server-wrapper.sh" \
    "${BIN_DIR}/ai-infra-llama-server-wrapper.sh"
  install -m 0755 "${MAC_SIDE}/macmon-exporter/macmon-exporter.sh" \
    "${BIN_DIR}/ai-infra-macmon-exporter.sh"
  install -m 0644 "${MAC_SIDE}/macmon-exporter/ai-infra-macmon-exporter.py" \
    "${BIN_DIR}/ai-infra-macmon-exporter.py"

  install -m 0644 "${MAC_SIDE}/llama-swap.yaml" "${CFG_DIR}/llama-swap.yaml"
  install -m 0644 "${MAC_SIDE}/otelcol-config.yaml" "${CFG_DIR}/otelcol-config.yaml"

  if [[ ! -x "${BIN_DIR}/otelcol-contrib" ]]; then
    warn "otelcol-contrib not found at ${BIN_DIR}/otelcol-contrib"
    warn "install the pinned binary there (no Homebrew formula); see setup/mac-side/README.md"
  fi
}

install_agent() {
  local label="$1"
  local src="${MAC_SIDE}/launchd/${label}.plist"
  local dst="${AGENTS_DIR}/${label}.plist"
  [[ -f "${src}" ]] || die "missing plist template: ${src}"
  # Substitute the __HOME__ placeholder with the real home dir (never committed).
  sed "s|__HOME__|${HOME}|g" "${src}" >"${dst}"
  chmod 0644 "${dst}"
}

load_agent() {
  local label="$1"
  local dst="${AGENTS_DIR}/${label}.plist"
  local uid domain
  uid="$(id -u)"
  domain="gui/${uid}"
  # Re-load cleanly. `launchctl bootout` is ASYNC: bootstrapping before the old record
  # clears races and fails with "Input/output error" (errno 5), leaving the agent
  # UNLOADED — observed on a fresh host:up when a prior session's agent was still
  # registered (e.g. after a base-name/port change). So: bootout, WAIT (bounded) for
  # the label to actually disappear, then bootstrap with a few retries.
  launchctl bootout "${domain}/${label}" 2>/dev/null || true
  local waited=0
  while launchctl print "${domain}/${label}" >/dev/null 2>&1; do
    [[ "${waited}" -ge 10 ]] && break # ~5s cap
    sleep 0.5
    waited=$((waited + 1))
  done
  local attempt
  for attempt in 1 2 3; do
    if launchctl bootstrap "${domain}" "${dst}"; then
      info "loaded ${label}"
      return 0
    fi
    warn "bootstrap ${label} attempt ${attempt}/3 failed; re-booting out and retrying"
    launchctl bootout "${domain}/${label}" 2>/dev/null || true
    sleep 1
  done
  warn "launchctl bootstrap failed for ${label} after 3 attempts (check 'host:status')"
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || die "host:up targets macOS (Darwin) only"
  stage_scripts
  local label
  for label in "${LABELS[@]}"; do
    install_agent "${label}"
    load_agent "${label}"
  done
  info "host services started; run 'mise run host:smoke' to verify"
}

main "$@"
