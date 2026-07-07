#!/usr/bin/env bash
#MISE description="Bring up the whole lab in the HA (3-node) profile — for 32GB+ hosts (e.g. the MacBook Pro). Same flow as 'up', pinned to the HA profile."
set -euo pipefail

# up:ha — thin profile-pinning wrapper. It exports AI_INFRA_PROFILE=ha (the INTERNAL
# profile plumbing every lifecycle phase reads) and delegates to the non-interactive
# engine `up:run` (.config/mise/tasks/up/run.sh) so there is NO duplicated bring-up
# logic. A bare `mise run up` runs the resource preflight and PROMPTS lean/HA/abort;
# run THIS to stand up the 3-node HA topology non-interactively (skips the prompt).
# See docs/profiles.md.
#
# NB: switching the profile of an ALREADY-created cluster needs a from-bare recreate
# (`mise run lima:recreate:ha`), not this — VM sizing/node-count is fixed at create
# time. On a fresh host (no ai-inf-platform-* instances) `up:ha` creates HA directly.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

export AI_INFRA_PROFILE=ha
info "up:ha — profile=ha (3-node HA); delegating to 'mise run up:run'"
mise run up:run
