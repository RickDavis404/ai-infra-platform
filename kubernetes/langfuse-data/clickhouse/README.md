# ClickHouse for Langfuse (`langfuse-ch` + `langfuse-keeper`)

ClickHouse is Langfuse's analytics/event store (traces, observations, scores) and
the heaviest component in the data plane. This base holds the two Altinity custom
resources reconciled by the operator in
[`../../operators/clickhouse-operator/`](../../operators/clickhouse-operator/):

| File          | Kind                            | Name              |
|---------------|---------------------------------|-------------------|
| `keeper.yaml` | `ClickHouseKeeperInstallation`  | `langfuse-keeper` |
| `chi.yaml`    | `ClickHouseInstallation`        | `langfuse-ch`     |

Both live in namespace `langfuse-data`.

## HA topology

Production-like HA requires a coordination ensemble:

- **Keeper (CHK):** `replicasCount: 3` — an odd Raft quorum that tolerates the
  loss of one Keeper (2/3 retains quorum; 2 would be invalid for quorum). Pods
  are small (requests `cpu: 100m, memory: 256Mi`, limit `memory: 512Mi`), each
  with its own 2Gi `local-path` volume, spread across hosts by required
  anti-affinity on `kubernetes.io/hostname`.
- **CHI cluster `default`:** `shardsCount: 1`, `replicasCount: 2` →
  `ReplicatedMergeTree` across two ClickHouse replicas. Durability and
  coordination are delegated to the 3-node Keeper, so two data copies suffice;
  a third would only waste storage. Replicas are anti-affined by hostname, each
  with a 20Gi `local-path` PVC. The cluster **must** be named `default`:
  Langfuse hard-codes `ON CLUSTER default` for its schema migrations (see the
  comment in `chi.yaml`), so any other name lands `schema_migrations` on a single
  localhost replica and breaks migrations.

A node loss costs one ClickHouse replica and (if it co-locates) one Keeper vote —
both tolerated. The surviving replica serves reads/writes while Keeper holds
quorum; when the lost replica returns, `ReplicatedMergeTree` re-syncs missing
parts from its peer via Keeper.

This deliberately reverses the upstream single-node "drop the Keeper"
optimization, because v7 targets HA.

## Image & resources

- Image `clickhouse/clickhouse-server:25.8` (LTS, arm64 multi-arch), `TZ=UTC`.
  The `:25.8` tag is a **floating minor** pinned only by `@sha256`; patch bumps
  within the 25.8 LTS line are a manual digest re-pin (edit the `@sha256` in
  `chi.yaml`/`keeper.yaml`), never automatic.
- CH pod requests `cpu: 500m, memory: 2Gi`; limit `memory: 8Gi` (a constrained
  lab may lower the limit to `4Gi`). ClickHouse is explicitly subject to the
  resource-escalation policy: under sizing pressure, escalate the bump rather
  than quietly degrading. The documented honest fallback is a reduced posture
  (single replica, no Keeper) as a best-effort analytics store with a stated RPO.

## Service naming

Altinity per-host Services follow `chi-<chi>-<cluster>-<shard>-<replica>`. With
CHI `langfuse-ch` and cluster `default`, replica-0 is
`chi-langfuse-ch-default-0-0.langfuse-data.svc.cluster.local`. Langfuse's
`clickhouse.host` targets this host; where the operator version exposes a
load-balanced cluster Service for the CHI, prefer it, with the per-host name as
the documented fallback. Confirm the exact Service name against the pinned
operator version at install time.

## Auth & network

- The `default` user password is read from the `langfuse-shared-passwords`
  Secret, key `clickhouse-password` (fnox+age-managed; this base never authors
  the Secret).
- `default/networks/ip: ["::/0"]` is a deliberate wildcard: langfuse-web /
  worker run in a different namespace and would otherwise be rejected by
  ClickHouse IP pinning. It is acceptable **only** behind the Cilium
  NetworkPolicy that scopes access to this store, which the platform keeps.
- The `clickhouse_operator` user is restricted to the k3s default cluster CIDR
  (`10.42.0.0/16`, tied to `--cluster-cidr` and Cilium bpf-masquerade source
  NAT) plus `::1` and `127.0.0.1`.

## Prometheus

The native `<prometheus>` endpoint is enabled at port `9363` via a
`config.d/prometheus.xml` placed under `spec.configuration.files` (not
`spec.defaults.files`, which the operator rejects). The pod template annotates
scrape/port `9363`/path `/metrics` and names the container port `prometheus`.

## Apply

The CRDs must already be installed (operator base). Apply Keeper first so its
quorum Service exists before the CHI references it:

```sh
kustomize build kubernetes/langfuse-data/clickhouse | kubectl apply --server-side -f -
```

The `langfuse-shared-passwords` Secret must exist in `langfuse-data` before the
CHI reconciles (the lead provisions it from fnox).
