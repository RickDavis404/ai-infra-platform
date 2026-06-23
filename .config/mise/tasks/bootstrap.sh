#!/usr/bin/env bash
#MISE description="Install Homebrew if missing, run brew bundle, mise install, install hooks."
# .config/mise/tasks/bootstrap.sh — one-shot host bootstrap (spec §8.5 steps 1-4).
#
# Idempotent host setup:
#   1. Install Homebrew via the official installer if missing, then load its shellenv.
#   2. `brew analytics off` (privacy/quiet), then `brew bundle` from the repo Brewfile.
#   3. `mise install` to materialize the pinned [tools] versions.
#   4. `pre-commit install --install-hooks` so commits run the local validation subset.
# Re-running is safe: each step is a no-op when already satisfied. No secrets are
# touched here (fnox+age is a separate step, §8.5 step 5).
set -euo pipefail

repo_root="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
. "${repo_root}/.config/mise/lib/common.sh"
cd "${repo_root}"

phase() {
  _ai_infra_mise_write_event "info" "bootstrap: $*"
  printf '\n==> %s\n' "$*"
}

# --- 1. Homebrew (Apple Silicon prefix /opt/homebrew) ---
phase "Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    printf 'Installing Homebrew via the official installer...\n'
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
else
  printf 'Homebrew already installed: %s\n' "$(brew --version | head -n1)"
fi

# Privacy/quiet: disable analytics before any bundle run (idempotent).
brew analytics off || true

# --- 2. Host dependencies from the Brewfile ---
phase "brew bundle (host dependencies)"
bash "${repo_root}/.config/mise/tasks/brew/bundle.sh"

# --- 3. mise pinned tools ---
phase "mise install (pinned [tools])"
if command -v mise >/dev/null 2>&1; then
  # mise trust is required once for the repo config; tolerate already-trusted.
  mise trust --yes "${repo_root}" >/dev/null 2>&1 || true
  mise install
else
  printf 'WARNING: mise not on PATH after brew bundle. Activate mise, then run: mise install\n' >&2
fi

# --- 4. Git hooks ---
phase "pre-commit hooks"
bash "${repo_root}/.config/mise/tasks/precommit/install.sh"

phase "bootstrap complete"
printf 'Next: ensure your age key is present (fnox+age, §8.5 step 5), then run: mise run up\n'
