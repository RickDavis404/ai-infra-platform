#!/usr/bin/env bash
#MISE description="Port-forward Langfuse to 127.0.0.1:33000."
# .config/mise/tasks/port-forward/langfuse.sh — port-forward Langfuse web to 127.0.0.1:33000.
#
# Binds the loopback address ONLY. The Langfuse UI requires login (no anon access).
# Foreground process; Ctrl-C tears the forward down.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

if [[ -f "${REPO_ROOT}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.config/mise/lib/common.sh"
fi
declare -F info >/dev/null 2>&1 || info() { printf '[info] %s\n' "$*" >&2; }
declare -F err >/dev/null 2>&1 || err() { printf '[err ] %s\n' "$*" >&2; }
declare -F die >/dev/null 2>&1 || die() {
  err "$@"
  exit 1
}
declare -F need >/dev/null 2>&1 || need() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}
declare -F kc >/dev/null 2>&1 || kc() {
  KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kube/config}" kubectl "$@"
}

readonly NS="langfuse"
readonly TARGET="svc/langfuse-web"
readonly LOCAL_PORT="${LANGFUSE_LOCAL_PORT:-33000}"
readonly REMOTE_PORT="3000"

main() {
  need kubectl
  info "port-forward ${TARGET} -n ${NS} -> 127.0.0.1:${LOCAL_PORT} (loopback only; login required)"
  exec kc -n "${NS}" port-forward --address 127.0.0.1 \
    "${TARGET}" "${LOCAL_PORT}:${REMOTE_PORT}"
}

main "$@"
