#!/usr/bin/env bash
#MISE description="Report host CPU/RAM/disk vs each profile's requirements (lean/HA) and recommend one. Read-only — never brings anything up."
set -euo pipefail

# preflight:resources — stand-alone, read-only resource report. Prints the same
# table the interactive `up` dispatcher uses to decide lean/HA, but never prompts
# and never triggers a bring-up, so it is safe to run any time to check a host.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/preflight.sh"
install_err_trap

preflight_render
info "preflight:resources — recommendation: ${PF_RECOMMENDED} (run 'mise run up' to choose interactively, or 'mise run up:lean' / 'up:ha')"
