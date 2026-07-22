#!/usr/bin/env bash
#MISE description="Install/upgrade Cilium (pinned in kubernetes/cilium/kustomization.yaml) (kube-proxy-free), wait ready, then apply LB-IPAM + L2 policy."
set -euo pipefail

# k8s:cilium — install the pinned Cilium version in kube-proxy-free mode and wire up the service
# VIP plane, idempotent.
#
# Order matters: the CiliumLoadBalancerIPPool + CiliumL2AnnouncementPolicy CRs depend
# on CRDs the Cilium chart installs, so this:
#   1. Renders the chart-only portion of the kustomize base (helmCharts) with
#      `kustomize build --enable-helm` and applies it (direct-helm fallback if
#      kustomize is unavailable).
#   2. Waits for the Cilium DaemonSet + operator (and best-effort Hubble Relay).
#   3. Applies the LB-IPAM pool + L2 announcement policy CRs.
#
# Pin and values live in kubernetes/cilium/{kustomization,values}.yaml.
#
# IP-substitution mechanism (LITERAL DEFAULTS + sed override at apply): the committed
# values.yaml / lb-ipam-pool.yaml carry the DEFAULT IPs so the dir renders standalone
# with `kustomize build --enable-helm`. At apply time we copy the cilium dir to a temp
# render dir and `sed` the defaults to the env values:
#   - values.yaml        k8sServiceHost 192.168.105.40  -> ${AI_INFRA_CP_VIP}
#   - lb-ipam-pool.yaml   start 192.168.105.200          -> ${AI_INFRA_LB_RANGE_START}
#                         stop  192.168.105.250          -> ${AI_INFRA_LB_RANGE_STOP}
# l2-announcement-policy.yaml's interface (lima0) is NOT an IP and stays literal.
# A no-op when the env equals the defaults (bare checkout renders identical IPs).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

readonly CILIUM_DIR="${REPO_ROOT}/kubernetes/cilium"
readonly CILIUM_NS="kube-system"
readonly CILIUM_RELEASE="cilium"
readonly CILIUM_REPO="https://helm.cilium.io"
readonly CILIUM_VERSION="1.20.0-pre.3"
readonly WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"

# Default IPs as committed in kubernetes/cilium/*. Env overrides replace these.
readonly DEF_CP_VIP="192.168.105.40"
readonly DEF_LB_START="192.168.105.200"
readonly DEF_LB_STOP="192.168.105.250"
readonly CP_VIP="${AI_INFRA_CP_VIP:-${DEF_CP_VIP}}"
readonly LB_START="${AI_INFRA_LB_RANGE_START:-${DEF_LB_START}}"
readonly LB_STOP="${AI_INFRA_LB_RANGE_STOP:-${DEF_LB_STOP}}"
render_dir_for_cleanup=""

cleanup_render_dir() {
  [[ -z "${render_dir_for_cleanup}" ]] || rm -rf -- "${render_dir_for_cleanup}"
}

# Render the cilium kustomize dir into a temp copy with env IPs substituted, echo the
# temp dir path on stdout. Caller is responsible for cleanup. Keeps committed files
# untouched (defaults preserved for standalone `kustomize build`).
render_cilium_dir() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cilium-render.XXXXXX")"
  cp -R "${CILIUM_DIR}/." "${tmp}/"
  sed -i.bak -E "s#${DEF_CP_VIP}#${CP_VIP}#g" "${tmp}/values.yaml"
  sed -i.bak \
    -e "s#${DEF_LB_START}#${LB_START}#g" \
    -e "s#${DEF_LB_STOP}#${LB_STOP}#g" \
    "${tmp}/lb-ipam-pool.yaml"
  rm -f "${tmp}"/*.bak
  # AI_INFRA_PROFILE=lean runs a SINGLE-node cluster (see lima/start.sh): the
  # committed operator.replicas: 2 (HA leader-election pair) can never fully roll
  # out there — the chart's default REQUIRED hostname podAntiAffinity on the
  # operator pins the second replica Pending forever, and wait_ready's
  # `rollout status deploy/cilium-operator` would time out and DIE. Scale the
  # operator to 1 in the temp render copy only; the committed values.yaml keeps the
  # HA posture byte-identical.
  if [[ "${AI_INFRA_PROFILE:-lean}" == "lean" ]]; then
    yq -i '.operator.replicas = 1' "${tmp}/values.yaml"
  fi
  printf '%s\n' "${tmp}"
}

# Apply the Helm-rendered chart (CRDs + agent/operator/Hubble). The kustomize base
# also lists the two Cilium CRs (LB-IPAM pool, L2 policy), whose CRDs the chart
# installs in the SAME render — so the CRs may not register on this first apply if
# their CRDs are not yet established. That is tolerated here (--server-side, errors
# suppressed for the not-yet-known CR kinds); apply_lb_l2 re-applies the CRs after the
# chart is ready, which is the authoritative, must-succeed apply.
apply_chart_via_kustomize() {
  local render_dir="$1"
  info "rendering Cilium chart via kustomize build --enable-helm (k8sServiceHost=${CP_VIP})"
  kustomize build --enable-helm "${render_dir}" |
    kc apply --server-side --force-conflicts -f - 2>/dev/null || true
}

apply_chart_via_helm() {
  local render_dir="$1"
  info "kustomize unavailable; installing Cilium directly via helm (idempotent upgrade --install)"
  helm repo add cilium "${CILIUM_REPO}" >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || true
  helm upgrade --install "${CILIUM_RELEASE}" cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace "${CILIUM_NS}" \
    --values "${render_dir}/values.yaml" \
    --wait --timeout "${WAIT_TIMEOUT}"
}

wait_ready() {
  info "waiting for Cilium components to become ready"
  kc -n "${CILIUM_NS}" rollout status ds/cilium --timeout="${WAIT_TIMEOUT}" ||
    die "cilium DaemonSet did not become ready"
  kc -n "${CILIUM_NS}" rollout status deploy/cilium-operator --timeout="${WAIT_TIMEOUT}" ||
    die "cilium-operator did not become ready"
  kc -n "${CILIUM_NS}" rollout status deploy/hubble-relay --timeout="${WAIT_TIMEOUT}" ||
    warn "hubble-relay not ready (verify TCP 4244 is open on every node)"
}

apply_lb_l2() {
  local render_dir="$1"
  info "applying LB-IPAM pool (${LB_START}-${LB_STOP}) + L2 announcement policy"
  kc apply -f "${render_dir}/lb-ipam-pool.yaml"
  kc apply -f "${render_dir}/l2-announcement-policy.yaml"
}

main() {
  require_cmd kubectl
  # yq is only shelled out to on the lean path (operator.replicas rewrite in
  # render_cilium_dir); require it up front there so the failure is a clear
  # missing-tool error, not a mid-render one.
  [[ "${AI_INFRA_PROFILE:-lean}" != "lean" ]] || require_cmd yq
  [ -d "${CILIUM_DIR}" ] || die "Cilium base not found: ${CILIUM_DIR}"

  # Render the cilium dir once with env IPs substituted; reused by every apply path.
  local render_dir
  render_dir="$(render_cilium_dir)"
  render_dir_for_cleanup="${render_dir}"
  add_exit_trap cleanup_render_dir

  if command -v kustomize >/dev/null 2>&1; then
    apply_chart_via_kustomize "${render_dir}"
  elif command -v helm >/dev/null 2>&1; then
    apply_chart_via_helm "${render_dir}"
  else
    die "neither kustomize nor helm found; cannot install Cilium"
  fi

  wait_ready
  apply_lb_l2 "${render_dir}"

  if command -v cilium >/dev/null 2>&1; then
    KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.local/kube/config}" \
      cilium status --wait --wait-duration "${WAIT_TIMEOUT}" || warn "cilium status reported issues"
  fi
  info "Cilium ${CILIUM_VERSION} installed/updated and ready (LB-IPAM + L2 policy applied)"
}

main "$@"
