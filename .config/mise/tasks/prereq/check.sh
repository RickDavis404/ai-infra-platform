#!/usr/bin/env bash
#MISE description="Verify required host tools and versions are present."
# .config/mise/tasks/prereq/check.sh — verify required host tools and versions (spec §8.5).
#
# PASS/FAIL gate for the local host. Confirms Apple Silicon macOS, Homebrew, and the
# pinned tool surface (mise + the Brewfile binaries). Versions are checked as a
# minimum where a clean parse is available; presence is required for all. This is a
# read-only check — it installs nothing (use bootstrap.sh for that).
set -euo pipefail

repo_root="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

if [[ -f "${repo_root}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${repo_root}/.config/mise/lib/common.sh"
fi

pass=0
fail=0

ok() {
  printf 'PASS  %s\n' "$*"
  pass=$((pass + 1))
}
bad() {
  printf 'FAIL  %s\n' "$*" >&2
  fail=$((fail + 1))
}

# --- Platform: macOS on Apple Silicon ---
if [[ "$(uname -s)" == "Darwin" ]]; then
  ok "platform: macOS ($(uname -s))"
else
  bad "platform: expected macOS (Darwin), got $(uname -s)"
fi

if [[ "$(uname -m)" == "arm64" ]]; then
  ok "architecture: Apple Silicon (arm64)"
else
  bad "architecture: expected arm64 (Apple Silicon), got $(uname -m)"
fi

# --- bash 4+ (macOS ships 3.2; scripts use mapfile / assoc arrays, spec §8.2) ---
if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
  ok "bash: ${BASH_VERSION} (>= 4)"
else
  bad "bash: ${BASH_VERSION:-unknown} too old; need >= 4 (brew install bash; /opt/homebrew/bin must precede /usr/bin on PATH)"
fi

# --- Homebrew (Apple Silicon prefix /opt/homebrew) ---
if command -v brew >/dev/null 2>&1; then
  ok "homebrew: $(brew --version | head -n1)"
else
  bad "homebrew: not found (bootstrap.sh installs it via the official installer)"
fi

# --- git ---
if command -v git >/dev/null 2>&1; then
  ok "git: $(git --version)"
else
  bad "git: not found"
fi

# --- Required tool surface (presence). Versions are pinned via mise [tools]. ---
required_tools=(
  mise fnox age lima kubectl kustomize helm cilium
  jq yq pre-commit gitleaks shellcheck shfmt yamllint
)
for tool in "${required_tools[@]}"; do
  if command -v "${tool}" >/dev/null 2>&1; then
    ok "tool present: ${tool}"
  else
    bad "tool missing: ${tool} (brew bundle / mise install provides it)"
  fi
done

# --- Mac-side service binaries (host model serving + telemetry, §8.3/§8.4) ---
host_tools=(llama-server llama-swap macmon)
for tool in "${host_tools[@]}"; do
  if command -v "${tool}" >/dev/null 2>&1; then
    ok "host tool present: ${tool}"
  else
    printf 'WARN  host tool missing: %s (needed only for host:up)\n' "${tool}" >&2
  fi
done

# otelcol-contrib may be staged to ~/.local/bin (no homebrew-core formula, §8.3).
if command -v otelcol-contrib >/dev/null 2>&1 || [[ -x "${HOME}/.local/bin/otelcol-contrib" ]]; then
  ok "host tool present: otelcol-contrib"
else
  printf 'WARN  host tool missing: otelcol-contrib (stage pinned binary to ~/.local/bin)\n' >&2
fi

printf '\nprereq-check: %d passed, %d failed.\n' "${pass}" "${fail}"
if [[ "${fail}" -ne 0 ]]; then
  printf 'prereq-check: FAIL — run: mise run bootstrap  (or fix the items above).\n' >&2
  exit 1
fi
printf 'prereq-check: PASS\n'
