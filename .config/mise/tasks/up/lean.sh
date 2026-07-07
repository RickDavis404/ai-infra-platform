#!/usr/bin/env bash
#MISE description="Bring up the whole lab in the LEAN single-node profile (explicit; same as the default 'up') — for modest 16-24GB hosts."
set -euo pipefail

# up:lean — thin profile-pinning wrapper. It exports AI_INFRA_PROFILE=lean (the
# INTERNAL profile plumbing every lifecycle phase reads) and delegates to the
# non-interactive engine `up:run` (.config/mise/tasks/up/run.sh) so there is NO
# duplicated bring-up logic. Unlike a bare `mise run up` — which runs the resource
# preflight and PROMPTS lean/HA/abort — this pins lean and skips the prompt (so it is
# also CI-safe). It exists so the profile choice is DISCOVERABLE via `mise tasks`
# tab-completion alongside `up:ha`. See docs/profiles.md.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

export AI_INFRA_PROFILE=lean
info "up:lean — profile=lean (single-node, the default); delegating to 'mise run up:run'"
mise run up:run
