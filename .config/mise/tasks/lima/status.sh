#!/usr/bin/env bash
#MISE description="Show Lima instance state, kubeadm node Ready count, etcd quorum, kube-vip VIP, and Cilium status."
set -euo pipefail

# lima:status — best-effort health snapshot of the substrate:
#   - Lima instance states (ai-inf-platform-0/1/2).
#   - Node Ready count + roles (expect 3x control-plane Ready).
#   - etcd member health / quorum (stacked etcd; tolerates 1-node loss).
#   - kube-vip control-plane VIP reachability (https://192.168.105.40:6443/healthz).
#   - Cilium status (agents, operator, Hubble Relay, kubeProxyReplacement).
#
# Each section degrades gracefully if the cluster is down or a tool is missing.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"

readonly NODES=("ai-inf-platform-0" "ai-inf-platform-1" "ai-inf-platform-2")
readonly NODE0="ai-inf-platform-0"
readonly VIP="192.168.105.40"

section() { printf '\n=== %s ===\n' "$1"; }

# In-guest etcd health/member query on ai-inf-platform-0 over the stacked-etcd PKI paths
# kubeadm lays down at /etc/kubernetes/pki/etcd. Best-effort.
etcd_guest_script() {
  cat <<'GUEST'
set -eu
EP="https://127.0.0.1:2379"
C=/etc/kubernetes/pki/etcd
if command -v etcdctl >/dev/null 2>&1; then
  ETCDCTL_API=3 etcdctl --endpoints="$EP" \
    --cacert="$C/ca.crt" --cert="$C/server.crt" --key="$C/server.key" \
    endpoint health --cluster
  ETCDCTL_API=3 etcdctl --endpoints="$EP" \
    --cacert="$C/ca.crt" --cert="$C/server.crt" --key="$C/server.key" \
    member list -w table
else
  echo "etcdctl not present in guest; reporting control-plane nodes from kubectl:"
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes \
    -l node-role.kubernetes.io/control-plane --no-headers || true
fi
GUEST
}

report_etcd() {
  command -v limactl >/dev/null 2>&1 || {
    warn "limactl not found; skipping etcd check"
    return 0
  }
  if limactl shell "${NODE0}" sudo sh -c "$(etcd_guest_script)" 2>/dev/null; then
    return 0
  fi
  warn "etcd health query unavailable (node 0 down or etcdctl absent)"
}

main() {
  section "Lima instances"
  if command -v limactl >/dev/null 2>&1; then
    limactl list "${NODES[@]}" 2>/dev/null || warn "could not list Lima instances"
  else
    warn "limactl not found"
  fi

  section "Kubernetes nodes"
  if command -v kubectl >/dev/null 2>&1; then
    kc get nodes -o wide 2>/dev/null ||
      warn "kubectl could not reach the API (is the cluster up + kubeconfig set?)"
    local total ready
    total="$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$(kc get nodes --no-headers 2>/dev/null | awk '$2 ~ /(^|,)Ready($|,)/ {c++} END {print c + 0}')"
    printf 'Ready: %s/%s\n' "${ready:-0}" "${total:-0}"
  else
    warn "kubectl not found"
  fi

  section "etcd member health / quorum"
  report_etcd

  section "kube-vip control-plane VIP"
  if curl -sk "https://${VIP}:6443/healthz" 2>/dev/null | grep -q ok; then
    info "VIP ${VIP}:6443 /healthz OK"
  else
    warn "VIP ${VIP}:6443 /healthz not reachable (cluster down or VIP not held?)"
  fi

  section "Cilium status"
  if command -v cilium >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
    KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kube/config}" cilium status --wait=false 2>/dev/null ||
      warn "cilium status unavailable (cilium not installed yet?)"
  else
    warn "cilium CLI or kubectl not found; skipping Cilium status"
    info "Hubble Relay should report OK and TCP 4244 must be open on every node."
  fi
}

main "$@"
