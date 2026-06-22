# ingress — host access via Cilium service VIPs (port-forward = non-HA fallback)

Host access to every UI and API is now via **fixed Cilium LB-IPAM service VIPs** on
the shared `192.168.105.0/24` L2. The Mac sits on that same L2 (socket_vmnet
`shared` net, guest NIC `lima0`), so each `type=LoadBalancer` Service IP is
reachable **DIRECTLY from the Mac** — `curl http://192.168.105.20x:<port>` with no
`kubectl port-forward` (D005 / `research/feedback-v2/ha-networking.md` §4).

The VIPs are HA: Cilium L2-announces each LB IP from one of the 3 control-plane
nodes and fails the ARP announcement over to a surviving node if that node dies, so
a single Lima VM loss never severs host access. `kubectl port-forward` is kept
**only as a non-HA loopback fallback** (it pins to one pod/one apiserver path and
cannot HA-forward a VIP).

## Host-access VIP map (direct from the Mac, same L2)

LB-IPAM pool `lima-shared-pool` = `192.168.105.200`–`192.168.105.250` (above
`dhcpEnd: 192.168.105.199`, so vmnet DHCP never collides). Each Service pins its IP
with the `lbipam.cilium.io/ips` annotation and `loadBalancerClass:
io.cilium/l2-announcer`, `externalTrafficPolicy: Cluster`.

| Surface | VIP : port | Owning component | port-forward fallback | mise task |
|---|---|---|---|---|
| LiteLLM API + admin UI | [`192.168.105.200:4000`](http://192.168.105.200:4000) | `kubernetes/litellm` (`service.yaml`) | `127.0.0.1:34000` | `port-forward:litellm` |
| Langfuse web UI + OTLP ingest | [`192.168.105.201:3000`](http://192.168.105.201:3000) | `kubernetes/langfuse` (values + `patches/lb-service.yaml`) | `127.0.0.1:33000` | `port-forward:langfuse` |
| Grafana | [`192.168.105.202:3000`](http://192.168.105.202:3000) | `kubernetes/lgtm/grafana` (values) | `127.0.0.1:33001` | `port-forward:grafana` |
| In-cluster OTel Collector OTLP | `192.168.105.203:4318` (HTTP) + `:4317` (gRPC) | `kubernetes/lgtm/otel-collector` (`lb-service.yaml`) | `127.0.0.1:34318` | `port-forward:otel` |
| Hubble UI | [`192.168.105.204`](http://192.168.105.204) (:80) | **THIS base** (`hubble-ui-lb.yaml`) | `127.0.0.1` via port-forward | on demand |

Notes that are requirements, not options:

- **All VIPs sit above `dhcpEnd` (`.199`)** so socket_vmnet DHCP never hands out a
  service IP. The control-plane VIP (`192.168.105.40`, kube-vip) is separate and
  NOT in this pool.
- **OTLP is standardized on plain `:4318`** with `/v1/{traces,metrics,logs}` paths
  (no `/otel` prefix), on both the Mac-side shipper and the in-cluster collector.
  The OTel VIP carries both `:4318` (HTTP) and `:4317` (gRPC) on the single
  `.203` IP.
- **The OTel `otel-collector` Service is also the in-cluster DNS name.** The
  opentelemetry-collector chart renders no Service in daemonset mode, so
  `kubernetes/lgtm/otel-collector/lb-service.yaml` provides the Service named
  `otel-collector` that backs both the cluster DNS name
  `otel-collector.lgtm.svc.cluster.local:4318` and the host VIP `.203`.
- **Grafana's local port-forward still maps to `127.0.0.1:33001`** (to avoid
  colliding with Langfuse on `3000`); the VIP exposes the remote `:3000` directly.
- **Hubble UI** has no separate fallback task; reach it via port-forward or
  `cilium hubble ui` on demand.

## Why this base owns only Hubble's VIP

Every app-tier Service is patched to `type=LoadBalancer` **inside its own
component**, so the VIP lives next to the workload it fronts. Hubble UI is the one
exception: it is created by the Cilium install in `kube-system`
(`kubernetes/cilium/`, owned by B1 and not edited here). Its host-facing
LoadBalancer is therefore added here as an **additive** Service
(`hubble-ui-lb`, selecting `k8s-app: hubble-ui`) rather than by mutating the
chart's bundled ClusterIP `hubble-ui` Service.

## What this base deliberately does NOT do

- No external ingress controller, gateway, or HTTP route. Host access is the L2 VIP
  set above (LAN-scoped to the `192.168.105.0/24` socket_vmnet subnet), not a
  published off-host endpoint.
- No mutation of the Cilium-owned `hubble-ui` Service (additive `hubble-ui-lb` only).
- No `NodePort` and no node-level host ports.

## Apply order

Per `kubernetes/README.md`, this base is last in the apply order
(operators → cilium → namespaces → langfuse-data → litellm/langfuse → lgtm →
ingress). The Cilium `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy`
(`kubernetes/cilium/`, B1) MUST be reconciled before any LB Service here (or in the
app components) gets an IP assigned and announced.
