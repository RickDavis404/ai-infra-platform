# Tempo (lgtm)

Traces store for the LGTM observability plane. Namespace `lgtm`.

## Chart provenance

| Field | Value |
|---|---|
| Chart | `tempo` (single-binary) |
| Repo | `https://grafana-community.github.io/helm-charts` |
| Version (pinned) | `2.2.3` |
| Release name | `tempo` |
| Namespace | `lgtm` |

Rendered with `kustomize build --enable-helm kubernetes/lgtm/tempo`.

## Single-binary — documented HA exception

Tempo runs as the **single-binary** `tempo` chart at **1 replica**. This is a
deliberate, documented HA exception:

- The monolithic Tempo chart is not built for clean multi-replica scaling.
- The HA alternative `tempo-distributed` runs
  distributor/ingester/querier/query-frontend/compactor/metrics-generator as
  separate pods — too many for the fixed 4 CPU / 8 GiB node sizing.

Reliability is provided by storage + reschedule, not zero-downtime read
availability:

1. **Durability via SeaweedFS S3.** Traces live in SeaweedFS S3, so they survive a
   node loss even though the pod does not. On reschedule Tempo re-attaches to the
   same S3 backend (no data loss; RPO 0 for flushed blocks).
2. **WAL replay (~90s).** `readinessProbe.initialDelaySeconds: 90` (and the same on
   liveness) covers the WAL replay window so the pod is not declared Ready — or
   killed by liveness — before replay completes. A too-early Ready would serve 503s.
3. **Graceful drain.** `tempo-lifecycle-patch.yaml` adds `preStop: sleep 5` so
   kube-proxy drops the Endpoint before SIGTERM and in-flight OTLP pushes are not
   dropped against a terminating pod.

RTO is the reschedule + 90s WAL replay window (a brief ingest gap; the OTel
Collector retries/buffers). If the node sizing is bumped, migrating to
`tempo-distributed` (minimal 2× per component) on the same S3 backend is the path to
true HA.

## Object storage — SeaweedFS S3

`storage.trace.backend: s3` pointed at the embedded SeaweedFS S3 gateway on the
filer (`langfuse-seaweedfs-s3.langfuse-data.svc.cluster.local:8333`, `insecure:
true` for plain http, `forcepathstyle: true`). Bucket: **`tempo-traces`** (must
exist on SeaweedFS). Credentials use `${SEAWEEDFS_S3_ACCESS_KEY}` /
`${SEAWEEDFS_S3_SECRET_KEY}`, resolved at runtime via `-config.expand-env=true`
(`tempo.extraArgs`) from the **`tempo-s3-creds`** Secret (ns `lgtm`,
`tempo.extraEnvFrom` secretRef). The lead mirrors the SeaweedFS embedded-S3 creds
into this Secret.

## Metrics generator

Processors `[local-blocks, service-graphs, span-metrics]` are activated in
`overrides.defaults.metrics_generator.processors`. The generated series
(service-graph + RED/span metrics, powering Grafana's service map and the Tempo
`tracesToMetrics` correlation) are remote-written to Prometheus at
`http://prometheus-server.lgtm.svc.cluster.local/prometheus/api/v1/write` — note the
**`/prometheus` route-prefix**; Prometheus enables the remote-write receiver.

## Ceilings and retention

- `overrides.defaults.global.max_bytes_per_trace: 67108864` (64 MiB), matching the
  64 MiB pipeline ceilings elsewhere.
- 7-day retention: `retention: 168h` →
  `compactor.compaction.block_retention: 168h`.

## Ingest / query

The OTel Collector ships traces to `http://tempo.lgtm.svc.cluster.local:4318`
(OTLP/HTTP). Grafana queries Tempo at `http://tempo.lgtm.svc.cluster.local:3200`
(datasource UID `P214B5B846CF3925F`).
