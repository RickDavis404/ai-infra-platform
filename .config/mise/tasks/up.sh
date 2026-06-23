#!/usr/bin/env bash
#MISE description="Bring up the whole lab in order: host services -> Lima HA cluster (+Cilium/storage) -> k8s overlays."
set -euo pipefail

# up — SEQUENTIAL, fail-fast lab bring-up.
#
# WHY a file-task and not a depends-only aggregator: mise `depends` form a PARALLEL
# DAG, so the old `[tasks.up]` fired lima:kubeconfig / k8s:cilium / k8s:apply at the
# same time as lima:start — before ai-inf-platform-0 existed — and lima:kubeconfig died with
# "node-0 kubeconfig not found". This task runs the phases strictly in order, and any
# phase failing aborts the rest (set -e + explicit error on a failed `mise run`).
#
# lima:start is COMPREHENSIVE: it already does kubeconfig + Cilium + storage + taint +
# wait-for-Ready internally, so up does NOT separately invoke lima:kubeconfig /
# k8s:cilium (they would be redundant and racy). The three phases are:
#   0. secrets:check — fail early if the fnox store is not initialized.
#   1. host:up       — Mac-side host services (llama-swap, OTel, macmon exporter).
#   2. lima:start    — 3-node HA kubeadm cluster + kubeconfig + Cilium + storage + taint.
#   3. k8s:apply     — all in-scope kustomize overlays (namespaces .. ingress).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

main() {
  require_cmd mise

  if [[ "${AI_INFRA_SKIP_SECRETS:-0}" == "1" ]]; then
    warn "AI_INFRA_SKIP_SECRETS=1 — skipping secrets preflight; k8s:apply assumes Secrets already exist"
  else
    info "=== up preflight: secrets:check (fnox+age key set) ==="
    mise run secrets:check
  fi

  info "=== up phase 1/3: host:up (Mac-side host services) ==="
  mise run host:up

  info "=== up phase 2/3: lima:start (HA cluster + kubeconfig + Cilium + storage) ==="
  mise run lima:start

  info "=== up phase 3/3: k8s:apply (in-scope kustomize overlays) ==="
  mise run k8s:apply

  info "=== up complete — host services + 3-node HA cluster + components are live ==="
}

main "$@"
