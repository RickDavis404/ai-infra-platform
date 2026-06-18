#!/usr/bin/env bash
#MISE description="Copy the cluster kubeconfig to ./.local/kube/config and rewrite server to the kube-vip VIP."
set -euo pipefail

# lima:kubeconfig — copy ai-inf-platform-0's copied-from-guest kubeconfig to the repo-local
# KUBECONFIG (under ./.local/kube, gitignored — it is a credential), rewrite the
# `server:` field to https://<AI_INFRA_CP_VIP>:6443 (the kube-vip control-plane VIP,
# reachable directly from the host on the shared L2), set mode 600, and print the
# KUBECONFIG export. Idempotent; safe to re-run after any start.
#
# IP parameterization: the VIP is env-driven (AI_INFRA_CP_VIP, default 192.168.105.40)
# so init's 99-local.toml override applies. The SOURCE is unchanged —
# ~/.lima/ai-inf-platform-0/copied-from-guest/kubeconfig.yaml (the template's copyToHost target).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

readonly NODE0="ai-inf-platform-0"
readonly VIP="${AI_INFRA_CP_VIP:-192.168.105.40}"
readonly VIP_ENDPOINT="https://${VIP}:6443"
# KUBECONFIG is defined in conf.d/10-env.toml as {{config_root}}/.local/kube/config;
# fall back to that same .local path when run outside mise's env.
readonly DEST="${KUBECONFIG:-${REPO_ROOT}/.local/kube/config}"

# Temp file for the atomic rewrite. GLOBAL (not a main() local) + initialized empty so
# the EXIT trap below can clean it up without tripping `set -u` after main() returns.
tmp=""
cleanup_tmp() { rm -f -- "${tmp}"; }
add_exit_trap cleanup_tmp

# Resolve ai-inf-platform-0's Lima instance directory, then its copyToHost kubeconfig path.
node0_dir() {
  local dir
  dir="$(limactl list --format '{{.Dir}}' "${NODE0}" 2>/dev/null || true)"
  if [ -z "${dir}" ]; then
    dir="${LIMA_HOME:-${HOME}/.lima}/${NODE0}"
  fi
  printf '%s\n' "${dir}"
}

main() {
  require_cmd limactl

  local dir src
  dir="$(node0_dir)"
  src="${dir}/copied-from-guest/kubeconfig.yaml"
  [ -f "${src}" ] || die "node-0 kubeconfig not found at ${src} (is ${NODE0} running?)"

  mkdir -p "$(dirname "${DEST}")"

  # Rewrite the server address to the VIP endpoint. Write to a temp file, then move
  # into place atomically with restrictive perms. tmp is the script global declared
  # above (with the EXIT trap) so cleanup survives main() returning under set -u.
  tmp="$(mktemp "${DEST}.XXXXXX")"
  sed -E "s#(server:[[:space:]]*)https?://[^[:space:]]+#\1${VIP_ENDPOINT}#" "${src}" >"${tmp}"

  if ! grep -q "server: ${VIP_ENDPOINT}" "${tmp}"; then
    die "failed to rewrite server endpoint to ${VIP_ENDPOINT} in kubeconfig"
  fi

  install -m 600 "${tmp}" "${DEST}"
  info "wrote host kubeconfig: ${DEST} (server -> ${VIP_ENDPOINT}, mode 600)"
  printf 'export KUBECONFIG=%s\n' "${DEST}"
}

main "$@"
