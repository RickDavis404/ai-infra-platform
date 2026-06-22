# monitoring-crds — ServiceMonitor + PodMonitor CRDs (no operator)

This overlay installs **only** the two Prometheus-Operator custom-resource
definitions the platform's charts emit:

| CRD | Group/Version | Kind |
| --- | --- | --- |
| `servicemonitors.monitoring.coreos.com` | `monitoring.coreos.com/v1` | `ServiceMonitor` |
| `podmonitors.monitoring.coreos.com` | `monitoring.coreos.com/v1` | `PodMonitor` |

It does **not** deploy the prometheus-operator controller. The metrics path is:

```
ServiceMonitors / PodMonitors (chart-emitted + hand-written)
        │  discovered cluster-wide by
        ▼
Grafana Alloy  (ns lgtm, DaemonSet)
  prometheus.operator.servicemonitors + prometheus.operator.podmonitors
        │  prometheus.remote_write
        ▼
http://prometheus-server.lgtm.svc.cluster.local/prometheus/api/v1/write
  (Prometheus server: storage + query only; --web.enable-remote-write-receiver)
```

Alloy natively understands the SM/PM CRDs (the
`prometheus.operator.servicemonitors` / `...podmonitors` components), so the
operator's reconcile loop is unnecessary — only the API **types** are needed for
the charts to apply and for Alloy to discover them.

## Provenance

The two CRD YAMLs under `crds/` are vendored **verbatim** from
[`prometheus-operator/prometheus-operator`](https://github.com/prometheus-operator/prometheus-operator)
at tag **`v0.81.0`**:

```
example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
```

The pin (`v0.81.0`) is recorded here — this README is the provenance record for the
vendored CRDs (they are plain manifests, not a `helmCharts:` entry). Bumping the
version means re-fetching both files at the new tag.

## Apply order

`k8s:apply` applies this overlay **immediately after `namespaces` and before any
chart that emits a ServiceMonitor/PodMonitor** (operators → data-plane → lgtm →
apps). Applying an SM/PM before its CRD is registered fails with
`no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"`, so
the early ordering is load-bearing. The CRDs are cluster-scoped and depend on
nothing.
