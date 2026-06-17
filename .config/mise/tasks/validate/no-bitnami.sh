#!/usr/bin/env bash
#MISE description="Fail if any rendered manifest references a Bitnami image."
#MISE depends=["validate:render-warm"]
# .config/mise/tasks/validate/no-bitnami.sh — fail on any Bitnami image in rendered manifests (spec §8.2/§15.2).
#
# The lab forbids Bitnami charts and images, direct OR transitive. Because the
# Langfuse umbrella chart vendors Bitnami subcharts (postgresql/clickhouse/valkey/
# minio, all set deploy:false), this proof MUST grep the FINAL rendered objects —
# not the chart cache or Chart.yaml — where disabled subcharts produce no resources.
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

render="${repo_root}/.config/mise/lib/render-all.sh"

# Render every overlay exactly as it will be applied (helm subcharts expanded).
rendered="$(bash "${render}")" || {
  printf 'no-bitnami: render failed (offline helm-repo fetch?). Cannot prove clean.\n' >&2
  exit 1
}

if printf '%s' "${rendered}" | grep -nE \
  -e 'bitnami(legacy)?/' \
  -e 'registry-1\.docker\.io/bitnamicharts' \
  -e 'docker\.io/bitnami/'; then
  printf 'ERROR: Bitnami image/registry reference found in rendered output.\n' >&2
  exit 1
fi
printf 'no-bitnami: clean (direct + transitive).\n'
