#!/usr/bin/env bash
#MISE description="Run all component smoke tests."
set -euo pipefail

# smoke — sequential component checks. The OTel smoke depends on LGTM/collector
# readiness, and several leaf checks may open local port-forwards, so keep order
# explicit instead of relying on mise's parallel depends DAG.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

main() {
  require_cmd mise

  info "=== smoke phase 1/7: k8s:cilium:smoke ==="
  mise run k8s:cilium:smoke

  info "=== smoke phase 2/7: host:smoke ==="
  mise run host:smoke

  info "=== smoke phase 3/7: models:check ==="
  mise run models:check

  info "=== smoke phase 4/7: langfuse:smoke ==="
  mise run langfuse:smoke

  info "=== smoke phase 5/7: litellm:smoke ==="
  mise run litellm:smoke

  info "=== smoke phase 6/7: lgtm:smoke ==="
  mise run lgtm:smoke

  info "=== smoke phase 7/7: otel:smoke ==="
  mise run otel:smoke

  info "=== smoke complete ==="
}

main "$@"
