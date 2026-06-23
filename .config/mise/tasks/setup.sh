#!/usr/bin/env bash
#MISE description="Run the full local bootstrap (prereqs, brew bundle, mise install, hooks)."
set -euo pipefail

# setup — sequential bootstrap wrapper. A depends-only mise task would run children
# in parallel, which races bootstrap/mise install against pre-commit hook setup.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

main() {
  require_cmd mise

  info "=== setup phase 1/3: prereq:check ==="
  mise run prereq:check

  info "=== setup phase 2/3: bootstrap ==="
  mise run bootstrap

  info "=== setup phase 3/3: precommit:install ==="
  mise run precommit:install

  info "=== setup complete ==="
}

main "$@"
