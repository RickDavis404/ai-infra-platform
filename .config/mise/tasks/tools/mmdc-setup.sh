#!/usr/bin/env bash
#MISE description="Install the headless Chrome that mermaid-cli (mmdc) needs (peer dep; mise --ignore-scripts skips it)."
set -euo pipefail

# mermaid-cli (mmdc) is pinned in .config/mise/conf.d/00-tools.toml via the npm: backend, but `mise install`
# canNOT fetch the Chrome it renders with: puppeteer is a PEER dependency that npm does
# not auto-install, and the npm backend runs with --ignore-scripts so no browser is
# downloaded. This task closes that gap by installing a puppeteer-managed Chrome and
# verifying mmdc resolves. It is idempotent — re-running is a no-op once Chrome is present.

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
. "${REPO_ROOT}/.config/mise/lib/common.sh"

mmdc_log() { info "[mmdc-setup] $*"; }

if ! command -v mmdc >/dev/null 2>&1; then
  mmdc_log "mmdc not on PATH yet — run 'mise install' first (it is pinned via the npm: backend in .config/mise/conf.d/00-tools.toml)."
  exit 1
fi

mmdc_log "installing a puppeteer-managed Chrome (idempotent; skips download if already present)"
# `npx --yes` runs puppeteer's browser installer without a persisted global install.
# puppeteer caches under ~/.cache/puppeteer, so a second run just reports the cached build.
npx --yes puppeteer browsers install chrome

mmdc_log "verifying mmdc resolves"
mmdc --version

mmdc_log "done — mmdc + Chrome ready; validate with 'mise run validate:mermaid'"
