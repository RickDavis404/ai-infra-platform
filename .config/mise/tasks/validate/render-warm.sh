#!/usr/bin/env bash
#MISE description="Serial pre-warm: pull all Helm charts once so parallel render guards read a warm cache."
# .config/mise/tasks/validate/render-warm.sh — serialize the one-time Helm chart pull.
#
# The `validate` aggregator fans its sub-checks out in PARALLEL (mise `depends` are a
# DAG). Four of them — validate:no-bitnami, validate:no-nodeport, validate:scrub, and
# validate:helm-kustomize — each independently run .config/mise/lib/render-all.sh,
# whose `kustomize build --enable-helm` helm-pull-untars every missing chart into the
# gitignored kubernetes/**/charts/ cache. On a COLD cache two concurrent pulls into
# the same charts/<chart> dir race — one reads a half-extracted chart while another is
# still writing it — so `kustomize build` fails and the guard flakes.
#
# This task renders the whole tree ONCE, up front, as the single writer. The four
# render consumers declare `#MISE depends=["validate:render-warm"]`, so mise runs this
# to completion — charts fully pulled — before fanning the guards out over a now
# read-only cache. Warm-cache renders are pure reads and safe to parallelize.
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

install_err_trap

render="${repo_root}/.config/mise/lib/render-all.sh"

# Render every overlay once (single writer) to populate kubernetes/**/charts/. Output
# is discarded — this task only warms the chart cache; the guards render again (now
# read-only) and inspect their own copy of the stream.
printf 'render-warm: pre-pulling Helm charts (single writer) via render-all.sh...\n'
if ! bash "${render}" >/dev/null; then
  printf 'render-warm: render failed (offline helm-repo fetch?). Cannot pre-warm chart cache.\n' >&2
  exit 1
fi
printf 'render-warm: chart cache warm — parallel render guards may now read it.\n'
