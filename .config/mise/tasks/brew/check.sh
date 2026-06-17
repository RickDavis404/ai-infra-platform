#!/usr/bin/env bash
#MISE description="Check whether Brewfile dependencies are installed (idempotent gate)."
# .config/mise/tasks/brew/check.sh — idempotent "are Brewfile deps installed?" gate (spec §8.3).
#
# Wraps `brew bundle check` so callers can gate on dependency presence without
# triggering an install.
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

printf 'brew bundle check: verifying dependencies from %s ...\n' "${brewfile#"${repo_root}"/}"
if brew bundle check --file "${brewfile}"; then
  printf 'brew bundle check: all dependencies satisfied.\n'
else
  printf 'brew bundle check: missing dependencies — run: mise run brew:bundle\n' >&2
  exit 1
fi
