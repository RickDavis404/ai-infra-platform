#!/usr/bin/env bash
#MISE description="Substrate smoke: 3 Ready, etcd quorum, kube-vip VIP, kubeProxyReplacement=True, LoadBalancer VIP."
set -euo pipefail

# lima:smoke — post-bootstrap validation of the cluster SUBSTRATE only (component
# smoke lives in the respective component tasks). Checks:
#   - host kubectl reaches the VIP (https://192.168.105.40:6443).
#   - 3 control-plane nodes Ready.
#   - etcd quorum present (stacked etcd; tolerates 1-node loss).
#   - kube-vip control-plane VIP /healthz reachable from the host.
#   - Cilium reports KubeProxyReplacement: True.
#   - a scratch LoadBalancer service is assigned a VIP from the lima-shared-pool.
#   - a scratch pod gets a 10.42.x IP, resolves DNS, reaches a ClusterIP.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"

readonly NODE0="ai-inf-platform-0"
readonly VIP="192.168.105.40"
readonly POOL_PREFIX="192.168.105.2"
readonly SCRATCH_NS="default"
readonly SCRATCH_POD="ai-infra-smoke"
readonly SCRATCH_LB="ai-infra-smoke-lb"
readonly POD_CIDR_PREFIX="10.42."

fail=0
note_fail() {
  warn "FAIL: $*"
  fail=1
}

check_host_api() {
  info "check: host kubectl reaches https://${VIP}:6443"
  local server
  server="$(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  case "${server}" in
  "https://${VIP}:6443") : ;;
  *) note_fail "kubeconfig server is '${server}', expected https://${VIP}:6443" ;;
  esac
  kc version >/dev/null 2>&1 || note_fail "host kubectl could not reach the API server"
}

check_nodes() {
  info "check: 3 control-plane nodes Ready"
  local total ready cp
  total="$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  ready="$(kc get nodes --no-headers 2>/dev/null | awk '$2 ~ /(^|,)Ready($|,)/ {c++} END {print c + 0}')"
  cp="$(kc get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${total:-0}" -ge 3 ] || note_fail "expected >=3 nodes, found ${total:-0}"
  [ "${ready:-0}" -ge 3 ] || note_fail "expected >=3 Ready nodes, found ${ready:-0}"
  [ "${cp:-0}" -ge 3 ] || note_fail "expected >=3 control-plane nodes, found ${cp:-0}"
}

check_etcd_quorum() {
  info "check: etcd quorum (tolerates 1-node loss)"
  command -v limactl >/dev/null 2>&1 || {
    warn "limactl absent; skipping in-guest etcd quorum check"
    return 0
  }
  local healthy
  healthy="$(
    # SC2016: intentional single-quotes — $C must expand inside the guest shell.
    # shellcheck disable=SC2016
    limactl shell "${NODE0}" sudo sh -c '
      C=/etc/kubernetes/pki/etcd
      if command -v etcdctl >/dev/null 2>&1; then
        ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
          --cacert="$C/ca.crt" --cert="$C/server.crt" --key="$C/server.key" \
          endpoint health --cluster 2>/dev/null | grep -c "is healthy" || true
      else
        echo skip
      fi
    ' 2>/dev/null || true
  )"
  if [ "${healthy}" = "skip" ]; then
    warn "etcdctl absent in guest; relying on the 3-CP node count above for quorum"
  elif [ "${healthy:-0}" -ge 2 ]; then
    info "etcd healthy members: ${healthy} (quorum present)"
  else
    note_fail "etcd healthy members ${healthy:-0} < 2 (no quorum)"
  fi
}

check_vip() {
  info "check: kube-vip control-plane VIP /healthz reachable from host"
  if curl -sk "https://${VIP}:6443/healthz" 2>/dev/null | grep -q ok; then
    info "VIP ${VIP}:6443 /healthz OK"
  else
    note_fail "VIP ${VIP}:6443 /healthz not reachable"
  fi
}

check_kube_proxy_replacement() {
  info "check: Cilium KubeProxyReplacement: True"
  local out
  out="$(kc -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null |
    grep -i "KubeProxyReplacement" || true)"
  if [ -z "${out}" ]; then
    out="$(kc -n kube-system exec ds/cilium -- cilium status 2>/dev/null |
      grep -i "KubeProxyReplacement" || true)"
  fi
  case "${out}" in
  *[Tt]rue*) info "Cilium ${out# }" ;;
  *) note_fail "KubeProxyReplacement not True (got: '${out:-<empty>}')" ;;
  esac
}

cleanup_lb() {
  kc -n "${SCRATCH_NS}" delete svc "${SCRATCH_LB}" --ignore-not-found >/dev/null 2>&1 || true
  kc -n "${SCRATCH_NS}" delete deploy "${SCRATCH_LB}" --ignore-not-found >/dev/null 2>&1 || true
}

check_loadbalancer_vip() {
  info "check: a LoadBalancer service is assigned a VIP from lima-shared-pool"
  trap cleanup_lb RETURN
  cleanup_lb
  kc -n "${SCRATCH_NS}" create deployment "${SCRATCH_LB}" \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.47 -- /agnhost netexec --http-port=8080 \
    >/dev/null 2>&1 || {
    note_fail "could not create scratch LB deployment"
    return 0
  }
  kc -n "${SCRATCH_NS}" expose deployment "${SCRATCH_LB}" \
    --type=LoadBalancer --port=80 --target-port=8080 \
    --overrides='{"spec":{"loadBalancerClass":"io.cilium/l2-announcer"}}' \
    >/dev/null 2>&1 || {
    note_fail "could not expose scratch LB service"
    return 0
  }
  local ip deadline=$((SECONDS + 90))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    ip="$(kc -n "${SCRATCH_NS}" get svc "${SCRATCH_LB}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -n "${ip}" ] && break
    sleep 3
  done
  case "${ip}" in
  "${POOL_PREFIX}"*) info "LoadBalancer VIP assigned: ${ip} (from lima-shared-pool)" ;;
  "") note_fail "LoadBalancer service did not get a VIP within deadline" ;;
  *) note_fail "LoadBalancer VIP '${ip}' is not in the lima-shared-pool range" ;;
  esac
}

cleanup_scratch() {
  kc -n "${SCRATCH_NS}" delete pod "${SCRATCH_POD}" --ignore-not-found --now >/dev/null 2>&1 || true
}

check_scratch_pod() {
  info "check: scratch pod gets a 10.42.x IP, resolves DNS, reaches a ClusterIP"
  trap cleanup_scratch RETURN
  cleanup_scratch
  kc -n "${SCRATCH_NS}" run "${SCRATCH_POD}" \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.47 \
    --restart=Never --command -- sleep 600 >/dev/null 2>&1 || {
    note_fail "could not create scratch pod"
    return 0
  }
  if ! kc -n "${SCRATCH_NS}" wait --for=condition=Ready "pod/${SCRATCH_POD}" --timeout=120s >/dev/null 2>&1; then
    note_fail "scratch pod did not become Ready"
    return 0
  fi
  local pod_ip
  pod_ip="$(kc -n "${SCRATCH_NS}" get pod "${SCRATCH_POD}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  case "${pod_ip}" in
  "${POD_CIDR_PREFIX}"*) info "scratch pod IP ${pod_ip} is in 10.42.0.0/16" ;;
  *) note_fail "scratch pod IP '${pod_ip}' is not in ${POD_CIDR_PREFIX}0.0/16" ;;
  esac
  if kc -n "${SCRATCH_NS}" exec "${SCRATCH_POD}" -- \
    sh -c 'getent hosts kubernetes.default.svc.cluster.local >/dev/null 2>&1'; then
    info "in-pod DNS resolution OK"
  else
    note_fail "in-pod DNS resolution failed"
  fi
  local svc_ip
  svc_ip="$(kc -n "${SCRATCH_NS}" get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [ -n "${svc_ip}" ] && kc -n "${SCRATCH_NS}" exec "${SCRATCH_POD}" -- \
    sh -c "nc -z -w 5 ${svc_ip} 443"; then
    info "in-pod ClusterIP reachability OK (${svc_ip}:443)"
  else
    note_fail "in-pod ClusterIP reachability to kubernetes svc failed"
  fi
}

main() {
  require_cmd kubectl

  check_host_api
  check_nodes
  check_etcd_quorum
  check_vip
  check_kube_proxy_replacement
  check_loadbalancer_vip
  check_scratch_pod

  if [ "${fail}" -ne 0 ]; then
    die "lima:smoke FAILED — see warnings above"
  fi
  info "lima:smoke PASSED — substrate healthy"
}

main "$@"
