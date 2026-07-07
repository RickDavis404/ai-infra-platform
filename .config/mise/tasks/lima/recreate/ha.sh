#!/usr/bin/env bash
#MISE description="From-bare recreate of the Lima cluster in the HA (3-node) profile — the required path to SWITCH an existing cluster to HA (sizing is fixed at create)."
set -euo pipefail

# lima:recreate:ha — profile-pinning wrapper around `lima:recreate` (delete + start).
# VM sizing / node-count is fixed at CREATE, so switching an already-created cluster's
# profile needs a from-bare delete+recreate, not down->up. This exports
# AI_INFRA_PROFILE=ha and delegates to the single lima:recreate implementation so there
# is NO duplicated logic. See docs/profiles.md.
#
# WARNING: lima:recreate DELETES the VMs (and their PVC data) before recreating —
# it is destructive. Use `mise run up:ha` on a fresh host; use this to convert an
# existing lean cluster to HA.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

export AI_INFRA_PROFILE=ha
info "lima:recreate:ha — profile=ha (3-node HA); delegating to 'mise run lima:recreate'"
mise run lima:recreate
