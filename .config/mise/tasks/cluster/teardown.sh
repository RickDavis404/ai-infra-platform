#!/usr/bin/env bash
#MISE description="Full teardown: lima:delete (kubeadm reset + Cilium cleanup) plus host-side artifact cleanup."
set -euo pipefail

# cluster:teardown — full teardown runbook.
#
# = lima:delete (in-guest Cilium iface cleanup + `kubeadm reset` BEFORE `limactl
#   delete` each instance) PLUS host-side cleanup of the generated, never-committed
#   local artifacts:
#     - the copied/rewritten kubeconfig (KUBECONFIG / .kube/config)
#     - any leftover copied-from-guest kubeconfig under the Lima instance dirs
#     - secrets/shared.env, moved to a timestamped backup so generated values are
#       preserved but the next init run creates a fresh plaintext input file
#
# It does NOT touch committed config, fnox/age secret material, or the host PVC data
# under .local/lima/<vm>/storage. That data is preserved across a `down`->`up`
# restart; it is wiped automatically the next time an instance is CREATED from bare
# (lima:start's prepare_host_mounts), so a from-bare rebuild starts truly clean.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

readonly NODES=("ai-inf-platform-0" "ai-inf-platform-1" "ai-inf-platform-2")
readonly HOST_KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.local/kube/config}"
readonly SHARED_ENV="${REPO_ROOT}/secrets/shared.env"

backup_plaintext_secrets() {
  if [ ! -f "${SHARED_ENV}" ]; then
    info "host cleanup: no secrets/shared.env plaintext file to back up"
    return
  fi

  local stamp backup
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${REPO_ROOT}/secrets/shared.env.backup-${stamp}"
  if [ -e "${backup}" ]; then
    backup="${backup}.$$"
  fi

  mv "${SHARED_ENV}" "${backup}"
  chmod 600 "${backup}" # macOS/BSD chmod rejects `--`
  info "moved secrets/shared.env to ${backup#"${REPO_ROOT}"/}"
  warn "restore this backup manually if you intend to reuse existing Langfuse data; otherwise next init generates fresh write-once values"
}

host_cleanup() {
  info "host cleanup: removing generated kubeconfig artifacts"
  if [ -f "${HOST_KUBECONFIG}" ]; then
    rm -f -- "${HOST_KUBECONFIG}"
    info "removed ${HOST_KUBECONFIG}"
  fi
  if command -v limactl >/dev/null 2>&1; then
    local node dir
    for node in "${NODES[@]}"; do
      dir="$(limactl list --format '{{.Dir}}' "${node}" 2>/dev/null || true)"
      if [ -n "${dir}" ] && [ -f "${dir}/copied-from-guest/kubeconfig.yaml" ]; then
        rm -f -- "${dir}/copied-from-guest/kubeconfig.yaml"
        info "removed ${dir}/copied-from-guest/kubeconfig.yaml"
      fi
    done
  fi
  backup_plaintext_secrets
}

main() {
  info "full teardown — delete instances (in-guest cleanup first), then host cleanup"
  "${REPO_ROOT}/.config/mise/tasks/lima/delete.sh"
  host_cleanup
  info "teardown complete — cluster destroyed, local kubeconfig artifacts removed"
  warn "fnox/age secret material + committed config are untouched; .local/lima/<vm>/storage PVC data persists until the next from-bare instance create (lima:start), which wipes it"
}

main "$@"
