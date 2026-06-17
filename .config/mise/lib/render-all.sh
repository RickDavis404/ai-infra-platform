#!/usr/bin/env bash
# .config/mise/lib/render-all.sh — render every kubernetes/<component> overlay to stdout.
#
# Renders each kustomize base via `kustomize build --enable-helm` and concatenates
# the YAML to stdout. `--enable-helm` is mandatory: kubectl's built-in kustomize
# silently DROPS `helmCharts:` blocks, so a build without it would emit incomplete
# manifests (spec §15.1). This concatenated stream is the input for the no-Bitnami
# and no-NodePort guards (spec §8.2 / §15.2).
#
# A component that requires a live cluster to render (none today) is skipped with a
# clear "# SKIP" note on stderr so the guards still get a valid stream on stdout.
# Helm-repo fetch failures (offline) are reported clearly and fail the render.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Optional shared helpers (logging). Tolerate absence so guards can run standalone.
if [[ -f "${repo_root}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${repo_root}/.config/mise/lib/common.sh"
fi

log() { printf '%s\n' "$*" >&2; }

k8s_dir="${repo_root}/kubernetes"

if ! command -v kustomize >/dev/null 2>&1; then
  log "ERROR: 'kustomize' not found on PATH (need >= 5.8.1 with --enable-helm)."
  exit 127
fi

if [[ ! -d "${k8s_dir}" ]]; then
  log "ERROR: kubernetes/ directory not found at ${k8s_dir}."
  exit 1
fi

# Helm Capabilities.APIVersions advertised to `kustomize build --enable-helm` so
# CRD-gated chart objects render offline (kustomize never queries the cluster). The
# Loki chart gates its ServiceMonitor/PrometheusRules behind
# `monitoring.coreos.com/v1/ServiceMonitor` presence; advertising the monitoring
# GVKs makes the guards see the SAME stream the apply path emits (the CRDs are
# applied before any SM-bearing overlay). Kept in lock-step with apply.sh.
helm_api_versions=(
  --helm-api-versions "monitoring.coreos.com/v1/ServiceMonitor"
  --helm-api-versions "monitoring.coreos.com/v1/PodMonitor"
  --helm-api-versions "monitoring.coreos.com/v1/PrometheusRule"
)

# Components that need a live cluster to render (cluster-bound generators). Empty
# today; listed here so future additions skip cleanly instead of failing the guards.
needs_cluster=()

is_skipped() {
  local name="$1" s
  for s in "${needs_cluster[@]:-}"; do
    [[ "${s}" == "${name}" ]] && return 0
  done
  return 1
}

# Discover every kustomization base (a directory holding kustomization.yaml|.yml),
# at any depth under kubernetes/ (covers operators/cnpg, operators/clickhouse-operator).
mapfile -t kustomizations < <(
  find "${k8s_dir}" -type f \( -name kustomization.yaml -o -name kustomization.yml \) |
    sort
)

if [[ "${#kustomizations[@]}" -eq 0 ]]; then
  log "WARNING: no kustomization.yaml found under ${k8s_dir} — nothing to render."
  exit 0
fi

rc=0
for kfile in "${kustomizations[@]}"; do
  base_dir="$(dirname "${kfile}")"
  rel="${base_dir#"${repo_root}"/}"
  name="${base_dir#"${k8s_dir}"/}"

  if is_skipped "${name}"; then
    log "# SKIP ${rel}: requires a live cluster to render."
    continue
  fi

  log "# RENDER ${rel}"
  printf -- '---\n# source: %s\n' "${rel}"
  if ! kustomize build --enable-helm "${helm_api_versions[@]}" "${base_dir}"; then
    log "ERROR: 'kustomize build --enable-helm ${rel}' failed."
    log "       If this is an offline helm-repo fetch failure, run with network access"
    log "       or pre-populate the helm chart cache, then retry."
    rc=1
  fi
done

exit "${rc}"
