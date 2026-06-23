#!/usr/bin/env bash
#MISE description="Tear down the whole lab in reverse order: best-effort k8s teardown -> lima:stop -> host:down."
set -euo pipefail

# down — SEQUENTIAL teardown in REVERSE of `up`.
#
# Mirror of up.sh (sequential file-task, not a parallel depends-DAG). Order:
#   1. k8s teardown — best-effort: delete the in-scope overlays from the cluster if a
#      reachable kubeconfig exists; skip (do not fail down) when the cluster is already
#      gone / unreachable. This is intentionally non-fatal so down always proceeds to
#      stop Lima and the host services even if the API is down.
#   2. lima:stop  — pause (not delete) the kubeadm instances; disks preserved. Use
#      `mise run cluster:teardown` for a full destroy.
#   3. host:down  — unload the Mac-side launchd host services.
#
# down is intentionally TOLERANT: each phase is wrapped so a single failure is logged
# and skipped rather than aborting the remaining teardown.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

# Best-effort delete of the in-scope overlays. Skips cleanly when there is no
# reachable cluster (kubeconfig absent or API unreachable) — down must not fail here.
k8s_teardown() {
  local kubeconfig="${KUBECONFIG:-${REPO_ROOT}/.local/kube/config}"
  if [ ! -f "${kubeconfig}" ]; then
    info "k8s teardown: no kubeconfig at ${kubeconfig}; skipping (cluster not bootstrapped here)"
    return 0
  fi
  if ! kc version >/dev/null 2>&1; then
    info "k8s teardown: cluster API not reachable; skipping in-cluster delete"
    return 0
  fi
  info "k8s teardown: deleting in-scope overlays (best-effort, reverse order)"
  local rel
  for rel in ingress litellm langfuse lgtm langfuse-data \
    operators/clickhouse-operator operators/cnpg namespaces; do
    local dir="${REPO_ROOT}/kubernetes/${rel}"
    [ -d "${dir}" ] || continue
    kustomize build --enable-helm "${dir}" 2>/dev/null |
      kc delete --ignore-not-found=true -f - 2>/dev/null ||
      warn "k8s teardown: delete of overlay ${rel} reported errors (continuing)"
  done
}

main() {
  require_cmd mise

  info "=== down phase 1/3: k8s teardown (best-effort) ==="
  k8s_teardown || warn "k8s teardown encountered errors; continuing"

  info "=== down phase 2/3: lima:stop (pause instances, disks preserved) ==="
  mise run lima:stop || warn "lima:stop reported errors; continuing"

  info "=== down phase 3/3: host:down (unload Mac-side host services) ==="
  mise run host:down || warn "host:down reported errors; continuing"

  info "=== down complete — components stopped, instances paused, host services unloaded ==="
}

main "$@"
