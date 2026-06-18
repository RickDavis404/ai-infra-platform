#!/usr/bin/env bash
#MISE description="Delete the Lima kubeadm instances (kubeadm reset + Cilium iface cleanup first)."
set -euo pipefail

# lima:delete — destroy the cluster. Because Cilium installs host-level interfaces +
# iptables rules INSIDE each guest, the in-guest Cilium cleanup runs BEFORE
# `kubeadm reset`, to avoid losing in-guest connectivity mid-teardown. After the
# in-guest cleanup, `limactl delete --force` each instance (ai-inf-platform-2/1/0).
#
# Note: `limactl factory-reset` is NOT used for template iteration — it does not
# re-read the template; template/sizing changes require delete+recreate (lima:recreate).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

# Reverse start order: highest-numbered node first.
readonly NODES=("ai-inf-platform-2" "ai-inf-platform-1" "ai-inf-platform-0")

instance_exists() { limactl list --quiet 2>/dev/null | grep -qx "$1"; }
instance_running() { [ "$(limactl list --format '{{.Status}}' "$1" 2>/dev/null || true)" = "Running" ]; }

# In-guest Cilium iface + iptables cleanup, then `kubeadm reset`. Best-effort: every
# step tolerates absence (|| true) so a partially-built node still tears down cleanly.
#
# The cleanup is COSMETIC — its only job is to remove Cilium host ifaces + iptables
# rules gracefully BEFORE the VM is force-deleted (`limactl delete --force`) right
# after. On a wedged control-plane node (etcd/API down), `kubeadm reset` can block
# indefinitely waiting on the dead API, which would hang the entire teardown (and
# thus the hands-off `cluster:teardown` / `mise run`). So we BOUND the whole in-guest
# step with `timeout`: if it exceeds GUEST_CLEANUP_TIMEOUT, we warn and proceed
# straight to the force-delete (the VM is destroyed wholesale anyway, ifaces with it).
readonly GUEST_CLEANUP_TIMEOUT="${GUEST_CLEANUP_TIMEOUT:-90s}"
cleanup_guest() {
  local node="$1"
  info "in-guest Cilium + kubeadm reset on ${node} (bounded to ${GUEST_CLEANUP_TIMEOUT})"
  # Prefer GNU `timeout` (coreutils) when present; fall back to no bound if absent
  # (the force-delete still follows). `timeout` exit 124 == hit the deadline.
  local _timeout=()
  if command -v timeout >/dev/null 2>&1; then
    _timeout=(timeout "${GUEST_CLEANUP_TIMEOUT}")
  elif command -v gtimeout >/dev/null 2>&1; then
    _timeout=(gtimeout "${GUEST_CLEANUP_TIMEOUT}")
  fi
  local rc=0
  "${_timeout[@]}" limactl shell "${node}" sudo sh -eu <<'GUEST' || rc=$?
    kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock || true
    ip link delete cilium_host 2>/dev/null || true
    ip link delete cilium_net 2>/dev/null || true
    ip link delete cilium_vxlan 2>/dev/null || true
    ip link delete cilium_geneve 2>/dev/null || true
    iptables-save | grep -iv cilium | iptables-restore || true
    ip6tables-save | grep -iv cilium | ip6tables-restore || true
    rm -rf /etc/cni/net.d/*cilium* 2>/dev/null || true
GUEST
  if [ "${rc}" = "124" ]; then
    warn "in-guest cleanup on ${node} exceeded ${GUEST_CLEANUP_TIMEOUT} (wedged node?) — skipping to force-delete"
  elif [ "${rc}" != "0" ]; then
    warn "in-guest cleanup on ${node} returned ${rc} (continuing to force-delete)"
  fi
}

main() {
  require_cmd limactl
  local node
  for node in "${NODES[@]}"; do
    if ! instance_exists "${node}"; then
      info "${node} does not exist; skipping"
      continue
    fi
    if instance_running "${node}"; then
      cleanup_guest "${node}"
    else
      info "${node} not running; skipping in-guest cleanup, deleting directly"
    fi
    info "deleting ${node}"
    limactl delete --force "${node}" || die "failed to delete ${node}"
  done
  info "lima:delete complete — instances destroyed"
}

main "$@"
