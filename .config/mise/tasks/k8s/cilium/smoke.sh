#!/usr/bin/env bash
#MISE description="Cilium smoke: status, agents Ready on every node, KubeProxyReplacement=True, LB-IPAM pool present."
set -euo pipefail

# k8s:cilium:smoke — Cilium-focused smoke. Verifies:
#   - `cilium status` OK (or kubectl readiness fallback if the CLI is absent).
#   - cilium-agent Ready on every node.
#   - KubeProxyReplacement: True (this cluster runs kube-proxy-free).
#   - the CiliumLoadBalancerIPPool (lima-shared-pool) + CiliumL2AnnouncementPolicy
#     (lima-lb-l2) exist.
#
# Does NOT run the full `cilium connectivity test` by default (heavy, pulls images);
# set CILIUM_FULL_CONNECTIVITY=1 to also run it.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"

readonly CILIUM_NS="kube-system"
readonly WAIT_TIMEOUT="${WAIT_TIMEOUT:-120s}"

fail=0
note_fail() {
  warn "FAIL: $*"
  fail=1
}

status_check() {
  if command -v cilium >/dev/null 2>&1; then
    info "cilium status (CLI):"
    KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kube/config}" cilium status --wait=false ||
      note_fail "cilium status reported not-OK"
  else
    warn "cilium CLI not installed; falling back to kubectl readiness checks."
    kc -n "${CILIUM_NS}" rollout status ds/cilium --timeout="${WAIT_TIMEOUT}" >/dev/null 2>&1 ||
      note_fail "cilium DaemonSet not ready"
    kc -n "${CILIUM_NS}" rollout status deploy/cilium-operator --timeout="${WAIT_TIMEOUT}" >/dev/null 2>&1 ||
      note_fail "cilium-operator not ready"
    kc -n "${CILIUM_NS}" rollout status deploy/hubble-relay --timeout="${WAIT_TIMEOUT}" >/dev/null 2>&1 ||
      warn "hubble-relay not ready (verify TCP 4244 open on every node)"
  fi
}

agents_ready() {
  info "check: cilium-agent Ready on every node"
  local desired ready
  desired="$(kc -n "${CILIUM_NS}" get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
  ready="$(kc -n "${CILIUM_NS}" get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  info "cilium agents ready: ${ready}/${desired}"
  if [ "${desired:-0}" -lt 1 ] || [ "${ready:-0}" -lt "${desired:-1}" ]; then
    note_fail "cilium agents not Ready on every node (${ready}/${desired})"
  fi
}

kube_proxy_replacement() {
  info "check: KubeProxyReplacement: True"
  local out
  out="$(kc -n "${CILIUM_NS}" exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null |
    grep -i "KubeProxyReplacement" || true)"
  if [ -z "${out}" ]; then
    out="$(kc -n "${CILIUM_NS}" exec ds/cilium -- cilium status 2>/dev/null |
      grep -i "KubeProxyReplacement" || true)"
  fi
  case "${out}" in
  *[Tt]rue*) info "Cilium ${out# }" ;;
  *) note_fail "KubeProxyReplacement not True (got: '${out:-<empty>}')" ;;
  esac
}

lb_resources() {
  info "check: LB-IPAM pool + L2 announcement policy exist"
  kc get ciliumloadbalancerippool lima-shared-pool >/dev/null 2>&1 ||
    note_fail "CiliumLoadBalancerIPPool/lima-shared-pool not found"
  kc get ciliuml2announcementpolicy lima-lb-l2 >/dev/null 2>&1 ||
    note_fail "CiliumL2AnnouncementPolicy/lima-lb-l2 not found"
}

full_connectivity() {
  if [ "${CILIUM_FULL_CONNECTIVITY:-0}" = "1" ] && command -v cilium >/dev/null 2>&1; then
    info "running full cilium connectivity test (CILIUM_FULL_CONNECTIVITY=1)"
    KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kube/config}" cilium connectivity test ||
      note_fail "cilium connectivity test failed"
  else
    info "skipping heavy 'cilium connectivity test' (set CILIUM_FULL_CONNECTIVITY=1 to enable)"
  fi
}

main() {
  require_cmd kubectl
  status_check
  agents_ready
  kube_proxy_replacement
  lb_resources
  full_connectivity
  if [ "${fail}" -ne 0 ]; then
    die "cilium smoke FAILED — see warnings above"
  fi
  info "cilium smoke PASSED"
}

main "$@"
