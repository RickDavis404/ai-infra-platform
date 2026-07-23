#!/usr/bin/env bash
#MISE description="Archive codex's bundled model catalog to docs/reference/codex-model-catalog/codex-<version>.json (append-only per codex version, deterministic/offline)."
# .config/mise/tasks/codex/model-catalog-snapshot.sh — per-version codex model-catalog archive.
#
# `codex debug models --bundled` dumps the model catalog COMPILED INTO the codex binary:
# no network, no auth, no gateway — deterministic and reproducible for a given codex
# version (the `--bundled` copy is exactly what codex falls back to offline). We pin one
# JSON snapshot PER codex version, jq-sorted for stable line-diffs, so the catalog's
# evolution (models added/removed, reasoning/param changes) is reviewable in git history.
#
# Append-only by construction: the file is named codex-<version>.json, so a run only ever
# touches the CURRENT version's file — older per-version snapshots are never deleted. If the
# current version's file already exists the run overwrites just that same-version file
# (idempotent) and logs it. Run this after every codex version bump.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
require_cmd codex jq

out_dir="${REPO_ROOT}/docs/reference/codex-model-catalog"
tmp_json=""

cleanup_catalog_snapshot() {
  if [[ -n "${tmp_json}" && -f "${tmp_json}" ]]; then
    rm -f -- "${tmp_json}"
  fi
}
add_exit_trap cleanup_catalog_snapshot

# --- Resolve the codex version (parse the semver token from `codex --version`) --
# `codex --version` prints a line like "codex-cli 0.144.6"; take the first
# semver-ish token so the snapshot filename tracks the exact binary that produced it.
codex_version_raw="$(codex --version 2>/dev/null || true)"
codex_version="$(printf '%s\n' "${codex_version_raw}" |
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?' | head -n1)"
[[ -n "${codex_version}" ]] ||
  die "could not parse a version token from 'codex --version' output: ${codex_version_raw}"

out_file="${out_dir}/codex-${codex_version}.json"

mkdir -p -- "${out_dir}"

# --- Dump + normalize --------------------------------------------------------
# `--bundled` is offline/deterministic; `jq -S .` sorts object keys for stable diffs.
# Write to a temp file first so a mid-pipeline failure never truncates an existing
# snapshot (set -o pipefail makes the `if` catch a codex OR jq failure).
tmp_json="$(mktemp "${out_dir}/.codex-catalog.XXXXXX.json")"
info "dumping bundled codex model catalog (version ${codex_version})"
if ! codex debug models --bundled | jq -S . >"${tmp_json}"; then
  die "failed to dump/normalize the bundled codex model catalog (codex debug models --bundled | jq -S .)"
fi
[[ -s "${tmp_json}" ]] || die "bundled codex model catalog came back empty; refusing to write ${out_file}"

# --- Append-only write: only ever the current version's file -----------------
if [[ -f "${out_file}" ]]; then
  info "overwriting existing same-version snapshot ${out_file} (idempotent)"
else
  info "creating new snapshot ${out_file}"
fi
mv -f -- "${tmp_json}" "${out_file}"
tmp_json=""

info "codex:model-catalog-snapshot complete (${out_file})"
