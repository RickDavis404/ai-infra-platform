# Cilium CNI (kube-proxy-free, HA service VIPs)

Cilium is the CNI for the three-node HA **kubeadm** cluster (`ai-inf-platform-0/1/2`). kubeadm
is bootstrapped with `--skip-phases=addon/kube-proxy` (no kube-proxy), so the cluster has
**no CNI and no service proxy** and all nodes are `NotReady` until Cilium is installed.
Cilium is installed **immediately after** the control-plane init (before any workload),
via Helm, from this committed values file — it provides both the pod network and the
ClusterIP/service load-balancing that kube-proxy would otherwise handle.

## Chart provenance and pin

| Field        | Value                     |
|--------------|---------------------------|
| Chart        | `cilium`                  |
| Repo         | `https://helm.cilium.io`  |
| Version      | **`1.20.0-pre.4`** (pinned, pre-release) |
| Release name | `cilium`                  |
| Namespace    | `kube-system`             |
| Values       | `values.yaml`             |
| CRDs         | `includeCRDs: true`       |

The chart version is pinned exactly in `kustomization.yaml`; it does **not** float.
Re-test the kube-proxy-replacement, LB-IPAM, and L2-announcement knobs on any bump.

## Render and apply

This base inlines the Helm chart via `helmCharts:` and must be rendered with
`--enable-helm`, then the LB-IPAM pool + L2 policy are applied:

```bash
kustomize build --enable-helm kubernetes/cilium | kubectl apply --server-side -f -
```

The repo wraps this (idempotent install/upgrade + wait-for-ready, then the
`CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` apply) in the `k8s:cilium`
mise task, which `lima:start` invokes right after `ai-inf-platform-0` is serving the API.

## kube-proxy REPLACED (kube-proxy-free)

`kubeProxyReplacement: true` — Cilium's eBPF datapath fully replaces kube-proxy. Because
there is no kube-proxy to program the `kubernetes` ClusterIP, Cilium must reach the
apiserver out-of-band: `k8sServiceHost: 192.168.105.40` (the **kube-vip control-plane
VIP**, NOT a node IP or localhost) and `k8sServicePort: 6443`. The VIP is used so the
agents survive the loss of any single control-plane node (it exists before Cilium because
kube-vip is a static pod brought up during `kubeadm init`).

`routingMode: native` with `ipv4NativeRoutingCIDR: 10.42.0.0/16` and
`autoDirectNodeRoutes: true` — direct routing on the flat `192.168.105.0/24` shared-L2
subnet (no tunnel overhead). `devices: lima0` pins the datapath to the socket_vmnet NIC
(never `eth0`, the SLIRP NAT NIC). If inter-node pod routing ever proves flaky, fall back
to `routingMode: tunnel` (vxlan) — kube-proxy-replacement works in both.

## IPAM / pod-CIDR alignment

`ipam.mode: kubernetes` with `operator.clusterPoolIPv4PodCIDRList: ["10.42.0.0/16"]`
aligns Cilium's IPAM with kubeadm's `networking.podSubnet` so pod IPs come from exactly
that range (service CIDR is `10.43.0.0/16`).

## Service VIPs — LB-IPAM + L2 announcements (HA host access)

Cilium owns all `type: LoadBalancer` services and gives each a stable VIP on the Lima
shared L2 subnet, reachable **directly from the Mac** (same L2) and failing over on node
loss — this is the HA replacement for `kubectl port-forward`:

- **`CiliumLoadBalancerIPPool` `lima-shared-pool`** (`cilium.io/v2`) — pool
  `192.168.105.200`–`192.168.105.250`.
- **`CiliumL2AnnouncementPolicy` `lima-lb-l2`** (`cilium.io/v2alpha1`, Beta in 1.19) —
  `loadBalancerIPs: true`, `interfaces: ['^lima0$']`, any control-plane node may answer ARP.
- Enabled in values: `l2announcements.enabled: true`, `externalIPs.enabled: true`,
  `k8sClientRateLimit: {qps: 50, burst: 100}` (the L2-lease churn exhausts the default 5/10).

Services pin a fixed VIP with the annotation `lbipam.cilium.io/ips: <ip>` +
`loadBalancerClass: io.cilium/l2-announcer` + `externalTrafficPolicy: Cluster` (Local can
drop on pod-less nodes). The v1 service VIPs: LiteLLM `.200:4000`, Langfuse-web `.201:3000`,
Grafana `.202:3000`, OTel OTLP `.203:4318(+4317)`, Hubble UI `.204`.

> kube-vip is configured **control-plane-only** (`cp_enable`, no `svc_enable`) so it never
> competes with Cilium for service IPs — kube-vip owns the API VIP, Cilium owns service VIPs.

## Operator HA + Hubble

`operator.replicas: 2` (leader-elected) for the 3-node cluster. Hubble (relay + UI +
metrics) is enabled and feeds the LGTM/Grafana stack. Hubble Relay needs TCP `4244` on
every node (`cilium status` → Relay `OK`). Metrics are scraped via `prometheus.io/scrape`
annotations (`serviceMonitor.enabled: false`): cilium-agent `:9962`, Hubble Relay `:9966`,
operator metrics. The Hubble UI is reachable via its LoadBalancer VIP `192.168.105.204`
(port-forward remains a fallback).

## L7 visibility — OPT-IN add-on

L7 HTTP visibility is an opt-in add-on with a documented hard safety coupling
(`policyAuditMode: true` cluster-wide + an L7 `CiliumClusterwideNetworkPolicy`; an
`endpointSelector: {}` CCWNP flips endpoints to ingress-deny-default for non-matching flows
the moment it attaches — safe **only** while audit mode is on). Never flip audit mode off
without widening the port list or removing the policy. When enabled, also set the Envoy
tuning (`envoy.log.accessLogBufferSize: 65536`,
`envoy.streamIdleTimeoutDurationSeconds: 900`). Not in the default install.
