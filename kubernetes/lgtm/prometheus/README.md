# Prometheus — standalone, 2-replica, route-prefixed

Standalone Prometheus from the `prometheus-community/prometheus` chart. It is the
metrics store and the remote-write receiver for the OTel Collector and Tempo's
metrics-generator.

| | |
|---|---|
| Chart | `prometheus` |
| Repo | `https://prometheus-community.github.io/helm-charts` |
| Version (pinned) | `29.14.0` |
| Release | `prometheus` |
| Namespace | `lgtm` |
| Topology | StatefulSet, 2 replicas, hard anti-affinity, `/prometheus` route-prefix |

## Provenance and apply

```bash
kustomize build --enable-helm kubernetes/lgtm/prometheus | kubectl apply -f -
```

The pin (`29.14.0`) is exact and does not float. Namespace is `lgtm` (decision
D001); the OTel Collector remote-writes to
`http://prometheus-server.lgtm.svc.cluster.local/prometheus/api/v1/write`.

## The `/prometheus` route-prefix gotcha (read before you debug a 404)

Prometheus is served under `/prometheus`, not `/`. Three settings must agree or the
UI and every Grafana panel 404s:

- `server.prefixURL: /prometheus` — rewrites generated asset/link paths.
- `server.routePrefix: /prometheus` — serves the API and UI under the prefix.
- `server.baseURL: /prometheus` — external base for generated absolute URLs.

The fallout if any is missing:

- **Readiness/liveness probes** must hit `/prometheus/-/ready`, not `/-/ready`
  (`server.probePath`), or the pod never goes Ready.
- **The self-scrape job** must use `metrics_path: /prometheus/metrics`, not
  `/metrics`, or Prometheus cannot scrape itself (it 404s its own target). This is
  set in `serverFiles.prometheus.yml`.
- **Grafana's Prometheus datasource URL** must include the prefix
  (`http://prometheus-server.lgtm.svc.cluster.local/prometheus`).

## The documented no-dedup 2-replica exception

`server.statefulSet.enabled: true` with `replicaCount: 2` and
`podAntiAffinity: hard` gives two replicas on different nodes, each on its own
`local-path` PVC. This is **HA by redundant independent scrapers**: both replicas
scrape everything, so losing one node leaves a fully functional Prometheus going
forward.

The accepted limitation: **no cross-replica deduplication.** Thanos and Mimir are
out of scope, so the two replicas hold independent (not merged) time series, and a
query lands on whichever replica the Service routes to. Likewise, remote-write
intake (OTel Collector + Tempo metrics-generator) lands on one replica per write,
so generated/remote-written series populate one replica at a time. These are
operational metadata, not the platform's source of truth — the limitation is
documented rather than worked around. This is the only Prometheus HA exception.

## Flags and scrape config

`extraFlags`:

- `web.enable-lifecycle` — config reload via `POST /prometheus/-/reload`.
- `web.enable-remote-write-receiver` — **required**; the OTel Collector's
  `prometheusremotewrite` exporter and Tempo's metrics-generator push here.
- `log.format=json`.

`retention: 7d`. Alertmanager and pushgateway are disabled; node-exporter and
kube-state-metrics are enabled.

`extraScrapeConfigs` discovers `prometheus.io/scrape`-annotated pods plus explicit
jobs for the platform exporters: Cilium agent (`:9962`), Hubble relay (`:9966`),
ClickHouse (`:9363`), CNPG (`:9187`), SeaweedFS (`:9327`), and LiteLLM
(`:4000` at `/metrics/`).

## Access (port-forward only)

```bash
kubectl -n lgtm port-forward svc/prometheus-server 9090:80
# UI: http://127.0.0.1:9090/prometheus
```
