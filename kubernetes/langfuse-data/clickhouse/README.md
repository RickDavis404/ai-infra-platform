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
  are small (requests `cpu: 25m, memory: 128Mi`, limit `memory: 512Mi`), each
  with its own 2Gi `local-path` volume, spread across hosts by required
  anti-affinity on `kubernetes.io/hostname`.
- **CHI cluster `default`:** `shardsCount: 1`, `replicasCount: 1` — a single
  ClickHouse replica (20Gi `local-path` PVC), still coordinated by the Keeper so
  Langfuse's `ReplicatedMergeTree` DDL works. Single-replica because two-replica HA
  on one physical host is theatrical, and a 2nd replica makes the Altinity operator
  block the CHI on new-replica catch-up — which hangs forever if a replica
  resurrects stale on-disk data against a fresh Keeper (readonly tables, unbounded
  `absolute_delay`; the 2026-07-06 from-bare stall). The cluster **must** still be
  named `default`: Langfuse hard-codes `ON CLUSTER default` for its schema
  migrations (see the comment in `chi.yaml`), so any other name breaks migrations.

ClickHouse itself is therefore a single point of failure (one replica); the Keeper
quorum (3 nodes) still tolerates one node loss. This is a deliberate local-lab
posture — the whole platform runs on one physical host, so ClickHouse HA across VMs
bought nothing but the operator new-replica-wait fragility described above. The
Keeper is kept (not dropped) so Langfuse's `Replicated*` DDL and `ON CLUSTER
default` apply unchanged, leaving a clean path back to multi-replica if this ever
runs on real multi-host hardware.

## Image & resources

- Image `clickhouse/clickhouse-server:26.3.17.56` (26.3 LTS, arm64 multi-arch), `TZ=UTC`.
  The tag is an **exact 4-part version** pinned by `@sha256`; patch bumps within the
  26.3 LTS line are a manual tag + digest re-pin (edit the tag and `@sha256` in
  `chi.yaml`/`keeper.yaml`), never automatic.
- CH pod requests `cpu: 50m, memory: 512Mi`; limit `memory: 8Gi` (a constrained
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
