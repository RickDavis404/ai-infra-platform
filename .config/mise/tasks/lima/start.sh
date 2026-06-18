#!/usr/bin/env bash
#MISE description="Create/start the 3-node Lima kubeadm HA cluster (init + 2 CP joins) and install Cilium."
set -euo pipefail

# lima:start — bring up the 3-node HA kubeadm control plane (stacked etcd, quorum
# 2/3) on the socket_vmnet shared network, then install Cilium, storage, and remove
# the control-plane taint so workloads schedule on all 3 nodes.
#
# Sequence:
#   1. Resolve repoRoot; mkdir -p <repoRoot>/.local/lima/<vm>/{storage,config} for
#      every VM on the HOST (virtiofs requires the host dir to exist + be writable);
#      copy lima/kube-vip.yaml into each VM's config mount so the template's provision
#      script can place the kube-vip static pod before init/join.
#   2. Start ai-inf-platform-0 with role=init (kubeadm init --upload-certs, kube-proxy skipped).
#   3. Discover the control-plane join command + certificate key FROM ai-inf-platform-0
#      (in-process, never written to a committed file).
#   4. Start ai-inf-platform-1 then ai-inf-platform-2 sequentially with role=join (control-plane joins).
#   5. Write the repo-local kubeconfig (server -> https://VIP:6443) via lima:kubeconfig.
#   6. Remove the control-plane taint from all nodes (before Cilium so Hubble can schedule).
#   7. Install Cilium (k8s:cilium) — nodes are NotReady until the CNI is up.
#   8. Install Spegel (k8s:spegel) — peer-to-peer OCI mirror; needs pod networking
#      (so AFTER Cilium) and must be up BEFORE k8s:apply pulls the heavy app images.
#   9. Install the local-path storage provisioner (default StorageClass).
#  10. Wait for 3 nodes Ready.
#
# kubeadm uses its own bootstrap token + certificate key (generated at init, captured
# here and passed to joiners in-process). There is NO committed cluster token.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

readonly TEMPLATE="${REPO_ROOT}/lima/templates/k8s-cilium.yaml"
readonly KUBE_VIP_SRC="${REPO_ROOT}/lima/kube-vip.yaml"
# XDP foreign-unicast drop: makes host->Cilium-LB-VIP work over socket_vmnet (which
# floods unicast to all VMs). Seeded into each VM's config mount; the template's
# provision step compiles it with the node's lima0 MAC and loads it on lima0.
readonly XDP_SRC="${REPO_ROOT}/lima/xdp/drop-foreign.c"
# IP parameterization (env-driven so init's 99-local.toml overrides apply; defaults
# match the committed YAML so a bare checkout still renders the documented IPs):
#   - VIP     = kube-vip control-plane VIP -> passed as the template `vip` param AND
#               substituted into lima/kube-vip.yaml's `${AI_INFRA_CP_VIP}` placeholder
#               (envsubst) when seeding each VM's config mount.
#   - NETWORK = socket_vmnet network name -> overrides the template's `networks[0].lima`
#               via `--set` so a dedicated network (init may create one) is honored.
readonly VIP="${AI_INFRA_CP_VIP:-192.168.105.40}"
readonly NETWORK="${AI_INFRA_LIMA_NETWORK:-shared}"
# Docker Hub pull-through cache endpoint (host:port on the shared L2). Env-driven so
# cache:up's 99-local.toml override (the cache VM's DISCOVERED DHCP IP) flows into the
# template's containerd certs.d docker.io mirror via `--set`. Default matches the
# committed conf.d/10-env.toml + the template's registryAddr param default.
readonly REGISTRY_ADDR="${AI_INFRA_REGISTRY_ADDR:-192.168.105.50:5000}"
readonly NODE0="ai-inf-platform-0"
readonly JOIN_NODES=("ai-inf-platform-1" "ai-inf-platform-2")
readonly POD_CIDR="10.42.0.0/16"
readonly SERVICE_CIDR="10.43.0.0/16"
readonly READY_DEADLINE_SECS="${READY_DEADLINE_SECS:-900}"
# Bound for the host->kube-vip API VIP reachability gate before the first host-side
# kubectl (see wait_host_vip_ready): kube-vip leader election + gratuitous-ARP refresh
# of the host neighbor entry normally converges in seconds, so 180s is generous.
readonly VIP_READY_DEADLINE_SECS="${VIP_READY_DEADLINE_SECS:-180}"

instance_exists() { limactl list --quiet 2>/dev/null | grep -qx "$1"; }
instance_running() { [ "$(limactl list --format '{{.Status}}' "$1" 2>/dev/null || true)" = "Running" ]; }

# Prepare the per-VM host mount dirs and seed the kube-vip manifest into the config
# mount, BEFORE `limactl start` (virtiofs needs the host dir present + writable).
#
# IP-substitution mechanism (kube-vip static pod — NOT a kustomize input): the
# committed lima/kube-vip.yaml carries the `address: ${AI_INFRA_CP_VIP}` placeholder
# (a valid YAML scalar). It is rendered with `envsubst` here — substituting ONLY
# AI_INFRA_CP_VIP (default 192.168.105.40) — into each VM's config mount, so an
# init-chosen VIP flows into the static pod the guest provision script installs.
prepare_host_mounts() {
  local vm="$1"
  local base="${REPO_ROOT}/.local/lima/${vm}"
  mkdir -p "${base}/storage" "${base}/config"
  # Restrict envsubst to the single VIP var so no other $-token in the manifest is
  # touched; export it for the subshell since `readonly VIP` may differ in name.
  # SC2016: the single-quoted '${AI_INFRA_CP_VIP}' is envsubst's var-restriction
  # argument (a literal it must receive), NOT a shell expansion — keep it single-quoted.
  # shellcheck disable=SC2016
  AI_INFRA_CP_VIP="${VIP}" envsubst '${AI_INFRA_CP_VIP}' \
    <"${KUBE_VIP_SRC}" >"${base}/config/kube-vip.yaml"
  chmod 600 "${base}/config/kube-vip.yaml"
  # Seed the XDP source (compiled + loaded per-node by the template's provision step).
  install -m 644 "${XDP_SRC}" "${base}/config/drop-foreign.c"
  info "prepared host mounts for ${vm}: ${base}/{storage,config} (+kube-vip.yaml, +drop-foreign.c, VIP=${VIP})"
}

# Start (or restart) a single instance from the template with the given role/params.
# Arg 1: name. Arg 2: role (init|join). Arg 3: joinCmdB64 (empty for init).
start_instance() {
  local name="$1" role="$2" join_b64="${3:-}"
  if instance_running "${name}"; then
    info "${name} already running; leaving as-is (use lima:recreate to rebuild)"
    return 0
  fi
  if instance_exists "${name}"; then
    info "${name} exists but stopped; starting (state preserved)"
    limactl start --tty=false --timeout "${START_TIMEOUT:-900s}" "${name}"
    return 0
  fi
  prepare_host_mounts "${name}"
  info "creating + starting ${name} (role=${role}, vip=${VIP}, network=${NETWORK}, registry=${REGISTRY_ADDR})"
  # --set yq-expression: pass the env-driven vip param AND override the socket_vmnet
  # network name (.networks[0].lima) so a non-default (e.g. init-created dedicated)
  # network is honored. vip_interface stays lima0 (the first vmnet NIC, set in the
  # template's networks[0].interface). registryAddr = the Docker Hub pull-through cache
  # endpoint (cache:up's discovered DHCP IP via AI_INFRA_REGISTRY_ADDR) -> certs.d mirror.
  limactl start --tty=false --timeout "${START_TIMEOUT:-900s}" \
    --name "${name}" \
    --set ".param.role=\"${role}\" | .param.vip=\"${VIP}\" | .param.repoRoot=\"${REPO_ROOT}\" | .param.podCIDR=\"${POD_CIDR}\" | .param.serviceCIDR=\"${SERVICE_CIDR}\" | .param.joinCmdB64=\"${join_b64}\" | .param.registryAddr=\"${REGISTRY_ADDR}\" | .networks[0].lima=\"${NETWORK}\"" \
    "${TEMPLATE}"
}

# Discover the control-plane join command (token + ca-cert-hash + fresh cert key)
# from ai-inf-platform-0. Prints a base64-encoded `kubeadm join ... --control-plane` command
# on stdout; diagnostics go to stderr. The certificate key uploaded at init expires
# after 2h, so a fresh one is uploaded here for late joiners.
discover_join_cmd() {
  local cert_key join_cmd
  cert_key="$(limactl shell "${NODE0}" sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  [ -n "${cert_key}" ] || die "could not upload/obtain a fresh certificate key from ${NODE0}"
  join_cmd="$(limactl shell "${NODE0}" sudo kubeadm token create --print-join-command 2>/dev/null | tr -d '\r')"
  [ -n "${join_cmd}" ] || die "could not obtain join command from ${NODE0}"
  printf '%s --control-plane --certificate-key %s' "${join_cmd}" "${cert_key}" | base64 | tr -d '\n'
}

# Poll the kube-vip control-plane API VIP FROM THE HOST until /healthz returns "ok"
# (or the bounded deadline elapses). Right after the fresh VMs come up there is a
# transient window where kube-vip's leader election + gratuitous-ARP has not yet
# refreshed the host's neighbor entry for the VIP — especially after a base-name
# rename that reuses the VIP IP behind a NEW VM MAC, leaving the Mac's stale ARP entry
# pointed at the deleted VM. In that window the host's first API call fails with
# "no route to host". EVERY host-side kubectl step below (taint removal, monitoring
# CRDs, Cilium, Spegel, storage) targets this VIP via the kubeconfig written above, so
# gate on the VIP once here. Idempotent: returns immediately once the VIP answers
# (e.g. on a re-run against already-joined nodes).
wait_host_vip_ready() {
  local deadline=$((SECONDS + VIP_READY_DEADLINE_SECS))
  info "waiting for host -> kube-vip API VIP https://${VIP}:6443/healthz (deadline ${VIP_READY_DEADLINE_SECS}s)"
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if curl -sk --max-time 5 "https://${VIP}:6443/healthz" 2>/dev/null | grep -q ok; then
      info "kube-vip API VIP reachable from host"
      return 0
    fi
    info "VIP ${VIP}:6443 not reachable from host yet; retrying in 5s"
    sleep 5
  done
  die "host could not reach kube-vip API VIP https://${VIP}:6443 within ${VIP_READY_DEADLINE_SECS}s (kube-vip leader/ARP not converged? check 'limactl list' + host neighbor table for ${VIP})"
}

# Poll host kubectl for >= 3 total and >= 3 Ready nodes (after Cilium install).
wait_nodes_ready() {
  local deadline=$((SECONDS + READY_DEADLINE_SECS)) total ready
  info "waiting for 3 nodes Ready (deadline ${READY_DEADLINE_SECS}s)"
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    total="$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$(kc get nodes --no-headers 2>/dev/null | awk '$2 ~ /(^|,)Ready($|,)/ {c++} END {print c + 0}')"
    info "nodes: ${ready:-0}/${total:-0} Ready"
    if [ "${total:-0}" -ge 3 ] && [ "${ready:-0}" -ge 3 ]; then
      info "all 3 nodes Ready"
      return 0
    fi
    sleep 10
  done
  die "cluster did not reach 3 Ready nodes within ${READY_DEADLINE_SECS}s"
}

main() {
  require_cmd limactl kubectl base64 curl
  [ -f "${TEMPLATE}" ] || die "Lima template not found: ${TEMPLATE}"
  [ -f "${KUBE_VIP_SRC}" ] || die "kube-vip manifest not found: ${KUBE_VIP_SRC}"

  # Step 2: ai-inf-platform-0 initializes the control plane.
  start_instance "${NODE0}" "init" ""

  # Step 3: capture the control-plane join command (in-process only).
  info "discovering control-plane join command from ${NODE0}"
  local join_b64
  join_b64="$(discover_join_cmd)"

  # Step 4: ai-inf-platform-1, ai-inf-platform-2 join as control-plane nodes (sequential).
  local node
  for node in "${JOIN_NODES[@]}"; do
    start_instance "${node}" "join" "${join_b64}"
  done

  # Step 5: repo-local kubeconfig (server -> https://VIP:6443).
  info "writing host kubeconfig (server -> https://${VIP}:6443)"
  "${SCRIPT_DIR}/kubeconfig.sh"

  # Step 5b: block until the HOST can actually reach the kube-vip API VIP before ANY
  # host-side kubectl runs. This closes a transient early-bring-up window (kube-vip
  # leader election / gratuitous-ARP not yet refreshing the host neighbor entry) that
  # otherwise fails the first host API call with "no route to host". See
  # wait_host_vip_ready. Idempotent — returns at once when the VIP is already up.
  wait_host_vip_ready

  # Step 6: remove the control-plane taint BEFORE Cilium. This is an all-control-plane
  # cluster that runs workloads on every node — and Cilium's own hubble-relay/hubble-ui
  # Deployments do NOT tolerate the control-plane taint, so leaving it on DEADLOCKS
  # k8s:cilium's readiness wait (those pods stay Pending/unschedulable).
  info "removing control-plane taint from all nodes (before Cilium so Hubble can schedule)"
  kc taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

  # Step 6b: Monitoring CRDs (ServiceMonitor + PodMonitor, monitoring.coreos.com/v1).
  # MUST precede BOTH k8s:cilium (Step 7) and k8s:spegel (Step 8): each chart emits
  # ServiceMonitor/PodMonitor objects (Cilium agent/operator/hubble SMs with
  # trustCRDsExist; Spegel serviceMonitor.enabled), and both are applied here in
  # lima:start — BEFORE the k8s:apply phase that normally installs monitoring-crds.
  # Cilium's apply swallows errors (`... | kc apply ... 2>/dev/null || true`), so a
  # missing CRD would SILENTLY drop its SMs (no Cilium/Hubble metrics) rather than
  # fail loudly; Spegel's apply fails hard with
  #   no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1".
  # The CRDs are plain kustomize (no helm), cluster-scoped, depend on nothing, and
  # only register API types — no CNI/pod networking required, so they install fine
  # before Cilium. Idempotent with the later k8s:apply re-apply (server-side apply
  # converges). Block on Established so the kinds are servable before Cilium applies.
  info "installing monitoring CRDs (ServiceMonitor + PodMonitor) before Cilium + Spegel"
  kc apply -k "${REPO_ROOT}/kubernetes/monitoring-crds"
  kc wait --for=condition=Established --timeout=120s \
    crd/servicemonitors.monitoring.coreos.com \
    crd/podmonitors.monitoring.coreos.com

  # Step 7: Cilium (nodes are NotReady until this completes).
  info "installing Cilium"
  mise run k8s:cilium

  # Step 8: Spegel (peer-to-peer OCI mirror). Placed AFTER Cilium because Spegel needs
  # pod networking to peer-share layers, and BEFORE wait_nodes_ready / k8s:apply so the
  # DaemonSet is serving on every node before the heavy app images are pulled — that is
  # what makes a cold build do ~one docker.io pull per image cluster-wide.
  info "installing Spegel (peer-to-peer OCI registry mirror)"
  mise run k8s:spegel

  # Step 9: storage provisioner (default StorageClass).
  info "installing local-path storage provisioner"
  kc apply -k "${REPO_ROOT}/kubernetes/storage"

  # Step 10: verify 3 Ready.
  wait_nodes_ready

  info "lima:start complete — 3-node HA kubeadm + Cilium up"
  info "export KUBECONFIG=${KUBECONFIG:-${REPO_ROOT}/.local/kube/config}"
}

main "$@"
