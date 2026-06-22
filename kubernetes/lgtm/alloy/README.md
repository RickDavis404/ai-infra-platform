# Alloy — meta-observability ONLY

Grafana Alloy here has exactly **one** job: ship the in-cluster OTel Collector's
own pod logs to Loki. It is **not** the general container-log path.

| | |
|---|---|
| Chart | `alloy` |
| Repo | `https://grafana.github.io/helm-charts` |
| Version (pinned) | `1.10.0` |
| Release | `alloy` |
| Namespace | `lgtm` |
| Topology | DaemonSet, tiny footprint |

## Provenance and apply

```bash
kustomize build --enable-helm kubernetes/lgtm/alloy | kubectl apply -f -
```

The chart pin (`1.10.0`) is exact and does not float; the Alloy image tag is pinned
to `v1.17.1` (an explicit `image.tag` override — the chart 1.10.0 default is
unchanged). Namespace is `lgtm` (decision D001).

## Why Alloy exists (and what it is NOT)

The general log path for the whole platform is the **OTel Collector's `filelog`
receiver** — every container log flows through the collector to Loki. The collector
deliberately does **not** ship its own logs (its `logsCollection` preset sets
`includeCollectorLogs: false`), because a collector cannot reliably log about its
own export failures: if the collector's Loki export is broken, the very messages
explaining why would be the ones that fail to ship.

Alloy closes that gap and nothing more. It discovers pods in `lgtm` labelled
`app.kubernetes.io/name=opentelemetry-collector`, **drops Alloy's own pods**
(anti-loop), stamps `service_name=otel-collector-self`, and pushes to
`http://loki.lgtm.svc.cluster.local:3100/loki/api/v1/push`.

**Do not** repurpose Alloy as the general log path. The narrative that "every
container log flows via Alloy" is aspirational Promtail-migration direction, not the
deployed scope. The River config in `values.yaml` and the meta-observability scope
above are authoritative.

## River config summary

- `discovery.kubernetes` — role `pod`, namespace `lgtm`.
- `discovery.relabel` — keep `opentelemetry-collector`, drop `alloy`, stamp
  `service_name=otel-collector-self`, carry `namespace`/`pod` labels, derive
  `__path__`.
- `loki.source.kubernetes` — tail the kept pods' log files.
- `loki.write` — push to Loki in `lgtm`.

## Access (port-forward only)

Alloy has no user-facing UI in this scope. Confirm it is shipping by querying Loki
for `{service_name="otel-collector-self"}`.
