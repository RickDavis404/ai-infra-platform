#!/usr/bin/env bash
#MISE description="Verify shfmt would not reformat any shell script."
# .config/mise/tasks/validate/shfmt.sh — verify shfmt would not reformat any shell script (spec §15.1).
#
# Diff mode (`-d`), 2-space indent (`-i 2`). Fails and prints the diff if any script
# would be reformatted. Matches .editorconfig (indent_size=2, LF, final newline).
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

if ! command -v shfmt >/dev/null 2>&1; then
  printf 'ERROR: shfmt not found on PATH (need 3.13.1).\n' >&2
  exit 127
fi

# Collect every mise file-task (.config/mise/tasks/**/*.sh) plus the sourced helper
# library (.config/mise/lib/*.sh). find avoids unsafe globstar dependence. The
# while/read append form is bash 3.2-safe (no mapfile).
scripts=()
while IFS= read -r script_path; do
  scripts+=("${script_path}")
done < <(find .config/mise/tasks -type f -name '*.sh' | sort)

if [[ -d .config/mise/lib ]]; then
  while IFS= read -r script_path; do
    scripts+=("${script_path}")
  done < <(find .config/mise/lib -type f -name '*.sh' | sort)
fi

if [[ -d setup ]]; then
  while IFS= read -r script_path; do
    scripts+=("${script_path}")
  done < <(find setup -type f -name '*.sh' | sort)
fi

# The repo-launcher bin dir holds EXTENSIONLESS shell wrappers (the committed `codex`
# launcher MUST be named `codex` to shadow the mise-managed binary on PATH), so match
# by shell shebang rather than a `.sh` suffix.
if [[ -d .config/bin ]]; then
  while IFS= read -r script_path; do
    IFS= read -r first_line <"${script_path}" || true
    [[ "${first_line}" == '#!'*sh* ]] && scripts+=("${script_path}")
  done < <(find .config/bin -type f | sort)
fi

if [[ "${#scripts[@]}" -eq 0 ]]; then
  printf 'WARNING: no shell scripts found to check.\n' >&2
  exit 0
fi

printf 'shfmt: checking formatting of %d script(s) (-d -i 2)...\n' "${#scripts[@]}"
if ! shfmt -d -i 2 "${scripts[@]}"; then
  printf 'shfmt: formatting differences found above — run: shfmt -w -i 2 <file>\n' >&2
  exit 1
fi
printf 'shfmt: clean\n'
