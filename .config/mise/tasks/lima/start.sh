#!/usr/bin/env bash
#MISE description="Create/start the Lima kubeadm cluster (HA: 3-node init + 2 CP joins; lean: single node) and install Cilium."
set -euo pipefail

# lima:start — bring up the kubeadm control plane on the socket_vmnet shared network,
# then install Cilium, storage, and remove the control-plane taint so workloads
# schedule on every node. TOPOLOGY IS PROFILE-DRIVEN:
#   - lean (DEFAULT, `mise run up`): ONE node — ai-inf-platform-0 (role=init) only.
#     Steps 3-4 (join discovery + CP joins) are skipped entirely and the Ready wait
#     expects 1 node, so a lean bring-up never blocks waiting for joiners that don't
#     exist. This is what a bare `mise run up` (no AI_INFRA_PROFILE) selects.
#   - AI_INFRA_PROFILE=ha (`mise run up:ha`): 3 control-plane nodes (stacked etcd,
#     quorum 2/3).
#
# Sequence:
#   1. Resolve repoRoot; mkdir -p <repoRoot>/.local/lima/<vm>/{storage,config} for
#      every VM on the HOST (virtiofs requires the host dir to exist + be writable);
#      copy lima/kube-vip.yaml into each VM's config mount so the template's provision
#      script can place the kube-vip static pod before init/join.
#   2. Start ai-inf-platform-0 with role=init (kubeadm init --upload-certs, kube-proxy skipped).
#   3. (HA only) Discover the control-plane join command + certificate key FROM
#      ai-inf-platform-0 (in-process, never written to a committed file).
#   4. (HA only) Start ai-inf-platform-1 then ai-inf-platform-2 sequentially with role=join
#      (control-plane joins).
#   5. Write the repo-local kubeconfig (server -> https://VIP:6443) via lima:kubeconfig.
#   6. Remove the control-plane taint from all nodes (before Cilium so Hubble can schedule).
#   7. Install Cilium (k8s:cilium) — nodes are NotReady until the CNI is up.
#   8. Install Spegel (k8s:spegel) — peer-to-peer OCI mirror; needs pod networking
#      (so AFTER Cilium) and must be up BEFORE k8s:apply pulls the heavy app images.
#   9. Install the local-path storage provisioner (default StorageClass).
#  10. Wait for all profile-expected nodes Ready (HA: 3, lean: 1).
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
# Profile (unset/`lean` = DEFAULT single node; `ha` = 3-node HA). Mirrors the
# k8s:apply overlay selector — one env var drives BOTH the k8s posture and the
# substrate topology/sizing here. Set by the up/up:ha/up:lean tasks, not by hand.
readonly PROFILE="${AI_INFRA_PROFILE:-lean}"
# Profile-driven VM sizing + topology. Sizing/topology only applies at CREATE, so
# switching profiles needs a from-bare recreate (lima:recreate), not down->up.
#
#   - HA (32GB+ host, `mise run up:ha`): 3 nodes x template defaults (3 vCPU / 9GiB /
#     systemReservedMem 1280Mi); SIZE_OVERRIDE stays empty. (8GiB packed 2/3 nodes
#     memory-full and stranded the tempo local-path PV; 9GiB gives ~1GiB more
#     Allocatable per node — see lima/templates/k8s-cilium.yaml.)
#   - lean (DEFAULT, 16-24GB host, `mise run up`): ONE node at 6 vCPU / 12GiB,
#     systemReservedMem left at the template's 1280Mi default (the measured ~1.3GiB
#     control-plane + system baseline is PER-NODE and is the same stack on the single
#     node — no override needed).
#
# WHY single-node for lean (2026-07 measurements): the previous 3 x 4608MiB layout
# paid the control-plane tax 3x (~2GiB of apiserver ~400Mi + etcd + cilium ~260Mi +
# kube-vip duplicated per node) and then lost the remainder to cross-node
# bin-packing — the cluster packed 83% but unevenly (node-0 53%, nodes 1/2 96-97% +
# MemoryPressure-tainted), litellm sat 112Mi short of the only schedulable node, and
# the host still compressed ~5.3GB (20 ContainerStatusUnknown / 8 Error churn). One
# big node pays the control-plane tax ONCE and gives every pod a single large
# Allocatable pool, so bin-packing imbalance cannot strand memory.
#
# Lean guest math at 12GiB: 12288Mi - 1280Mi systemReserved - 300Mi evictionHard
# ≈ 10.7GiB Allocatable vs ~7.6GiB scheduled requests (~3GiB request headroom) and
# ~10GiB measured ACTUAL full-stack usage — itself an overestimate here, since the
# 3-node measurement counted every DaemonSet (cilium/spegel/alloy/...) 3x. litellm's
# honest 1536Mi request + ai-infra-gateway PriorityClass fit with room to spare.
# 11GiB was rejected: ~9.7GiB Allocatable sits AT the measured actual — no headroom.
#
# Lean host math at 12GiB: 12GiB VM + ~2.9GiB macOS baseline ≈ 14.9GiB of the 16GiB
# host, leaving macOS ~3-4GB (vs 2.2GiB at the 13.8GiB 3-node VM footprint that
# thrashed the compressor). The 2GiB ai-registry cache VM overlaps mainly during
# image pulls (its registry workload touches far less than its ceiling); stop it
# post-standup if the host runs tight. 6 vCPU keeps the previous lean compute total
# (3 x 2 vCPU) in one scheduler pool and leaves 2 host cores for macOS + shippers.
SIZE_OVERRIDE=""
[[ "${PROFILE}" == "lean" ]] && SIZE_OVERRIDE=' | .cpus=6 | .memory="12GiB"'
readonly SIZE_OVERRIDE
readonly NODE0="ai-inf-platform-0"
# Control-plane JOIN nodes: HA adds -1/-2 (stacked etcd, quorum 2/3); lean joins
# NOTHING — the init node is the whole cluster (sole etcd member, sole kube-vip
# leader; leader election with one candidate elects itself, no peer quorum needed).
if [[ "${PROFILE}" == "lean" ]]; then
  JOIN_NODES=()
else
  JOIN_NODES=("ai-inf-platform-1" "ai-inf-platform-2")
fi
readonly JOIN_NODES
# Total nodes the Ready wait expects (init + joiners). NB: bash-3.2-safe — ${#arr[@]}
# on an empty array is fine under set -u; only "${arr[@]}" expansion is not, and the
# join loop below is guarded so it never expands an empty array.
readonly EXPECTED_NODES=$((1 + ${#JOIN_NODES[@]}))
readonly POD_CIDR="10.42.0.0/16"
readonly SERVICE_CIDR="10.43.0.0/16"
readonly READY_DEADLINE_SECS="${READY_DEADLINE_SECS:-900}"
# Bound for the host->kube-vip API VIP reachability gate before the first host-side
# kubectl (see wait_host_vip_ready): kube-vip leader election + gratuitous-ARP refresh
# of the host neighbor entry normally converges in seconds, so 180s is generous.
readonly VIP_READY_DEADLINE_SECS="${VIP_READY_DEADLINE_SECS:-180}"
# Bounded-retry knobs for the Step 6b monitoring-CRDs apply — a safety net for GENUINE
# transient apiserver unavailability during early bring-up. The apply is server-side
# (idempotent, so re-running is safe; no client openapi/v2 download), and re-attempts the
# `kc apply --server-side -k` + Established wait up to CRD_APPLY_MAX_ATTEMPTS times,
# sleeping CRD_APPLY_BACKOFF_SECS between tries. A "no route to host" failure is NOT
# retried blindly: it is contrast-checked against Apple's exempt /usr/bin/curl and, when
# curl reaches the VIP while kubectl is denied, treated as the macOS Local Network
# privacy denial (see assert_host_kubectl_vip_access) and fails fast. See Step 6b.
readonly CRD_APPLY_MAX_ATTEMPTS="${CRD_APPLY_MAX_ATTEMPTS:-8}"
readonly CRD_APPLY_BACKOFF_SECS="${CRD_APPLY_BACKOFF_SECS:-5}"

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
  # From-bare hygiene: reaching prepare_host_mounts means this instance is being
  # CREATED (start_instance returns early for already-running or stopped-existing
  # instances), so anything under the host-persisted storage mount is leftover PVC
  # data from a PREVIOUS cluster life. The local-path storageclass uses deterministic
  # pathPattern volumes (<ns>/<pvc-name>), so on a from-bare rebuild a replicated
  # store (ClickHouse/Keeper/CNPG-PG/SeaweedFS/Valkey) can otherwise resurrect stale
  # on-disk state INTO a fresh cluster whose Keeper/quorum is empty — e.g. ClickHouse
  # attaches its tables READONLY (absolute_delay grows forever → CHI never Completed),
  # or langfuse-pg comes up already carrying a previous life's 419 Prisma migrations,
  # breaking langfuse-web's migrate step (the 2026-07-06 bring-up stall). Wiping here
  # makes "from-bare" actually bare; a normal `down`→`up` restart takes the
  # instance_exists branch above and NEVER reaches this line, so data is preserved
  # across restarts. Data lifecycle == VM lifecycle.
  if [ -d "${base}/storage" ] && [ -n "$(ls -A "${base}/storage" 2>/dev/null)" ]; then
    warn "wiping stale PVC data under ${base}/storage (instance ${vm} is being (re)created from bare)"
    rm -rf -- "${base}/storage"/* "${base}/storage"/.[!.]* 2>/dev/null || true
  fi
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
  # SIZE_OVERRIDE (empty for HA) appends the lean-profile cpus/memory shrink.
  limactl start --tty=false --timeout "${START_TIMEOUT:-900s}" \
    --name "${name}" \
    --set ".param.role=\"${role}\" | .param.vip=\"${VIP}\" | .param.repoRoot=\"${REPO_ROOT}\" | .param.podCIDR=\"${POD_CIDR}\" | .param.serviceCIDR=\"${SERVICE_CIDR}\" | .param.joinCmdB64=\"${join_b64}\" | .param.registryAddr=\"${REGISTRY_ADDR}\" | .networks[0].lima=\"${NETWORK}\"${SIZE_OVERRIDE}" \
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

# macOS Local Network privacy (macOS 15+/26): third-party binaries — the mise-managed
# kubectl included — are DENIED traffic to local-network addresses (the socket_vmnet
# subnet, incl. the kube-vip API VIP) UNLESS the run inherits a session holding the
# Local Network permission. A detached run (nohup/orphaned/launchd; e.g. a
# fire-and-forget ssh) fails EVERY kubectl dial INSTANTLY with "connect: no route to
# host" while Apple's /usr/bin/curl (a platform binary, exempt) reaches the same URL.
# Probe kubectl once and, if it is denied while curl succeeds, FAIL FAST with the real
# diagnosis instead of spinning a retry loop against a policy denial for minutes.
# (/usr/bin/curl is deliberately explicit here: the Apple-platform-binary exemption is
# the whole point of the contrast probe — a PATH curl could be a third-party build.)
assert_host_kubectl_vip_access() {
  local out attempt=1
  while [ "${attempt}" -le 3 ]; do
    if out="$(kc get --raw='/healthz' --request-timeout=10s 2>&1)"; then
      info "host kubectl -> API VIP https://${VIP}:6443 reachable (Local Network access OK)"
      return 0
    fi
    case "${out}" in
    *"no route to host"*)
      if /usr/bin/curl -sk --max-time 5 "https://${VIP}:6443/healthz" 2>/dev/null | grep -q ok; then
        die "host kubectl is DENIED macOS Local Network access to the API VIP ${VIP}:6443 (curl reaches it; kubectl gets 'no route to host'). This run is detached from any session holding the Local Network permission (nohup/orphaned/launchd/fire-and-forget ssh). Re-run 'mise run up' from a live terminal, or from a foreground ssh session kept open for the ENTIRE run (do NOT nohup it on the mac). kubectl said: ${out}"
      fi
      ;;
    esac
    warn "host kubectl -> API VIP probe failed (attempt ${attempt}/3): ${out}"
    attempt=$((attempt + 1))
    sleep 5
  done
  die "host kubectl cannot reach the API VIP https://${VIP}:6443 after 3 attempts; last error: ${out}"
}

# Poll host kubectl for >= EXPECTED_NODES total and Ready nodes (after Cilium
# install). EXPECTED_NODES is profile-derived (HA: 3, lean: 1) so a lean bring-up
# does not hang here waiting for joiners that were never created.
wait_nodes_ready() {
  local deadline=$((SECONDS + READY_DEADLINE_SECS)) total ready
  info "waiting for ${EXPECTED_NODES} nodes Ready (deadline ${READY_DEADLINE_SECS}s)"
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    total="$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$(kc get nodes --no-headers 2>/dev/null | awk '$2 ~ /(^|,)Ready($|,)/ {c++} END {print c + 0}')"
    info "nodes: ${ready:-0}/${total:-0} Ready"
    if [ "${total:-0}" -ge "${EXPECTED_NODES}" ] && [ "${ready:-0}" -ge "${EXPECTED_NODES}" ]; then
      info "all ${EXPECTED_NODES} nodes Ready"
      return 0
    fi
    sleep 10
  done
  die "cluster did not reach ${EXPECTED_NODES} Ready nodes within ${READY_DEADLINE_SECS}s"
}

main() {
  require_cmd limactl kubectl base64 curl
  [ -f "${TEMPLATE}" ] || die "Lima template not found: ${TEMPLATE}"
  [ -f "${KUBE_VIP_SRC}" ] || die "kube-vip manifest not found: ${KUBE_VIP_SRC}"

  # Step 2: ai-inf-platform-0 initializes the control plane.
  start_instance "${NODE0}" "init" ""

  # Steps 3+4 (HA only): capture the control-plane join command (in-process only),
  # then join ai-inf-platform-1, ai-inf-platform-2 sequentially. The lean profile has
  # NO join nodes: skip both — nothing would consume the join command, and the
  # single-node bring-up must never wait on joiners. (Guarded on the array LENGTH so
  # the empty lean array is never expanded — bash-3.2 + set -u safe.)
  if [ "${#JOIN_NODES[@]}" -gt 0 ]; then
    info "discovering control-plane join command from ${NODE0}"
    local join_b64 node
    join_b64="$(discover_join_cmd)"
    for node in "${JOIN_NODES[@]}"; do
      start_instance "${node}" "join" "${join_b64}"
    done
  else
    info "profile=${PROFILE}: single-node topology — skipping join discovery + control-plane joins"
  fi

  # Step 5: repo-local kubeconfig (server -> https://VIP:6443).
  info "writing host kubeconfig (server -> https://${VIP}:6443)"
  "${SCRIPT_DIR}/kubeconfig.sh"

  # Step 5b: block until the HOST can actually reach the kube-vip API VIP before ANY
  # host-side kubectl runs. This closes a transient early-bring-up window (kube-vip
  # leader election / gratuitous-ARP not yet refreshing the host neighbor entry) that
  # otherwise fails the first host API call with "no route to host". See
  # wait_host_vip_ready. Idempotent — returns at once when the VIP is already up.
  wait_host_vip_ready

  # Step 5c: fail-fast preflight — verify HOST KUBECTL (not just curl) can dial the API
  # VIP before the first kc use. macOS Local Network privacy denies DETACHED third-party
  # binaries (the mise-managed kubectl) access to the socket_vmnet subnet even while
  # Apple's exempt /usr/bin/curl succeeds against the same URL, so a passing Step 5b
  # curl gate does NOT prove kubectl can connect. Without this, every kc step below
  # fails instantly with "no route to host". See assert_host_kubectl_vip_access.
  assert_host_kubectl_vip_access

  # Step 6: remove the control-plane taint BEFORE Cilium. This is an all-control-plane
  # cluster that runs workloads on every node — and Cilium's own hubble-relay/hubble-ui
  # Deployments do NOT tolerate the control-plane taint, so leaving it on DEADLOCKS
  # k8s:cilium's readiness wait (those pods stay Pending/unschedulable). A silently
  # swallowed failure here therefore matters: capture the output and WARN on any error
  # other than the idempotent "taint not found" (already removed) case. Non-fatal — a
  # re-run or a manual `kubectl taint` can recover — but never invisible.
  info "removing control-plane taint from all nodes (before Cilium so Hubble can schedule)"
  local taint_out
  if taint_out="$(kc taint nodes --all node-role.kubernetes.io/control-plane- 2>&1)"; then
    info "control-plane taint removed (or already absent) on all nodes"
  else
    case "${taint_out}" in
    *"not found"*)
      info "control-plane taint already removed (idempotent re-run): ${taint_out}"
      ;;
    *)
      warn "control-plane taint removal FAILED (a still-tainted node deadlocks k8s:cilium's Hubble readiness wait): ${taint_out}"
      ;;
    esac
  fi

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
  # before Cilium. Block on Established so the kinds are servable before Cilium applies.
  #
  # The apply is `--server-side --force-conflicts`: repo-idiomatic (the entire k8s:apply
  # pipeline applies server-side — apply.sh, spegel.sh, cilium, secrets/sync), idempotent
  # (safe to retry), and field-manager-consistent with the LATER k8s:apply re-apply via
  # apply_overlay "monitoring-crds" (also server-side), so the two converge with no
  # field-owner conflict. It also performs NO client-side openapi/v2 schema download (a
  # plain `kc apply -k` does one before applying).
  #
  # History note: earlier "no route to host" failures at this step were blamed on a
  # transient "macOS vmnet fresh-connection ARP/neighbor blip" that curl supposedly could
  # not see — DISPROVEN. The real cause is macOS Local Network privacy denying DETACHED
  # third-party binaries (kubectl) access to the socket_vmnet subnet while Apple's exempt
  # /usr/bin/curl succeeds; the Step 5c assert_host_kubectl_vip_access preflight now
  # fails that case fast. The bounded retry below remains as a safety net for GENUINE
  # transient apiserver unavailability during early bring-up: each failed attempt's
  # combined output is surfaced (warn) so the failure CLASS is visible, and a
  # "no route to host" is contrast-checked against /usr/bin/curl — curl ok + kubectl
  # denied means the run lost its permission-holding session MID-RUN (e.g. the driving
  # ssh dropped), which retrying cannot fix, so die with the Local-Network diagnosis
  # instead of burning the remaining attempts against a policy denial.
  info "installing monitoring CRDs (ServiceMonitor + PodMonitor) before Cilium + Spegel"
  local crd_attempt=1 crd_applied=0 crd_out=""
  while [ "${crd_attempt}" -le "${CRD_APPLY_MAX_ATTEMPTS}" ]; do
    # Guard the apply AND the Established wait TOGETHER: a transient failure of EITHER
    # must not trip set -e / the ERR trap. The command substitution runs them in a
    # subshell (the ERR trap is not inherited — no `set -E`) and `if !` catches the
    # nonzero exit, so a transient failure is a retryable warn, not a fatal abort.
    if ! crd_out="$(
      {
        kc apply --server-side --force-conflicts -k "${REPO_ROOT}/kubernetes/monitoring-crds" &&
          kc wait --for=condition=Established --timeout=120s \
            crd/servicemonitors.monitoring.coreos.com \
            crd/podmonitors.monitoring.coreos.com
      } 2>&1
    )"; then
      warn "monitoring-CRDs apply/wait failed (attempt ${crd_attempt}/${CRD_APPLY_MAX_ATTEMPTS}): ${crd_out}"
      case "${crd_out}" in
      *"no route to host"*)
        if /usr/bin/curl -sk --max-time 5 "https://${VIP}:6443/healthz" 2>/dev/null | grep -q ok; then
          die "host kubectl is DENIED macOS Local Network access to the API VIP ${VIP}:6443 (curl reaches it; kubectl gets 'no route to host'). The run lost its session holding the Local Network permission MID-RUN (nohup/orphaned/launchd/dropped ssh). Re-run 'mise run up' from a live terminal, or from a foreground ssh session kept open for the ENTIRE run (do NOT nohup it on the mac). kubectl said: ${crd_out}"
        fi
        ;;
      esac
      sleep "${CRD_APPLY_BACKOFF_SECS}"
      crd_attempt=$((crd_attempt + 1))
      continue
    fi
    info "monitoring CRDs (ServiceMonitor + PodMonitor) installed + Established (attempt ${crd_attempt}/${CRD_APPLY_MAX_ATTEMPTS})"
    crd_applied=1
    break
  done
  [ "${crd_applied}" = "1" ] || die "monitoring-CRDs apply did not succeed after ${CRD_APPLY_MAX_ATTEMPTS} attempts against kube-vip API VIP https://${VIP}:6443; last output: ${crd_out}"

  # Step 7: Cilium (nodes are NotReady until this completes).
  info "installing Cilium"
  mise run k8s:cilium

  # Step 8: Spegel (peer-to-peer OCI mirror). Placed AFTER Cilium because Spegel needs
  # pod networking to peer-share layers, and BEFORE wait_nodes_ready / k8s:apply so the
  # DaemonSet is serving on every node before the heavy app images are pulled — that is
  # what makes a cold build do ~one docker.io pull per image cluster-wide.
  # SKIPPED on a single-node cluster (lean): Spegel's P2P router cannot bootstrap without
  # peers — it fails "routing table is empty after bootstrapping", never goes Ready, and
  # its DaemonSet rollout wait would abort the up. A peer mirror is also pointless with one
  # node (containerd's own image cache + the pull-through registry already cover docker.io).
  if [ "${#JOIN_NODES[@]}" -gt 0 ]; then
    info "installing Spegel (peer-to-peer OCI registry mirror)"
    mise run k8s:spegel
  else
    info "skipping Spegel — single-node cluster has no peers (P2P mirror needs >=2 nodes); containerd cache + pull-through registry suffice"
  fi

  # Step 9: storage provisioner (default StorageClass).
  info "installing local-path storage provisioner"
  kc apply -k "${REPO_ROOT}/kubernetes/storage"

  # Step 10: verify all profile-expected nodes Ready (HA: 3, lean: 1).
  wait_nodes_ready

  if [ "${#JOIN_NODES[@]}" -gt 0 ]; then
    info "lima:start complete — 3-node HA kubeadm + Cilium up"
  else
    info "lima:start complete — single-node lean kubeadm + Cilium up"
  fi
  info "export KUBECONFIG=${KUBECONFIG:-${REPO_ROOT}/.local/kube/config}"
}

main "$@"
