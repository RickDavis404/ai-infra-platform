# LGTM observability plane (`lgtm`)

The Loki / Grafana / Tempo / Prometheus stack plus the OpenTelemetry Collector and a
narrowly-scoped Alloy, all in namespace **`lgtm`** (decision D001 — every datasource
URL, OTel exporter, and cross-namespace DNS hardcodes `*.lgtm.svc.cluster.local`).

> The namespace is `lgtm`, never `observability`.

## Layout

| Base | Chart / kind | Pin | Role |
|---|---|---|---|
| `otel-collector/` | opentelemetry-collector | 0.164.1 | OTLP gateway (DaemonSet) |
| `prometheus/` | prometheus (standalone) | 29.14.0 | metrics (server + node-exporter + kube-state-metrics) |
| `alloy/` | alloy | 1.10.0 | otel-collector self-log shipper (DaemonSet) |
| `grafana/` | grafana | 12.7.2 | UI + datasources + dashboards |
| `loki/` | loki | 18.4.3 | logs (SimpleScalable on SeaweedFS S3) |
| `tempo/` | tempo | 2.2.3 | traces (single-binary on SeaweedFS S3) |
| `dashboards/` | raw ConfigMaps | — | hand-rolled sideloaded dashboards |

Charts come from `https://grafana-community.github.io/helm-charts` (Grafana/Loki/
Tempo, migrated 2025-12), `prometheus-community`, `open-telemetry/...`, and
`grafana/alloy`. All rendered images come from the upstream project registries
(Grafana, OpenTelemetry, prometheus-community) — no repackaged third-party images.

## Build

```sh
kustomize build --enable-helm kubernetes/lgtm | kubectl apply -f -
```

Per-component bases render individually with the same command against each subdir.

## Apply order

LGTM is applied **after** the data plane (the stores it depends on must exist first):

1. operators → cilium → namespaces
2. `langfuse-data` stores — in particular **SeaweedFS** (Loki/Tempo S3 backend) and
   the CNPG operator (Grafana's database)
3. litellm / langfuse
4. **lgtm** (this base)
5. ingress

Within lgtm, the kustomization lists otel-collector and prometheus first
(remote-write receiver targets), then grafana/loki/tempo, then dashboards.

## S3 buckets (SeaweedFS)

Loki and Tempo externalize their object storage to the embedded SeaweedFS S3 gateway
on the filer (`langfuse-seaweedfs-s3.langfuse-data.svc.cluster.local:8333`,
path-style, plain http). Dedicated buckets keep observability data isolated from app
data and must exist on SeaweedFS:

| Component | Buckets |
|---|---|
| Loki | `loki-chunks`, `loki-ruler`, `loki-admin` |
| Tempo | `tempo-traces` |

The SeaweedFS embedded-S3 credentials are mirrored from `langfuse-data` into `lgtm`
as `loki-s3-creds` and `tempo-s3-creds` (keys `SEAWEEDFS_S3_ACCESS_KEY` /
`SEAWEEDFS_S3_SECRET_KEY`); the lead reconciles these.

## Datasource UIDs (stable, baked into dashboards)

| Datasource | URL (in-cluster) | UID | default |
|---|---|---|---|
| Prometheus | `http://prometheus-server.lgtm.svc.cluster.local/prometheus` | `PBFA97CFB590B2093` | yes |
| Loki | `http://loki.lgtm.svc.cluster.local:3100` | `P8E80F9AEF21F6940` | no |
| Tempo | `http://tempo.lgtm.svc.cluster.local:3200` | `P214B5B846CF3925F` | no |

The Prometheus URL **must** include the `/prometheus` route-prefix
(`--web.route-prefix=/prometheus`); omitting it 404s every query. Tempo correlations
(`tracesToLogsV2 → Loki`, `tracesToMetrics`/`serviceMap → Prometheus`,
`nodeGraph`) power the trace → logs → metrics drilldown.

## HA posture

- Grafana 2 replicas (CNPG-backed DB, unified-alerting HA, login required, no anon).
- Loki SimpleScalable read/write/backend 2 each, RF 2, on SeaweedFS S3.
- Tempo single-binary 1 replica — **documented HA exception**; durability via
  SeaweedFS S3 + reschedule (see `tempo/README.md`).
- Prometheus StatefulSet 2 replicas, hard anti-affinity — **documented no-dedup
  exception**.

All components use pod anti-affinity on `kubernetes.io/hostname`, RollingUpdate,
readiness + liveness probes, and `disableNameSuffixHash` (stable Secret/ConfigMap
names for cross-namespace references and dashboard provisioning).

## Retention — uniform 7 days

| Component | Setting | Value |
|---|---|---|
| Loki | `limits_config.retention_period` + compactor `retention_enabled` | 168h |
| Tempo | compactor `compaction.block_retention` | 168h |
| Prometheus | `server.retention` | 7d |

The production 90-day target is out of scope for v7 (fits local PVC/S3 budgets).

## Access

```sh
kubectl -n lgtm port-forward svc/grafana 33001:3000   # http://127.0.0.1:33001 (login required)
```
