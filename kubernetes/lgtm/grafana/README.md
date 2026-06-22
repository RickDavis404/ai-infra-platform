# Grafana (lgtm)

UI, datasource provisioning, and dashboard provisioning for the LGTM observability
plane. Namespace `lgtm`.

## Chart provenance

| Field | Value |
|---|---|
| Chart | `grafana` |
| Repo | `https://grafana-community.github.io/helm-charts` |
| Version (pinned) | `12.7.1` |
| Release name | `grafana` |
| Namespace | `lgtm` |

The chart migrated from `grafana/helm-charts` to the `grafana-community` repository
(after 2026-01-30); v7 pulls it only from the migrated repo. Rendered with
`kustomize build --enable-helm kubernetes/lgtm/grafana`.

## HA topology

- `replicas: 2`, RollingUpdate, pod anti-affinity on `kubernetes.io/hostname` so the
  two replicas land on different nodes.
- `headlessService: true` — the headless Service backs unified-alerting HA gossip on
  `:9094` (`ha_peers: grafana-headless:9094`, `ha_listen_address` /
  `ha_advertise_address: ${POD_IP}:9094`). `POD_IP` is auto-injected by the chart.
- Requests `100m / 128Mi`, limit `512Mi`.

## Login required — no anonymous access

This REPLACES the upstream/source posture. `auth.anonymous.enabled = false` and
`auth.basic.enabled = true`; the source's anonymous-Admin no-login-boundary and its
plaintext admin password are removed. Admin user is `admin`; the password is injected
from the **`grafana-admin`** Secret (key `admin-password`, fnox+age managed) via
`admin.existingSecret` — never a committed literal. Logs are console JSON
(`[log] mode = console`, `[log.console] format = json`).

`serve_from_sub_path` / `root_url` sub-path serving is intentionally dropped: v7 is
reached at `127.0.0.1:33001` via `kubectl port-forward svc/grafana 33001:3000`, not a
reverse-proxy sub-path.

## The `/prometheus` route-prefix gotcha

The Prometheus datasource URL is
`http://prometheus-server.lgtm.svc.cluster.local/prometheus` — the **`/prometheus`
suffix is mandatory**. The Prometheus server runs with
`--web.route-prefix=/prometheus`, so the entire query API lives under
`/prometheus/api/v1/*`. Omitting the suffix 404s every query and every panel shows
"No data." This is the single most common LGTM misconfiguration.

## Datasources (stable UIDs)

| Datasource | type | URL | UID | default |
|---|---|---|---|---|
| Prometheus | prometheus | `…/prometheus` (route-prefix) | `PBFA97CFB590B2093` | yes |
| Loki | loki | `http://loki.lgtm.svc.cluster.local:3100` | `P8E80F9AEF21F6940` | no |
| Tempo | tempo | `http://tempo.lgtm.svc.cluster.local:3200` | `P214B5B846CF3925F` | no |

UIDs are baked into the sideloaded dashboards (see `../dashboards/`). Tempo
correlations are pre-wired in `jsonData`: `tracesToLogsV2 → Loki`,
`tracesToMetrics`/`serviceMap → Prometheus`, `nodeGraph.enabled: true`,
`httpMethod: GET`. Loki `maxLines: 1000`.

## CNPG-backed database (dependency)

Grafana's database is moved off embedded SQLite onto externalized CloudNativePG
Postgres so dashboards/users/annotations are consistent across the 2 replicas and
survive a node loss:

- `database.type = postgres`, host `grafana-pg-rw.lgtm.svc.cluster.local:5432`,
  db/user `grafana`, `ssl_mode = require`.
- The password is injected as `GF_DATABASE_PASSWORD` from the CNPG-minted
  **`grafana-pg-app`** Secret (key `password`).

**Dependency:** a CNPG `Cluster` named `grafana-pg` in namespace `lgtm` must exist
(its `-rw` Service and the `grafana-pg-app` Secret are the names referenced here).
This is a dedicated Grafana Postgres cluster, distinct from `litellm-pg` /
`langfuse-pg`. It is shipped IN THIS BASE as `grafana-pg.yaml` (added to
`kustomization.yaml` under `resources:`), so `kustomize build --enable-helm
kubernetes/lgtm/grafana` renders both the chart and the `grafana-pg` `Cluster` CR.

`grafana-pg` runs a **deliberately lighter footprint** than the app data-plane DBs:
`instances: 2` (primary + one async standby) and **no `synchronous` block**, versus
the 3-instance quorum-synchronous `langfuse-pg` / `litellm-pg`. Grafana's DB holds
only reconstructible UI state (users, annotations, alert state); dashboards and
datasources are file-provisioned, so quorum-sync durability is not warranted here.

> **OPERATORS BEFORE CRs.** The CloudNativePG operator and its `postgresql.cnpg.io`
> CRDs (`kubernetes/operators/cnpg`) MUST be applied and Ready BEFORE this base, or
> the `grafana-pg` `Cluster` CR has no controller/CRD to reconcile it. Apply order:
> operators → … → `lgtm`. The `grafana-pg-app` Secret (Grafana's DB password) is
> pre-created by `mise run secrets:sync` (username `grafana` + password); CNPG
> adopts it and mints the `uri` key.

The `grafana-pg-app` `password` key is materialized from fnox key
`GRAFANA_PG_PASSWORD` by the secrets pipeline. If the data-plane scope provisions a
Grafana DB under a different name, update the host and secret name here to match.

## Dashboards

Two parallel loaders:

1. **gnetId chart downloads** (`dashboards.default`, pinned revisions) — k8s-views,
   node-exporter, coredns, cilium-*, prometheus-overview, otel-collector, litellm.
2. **ConfigMap sidecar** (`sidecar.dashboards`, label `grafana_dashboard=1`,
   `searchNamespace: lgtm`) — the hand-rolled JSON in `../dashboards/`.

Only the in-scope dashboards above are provisioned. Vector-database boards and the
workstation-VPN boards are out of scope and excluded from both loaders.

## Access

```sh
kubectl -n lgtm port-forward svc/grafana 33001:3000
# browse http://127.0.0.1:33001  (login: admin / <grafana-admin secret>)
```
