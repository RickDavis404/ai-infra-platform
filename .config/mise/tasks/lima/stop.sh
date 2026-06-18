#!/usr/bin/env bash
#MISE description="Stop the Lima kubeadm instances without deleting them."
set -euo pipefail

# lima:stop — stop ai-inf-platform-2, ai-inf-platform-1, ai-inf-platform-0 (reverse order) via `limactl stop`.
# Instance state and disks are preserved; this is a clean pause, not a teardown. The
# host kubeconfig copy is removed on stop (template copyToHost deleteOnStop: true);
# lima:kubeconfig re-creates it after the next start.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

# Reverse start order: highest-numbered node first.
readonly NODES=("ai-inf-platform-2" "ai-inf-platform-1" "ai-inf-platform-0")

instance_exists() { limactl list --quiet 2>/dev/null | grep -qx "$1"; }

main() {
  require_cmd limactl
  local node
  for node in "${NODES[@]}"; do
    if instance_exists "${node}"; then
      info "stopping ${node} (state preserved)"
      limactl stop "${node}" || warn "failed to stop ${node} (already stopped?)"
    else
      info "${node} does not exist; skipping"
    fi
  done
  info "lima:stop complete — instances paused, disks preserved"
}

main "$@"
