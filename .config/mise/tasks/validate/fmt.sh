#!/usr/bin/env bash
#MISE description="Verify shell/YAML/TOML formatting (no changes needed)."
# .config/mise/tasks/validate/fmt.sh — aggregate formatting gate (spec §8.2 validate:fmt).
#
# Verifies that shell and YAML formatting need no changes by delegating to the leaf
# checks (shfmt -d, yamllint). This is the "no reformat needed" gate: it does not
# rewrite anything; it fails if any formatter or linter would change a file.
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

# Delegate to the sibling validate file-tasks by path. Invoking the bodies directly
# keeps this gate self-contained (no mise re-entrancy / tool gate).
here="${repo_root}/.config/mise/tasks/validate"

rc=0
run_step() {
  local label="$1" script="$2"
  printf '== fmt: %s ==\n' "${label}"
  if bash "${script}"; then
    printf '== fmt: %s OK ==\n\n' "${label}"
  else
    printf '== fmt: %s FAILED ==\n\n' "${label}" >&2
    rc=1
  fi
}

run_step 'shfmt (shell formatting)' "${here}/shfmt.sh"
run_step 'yamllint (yaml formatting)' "${here}/yaml.sh"

if [[ "${rc}" -ne 0 ]]; then
  printf 'fmt: one or more formatting checks failed.\n' >&2
  exit 1
fi
printf 'fmt: all formatting checks clean.\n'
