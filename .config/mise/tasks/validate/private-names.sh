#!/usr/bin/env bash
#MISE description="Fail if any forbidden private name/path is present (rg guard)."
# .config/mise/tasks/validate/private-names.sh — rg guard for forbidden private names/paths (spec §8.2).
#
# Forbidden tokens are stored in .config/mise/lib/forbidden-names.txt (one regex per
# line, gitignored from the public guard output) so the patterns themselves never
# appear inline. They cover: the org name, private internal domains, customer
# prefixes, tailnet hostnames, real absolute home paths, and the alternate VM
# runtime name. This file AND the working list self-exclude from the scan.
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

if ! command -v rg >/dev/null 2>&1; then
  printf 'ERROR: ripgrep (rg) not found on PATH.\n' >&2
  exit 127
fi

list="${repo_root}/.config/mise/lib/forbidden-names.txt"
if [[ ! -f "${list}" ]]; then
  printf 'ERROR: %s not found. Copy the template:\n' "${list}" >&2
  printf '  cp .config/mise/lib/forbidden-names.txt.example .config/mise/lib/forbidden-names.txt\n' >&2
  exit 1
fi

# Read non-comment, non-blank pattern lines and OR them into one alternation.
mapfile -t patterns < <(grep -vE '^[[:space:]]*(#|$)' "${list}")
if [[ "${#patterns[@]}" -eq 0 ]]; then
  printf 'WARNING: no patterns in %s — nothing to guard.\n' "${list}" >&2
  exit 0
fi
pat="$(
  IFS='|'
  echo "${patterns[*]}"
)"

# Scan the publishable tree. The guard script, the working pattern list, and the
# committed template all self-exclude so their own literals are not flagged. Helm
# chart CACHES (build artifacts) and planning/** (pre-publication source-of-truth
# specs the guard scrubs FROM) are excluded by definition; .claude/.codex/docs and
# authored kubernetes manifests are NOT excluded so real leaks still surface.
if rg -n --hidden \
  --glob '!.git' \
  --glob '!.config/mise/tasks/validate/*' \
  --glob '!.config/mise/lib/render-all.sh' \
  --glob '!.config/mise/lib/forbidden-names.txt' \
  --glob '!.config/mise/lib/forbidden-names.txt.example' \
  --glob '!.config/mise/tasks/codex/smoke.sh' \
  --glob '!.config/mise/tasks/claude/smoke.sh' \
  --glob '!**/charts/**' \
  --glob '!planning/**' \
  --glob '!.agents/skills/**' \
  -e "${pat}" .; then
  printf 'ERROR: forbidden private/publication-unsafe token found above.\n' >&2
  exit 1
fi
printf 'private-names: clean (no forbidden tokens).\n'
