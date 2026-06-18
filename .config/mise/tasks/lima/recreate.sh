#!/usr/bin/env bash
#MISE description="Delete then recreate the Lima kubeadm instances from the template."
set -euo pipefail

# lima:recreate — lima:delete followed by lima:start. This is the REQUIRED path for any
# change to lima/templates/k8s-cilium.yaml or the per-node sizing (cpus/memory/disk are
# not hot-editable), because Lima does not re-read the template on a plain restart or
# factory-reset.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

main() {
  info "lima:recreate — delete then start"
  "${SCRIPT_DIR}/delete.sh"
  "${SCRIPT_DIR}/start.sh"
  info "lima:recreate complete"
}

main "$@"
