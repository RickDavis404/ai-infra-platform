#!/usr/bin/env bash
#MISE description="Server-side dry-run diff of overlays against live cluster state."
# .config/mise/tasks/k8s/diff.sh — server-side dry-run diff of all in-scope overlays.
#
# For each overlay (in the same dependency order as apply.sh) this renders with
# `kustomize build --enable-helm` and runs `kubectl diff -f -` (a server-side
# dry-run that compares the rendered manifests against live cluster state) so you
# can preview what `k8s:apply` would change.
#
# `--render-only` / `--emit`: skip the cluster entirely and just stream the
# rendered YAML for every overlay to stdout. This is the input the image-source
# and service-type guards consume (spec §8.2 / §15.2), so it must succeed with NO
# cluster connection.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

if [[ -f "${REPO_ROOT}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.config/mise/lib/common.sh"
fi
declare -F info >/dev/null 2>&1 || info() { printf '[info] %s\n' "$*" >&2; }
declare -F warn >/dev/null 2>&1 || warn() { printf '[warn] %s\n' "$*" >&2; }
declare -F err >/dev/null 2>&1 || err() { printf '[err ] %s\n' "$*" >&2; }
declare -F die >/dev/null 2>&1 || die() {
  err "$@"
  exit 1
}
declare -F need >/dev/null 2>&1 || need() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}
declare -F kc >/dev/null 2>&1 || kc() {
  KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kube/config}" kubectl "$@"
}

readonly K8S_DIR="${REPO_ROOT}/kubernetes"

# Helm Capabilities.APIVersions advertised to `kustomize build --enable-helm` so
# CRD-gated chart objects (e.g. the Loki chart's ServiceMonitor/PrometheusRules)
# render offline. Kept in lock-step with apply.sh / render-all.sh so the diff and
# guard streams match what apply emits.
HELM_API_VERSIONS=(
  --helm-api-versions "monitoring.coreos.com/v1/ServiceMonitor"
  --helm-api-versions "monitoring.coreos.com/v1/PodMonitor"
  --helm-api-versions "monitoring.coreos.com/v1/PrometheusRule"
)

# In-scope overlays in bring-up order (same set apply.sh applies).
OVERLAYS=(
  namespaces
  operators/cnpg
  operators/clickhouse-operator
  langfuse-data
  lgtm
  langfuse
  litellm
  ingress
)

# Only overlays that actually exist on disk (the lead may stage them incrementally).
present_overlays() {
  local rel
  for rel in "${OVERLAYS[@]}"; do
    if [[ -f "${K8S_DIR}/${rel}/kustomization.yaml" || -f "${K8S_DIR}/${rel}/kustomization.yml" ]]; then
      printf '%s\n' "${rel}"
    else
      warn "overlay not present (skipping): ${rel}"
    fi
  done
}

render_only() {
  need kustomize
  local rel rc=0
  while IFS= read -r rel; do
    info "render: ${rel}"
    printf -- '---\n# source: kubernetes/%s\n' "${rel}"
    if ! kustomize build --enable-helm "${HELM_API_VERSIONS[@]}" "${K8S_DIR}/${rel}"; then
      err "render failed for kubernetes/${rel} (offline helm-repo fetch? run with network access)"
      rc=1
    fi
  done < <(present_overlays)
  return "${rc}"
}

diff_live() {
  need kubectl
  need kustomize
  local rel rc=0 status
  while IFS= read -r rel; do
    info "diff: ${rel}"
    # `kubectl diff` exits 1 when there IS a diff (not an error). Capture and map.
    set +e
    kustomize build --enable-helm "${HELM_API_VERSIONS[@]}" "${K8S_DIR}/${rel}" |
      kc diff --server-side -f -
    status=${PIPESTATUS[1]}
    set -e
    case "${status}" in
    0) info "diff: ${rel} — no changes" ;;
    1) info "diff: ${rel} — changes pending (see above)" ;;
    *)
      err "diff: ${rel} — kubectl diff errored (exit ${status})"
      rc=1
      ;;
    esac
  done < <(present_overlays)
  return "${rc}"
}

main() {
  case "${1:-}" in
  --render-only | --emit)
    render_only
    ;;
  "")
    diff_live
    ;;
  *)
    die "unknown argument: $1 (expected --render-only/--emit or no argument)"
    ;;
  esac
}

main "$@"
