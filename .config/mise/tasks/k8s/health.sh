#!/usr/bin/env bash
#MISE description="One-shot READ-ONLY platform health: nodes, Cilium/kube-vip/LB VIPs, pods per namespace, CNPG/ClickHouse/Keeper, Spegel, langfuse/litellm, pull-through cache."
# .config/mise/tasks/k8s/health.sh — one-shot read-only health snapshot of the
# whole platform. Mirrors the manual checks repeated while bringing the stack up:
#   - nodes Ready
#   - Cilium KubeProxyReplacement=True + agents Ready
#   - kube-vip API VIP + each LoadBalancer service VIP reachable FROM THE HOST
#   - all pods per in-scope namespace (surfacing only the not-Running ones)
#   - CNPG Cluster health (langfuse-pg, litellm-pg)
#   - ClickHouse CHI status + Keeper CHK quorum
#   - Spegel DaemonSet rollout
#   - langfuse web/worker + litellm rollouts Ready
#   - the ai-registry pull-through cache (/v2/) reachable from the host
#
# READ-ONLY: this task only GETs/describes and probes endpoints with curl. It
# performs NO mutations (no apply/scale/delete/patch/restart). Never prints secrets.
# Exits non-zero if any hard check (nodes, Cilium, a CNPG/CH/Keeper not Ready, a
# not-Running pod) fails; VIP/cache reachability are reported but treated as soft
# (host networking varies) unless STRICT_VIP=1 is set.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"

# In-scope namespaces (spec §3 namespace map) + the infra namespaces we install.
NAMESPACES=(
  kube-system
  cnpg-system
  clickhouse-system
  spegel
  langfuse-data
  lgtm
  langfuse
  litellm
  ingress
)

# Per-service LoadBalancer VIP probes (env-overridable; defaults match conf.d/10-env).
CP_VIP="${AI_INFRA_CP_VIP:-192.168.105.40}"
LITELLM_VIP="${AI_INFRA_LITELLM_VIP:-192.168.105.200}"
LANGFUSE_VIP="${AI_INFRA_LANGFUSE_VIP:-192.168.105.201}"
GRAFANA_VIP="${AI_INFRA_GRAFANA_VIP:-192.168.105.202}"
OTEL_VIP="${AI_INFRA_OTEL_VIP:-192.168.105.203}"
HUBBLE_VIP="${AI_INFRA_HUBBLE_VIP:-192.168.105.204}"
CLICKHOUSE_VIP="${AI_INFRA_CLICKHOUSE_VIP:-192.168.105.207}"
REGISTRY_ADDR="${AI_INFRA_REGISTRY_ADDR:-192.168.105.50:5000}"

PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
STRICT_VIP="${STRICT_VIP:-0}"

# Aggregate failure flag for HARD checks (set to 1 on any hard failure).
_unhealthy=0
fail() {
  err "$*"
  _unhealthy=1
}

section() { printf '\n=== %s ===\n' "$*" >&2; }

# probe_https_host <name> <url> — HEAD/GET an https endpoint from the host with a
# short timeout, accepting any HTTP status (incl. 401/403/404 — the point is L4/L7
# reachability, not a 200). -k: the kube-vip API + service TLS are self-signed.
# Soft by default; hard only under STRICT_VIP=1.
probe_endpoint() {
  local name="$1" url="$2" hard="${3:-soft}" code
  code="$(curl -sk -o /dev/null -m "${PROBE_TIMEOUT}" -w '%{http_code}' "${url}" 2>/dev/null || true)"
  if [[ -n "${code}" && "${code}" != "000" ]]; then
    info "  reachable: ${name} (${url}) -> HTTP ${code}"
    return 0
  fi
  if [[ "${hard}" == "hard" || "${STRICT_VIP}" == "1" ]]; then
    fail "  UNREACHABLE: ${name} (${url})"
  else
    warn "  unreachable (soft): ${name} (${url}) — host networking/VIP not up yet?"
  fi
  return 0
}

check_nodes() {
  section "nodes"
  kc get nodes -o wide 2>/dev/null ||
    die "cannot reach cluster API (is KUBECONFIG -> .local/kube/config and the API VIP up?)"
  local not_ready
  not_ready="$(kc get nodes --no-headers 2>/dev/null |
    awk '$2 !~ /(^|,)Ready($|,)/ {print $1" "$2}' || true)"
  if [[ -n "${not_ready}" ]]; then
    fail "node(s) not Ready:"
    printf '%s\n' "${not_ready}" >&2
  else
    info "all nodes Ready"
  fi
}

check_cilium() {
  section "cilium (kube-proxy-free)"
  # KubeProxyReplacement reported by the agent config. Read it from one agent pod's
  # `cilium status` (no cilium-cli dependency required).
  local agent kpr
  agent="$(kc -n kube-system get pods -l k8s-app=cilium \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${agent}" ]]; then
    fail "no cilium agent pods found in kube-system"
    return 0
  fi
  kpr="$(kc -n kube-system exec "${agent}" -c cilium-agent -- \
    cilium status 2>/dev/null | grep -i 'KubeProxyReplacement' | head -1 || true)"
  if printf '%s' "${kpr}" | grep -qiE 'True|Strict'; then
    info "  ${kpr#*:KubeProxyReplacement}KubeProxyReplacement OK (${kpr##*KubeProxyReplacement})"
  elif [[ -n "${kpr}" ]]; then
    fail "  KubeProxyReplacement not enabled: ${kpr}"
  else
    warn "  could not read KubeProxyReplacement from ${agent} (continuing)"
  fi
  # Cilium DaemonSet rollout (agents Ready on every node).
  if kc -n kube-system rollout status ds/cilium --timeout=10s >/dev/null 2>&1; then
    info "  cilium DaemonSet rolled out on all nodes"
  else
    fail "  cilium DaemonSet not fully rolled out"
  fi
  # LB-IPAM pool present (a CiliumLoadBalancerIPPool must exist for the service VIPs).
  if kc get ciliumloadbalancerippools.cilium.io >/dev/null 2>&1 &&
    [[ -n "$(kc get ciliumloadbalancerippools.cilium.io --no-headers 2>/dev/null)" ]]; then
    info "  CiliumLoadBalancerIPPool present"
  else
    warn "  no CiliumLoadBalancerIPPool found (LB VIPs will not be assigned)"
  fi
}

check_vips() {
  section "VIP reachability from host (API VIP=hard, service VIPs=soft unless STRICT_VIP=1)"
  # kube-vip control-plane VIP — the API server. Hard: the cluster is unusable
  # from the host without it.
  probe_endpoint "kube-vip API VIP" "https://${CP_VIP}:6443/livez" hard
  # LoadBalancer service VIPs (Cilium L2). Reachability from the Mac depends on the
  # XDP foreign-MAC drop (D007); report but don't hard-fail by default.
  probe_endpoint "litellm" "http://${LITELLM_VIP}:4000/health/liveliness"
  probe_endpoint "langfuse" "http://${LANGFUSE_VIP}:3000/api/public/health"
  probe_endpoint "grafana" "http://${GRAFANA_VIP}:3000/api/health"
  probe_endpoint "otel-collector" "http://${OTEL_VIP}:13133/"
  probe_endpoint "hubble-ui" "http://${HUBBLE_VIP}:80/"
  probe_endpoint "clickhouse" "http://${CLICKHOUSE_VIP}:8123/ping"
}

check_pods() {
  section "pods per namespace (surfacing NOT Running/Completed only)"
  local ns bad
  for ns in "${NAMESPACES[@]}"; do
    kc get namespace "${ns}" >/dev/null 2>&1 || {
      warn "  namespace absent (skipping): ${ns}"
      continue
    }
    bad="$(kc -n "${ns}" get pods --no-headers 2>/dev/null |
      awk '$3 != "Running" && $3 != "Completed" {print "    "$0}' || true)"
    if [[ -n "${bad}" ]]; then
      fail "  ${ns}: pod(s) not Running/Completed:"
      printf '%s\n' "${bad}" >&2
    else
      local total
      total="$(kc -n "${ns}" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
      info "  ${ns}: all ${total} pod(s) Running/Completed"
    fi
  done
}

check_cnpg() {
  section "CNPG clusters"
  local pairs=("langfuse-data:langfuse-pg" "litellm:litellm-pg")
  local pair ns name phase
  for pair in "${pairs[@]}"; do
    ns="${pair%%:*}"
    name="${pair#*:}"
    kc -n "${ns}" get cluster.postgresql.cnpg.io "${name}" >/dev/null 2>&1 || {
      warn "  ${ns}/${name}: CNPG Cluster not present (skipping)"
      continue
    }
    phase="$(kc -n "${ns}" get cluster.postgresql.cnpg.io "${name}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if printf '%s' "${phase}" | grep -qiE 'Cluster in healthy state'; then
      info "  ${ns}/${name}: ${phase}"
    else
      fail "  ${ns}/${name}: phase='${phase:-<none>}' (not healthy)"
    fi
  done
}

check_clickhouse() {
  section "ClickHouse CHI + Keeper CHK"
  local chi_status chk_pods chk_total chk_ready
  if kc -n langfuse-data get clickhouseinstallation langfuse-ch >/dev/null 2>&1; then
    chi_status="$(kc -n langfuse-data get clickhouseinstallation langfuse-ch \
      -o jsonpath='{.status.status}' 2>/dev/null || true)"
    if [[ "${chi_status}" == "Completed" ]]; then
      info "  CHI langfuse-ch: ${chi_status}"
    else
      fail "  CHI langfuse-ch: status='${chi_status:-<none>}' (expected Completed)"
    fi
  else
    warn "  CHI langfuse-ch not present (skipping)"
  fi
  # Keeper quorum: all 3 CHK pods Ready (Raft tolerates losing one of three).
  if kc -n langfuse-data get pods -l clickhouse-keeper.altinity.com/chk=langfuse-keeper \
    >/dev/null 2>&1; then
    chk_pods="$(kc -n langfuse-data get pods \
      -l clickhouse-keeper.altinity.com/chk=langfuse-keeper --no-headers 2>/dev/null || true)"
    chk_total="$(printf '%s\n' "${chk_pods}" | grep -c . || true)"
    chk_ready="$(printf '%s\n' "${chk_pods}" | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if (a[1]==a[2] && $3=="Running") c++} END{print c+0}')"
    if [[ "${chk_total}" -gt 0 && "${chk_ready}" == "${chk_total}" ]]; then
      info "  Keeper CHK: ${chk_ready}/${chk_total} pods Ready (Raft quorum intact)"
    elif [[ "${chk_total}" -gt 0 && "${chk_ready}" -gt $((chk_total / 2)) ]]; then
      warn "  Keeper CHK: ${chk_ready}/${chk_total} pods Ready (quorum present but degraded)"
    else
      fail "  Keeper CHK: ${chk_ready}/${chk_total} pods Ready (quorum LOST)"
    fi
  else
    warn "  Keeper CHK pods not present (skipping)"
  fi
}

check_spegel() {
  section "Spegel peer-mirror DaemonSet"
  if kc -n spegel get ds/spegel >/dev/null 2>&1; then
    if kc -n spegel rollout status ds/spegel --timeout=10s >/dev/null 2>&1; then
      info "  spegel DaemonSet Ready on all nodes"
    else
      fail "  spegel DaemonSet not fully rolled out"
    fi
  else
    warn "  spegel DaemonSet not present (peer mirror not installed?)"
  fi
}

check_apps() {
  section "langfuse + litellm rollouts"
  local pairs=("langfuse:deploy/langfuse-web" "langfuse:deploy/langfuse-worker" "litellm:deploy/litellm")
  local pair ns target
  for pair in "${pairs[@]}"; do
    ns="${pair%%:*}"
    target="${pair#*:}"
    if kc -n "${ns}" get "${target}" >/dev/null 2>&1; then
      if kc -n "${ns}" rollout status "${target}" --timeout=10s >/dev/null 2>&1; then
        info "  ${ns}/${target}: rolled out"
      else
        fail "  ${ns}/${target}: NOT ready"
      fi
    else
      warn "  ${ns}/${target}: not present (skipping)"
    fi
  done
}

check_cache() {
  section "pull-through cache (/v2/) from host"
  # The registry:2 proxy answers /v2/ with 200 (anonymous) or 401 (auth-mode); both
  # prove it is up. Soft by default — the cache is optional infra.
  probe_endpoint "ai-registry cache" "http://${REGISTRY_ADDR}/v2/"
}

main() {
  require_cmd kubectl curl awk grep

  check_nodes
  check_cilium
  check_vips
  check_pods
  check_cnpg
  check_clickhouse
  check_spegel
  check_apps
  check_cache

  section "summary"
  if [[ "${_unhealthy}" -ne 0 ]]; then
    err "platform health: ONE OR MORE HARD CHECKS FAILED (see above)"
    exit 1
  fi
  info "platform health: all hard checks passed"
}

main "$@"
