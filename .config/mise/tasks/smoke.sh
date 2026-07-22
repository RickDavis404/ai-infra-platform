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

  info "=== smoke phase 1/8: k8s:cilium:smoke ==="
  mise run k8s:cilium:smoke

  info "=== smoke phase 2/8: host:smoke ==="
  mise run host:smoke

  info "=== smoke phase 3/8: models:check ==="
  mise run models:check

  info "=== smoke phase 4/8: langfuse:smoke ==="
  mise run langfuse:smoke

  info "=== smoke phase 5/8: litellm:smoke ==="
  mise run litellm:smoke

  info "=== smoke phase 6/8: lgtm:smoke ==="
  mise run lgtm:smoke

  info "=== smoke phase 7/8: otel:smoke ==="
  mise run otel:smoke

  # §8c credential-scrub regression gate. Reads the spend-log DB only; explicitly
  # SKIPS (never fails) when no gateway traffic exists yet, so a cold `mise run smoke`
  # stays green and it asserts once codex/claude passthrough rows are present.
  info "=== smoke phase 8/8: litellm:verify-scrub ==="
  mise run litellm:verify-scrub

  info "=== smoke complete ==="
}

main "$@"
