#!/usr/bin/env bash
#MISE description="Re-mint LiteLLM virtual keys + teams (delete completed Jobs, re-apply keys overlay) to pick up budget/limit changes."
# .config/mise/tasks/litellm/remint-keys.sh — re-run the idempotent key/team provision
# Jobs so edited budgets/limits in kubernetes/litellm/keys/*.yaml take effect on a RUNNING
# cluster WITHOUT a full rebuild. Job pod templates are immutable, so we delete the
# completed Jobs first, then re-apply the keys overlay (which re-creates them). The mint
# script is idempotent: existing keys/teams are PATCHED (/key/update, /team/update) and
# fixed-value keys keep their fnox token (NO rotation).
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
require_cmd kustomize

jobs=(litellm-team-provision litellm-key-claude-code litellm-key-codex litellm-key-smoke-test)

info "deleting completed provision Jobs so their edited (immutable) templates can re-run"
kc delete job -n litellm "${jobs[@]}" --ignore-not-found

info "re-applying litellm/keys overlay (re-runs the mint Jobs; idempotent GET-then-PATCH/POST)"
kustomize build "${REPO_ROOT}/kubernetes/litellm/keys" | kc apply --server-side --force-conflicts -f -

info "waiting for provision Jobs to complete (team first; key Jobs init-wait on the team-ids secret)"
for j in "${jobs[@]}"; do
  if ! kc wait --for=condition=Complete --timeout=180s -n litellm "job/${j}"; then
    warn "job/${j} did not reach Complete in 180s; inspect: kubectl logs -n litellm job/${j}"
  fi
done

info "remint complete — key/team budgets + limits reconciled from the manifests"
