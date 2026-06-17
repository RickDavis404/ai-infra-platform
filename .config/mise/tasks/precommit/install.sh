#!/usr/bin/env bash
#MISE description="Install pre-commit git hooks for this repository."
# .config/mise/tasks/precommit/install.sh — install pre-commit git hooks (spec §8.5 step 4).
#
# Installs the pre-commit hooks (and their hook environments) for this repository so
# the local fast validation subset runs on every commit. Idempotent.
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

printf 'pre-commit: installing git hooks...\n'
pre-commit install --install-hooks
printf 'pre-commit: hooks installed.\n'
