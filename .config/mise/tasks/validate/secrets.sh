#!/usr/bin/env bash
#MISE description="Scan the tree for secret-shaped material with gitleaks."
# .config/mise/tasks/validate/secrets.sh — scan the tree for secret-shaped material (spec §15.1).
#
# Runs Gitleaks in two explicit modes using the repo .gitleaks.toml allowlist:
#   1. `gitleaks dir` over the filesystem tree, which catches untracked and
#      gitignored local plaintext/runtime artifacts under the repo.
#   2. `gitleaks git` over history, which catches committed secret-shaped values.
# This catches credential SHAPES that the named-token scrub guard
# (validate:scrub) does not. Both run; either failing fails the overall validate
# gate.
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

if ! command -v gitleaks >/dev/null 2>&1; then
  printf 'ERROR: gitleaks not found on PATH (need 8.30.1).\n' >&2
  exit 127
fi

config="${repo_root}/.gitleaks.toml"
common_args=(--no-banner --redact)
if [[ -f "${config}" ]]; then
  common_args+=(--config "${config}")
else
  printf 'WARNING: .gitleaks.toml not found; using gitleaks defaults.\n' >&2
fi

fail=0

printf 'publication guard: checking for repo-local plaintext/runtime artifact paths...\n'
shopt -s nullglob
candidate_paths=(
  .env
  .env.*
  .fnox
  .local
  .claude/otel-raw-bodies
  .claude/settings.local.json
  .claude/state
  .codex/auth.json
  .codex/*.local.*
  secrets/age
  secrets/shared.env
  secrets/*.dec
  secrets/*.env
  secrets/*.env.*
  secrets/*.env.runtime
  rendered-secrets
  rendered-secrets*.yaml
  *secret*.runtime.yaml
  *-secret.generated.yaml
)
shopt -u nullglob

blocked_paths=()
declare -A seen_blocked_paths=()
for path in "${candidate_paths[@]}"; do
  [[ -e "${path}" ]] || continue
  [[ "${path}" == ".env.example" ]] && continue
  [[ "${path}" == secrets/*.env.example ]] && continue
  if [[ -z "${seen_blocked_paths[${path}]:-}" ]]; then
    blocked_paths+=("${path}")
    seen_blocked_paths["${path}"]=1
  fi
done

if [[ "${#blocked_paths[@]}" -gt 0 ]]; then
  printf 'publication guard: remove or move these repo-local plaintext/runtime artifacts before publishing:\n' >&2
  printf '  %s\n' "${blocked_paths[@]}" >&2
  fail=1
else
  printf 'publication guard: no blocked repo-local plaintext/runtime artifact paths found.\n'
fi

printf 'gitleaks: scanning current filesystem tree for secret-shaped material...\n'
if gitleaks dir "${common_args[@]}" "."; then
  printf 'gitleaks: current filesystem tree clean.\n'
else
  printf 'gitleaks: secret-shaped material detected in current filesystem tree above.\n' >&2
  fail=1
fi

printf 'gitleaks: scanning git history for secret-shaped material...\n'
if gitleaks git "${common_args[@]}" "."; then
  printf 'gitleaks: git history clean.\n'
else
  printf 'gitleaks: secret-shaped material detected in git history above.\n' >&2
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  printf 'gitleaks: clean (current tree + git history).\n'
fi
exit "${fail}"
