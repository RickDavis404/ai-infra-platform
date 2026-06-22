# monitoring-extra — hand-written ServiceMonitors / PodMonitors for the gap targets

This overlay supplies the ServiceMonitor / PodMonitor objects for every metrics
target that does **not** get one from its own Helm chart. It complements the
chart-emitted SM/PMs (cilium, lgtm components, cnpg, etc.) so that, once the
metrics pipeline switched from the Prometheus chart's static `extraScrapeConfigs`
to the operator-CRD model, no target is lost.

## Pipeline

```
ServiceMonitors / PodMonitors (chart-emitted + these hand-written)
        │  discovered CLUSTER-WIDE (no label selector) by
        ▼
Grafana Alloy  (ns lgtm, DaemonSet)
  prometheus.operator.servicemonitors "all" + prometheus.operator.podmonitors "all"
        │  prometheus.remote_write
        ▼
http://prometheus-server.lgtm.svc.cluster.local/prometheus/api/v1/write
```

Because Alloy discovers **all** SM/PM cluster-wide, these objects need **no**
special discovery label — they are picked up wherever they live.

## Targets and type choice

| Target | Object | Port / path | Auth | Selection |
| --- | --- | --- | --- | --- |
| kube-apiserver | ServiceMonitor | `https` :443 `/metrics` | bearer + CA verify | existing `kubernetes` svc (default ns) |
| kubelet | ServiceMonitor | `https-metrics` :10250 `/metrics` | bearer, skip-verify | headless `kubelet` svc + synced EndpointSlice |
| cAdvisor | ServiceMonitor (same SM) | :10250 `/metrics/cadvisor` | bearer, skip-verify | same |
| kube-scheduler | ServiceMonitor | `https-metrics` :10259 `/metrics` | bearer, skip-verify | selector svc → `component: kube-scheduler` |
| kube-controller-manager | ServiceMonitor | `https-metrics` :10257 `/metrics` | bearer, skip-verify | selector svc → `component: kube-controller-manager` |
| etcd | PodMonitor | :2381 `/metrics` (http) | none | `component: etcd`, `__address__` rewrite |
| kube-vip | PodMonitor | named `metrics` :2112 (http) | none | `app.kubernetes.io/name: kube-vip` |
| hubble-relay | PodMonitor | named `prometheus` :9966 (http) | none | `k8s-app: hubble-relay` |
| litellm | PodMonitor | named `http` :4000 `/metrics/` (http) | none | `app.kubernetes.io/name: litellm` |
| clickhouse-keeper | PodMonitor | :7000 `/metrics` (http) | none | chk label, `__address__` rewrite |

**ServiceMonitor vs PodMonitor.** The HTTPS control-plane targets need the Alloy
pod's auto-renewing projected ServiceAccount token, supplied via `bearerTokenFile`
— a field that exists **only** on ServiceMonitor (the PodMonitor CRD has none), so
every bearer-token target is a ServiceMonitor. The plain-HTTP targets are
PodMonitors selected by pod label.

**Numeric ports are a trap on PodMonitors.** A numeric `port`/`targetPort` on a
PodMonitor becomes a `keep` relabel rule on the pod's *declared* container ports,
so a static / hostNetwork pod that declares no such port matches nothing. This
overlay therefore either references a **named** container port (kube-vip — port
added to `lima/kube-vip.yaml`; hubble-relay, litellm — named by their charts) or
omits the port and rewrites `__address__` to the pod IP : metrics-port (etcd,
clickhouse-keeper), with a container-name `keep` to dedup hostNetwork targets.

## Dependencies wired into `k8s:apply`

1. The kubeadm `ClusterConfiguration` in `lima/templates/k8s-cilium.yaml` flips the
   scheduler/controller-manager bind-address to `0.0.0.0` and etcd
   `listen-metrics-urls` to `http://0.0.0.0:2381` — without these the HTTPS/HTTP
   control-plane endpoints stay loopback-only and unscrapable.
2. `k8s:apply` applies this overlay right after `monitoring-crds` (CRDs registered)
   and after `namespaces`, then runs `sync_kubelet_endpoints` to populate the
   selector-less `kubelet` Service's EndpointSlice from the live node InternalIPs
   (operator-less, DHCP node IPs → synced at apply time, not committed).
