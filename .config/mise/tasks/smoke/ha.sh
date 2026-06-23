#!/usr/bin/env bash
#MISE description="Run the full HA + reliability smoke suite."
set -euo pipefail

# smoke:ha — sequential failure-injection suite. These leaves mutate cluster
# scheduling/pods/nodes, so running them in parallel can invalidate each result.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

main() {
  require_cmd mise

  info "=== smoke:ha phase 1/4: node-loss ==="
  mise run smoke:ha:node-loss

  info "=== smoke:ha phase 2/4: recovery ==="
  mise run smoke:ha:recovery

  info "=== smoke:ha phase 3/4: pod-loss ==="
  mise run smoke:ha:pod-loss

  info "=== smoke:ha phase 4/4: data-integrity ==="
  mise run smoke:ha:data-integrity

  info "=== smoke:ha complete ==="
}

main "$@"
