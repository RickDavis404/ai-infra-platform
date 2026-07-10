#!/usr/bin/env bash
#MISE description="Apply all in-scope kustomize overlays to the cluster."
# .config/mise/tasks/k8s/apply.sh — apply all in-scope kustomize overlays in dependency order.
#
# Renders each overlay with `kustomize build --enable-helm` (mandatory: kubectl's
# built-in kustomize silently DROPS `helmCharts:` blocks) and applies server-side
# with `kubectl apply --server-side`. Layers are applied in the spec's bring-up
# order (§5 / kubernetes/README.md) with wait/rollout gates between them so a layer
# only proceeds once its dependencies report Ready:
#
#   namespaces -> secrets (mise secrets:sync) -> operators (cnpg + clickhouse) ->
#   langfuse-data (stores) -> lgtm (observability) -> langfuse -> litellm (+ keys) ->
#   ingress
#
# Idempotent: re-running converges. Secrets are synced via `mise run secrets:sync`
# (fnox+age); this script NEVER inlines or echoes secret material. Set
# AI_INFRA_SKIP_SECRETS=1 to skip the secrets:sync step (e.g. when already synced).
#
# IP-substitution mechanism (LITERAL DEFAULTS + sed override on the RENDERED stream):
# the committed LoadBalancer manifests/values/patches (litellm/service.yaml,
# langfuse values, grafana values, lgtm/otel-collector/lb-service.yaml,
# ingress/hubble-ui-lb.yaml) carry the DEFAULT per-service VIPs in their
# `lbipam.cilium.io/ips` annotations so each base renders standalone with
# `kustomize build`. At apply time, apply_overlay pipes the kustomize-built YAML
# through `sed`, rewriting each default VIP to its env value:
#   litellm  192.168.105.200 -> ${AI_INFRA_LITELLM_VIP}
#   langfuse 192.168.105.201 -> ${AI_INFRA_LANGFUSE_VIP}
#   grafana  192.168.105.202 -> ${AI_INFRA_GRAFANA_VIP}
#   otel     192.168.105.203 -> ${AI_INFRA_OTEL_VIP}
#   hubble   192.168.105.204 -> ${AI_INFRA_HUBBLE_VIP}
# A no-op when env equals the defaults (bare checkout applies the documented IPs).
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

if [[ -f "${REPO_ROOT}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.config/mise/lib/common.sh"
fi
# Defensive shims if common.sh is absent or older.
declare -F info >/dev/null 2>&1 || info() { printf '[info] %s\n' "$*" >&2; }
declare -F warn >/dev/null 2>&1 || warn() { printf '[warn] %s\n' "$*" >&2; }
declare -F err >/dev/null 2>&1 || err() { printf '[err ] %s\n' "$*" >&2; }
declare -F die >/dev/null 2>&1 || die() {
  err "$@"
  exit 1
}
declare -F need >/dev/null 2>&1 || need() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}
declare -F kc >/dev/null 2>&1 || kc() {
  KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.local/kube/config}" kubectl "$@"
}

readonly K8S_DIR="${REPO_ROOT}/kubernetes"
# 1200s (not 600s): on constrained Apple-Silicon Lima hardware the Langfuse v3 web
# first-boot is the long pole — Prisma + 34 ClickHouse migrations (~6 min) THEN ~4 min
# of app init (ClickHouse compat, langfuse MCP feature registration, cache warmup)
# before /api/public/health first answers: MEASURED ~10 min end to end on a fresh DB.
# The langfuse-web startupProbe budget was raised to match (20 min), so the rollout
# wait must also allow it or `wait_rollout` dies before the single migrating pod goes
# Ready (observed: 600s expired mid first-boot -> "rollout did not complete"). A cold
# CNPG 3-instance clone (initdb + 2 pg_basebackup replicas w/ image pulls) also brushes
# past 5 min. 20 minutes gives headroom so the first `mise run up` completes in one
# shot; fast rollouts return as soon as they are Ready, so this only raises the ceiling.
readonly WAIT_TIMEOUT="${WAIT_TIMEOUT:-1200s}"

# Helm Capabilities.APIVersions advertised to `kustomize build --enable-helm`.
# Some charts gate optional objects behind a render-time CRD-presence check
# (`{{ if .Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor" }}`).
# kustomize renders Helm OFFLINE (it never queries the cluster), so without this
# the check is false and the object is DROPPED from the applied stream — even
# though the CRD really is registered (monitoring-crds is applied first). The Loki
# chart (loki 17.4.9) gates BOTH its ServiceMonitor and its PrometheusRules this way
# and offers no `trustCRDsExist` escape hatch (unlike the Cilium chart), so its
# ServiceMonitor would never be applied and Loki's component metrics would silently
# vanish from Alloy's discovery. Advertising the two monitoring GVKs here makes the
# gate pass at render time, matching the real (post-CRD) cluster state. Charts that
# don't gate ignore these.
HELM_API_VERSIONS=(
  --helm-api-versions "monitoring.coreos.com/v1/ServiceMonitor"
  --helm-api-versions "monitoring.coreos.com/v1/PodMonitor"
  --helm-api-versions "monitoring.coreos.com/v1/PrometheusRule"
)

# Per-service LoadBalancer VIP defaults (as committed in the manifests/values) mapped
# to their env overrides. vip_sed_args populates the SED_VIP_ARGS array with one
# `-e s#default#env#g` pair per service whose env DIFFERS from the default, so the
# substitution is a no-op on a bare checkout and only rewrites changed VIPs. An array
# (not a word-split string) is used for portability — BSD/macOS sed mis-parses a
# single split flag string, whereas array expansion passes each token cleanly.
SED_VIP_ARGS=()
vip_sed_args() {
  SED_VIP_ARGS=()
  local def env pair
  for pair in \
    "192.168.105.200:${AI_INFRA_LITELLM_VIP:-192.168.105.200}" \
    "192.168.105.201:${AI_INFRA_LANGFUSE_VIP:-192.168.105.201}" \
    "192.168.105.202:${AI_INFRA_GRAFANA_VIP:-192.168.105.202}" \
    "192.168.105.203:${AI_INFRA_OTEL_VIP:-192.168.105.203}" \
    "192.168.105.204:${AI_INFRA_HUBBLE_VIP:-192.168.105.204}"; do
    def="${pair%%:*}"
    env="${pair#*:}"
    if [[ "${def}" != "${env}" ]]; then
      SED_VIP_ARGS+=(-e "s#${def}#${env}#g")
    fi
  done
}

# Profile selector (lean DEFAULT vs AI_INFRA_PROFILE=ha). Echoes "<rel>/lean" when
# the lean profile is active AND a co-located lean/ overlay exists for that unit,
# else the base "<rel>". Only the four units carrying lean deltas (langfuse-data,
# lgtm, langfuse, litellm) ship a lean/ overlay; every other unit is
# profile-invariant and resolves to itself. Unset => lean (the default single-node
# posture, `mise run up`); AI_INFRA_PROFILE=ha selects the HA base (`mise run up:ha`).
# The up/up:ha/up:lean tasks set this var — users never set it by hand. See
# kubernetes/README.md + docs/profiles.md + planning/ha-lean-overlay-plan.md.
profile_target() {
  local rel="$1"
  if [[ "${AI_INFRA_PROFILE:-lean}" == "lean" && -d "${K8S_DIR}/${rel}/lean" ]]; then
    printf '%s/lean\n' "${rel}"
  else
    printf '%s\n' "${rel}"
  fi
}

# kustomize build (helm-enabled) of an overlay, applied server-side. The rendered
# stream is piped through sed to rewrite default LB VIPs to their env overrides
# (literal-defaults-render-standalone, sed-at-apply; see header). When no VIP env
# differs from the default, SED_VIP_ARGS is empty and `sed` passes the stream through.
#
# `--load-restrictor LoadRestrictionsNone` is REQUIRED for the AI_INFRA_PROFILE=lean
# overlays: their chart-redeclare kustomizations (valkey/seaweedfs/loki lean) point
# the Helm inflator at the base values one directory up (`valuesFile: ../values.yaml`
# + `additionalValuesFiles: [../values-lean.yaml]`), and kustomize's default
# root-only restrictor rejects a value file above the kustomization root. The flag is
# a no-op for the HA bases (no out-of-root file refs). This is a read of committed,
# in-repo values only — no untrusted kustomizations are processed here.
#
# The apply is RETRIED on transient failures. An overlay that creates custom
# resources guarded by an operator's admission webhook (e.g. CNPG `Cluster` ->
# `mcluster.cnpg.io`, ClickHouse CRs) can momentarily race the webhook Service
# endpoint becoming ready/flapping, surfacing as
#   Internal error ... failed calling webhook ... connect: connection refused | EOF
# A single such blip must NOT fail a hands-off run, so we re-render and re-apply up
# to APPLY_RETRIES times with a short backoff. The render is cheap and the apply is
# idempotent (server-side), so retrying is safe.
APPLY_RETRIES="${APPLY_RETRIES:-5}"
APPLY_RETRY_DELAY="${APPLY_RETRY_DELAY:-6}"
apply_overlay() {
  local rel="$1"
  local dir="${K8S_DIR}/${rel}"
  [[ -d "${dir}" ]] || die "overlay not found: ${dir}"
  info "apply: ${rel}"
  vip_sed_args
  local attempt=1 rc=0 out
  while ((attempt <= APPLY_RETRIES)); do
    rc=0
    # Capture combined output so we can both surface it and inspect it for a
    # retryable (transient) signature. PIPESTATUS[2] is the kubectl apply status.
    out="$(kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "${HELM_API_VERSIONS[@]}" "${dir}" 2>&1 |
      sed "${SED_VIP_ARGS[@]}" |
      kc apply --server-side --force-conflicts -f - 2>&1)" || rc=1
    printf '%s\n' "${out}"
    if ((rc == 0)); then
      return 0
    fi
    # Helm-hook Jobs (e.g. the SeaweedFS bucket hook) embed chart-versioned pod
    # templates, but Job spec.template is IMMUTABLE — the first apply after a chart
    # bump dies with `The Job "<name>" is invalid: ... field is immutable`. The old
    # (completed) Job is disposable: delete the named Job(s) and re-apply so the
    # chart's new hook Job is recreated and re-runs (all hook Jobs here are
    # idempotent — bucket creation etc.). Same class of fix as litellm:remint-keys.
    if printf '%s' "${out}" | grep -q 'The Job "' && printf '%s' "${out}" | grep -q 'field is immutable'; then
      local job_name job_ns
      while IFS= read -r job_name; do
        [[ -n "${job_name}" ]] || continue
        job_ns="$(kc get jobs -A -o jsonpath="{.items[?(@.metadata.name=='${job_name}')].metadata.namespace}" 2>/dev/null || true)"
        if [[ -n "${job_ns}" ]]; then
          warn "apply ${rel}: Job ${job_ns}/${job_name} has an immutable template change from a chart bump; deleting so it can be recreated"
          kc -n "${job_ns}" delete job "${job_name}" --wait=true || true
        fi
      done < <(printf '%s' "${out}" | grep -o 'The Job "[^"]*"' | sed 's/^The Job "//;s/"$//' | sort -u)
      if ((attempt < APPLY_RETRIES)); then
        ((attempt++))
        continue
      fi
    fi
    # Only retry KNOWN-transient failures: webhook unavailability, API blips, and
    # host->kube-vip API VIP connection drops over socket_vmnet under load (connection
    # reset by peer / http2 connection lost / broken pipe / mid-response read error).
    # The last class intermittently bites a mid-apply on this Lima/socket_vmnet
    # substrate (host 192.168.105.1 -> VIP 192.168.105.40:6443) and MUST be retried so a
    # hands-off `up` survives it instead of dying on one transient blip.
    if printf '%s' "${out}" | grep -qiE 'failed calling webhook|connection refused|connection reset by peer|unexpected error when reading response body|http2: |broken pipe|: EOF|timeout|TLS handshake|i/o timeout|etcdserver: leader changed|the server is currently unable'; then
      if ((attempt < APPLY_RETRIES)); then
        warn "apply ${rel}: transient error (attempt ${attempt}/${APPLY_RETRIES}); retrying in ${APPLY_RETRY_DELAY}s"
        sleep "${APPLY_RETRY_DELAY}"
        ((attempt++))
        continue
      fi
    fi
    # Non-transient, or retries exhausted.
    die "apply failed for overlay ${rel}"
  done
  die "apply failed for overlay ${rel} after ${APPLY_RETRIES} attempts"
}

# wait_for <namespace> <kind/name...> — best-effort readiness gate using rollout
# status for Deployments/StatefulSets/DaemonSets, falling back to `wait` for CRs.
wait_rollout() {
  local ns="$1"
  shift
  local target
  for target in "$@"; do
    info "wait: rollout ${target} -n ${ns}"
    kc -n "${ns}" rollout status "${target}" --timeout="${WAIT_TIMEOUT}" ||
      die "rollout did not complete: ${target} -n ${ns}"
  done
}

# wait_condition <namespace> <condition> <selector-or-resource...>
wait_condition() {
  local ns="$1" cond="$2"
  shift 2
  local target
  for target in "$@"; do
    info "wait: ${cond} ${target} -n ${ns}"
    kc -n "${ns}" wait --for="${cond}" "${target}" --timeout="${WAIT_TIMEOUT}" ||
      warn "condition not met (continuing best-effort): ${cond} ${target} -n ${ns}"
  done
}

# sync_kubelet_endpoints — populate the headless `kubelet` Service
# (kubernetes/monitoring-extra/kubelet-service.yaml, ns kube-system) with an
# EndpointSlice built from the live node InternalIPs so its ServiceMonitor
# (kubelet + cAdvisor :10250) has targets.
#
# WHY this exists: the kubelet is a HOST PROCESS, not a pod, so no selector
# resolves to it. The standard prometheus-operator pattern is a selector-less
# `kubelet` Service whose endpoints the OPERATOR's endpoints controller syncs from
# node IPs. This platform runs NO operator (Alloy consumes the SM/PM CRDs
# directly), so that sync is done here instead. Node IPs are DHCP-assigned on the
# socket_vmnet shared L2, so they cannot be committed into the overlay — they are
# discovered at apply time from `kubectl get nodes`. The scheduler /
# controller-manager Services are selector-BASED (their static pods are real
# pods), so the built-in endpoints controller populates those automatically — only
# the kubelet needs this hand-sync.
#
# Idempotent: the objects are server-side applied (re-running converges as nodes
# come and go). The port name MUST match the Service port name (`https-metrics`)
# and the ServiceMonitor `port`, or the ServiceMonitor yields no targets.
#
# Two objects are built, because Alloy's prometheus.operator.servicemonitors
# resolves ServiceMonitor targets through the LEGACY core `v1 Endpoints` API (it
# logs "v1 Endpoints is deprecated ... use EndpointSlice" while doing so), NOT
# discovery.k8s.io/v1 EndpointSlices. A selector-less Service has no auto-created
# Endpoints object, so without the v1 Endpoints below Alloy sees ZERO kubelet
# targets and kubelet/cAdvisor metrics never appear (the EndpointSlice alone is
# invisible to the operator component). We apply BOTH: the v1 Endpoints (what Alloy
# actually consumes today) and the EndpointSlice (forward-compatible / native
# clients). `kubernetes.io/service-name: kubelet` binds the slice to the Service;
# the Endpoints object binds by sharing the Service's name (`kubelet`).
sync_kubelet_endpoints() {
  info "sync: kubelet Service Endpoints + EndpointSlice from node InternalIPs (ns kube-system)"
  # Collect "<internalIP> <nodeName>" pairs for every node. jsonpath emits the
  # InternalIP address then the node name per line.
  local nodes_raw
  nodes_raw="$(kc get nodes \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{.metadata.name}{"\n"}{end}' \
    2>/dev/null)" || {
    warn "could not list nodes; skipping kubelet endpoint sync (kubelet/cAdvisor metrics will have no targets until re-run)"
    return 0
  }
  if [[ -z "${nodes_raw//[[:space:]]/}" ]]; then
    warn "no node InternalIPs found; skipping kubelet endpoint sync"
    return 0
  fi
  # Build the endpoint bodies once. discovery.k8s.io/v1 caps a slice at 1000
  # endpoints; a 3-node CP is far under that, so one slice suffices.
  local ip name slice_eps="" core_addrs=""
  while read -r ip name; do
    [[ -n "${ip}" ]] || continue
    slice_eps+="- addresses: [\"${ip}\"]"$'\n'
    slice_eps+="  conditions: {ready: true}"$'\n'
    slice_eps+="  nodeName: ${name}"$'\n'
    core_addrs+="  - ip: ${ip}"$'\n'
    core_addrs+="    nodeName: ${name}"$'\n'
  done <<<"${nodes_raw}"

  # 1) Legacy core/v1 Endpoints — what Alloy's prometheus.operator.servicemonitors
  #    actually reads. Bound to the Service by sharing its name (`kubelet`).
  local core_ep
  core_ep="$(
    cat <<YAML
apiVersion: v1
kind: Endpoints
metadata:
  name: kubelet
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kubelet
    app.kubernetes.io/part-of: ai-infra-platform
subsets:
- addresses:
$(printf '%s' "${core_addrs}")
  ports:
  - name: https-metrics
    port: 10250
    protocol: TCP
YAML
  )"
  printf '%s\n' "${core_ep}" | kc apply --server-side --force-conflicts -f - ||
    die "failed to sync kubelet core/v1 Endpoints"

  # 2) discovery.k8s.io/v1 EndpointSlice — forward-compatible / native clients.
  local slice
  slice="$(
    cat <<YAML
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: kubelet-metrics
  namespace: kube-system
  labels:
    kubernetes.io/service-name: kubelet
    app.kubernetes.io/name: kubelet
    app.kubernetes.io/part-of: ai-infra-platform
addressType: IPv4
ports:
- name: https-metrics
  port: 10250
  protocol: TCP
endpoints:
$(printf '%s' "${slice_eps}" | sed 's/^/  /')
YAML
  )"
  printf '%s\n' "${slice}" | kc apply --server-side --force-conflicts -f - ||
    die "failed to sync kubelet EndpointSlice"
}

sync_secrets() {
  if [[ "${AI_INFRA_SKIP_SECRETS:-0}" == "1" ]]; then
    warn "AI_INFRA_SKIP_SECRETS=1 — skipping secrets:sync (assuming secrets already present)"
    return 0
  fi
  if command -v mise >/dev/null 2>&1; then
    info "sync secrets via 'mise run secrets:sync' (fnox+age; no secret material echoed)"
    (cd "${REPO_ROOT}" && mise run secrets:sync) ||
      die "secrets:sync failed — ensure age identity + fnox store are available"
  else
    warn "mise not found; cannot run secrets:sync. Set AI_INFRA_SKIP_SECRETS=1 if secrets are already applied."
    die "secrets not synced"
  fi
}

main() {
  need kubectl
  need kustomize
  [[ -d "${K8S_DIR}" ]] || die "kubernetes/ directory not found at ${K8S_DIR}"

  # 1) Namespaces — every later layer applies into these.
  apply_overlay "namespaces"

  # 1b) Monitoring CRDs — ServiceMonitor + PodMonitor (monitoring.coreos.com/v1)
  #     ONLY (prometheus-operator v0.81.0 CRDs; NO operator controller). MUST be
  #     applied EARLY — before any chart that emits an SM/PM (operators, data
  #     plane, lgtm and the gap overlays all ship some). Applying a
  #     ServiceMonitor/PodMonitor before its CRD is registered fails with
  #       no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"
  #     so this gate precedes every SM-emitting overlay. The CRDs are cluster
  #     scoped, depend on nothing, and are consumed by Alloy's
  #     prometheus.operator.{servicemonitors,podmonitors} components (NOT an
  #     operator) -> prometheus.remote_write -> the Prometheus server.
  apply_overlay "monitoring-crds"
  # Block until both CRDs are Established so the very next SM/PM-emitting overlay
  # sees a fully-registered API type (a freshly-applied CRD is not instantly
  # servable; the Established condition is the readiness signal).
  info "wait: ServiceMonitor + PodMonitor CRDs Established"
  kc wait --for=condition=Established --timeout="${WAIT_TIMEOUT}" \
    crd/servicemonitors.monitoring.coreos.com \
    crd/podmonitors.monitoring.coreos.com ||
    die "monitoring.coreos.com CRDs did not become Established"

  # 1c) Monitoring EXTRA — hand-written ServiceMonitor/PodMonitor objects for the
  #     metrics targets that have NO chart-emitted SM/PM: kube-apiserver, kubelet+
  #     cAdvisor, kube-scheduler, kube-controller-manager (ServiceMonitors, HTTPS +
  #     bearer), and etcd, kube-vip, hubble-relay, litellm, clickhouse-keeper
  #     (PodMonitors, plain HTTP). Applied AFTER the CRDs (so the SM/PM kinds
  #     resolve) and AFTER namespaces (line above — litellm/langfuse-data must
  #     exist for the namespaced objects). These are pure selectors: applying them
  #     before their producer workloads exist is fine — Alloy's
  #     prometheus.operator.{servicemonitors,podmonitors} discover them cluster-wide
  #     and scrape once the targets appear.
  apply_overlay "monitoring-extra"
  # The kubelet ServiceMonitor selects a selector-LESS `kubelet` Service whose
  # endpoints no controller syncs (operator-less). Build its EndpointSlice from the
  # live node InternalIPs now so kubelet/cAdvisor have scrape targets. Idempotent;
  # re-run converges as nodes change. (scheduler/controller-manager Services are
  # selector-based and need no hand-sync.)
  sync_kubelet_endpoints

  # 2) Secrets — fnox+age materialized into k8s Secrets the workloads reference.
  sync_secrets

  # 3) Operators — CNPG + ClickHouse (Altinity) operators must be Ready before any
  #    cluster custom resources (CNPG Cluster, ClickHouseInstallation) are reconciled.
  apply_overlay "operators/cnpg"
  apply_overlay "operators/clickhouse-operator"
  wait_rollout "cnpg-system" "deploy/cnpg-cloudnative-pg"
  # A label selector can't go through wait_condition (it quotes the whole target as one
  # arg, so kubectl reads "deploy -l app..." as a bogus resource type). Call kubectl wait
  # directly so `deploy` (resource) and `-l ...` (selector flag) stay separate args.
  info "wait: clickhouse-operator Available"
  kc -n "clickhouse-system" wait --for=condition=Available --timeout="${WAIT_TIMEOUT}" \
    deploy -l app.kubernetes.io/name=altinity-clickhouse-operator ||
    die "clickhouse-operator did not become Available"

  # 4) Data plane (stores): CNPG clusters, ClickHouse + Keeper, Valkey, SeaweedFS.
  apply_overlay "$(profile_target langfuse-data)"
  # CNPG Clusters report Ready via the cnpg.io Cluster condition; ClickHouse via CHI.
  wait_condition "langfuse-data" "condition=Ready" "cluster/langfuse-pg"
  wait_condition "langfuse-data" "jsonpath={.status.status}=Completed" \
    "clickhouseinstallation/langfuse-ch"

  # 5) Observability plane (lgtm): Grafana/Loki/Tempo/Prometheus/OTel/Alloy.
  apply_overlay "$(profile_target lgtm)"

  # 6) Langfuse (web + worker) — depends on langfuse-data stores being Ready.
  #    Prisma migrations run in the langfuse-web entrypoint. With >1 web replica the
  #    pods race on the `add_model_indices` CREATE INDEX CONCURRENTLY step (which runs
  #    OUTSIDE a transaction, so the migrate advisory lock doesn't cover it) -> Postgres
  #    deadlock (40P01) -> a half-applied migration -> P3009 crashloop. Serialize it:
  #    scale langfuse-web to 1 immediately after apply (the freshly-created pods are
  #    still pulling the image, well before they reach the migration), let the single
  #    pod run all Postgres + ClickHouse migrations and go Ready, THEN scale back to the
  #    values target (the new pods find migrations already applied -> no-op, no race).
  # Resolve the profile-selected langfuse dir ONCE: the apply, and the scale-back
  # target read below, must both point at the same overlay (base for HA, langfuse/lean
  # for AI_INFRA_PROFILE=lean) so the post-migration replica count matches what was
  # applied (2 for HA, 1 for lean).
  local lf_dir
  lf_dir="$(profile_target langfuse)"
  apply_overlay "${lf_dir}"
  info "serializing langfuse-web migration: pinning to 1 replica while it migrates"
  kc -n langfuse scale deploy/langfuse-web --replicas=1
  wait_rollout "langfuse" "deploy/langfuse-web"
  local lf_web
  lf_web="$(kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "${HELM_API_VERSIONS[@]}" "${K8S_DIR}/${lf_dir}" 2>/dev/null |
    yq 'select(.kind=="Deployment" and .metadata.name=="langfuse-web") | .spec.replicas' 2>/dev/null |
    grep -E '^[0-9]+$' | head -1)"
  info "langfuse-web migration done; scaling to target replicas (${lf_web:-2})"
  kc -n langfuse scale deploy/langfuse-web --replicas="${lf_web:-2}"
  wait_rollout "langfuse" "deploy/langfuse-web" "deploy/langfuse-worker"

  # 7) LiteLLM (+ its CNPG litellm-pg) — raw manifests.
  apply_overlay "$(profile_target litellm)"
  wait_condition "litellm" "condition=Ready" "cluster/litellm-pg"
  wait_rollout "litellm" "deploy/litellm"

  # 7b) Virtual-key provisioning — SEPARATE base, applied AFTER the gateway is Ready
  # because every Job curls the live gateway (/health/readiness, /team/new,
  # /key/generate). The Jobs self-gate via initContainers (wait for the gateway +
  # litellm-team-ids), and are idempotent (GET-then-PATCH-or-POST). The codex key
  # Job mints the FIXED CODEX_LITELLM_VIRTUAL_KEY value (sourced from
  # litellm-app-secrets, materialized by secrets:sync from fnox+age) so the host-side
  # Codex client can authenticate hands-off — no out-of-band "mirror to fnox" step.
  apply_overlay "litellm/keys"
  # Best-effort wait for the per-client key Jobs to complete so the virtual keys are
  # provisioned before `up` returns. Non-fatal: the Jobs have backoffLimit + restart
  # OnFailure and converge on a later re-run if the gateway is briefly busy.
  wait_condition "litellm" "condition=Complete" \
    "job/litellm-team-provision" "job/litellm-key-codex" \
    "job/litellm-key-claude-code"

  # 8) Ingress (Traefik IngressRoutes / Ingress objects) — last.
  apply_overlay "ingress"

  info "apply: all in-scope overlays applied and gated Ready"
}

main "$@"
