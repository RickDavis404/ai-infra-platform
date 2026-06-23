#!/usr/bin/env bash
#MISE description="Port-forward Grafana to 127.0.0.1:33001."
# .config/mise/tasks/port-forward/grafana.sh — port-forward Grafana to 127.0.0.1:33001.
#
# Binds the loopback address ONLY. Local port 33001 maps to the in-cluster Grafana
# service port 3000 (so it can coexist with the Langfuse forward on 33000). Grafana
# requires login (no anonymous access). Foreground; Ctrl-C tears it down.
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

readonly NS="lgtm"
readonly TARGET="svc/grafana"
readonly LOCAL_PORT="${GRAFANA_LOCAL_PORT:-33001}"
readonly REMOTE_PORT="3000"

main() {
  need kubectl
  info "port-forward ${TARGET}:${REMOTE_PORT} -n ${NS} -> 127.0.0.1:${LOCAL_PORT} (loopback only; login required)"
  exec kc -n "${NS}" port-forward --address 127.0.0.1 \
    "${TARGET}" "${LOCAL_PORT}:${REMOTE_PORT}"
}

main "$@"
