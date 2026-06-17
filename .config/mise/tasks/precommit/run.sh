#!/usr/bin/env bash
#MISE description="Run all pre-commit hooks across the full repository."
# .config/mise/tasks/precommit/run.sh — run all pre-commit hooks across the repo (spec §8.2).
#
# Runs the full hook set over every tracked file (not just staged changes). Useful as
# a one-shot local gate equivalent to what CI runs.
set -euo pipefail

repo_root="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
. "${repo_root}/.config/mise/lib/common.sh"
cd "${repo_root}"

if ! command -v pre-commit >/dev/null 2>&1; then
  printf 'ERROR: pre-commit not found. Run: mise run brew:bundle  / mise install  first.\n' >&2
  exit 1
fi

if [[ ! -f "${repo_root}/.pre-commit-config.yaml" ]]; then
  printf 'ERROR: .pre-commit-config.yaml not found at repo root.\n' >&2
  exit 1
fi

printf 'pre-commit: running all hooks across the full repository...\n'
pre-commit run --all-files
printf 'pre-commit: all hooks passed.\n'
