#!/usr/bin/env bash
#MISE description="Port-forward the in-cluster OTel Collector OTLP/HTTP to 127.0.0.1:34318."
# .config/mise/tasks/port-forward/otel.sh — port-forward the in-cluster OTel Collector OTLP/HTTP
# receiver to 127.0.0.1:34318.
#
# Binds the loopback address ONLY. Use plain `:34318` with `/v1/{traces,metrics,logs}`
# paths — there is NO `/otel` prefix. Foreground; Ctrl-C tears the forward down.
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
readonly TARGET="svc/otel-collector"
readonly LOCAL_PORT="${OTEL_LOCAL_PORT:-34318}"
readonly REMOTE_PORT="4318"

main() {
  need kubectl
  info "port-forward ${TARGET}:${REMOTE_PORT} -n ${NS} -> 127.0.0.1:${LOCAL_PORT} (loopback only; /v1/* paths, no /otel prefix)"
  exec kc -n "${NS}" port-forward --address 127.0.0.1 \
    "${TARGET}" "${LOCAL_PORT}:${REMOTE_PORT}"
}

main "$@"
