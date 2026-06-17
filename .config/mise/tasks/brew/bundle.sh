#!/usr/bin/env bash
#MISE description="Install host dependencies from the repo Brewfile."
# .config/mise/tasks/brew/bundle.sh — install host dependencies from the repo Brewfile (spec §8.5).
#
# Runs `brew bundle` against the repo-root Brewfile. Idempotent: re-running installs
# only what is missing. Apple Silicon (/opt/homebrew) is assumed.
set -euo pipefail

repo_root="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
. "${repo_root}/.config/mise/lib/common.sh"
cd "${repo_root}"

if ! command -v brew >/dev/null 2>&1; then
  printf 'ERROR: Homebrew not found. Run: mise run bootstrap  first (installs brew).\n' >&2
  exit 1
fi

brewfile="${repo_root}/Brewfile"
if [[ ! -f "${brewfile}" ]]; then
  printf 'ERROR: Brewfile not found at %s\n' "${brewfile}" >&2
  exit 1
fi

printf 'brew bundle: installing host dependencies from %s ...\n' "${brewfile#"${repo_root}"/}"
brew bundle --file "${brewfile}"
printf 'brew bundle: done.\n'
