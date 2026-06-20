# SeaweedFS — S3 blob store for Langfuse

SeaweedFS provides the S3-compatible blob store for Langfuse **event uploads**,
**batch exports**, and **media** (spec §12.5). It is the most genuinely HA-ready
store in the data plane and the biggest HA win from moving to three real nodes.

## Chart provenance and pin

| Field        | Value                                            |
|--------------|--------------------------------------------------|
| Chart        | `seaweedfs`                                      |
| Repo         | `https://seaweedfs.github.io/seaweedfs/helm`     |
| Version      | **`4.37`** (pinned; resolves to `4.37.0`)        |
| Release name | `langfuse-seaweedfs`                             |
| Namespace    | `langfuse-data`                                  |
| Values       | `values.yaml`                                    |
| Image        | `chrislusf/seaweedfs:4.37` (multi-arch arm64+amd64) |

The chart cadence is **very fast** (multiple bumps per week), so the pin must not
float — re-verify on any bump. No Bitnami footprint.

Render with the `--enable-helm` flag:

```bash
kustomize build --enable-helm kubernetes/langfuse-data/seaweedfs | kubectl apply -f -
```

## HA topology

| Component | Replicas | Role | Notes |
|-----------|----------|------|-------|
| master    | 3        | Raft-quorum topology ensemble | odd quorum; tolerates one loss (2 is invalid for Raft) |
| volume    | 3        | data pods | **spread across the three nodes** (see below) |
| filer     | 2        | metadata + embedded S3 gateway | S3 endpoint redundancy |

### Volume spreading — the key HA decision

`volume.replicas: 3`, and the chart's **default** volume affinity is already
**required pod anti-affinity on `kubernetes.io/hostname`**. We deliberately do **not**
override it. The upstream/authoritative single-node `null` affinity patch (which
collapsed the three volume pods onto one node) is **DROPPED and never reintroduced**,
so the three volume pods spread across the three k3s nodes for true node-level
redundancy. This is the single biggest HA improvement of the three-node move.

### Replication "001" — server-aware becomes node-aware

`global.seaweedfs.enableReplication: true` with `replicationPlacement: "001"` (and
per-component `defaultReplication` / `defaultReplicaPlacement: "001"`). Policy "001"
keeps **2 copies per chunk**, the replica on a **different volume server**. SeaweedFS
replication is server-aware, not node-aware — but once the volume pods are spread
across nodes by the anti-affinity above, "different server" coincides with "different
node", so a whole-node failure still leaves a full copy.

### Filer metadata caveat

Two filers behind a Service give the **S3 endpoint** redundancy, but real filer
**metadata** HA depends on the filer's metadata-store backend; the embedded default is
a soft SPOF for metadata. This is documented honestly rather than overclaimed.

## S3 gateway and buckets

`filer.s3.enabled: true` on port **8333** (the embedded S3 on the filer replaces the
standalone gateway), `enableAuth: true`. The standalone `s3`, `sftp`, `admin`,
`worker`, `allInOne`, and `cosi` components stay `enabled: false`.

Three buckets are auto-created to match the Langfuse env wiring (§12.1):
`langfuse-events`, `langfuse-batch-exports`, `langfuse-media`. (If Barman PITR is
enabled per §12.2, add a fourth backup bucket.)

## S3 credentials — `patches/s3-secret.yaml`

`filer.s3.existingConfigSecret: langfuse-seaweedfs-s3-secret` points the filer at a
deterministic credentials Secret. Setting this knob **suppresses the chart's own
pre-install hook** (its `*-s3-secret` template is guarded by
`(not .Values.filer.s3.existingConfigSecret)`), so `patches/s3-secret.yaml`
**supplies** that Secret instead — it is referenced from `kustomization.yaml` under
`resources:`. The filer mounts the Secret's `seaweedfs_s3_config` key at
`/etc/sw/seaweedfs_s3_config`.

The committed file carries **placeholders only** (`CHANGEME-*`, generic identity name
`langfuse-admin`). At apply time the **fnox+age secrets pipeline** (§11.3.3) overwrites
the Secret from the gitignored runtime `.dec`, sourcing `SEAWEEDFS_S3_ACCESS_KEY` /
`SEAWEEDFS_S3_SECRET_KEY`. These same keys feed Langfuse's `s3-access-key-id` /
`s3-secret-access-key` and the Loki/Tempo S3 config in the `lgtm` plane, so all three
stay in lockstep. The older copy-creds sync Job (`seaweedfs-s3-sync-job.yaml`) is
**superseded and dropped** — it drifted on every apply and carried a forbidden kubectl
image; it must not be reintroduced.

## Security

`global.enableSecurity: false` (no inter-pod mTLS) is acceptable for the
localhost-only lab inside the Cilium boundary; the S3 gateway still enforces its own
access-key auth.

## Metrics

Each of master / filer / volume exposes Prometheus metrics on **:9327**. The chart's
`global.podAnnotations` is ignored, so scrape annotations
(`prometheus.io/scrape: "true"`, `prometheus.io/port: "9327"`) are set **per
component** in `values.yaml`.

## Resources / storage (spec §6.2 HA table)

| Component | requests          | limits    | storage (local-path) |
|-----------|-------------------|-----------|----------------------|
| master    | cpu 100m, mem 256Mi | mem 512Mi | 2Gi                  |
| filer     | cpu 100m, mem 256Mi | mem 1Gi   | 5Gi                  |
| volume    | cpu 100m, mem 256Mi | mem 1Gi   | 10Gi ×3 (~15Gi usable under "001") |

Raise volume to 20Gi if media uploads grow.

## Out of scope / external access

No Ingress, no LoadBalancer, no externally-routed Service. The S3 endpoint is reached
in-cluster (`langfuse-seaweedfs-filer.langfuse-data.svc.cluster.local:8333`) or, for
debugging, via `kubectl port-forward` to `127.0.0.1`.
