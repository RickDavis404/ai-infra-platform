#!/usr/bin/env bash
#MISE description="Show the ai-registry pull-through cache VM state, its shared-L2 address, and /v2/ reachability."
set -euo pipefail

# cache:status — best-effort health snapshot of the Docker Hub pull-through cache:
#   - Lima instance state (ai-registry).
#   - Discovered shared-L2 (lima0) IP and the AI_INFRA_REGISTRY_ADDR the cluster uses.
#   - registry:2 proxy container state (in-guest nerdctl).
#   - /v2/ reachability over the L2 from the host.
#   - Whether Docker Hub auth is configured (presence only — the token is NEVER printed).
#
# Each section degrades gracefully if the VM is down or a tool is missing.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"

readonly VM="ai-registry"
readonly REGISTRY_PORT="5000"
readonly REGISTRY_CONFIG="${REPO_ROOT}/.local/registry/config.yml"

section() { printf '\n=== %s ===\n' "$1"; }

main() {
  require_cmd limactl

  section "Lima instance"
  limactl list "${VM}" 2>/dev/null || warn "could not list ${VM} (not created yet? run 'mise run cache:up')"

  section "Shared-L2 address"
  local ip=""
  if [ "$(limactl list --format '{{.Status}}' "${VM}" 2>/dev/null || true)" = "Running" ]; then
    ip="$(limactl shell "${VM}" sh -c \
      "ip -4 -o addr show dev lima0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1" \
      2>/dev/null | tr -d '[:space:]')"
  fi
  if [ -n "${ip}" ]; then
    info "${VM} lima0 IP: ${ip} (cluster mirror endpoint: http://${ip}:${REGISTRY_PORT})"
  else
    warn "${VM} not running or lima0 IP not discoverable"
  fi
  if [ -n "${AI_INFRA_REGISTRY_ADDR:-}" ]; then
    info "AI_INFRA_REGISTRY_ADDR (what the cluster containerd uses): ${AI_INFRA_REGISTRY_ADDR}"
  else
    info "AI_INFRA_REGISTRY_ADDR not set in env — cluster falls back to the committed default in 10-env.toml"
  fi

  section "Proxy container (in-guest)"
  limactl shell "${VM}" sudo nerdctl ps --filter name=ai-registry-proxy 2>/dev/null ||
    warn "could not query the in-guest registry container (VM down?)"

  section "/v2/ reachability (over the L2)"
  if [ -n "${ip}" ] && curl -fsS "http://${ip}:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    info "registry /v2/ reachable at http://${ip}:${REGISTRY_PORT}/v2/ OK"
  else
    warn "registry /v2/ not reachable on the L2 (VM down, proxy not started, or IP unknown)"
  fi

  section "Docker Hub auth"
  if [ -f "${REGISTRY_CONFIG}" ] && grep -qE '^[[:space:]]*username:' "${REGISTRY_CONFIG}" 2>/dev/null; then
    info "proxy config has Docker Hub credentials configured (value NOT shown)"
  else
    warn "proxy config has NO Docker Hub credentials — running anonymously (lower pull limits). Set DOCKERHUB_USERNAME/DOCKERHUB_TOKEN in secrets/shared.env and re-run 'mise run cache:up'."
  fi
}

main "$@"
