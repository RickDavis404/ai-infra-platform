#!/usr/bin/env bash
#MISE description="Lint all repo shell scripts with shellcheck."
# .config/mise/tasks/validate/shell.sh — lint every repo shell script with shellcheck (spec §15.1).
#
# Dialect forced to bash; the repo .shellcheckrc supplies external-sources=true and
# source-path=SCRIPTDIR/. so helper-library sourcing does not raise SC1091.
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'ERROR: shellcheck not found on PATH (need 0.11.0).\n' >&2
  exit 127
fi

# Collect every mise file-task (.config/mise/tasks/**/*.sh) plus the sourced helper
# library (.config/mise/lib/*.sh). find avoids unsafe globstar dependence.
mapfile -t scripts < <(find .config/mise/tasks -type f -name '*.sh' | sort)

if [[ -d .config/mise/lib ]]; then
  mapfile -t -O "${#scripts[@]}" scripts < <(find .config/mise/lib -type f -name '*.sh' | sort)
fi

# Include any other repo *.sh outside the mise tree (e.g. setup/mac-side helpers).
if [[ -d setup ]]; then
  mapfile -t -O "${#scripts[@]}" scripts < <(find setup -type f -name '*.sh' | sort)
fi

if [[ "${#scripts[@]}" -eq 0 ]]; then
  printf 'WARNING: no shell scripts found to lint.\n' >&2
  exit 0
fi

printf 'shellcheck: linting %d script(s)...\n' "${#scripts[@]}"
shellcheck -s bash "${scripts[@]}"
printf 'shellcheck: clean\n'
