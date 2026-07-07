#!/usr/bin/env bash
#MISE description="Bring up the whole lab. Runs a host resource preflight, then prompts lean/HA/abort. (up:lean / up:ha skip the prompt.)"
#MISE raw=true
set -euo pipefail

# up — the INTERACTIVE bring-up entrypoint.
#
# `mise run up` (bare) runs a host CPU/RAM/disk preflight, prints a per-profile
# requirements-vs-available table, recommends a profile, and prompts the operator to
# choose lean / HA / abort. It then exports AI_INFRA_PROFILE and hands off to the
# non-interactive engine `up:run`.
#
# `#MISE raw=true` connects stdin to the terminal so the prompt's `read` works — mise
# does NOT wire stdin to tasks by default (same reason codex:launch is raw). The raw
# scope is deliberately confined to this short prompt; the long bring-up (`up:run`)
# runs as an ordinary non-raw task, and the explicit `up:lean` / `up:ha` wrappers call
# `up:run` directly, so they never hit the prompt and stay CI-safe.
#
# Non-interactive / CI (`mise run up` with no TTY): the preflight still prints
# (report-only) and it defaults to the documented lean profile without prompting —
# use `up:ha` to select HA explicitly in automation.
#
# AI_INFRA_UP_DRYRUN=1 prints the preflight + resolved choice and STOPS before the
# bring-up (nothing is created) — a safe way to preview which profile `up` would pick.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/preflight.sh"
install_err_trap

# If a profile is already pinned in the environment, honour it and skip the prompt
# (defensive — the normal explicit paths are up:lean / up:ha, which call up:run).
if [[ -n "${AI_INFRA_PROFILE:-}" ]]; then
  info "up — AI_INFRA_PROFILE=${AI_INFRA_PROFILE} already set; skipping preflight prompt."
  choice="${AI_INFRA_PROFILE}"
else
  preflight_render # prints the table; sets PF_RECOMMENDED / PF_LEAN_FITS / PF_HA_FITS
  choice=""
fi

# Resolve the profile when it was not pre-set: prompt on a TTY, else default lean.
if [[ -z "${choice}" ]]; then
  if [[ -t 0 ]]; then
    while :; do
      printf '\nSelect profile [lean / ha / abort] (default: %s): ' "${PF_RECOMMENDED}" >&2
      read -r ans || ans=""
      ans="$(printf '%s' "${ans}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
      [[ -z "${ans}" ]] && ans="${PF_RECOMMENDED}"
      case "${ans}" in
        lean | l)
          choice="lean"
          break
          ;;
        ha | h)
          choice="ha"
          break
          ;;
        abort | a | q | quit | n)
          info "up — aborted by operator; nothing was brought up."
          exit 0
          ;;
        *) warn "unrecognized choice '${ans}' — enter lean, ha, or abort." ;;
      esac
    done
  else
    # No TTY (automation): keep the historical default (lean); do not silently pick HA.
    choice="lean"
    warn "up — non-interactive (no TTY); defaulting to lean. Use 'mise run up:ha' for HA in automation."
  fi
fi

# Warn if the operator picked HA despite a preflight shortfall (only meaningful when
# the preflight actually ran — i.e. the profile was not pre-set).
if [[ "${choice}" == "ha" && "${PF_HA_FITS:-1}" != "1" ]]; then
  warn "up — proceeding with HA despite a preflight shortfall (operator choice)."
fi

export AI_INFRA_PROFILE="${choice}"
if [[ "${AI_INFRA_UP_DRYRUN:-0}" == "1" ]]; then
  info "up — DRY RUN: would bring up profile=${choice} (up:run). Nothing created."
  exit 0
fi
info "up — profile=${choice}; starting bring-up (up:run)."
exec mise run up:run
