#!/usr/bin/env bash
#MISE description="Stop the ai-registry pull-through cache VM (data + config preserved). Pass --delete to destroy the VM (the host-persistent cache on .local/registry is kept)."
set -euo pipefail

# cache:down — stop (default) or delete the long-lived Docker Hub pull-through cache VM.
#
# DEFAULT (no args): `limactl stop ai-registry` — a clean pause. The VM, its data, and
# its config are preserved; the next `mise run cache:up` resumes it. This is NOT part of
# the normal `mise run down` cluster teardown — the cache is meant to OUTLIVE cluster
# teardowns so cold standups stay fast. Stop it only when you want the host RAM back.
#
# --delete : destroy the VM (`limactl delete --force ai-registry`). The host-persistent
# blob cache + config under <repoRoot>/.local/registry are KEPT (gitignored, on the
# Mac), so a later `cache:up` rebuilds the VM and re-attaches the warmed cache. Pass
# `--purge` ALSO to wipe the on-disk cache (rare; forces a full re-pull next time).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

readonly VM="ai-registry"
readonly REGISTRY_DIR="${REPO_ROOT}/.local/registry"

instance_exists() { limactl list --quiet 2>/dev/null | grep -qx "$1"; }

main() {
  require_cmd limactl

  local do_delete="no" do_purge="no" arg
  for arg in "$@"; do
    case "${arg}" in
    --delete) do_delete="yes" ;;
    --purge) do_purge="yes" ;;
    *) die "unknown argument: ${arg} (use --delete and/or --purge)" ;;
    esac
  done

  if ! instance_exists "${VM}"; then
    info "${VM} does not exist; nothing to stop/delete"
  elif [ "${do_delete}" = "yes" ]; then
    info "deleting ${VM} (host-persistent cache under .local/registry is preserved)"
    limactl delete --force "${VM}" || die "failed to delete ${VM}"
  else
    info "stopping ${VM} (data + config preserved; use --delete to destroy the VM)"
    limactl stop "${VM}" || warn "failed to stop ${VM} (already stopped?)"
  fi

  if [ "${do_purge}" = "yes" ]; then
    warn "purging the on-disk pull-through cache at ${REGISTRY_DIR#"${REPO_ROOT}/"} — next standup re-pulls every layer"
    rm -rf -- "${REGISTRY_DIR}/data"
    info "purged ${REGISTRY_DIR#"${REPO_ROOT}/"}/data"
  fi

  info "cache:down complete"
}

main "$@"
