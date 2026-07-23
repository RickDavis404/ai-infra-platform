#!/usr/bin/env bash
#MISE description="Install + enable the Langfuse codex-observability-plugin (client-side Stop-hook → Langfuse) into ~/.codex (per-machine, idempotent)."
# .config/mise/tasks/codex/install-plugins.sh — USER-layer Codex plugin install.
#
# The Langfuse `tracing` plugin captures codex sessions CLIENT-SIDE: a codex `Stop`
# hook re-reads each turn's rollout transcript and uploads it to Langfuse as a
# separate trace (model responses, reasoning, tool calls with I/O, subagents,
# token usage), session-grouped by the codex session id. This complements — does
# NOT replace — the §8d gateway-side output recovery: it fixes the Langfuse sink
# only, while §8d/spend-logs/s3 cover the gateway trace. It bypasses the LiteLLM
# streaming-iterator gap entirely (the capture happens on the client, from the
# rollout file, never from the gateway response).
#
# Placement rationale (mirrors `codex:global-config` for `[otel]`): the plugin
# BINARY + marketplace snapshot are inherently per-machine (they live under
# ~/.codex/plugins + ~/.codex/.tmp/marketplaces), and `codex plugin add` itself
# writes the `[marketplaces.*]` source AND `[plugins."tracing@codex-observability-plugin"]
# enabled = true` into the USER config (~/.codex/config.toml). So the enablement is
# managed here, per machine, NOT hand-committed into the project .codex/config.toml
# (which cannot carry the per-machine marketplace snapshot anyway). On codex 0.144.1
# the legacy `[features] plugin_hooks` flag is REMOVED (the `hooks`/`plugins` features
# are stable-on by default), so it is intentionally not set.
#
# Runtime deps: node >= 22 on PATH (the Stop hook runs `node .../dist/index.mjs`; the
# repo pins node 24 via mise.toml) and the tracing env (TRACE_TO_LANGFUSE=true +
# LANGFUSE_BASE_URL + LANGFUSE_PUBLIC_KEY/SECRET_KEY), all wired by mise
# (conf.d/10-env.toml + secret-env.sh). No secret is written to any file here.
#
# HOOK TRUST (one-time per machine, like the Claude keychain ACL): codex runs an
# enabled hook only after its source is trusted. The FIRST interactive `codex` turn
# in the repo prompts to trust the Langfuse Stop hook — approve it once (persists).
# Headless automation passes `codex exec --dangerously-bypass-hook-trust` (the hook
# source is this pinned, committed plugin). Until trusted/bypassed, the hook silently
# does not fire and no client-side trace is produced.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
require_cmd mise jq

# The marketplace source (owner/repo), the marketplace name codex derives from it, and
# the fully-qualified plugin id. Marketplace-name derivation verified live against codex
# 0.144.1. Points at the USER FORK (RickDavis404/codex-observability-plugin) so it moves
# in LOCK-STEP with the Claude side (.claude/settings.json extraKnownMarketplaces ->
# RickDavis404/claude-observability-plugin): both CLIs' plugin sources are the user's
# forks that carry the Lane-H 900s Stop-hook `timeout` (upstream ships 30s, which actively
# truncates the codex Stop hook). DEPLOY SEQUENCING: the 900s hooks.json commit must be on
# the fork's DEFAULT branch before this repoint is deployed — `plugin marketplace add`
# owner/repo pulls the default branch (no in-source ref pin), so push the fork ahead of use.
MARKETPLACE_SOURCE="RickDavis404/codex-observability-plugin"
MARKETPLACE_NAME="${MARKETPLACE_SOURCE##*/}"   # codex derives the marketplace name from the repo basename
PLUGIN_ID="tracing@codex-observability-plugin"

# Resolve the REAL mise-managed codex WITHOUT PATH — the committed .config/bin/codex
# wrapper shadows the name on PATH, and `mise which` queries the tool registry (the
# npm install path), so this never resolves to (or recurses through) the wrapper, and
# never sources the wrapper's fnox gateway secrets (plugin management needs none).
real_codex="$(mise --cd "${REPO_ROOT}" which codex 2>/dev/null || true)"
[[ -n "${real_codex}" && -x "${real_codex}" ]] ||
  die "could not resolve the mise-managed codex binary (run 'mise install')"

codex_home="${CODEX_HOME:-${HOME}/.codex}"
config_toml="${codex_home}/config.toml"

# Soft runtime-dep check: the Stop hook needs Node >= 22. Warn (do not fail the
# install) — install can precede a node bump; the hook just won't fire until node is present.
if command -v node >/dev/null 2>&1; then
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [[ "${node_major}" -lt 22 ]]; then
    warn "node $(node --version) < 22 — the Langfuse Stop hook needs Node >= 22 to run (repo pins node 24 via mise.toml; run 'mise install')"
  fi
else
  warn "node not on PATH — the Langfuse Stop hook needs Node >= 22 at runtime (repo pins node 24 via mise.toml; run 'mise install')"
fi

# _plugin_ready — succeed iff PLUGIN_ID is both installed AND enabled per `plugin list --json`.
_plugin_ready() {
  "${real_codex}" plugin list --json </dev/null 2>/dev/null |
    jq -e --arg id "${PLUGIN_ID}" '(.installed // [])[] | select(.pluginId==$id) | (.installed==true and .enabled==true)' >/dev/null 2>&1
}

# _source_matches — true iff the installed marketplace's source references the desired
# owner/repo (MARKETPLACE_SOURCE). Guards the upstream->fork transition: `_plugin_ready`
# alone is idempotent-true even when the plugin is installed from the WRONG source (e.g.
# a prior install from langfuse/ upstream), so re-runs would never re-point to the fork.
_source_matches() {
  grep -A3 '^\[marketplaces\.' "${config_toml}" 2>/dev/null | grep -q -- "${MARKETPLACE_SOURCE}"
}

if _plugin_ready && _source_matches; then
  info "codex plugin already installed + enabled from ${MARKETPLACE_SOURCE} (nothing to do)"
else
  # Source drift: plugin installed, but from a different marketplace source than desired
  # (upstream -> fork). Remove the stale plugin + marketplace so the add below re-points
  # cleanly (the fork's derived marketplace NAME collides with upstream's, so a bare
  # `marketplace add` would not switch the source on its own).
  if _plugin_ready && ! _source_matches; then
    info "marketplace source drift -> re-pointing ${PLUGIN_ID} to fork ${MARKETPLACE_SOURCE}"
    "${real_codex}" plugin remove "${PLUGIN_ID}" </dev/null 2>/dev/null || true
    "${real_codex}" plugin marketplace remove "${MARKETPLACE_NAME}" </dev/null 2>/dev/null || true
  fi
  # Back up the user config BEFORE codex mutates it — only on the mutating path (a
  # ready no-op above never litters a backup). Idiom matches codex:global-config.
  if [[ -f "${config_toml}" ]]; then
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    backup="${config_toml}.backup-${stamp}"
    [[ -e "${backup}" ]] && backup="${backup}.$$"
    cp "${config_toml}" "${backup}"
    chmod 600 "${backup}" 2>/dev/null || true
    info "backed up ${config_toml} -> $(basename "${backup}")"
  fi

  info "adding marketplace '${MARKETPLACE_SOURCE}' (git clone; needs network) into ${codex_home}"
  # Both are idempotent (re-run prints 'already added' / re-installs cleanly, rc=0).
  "${real_codex}" plugin marketplace add "${MARKETPLACE_SOURCE}" </dev/null
  info "installing + enabling plugin '${PLUGIN_ID}'"
  "${real_codex}" plugin add "${PLUGIN_ID}" </dev/null

  _plugin_ready ||
    die "plugin '${PLUGIN_ID}' is not installed+enabled after 'plugin add' — check 'codex plugin list'"
  info "codex plugin installed + enabled: ${PLUGIN_ID}"
fi

# Keep the user config owner-only (codex may have created/rewritten it).
[[ -f "${config_toml}" ]] && chmod 600 "${config_toml}" 2>/dev/null || true

info "Langfuse client-side tracing env is wired by mise (TRACE_TO_LANGFUSE=true + LANGFUSE_BASE_URL + LANGFUSE_PUBLIC_KEY/SECRET_KEY)."
info "HOOK TRUST (one-time per machine): the first interactive 'codex' turn prompts to trust the Langfuse Stop hook — approve it once."
info "  headless/automation: run 'codex exec --dangerously-bypass-hook-trust' (the hook source is this pinned, committed plugin)."
info "codex:install-plugins complete (${config_toml})"
