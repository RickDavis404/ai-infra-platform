#!/usr/bin/env bash
#MISE description="Show rollout/health status of all in-scope workloads."
# .config/mise/tasks/k8s/status.sh — rollout / health status of all in-scope workloads.
#
# Read-only. Walks every in-scope namespace and prints a compact health summary:
# Deployments / StatefulSets / DaemonSets (replicas + rollout state), the CNPG
# Cluster and ClickHouseInstallation custom resources, PodDisruptionBudgets, and
# any not-Running pods. Never echoes secret material.
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

# In-scope namespaces (spec §3 namespace map).
NAMESPACES=(
  kube-system
  cnpg-system
  clickhouse-system
  langfuse-data
  lgtm
  langfuse
  litellm
  ingress
)

section() { printf '\n=== %s ===\n' "$*"; }

ns_exists() {
  kc get namespace "$1" >/dev/null 2>&1
}

workload_status() {
  local ns="$1"
  section "namespace: ${ns}"

  # Controllers: name, ready/desired, up-to-date, available.
  if kc -n "${ns}" get deploy,statefulset,daemonset >/dev/null 2>&1; then
    kc -n "${ns}" get deploy,statefulset,daemonset \
      -o wide 2>/dev/null || true
  fi

  # PodDisruptionBudgets (HA posture).
  if kc -n "${ns}" get pdb >/dev/null 2>&1; then
    local pdb_count
    pdb_count="$(kc -n "${ns}" get pdb --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${pdb_count}" != "0" ]]; then
      printf -- '--- PodDisruptionBudgets ---\n'
      kc -n "${ns}" get pdb 2>/dev/null || true
    fi
  fi

  # Stateful custom resources where relevant.
  case "${ns}" in
  cnpg-system | langfuse-data | litellm)
    if kc -n "${ns}" get clusters.postgresql.cnpg.io >/dev/null 2>&1; then
      printf -- '--- CNPG Clusters ---\n'
      kc -n "${ns}" get clusters.postgresql.cnpg.io 2>/dev/null || true
    fi
    ;;
  esac
  if [[ "${ns}" == "langfuse-data" || "${ns}" == "clickhouse-system" ]]; then
    if kc -n "${ns}" get clickhouseinstallations.clickhouse.altinity.com >/dev/null 2>&1; then
      printf -- '--- ClickHouseInstallations ---\n'
      kc -n "${ns}" get clickhouseinstallations.clickhouse.altinity.com 2>/dev/null || true
    fi
  fi

  # Pods that are not Running/Completed (surface problems only).
  local bad
  bad="$(kc -n "${ns}" get pods --no-headers 2>/dev/null |
    awk '$3 != "Running" && $3 != "Completed" {print}' || true)"
  if [[ -n "${bad}" ]]; then
    printf -- '--- pods NOT Running/Completed ---\n%s\n' "${bad}"
    overall_unhealthy=1
  fi
}

main() {
  need kubectl
  local overall_unhealthy=0

  section "nodes"
  kc get nodes -o wide 2>/dev/null || die "cannot reach cluster (is the kubeconfig pointed at 127.0.0.1?)"

  local ns
  for ns in "${NAMESPACES[@]}"; do
    if ns_exists "${ns}"; then
      workload_status "${ns}"
    else
      warn "namespace not present (skipping): ${ns}"
    fi
  done

  if [[ "${overall_unhealthy}" -ne 0 ]]; then
    warn "one or more workloads are not healthy (see 'pods NOT Running' sections above)"
    exit 1
  fi
  info "all in-scope workloads report healthy"
}

main "$@"
