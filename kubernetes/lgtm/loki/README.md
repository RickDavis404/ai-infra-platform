# Loki (lgtm)

Logs store for the LGTM observability plane. Namespace `lgtm`.

## Chart provenance

| Field | Value |
|---|---|
| Chart | `loki` |
| Repo | `https://grafana-community.github.io/helm-charts` |
| Version (pinned) | `18.3.0` |
| Release name | `loki` |
| Namespace | `lgtm` |

The chart migrated from `grafana/helm-charts` to `grafana-community` (2026-03-16);
v7 pulls it only from the migrated repo. Rendered with
`kustomize build --enable-helm kubernetes/lgtm/loki`.

## Deployment mode — SimpleScalable

`deploymentMode: SimpleScalable` with `write.replicas: 2`, `read.replicas: 2`,
`backend.replicas: 2`, and `commonConfig.replication_factor: 2`. All other modes
(`singleBinary`, the distributed targets) are zeroed — the chart errors if two
deployment modes are non-zero. Each target has pod anti-affinity on
`kubernetes.io/hostname`, so one node loss removes at most one pod per target while
the writer ring (RF 2) and SeaweedFS replication keep data available. Requests
`100m / 256Mi`, limit `1Gi` per pod.

> SimpleScalable is deprecated upstream (removal targeted before Loki 4.0). v7 uses
> it as the pragmatic 3-node local-HA sweet spot; Distributed-on-S3 is the forward
> migration path.

## Object storage — SeaweedFS S3

`storage.type: s3` pointed at the embedded SeaweedFS S3 gateway on the filer:
`http://langfuse-seaweedfs-s3.langfuse-data.svc.cluster.local:8333` (the filer
`:8333`, not the master `:9333`). `s3ForcePathStyle: true` is **required** for
SeaweedFS path-style addressing; `region: us-east-1` is cosmetic (SeaweedFS ignores
it). Schema is `tsdb` / `v13`. The bundled MinIO is disabled (`minio.enabled:
false`).

**Dedicated Loki buckets** (not the `langfuse-*` buckets) keep log objects isolated
from app data:

| Purpose | Bucket |
|---|---|
| Chunks | `loki-chunks` |
| Ruler | `loki-ruler` |
| Admin | `loki-admin` |

These buckets must exist on SeaweedFS (added to the filer `createBuckets` list, or
created out-of-band). If the SeaweedFS scope only provisions the three `langfuse-*`
buckets, add `loki-chunks` / `loki-ruler` / `loki-admin` there.

## Credentials (no committed literals)

Config uses `${SEAWEEDFS_S3_ACCESS_KEY}` / `${SEAWEEDFS_S3_SECRET_KEY}`, resolved at
runtime via `-config.expand-env=true` (`global.extraArgs`). The values come from the
**`loki-s3-creds`** Secret (ns `lgtm`, keys `SEAWEEDFS_S3_ACCESS_KEY` /
`SEAWEEDFS_S3_SECRET_KEY`), injected into every pod with `global.extraEnvFrom`
(`secretRef`). The lead mirrors the SeaweedFS embedded-S3 creds from `langfuse-data`
into this `lgtm` Secret.

## Single-tenant + 64 MiB ceilings + 7-day retention

- `auth_enabled: false` (single-tenant lab).
- `allow_structured_metadata: true` (session/conversation id as structured
  metadata).
- 64 MiB pipeline ceilings: `max_line_size: 64MB` (`max_line_size_truncate: false`),
  `grpc_server_max_recv_msg_size` / `grpc_server_max_send_msg_size: 67108864`,
  `ingestion_rate_mb: 32`, `ingestion_burst_size_mb: 64`.
- Retention: `limits_config.retention_period: 168h` (7d) **plus**
  `compactor.retention_enabled: true` so retention actually deletes. The `backend`
  target runs the compactor (`delete_request_store: s3`).

## OTLP ingest

The OTel Collector ships logs to `http://loki.lgtm.svc.cluster.local:3100/otlp`.
Grafana queries Loki at `http://loki.lgtm.svc.cluster.local:3100` (datasource UID
`P8E80F9AEF21F6940`, `maxLines: 1000`).
