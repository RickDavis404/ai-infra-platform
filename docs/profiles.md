# Profiles: lean (default) vs HA

The platform ships two topology profiles, chosen by which `mise run up:*` task you
run. Both bring up the **same full stack** — the LiteLLM gateway, Langfuse tracing,
the LGTM observability stack, and the externalized data plane (CloudNativePG,
ClickHouse, Valkey, SeaweedFS). They differ only in node count, VM sizing, replica
counts, and resource requests.

| | **lean** (default) | **HA** |
|---|---|---|
| Task | `mise run up:lean` (or `mise run up` → prompts) | `mise run up:ha` |
| Topology | **single node** (1 Lima VM) | **3 nodes** (stacked-etcd control plane, quorum 2/3) |
| VM sizing | 1 × **6 vCPU / 12 GiB** | 3 × **3 vCPU / 9 GiB** |
| Host RAM | **16–24 GB** Mac | **32 GB+** Mac |
| Replicas | single-replica everywhere | LiteLLM ×2, CNPG 3-instance + sync repl, ClickHouse ×2 / Keeper ×3, Loki RF 2, Grafana ×2, Valkey primary+2, SeaweedFS master ×3 |
| Requests | low (fit the single node) | realistic per-pod floors (no overcommit) |

## Which to run

- **Not sure / first time — `mise run up`.** A bare `up` runs a **resource
  preflight** (see below): it prints your host's CPU/RAM/disk against each profile's
  requirements, recommends one, and prompts you to choose **lean / HA / abort**. It
  then brings up the profile you pick. (In a non-interactive shell it prints the
  report and defaults to lean.)
- **Modest hardware — `mise run up:lean`.** The explicit lean form — single-node,
  skips the prompt. It fits the full stack (Langfuse included) on one 12 GiB VM. Use
  it on a 16–24 GB Mac.
- **HA / 32 GB+ — `mise run up:ha`.** Brings up the 3-node HA topology (skips the
  prompt) with replicated data stores, PDBs, pod anti-affinity, and a kube-vip
  control-plane VIP that is exercised by the HA smoke drills. Use it on a 32 GB+ Mac
  (e.g. a MacBook Pro). Publish specific single-VM failure claims only with fresh
  `smoke:ha` evidence from the target machine. The `smoke:ha` drills (node-loss,
  pod-loss, data-integrity) only apply here.

## Resource preflight

`mise run preflight:resources` prints a read-only report — your host's cores, RAM
(total / in-use / available), and free disk, versus each profile's requirement
(cluster VM footprint + a Mac-side host-service allowance) — and recommends lean or
HA. A bare `mise run up` runs this same check and then prompts. Requirements come
from the real VM sizing:

| Profile | Cluster VMs | Required (vCPU / RAM / disk) |
|---|---|---|
| lean | 1 × 6 vCPU / 12 GiB / 50 GiB | 6 / ~12.5 GiB / 50 GiB |
| HA | 3 × 3 vCPU / 9 GiB / 50 GiB | 9 / ~28.5 GiB / 150 GiB |

(Plus a transient `ai-registry` cache VM — 2 vCPU / 2 GiB / 40 GiB — during image
pulls.) The RAM gate uses **total host RAM minus a ~3 GiB macOS reserve**, not the
instantaneous "available", because macOS reclaims file cache on demand.

## How the selection works

The tasks set an internal `AI_INFRA_PROFILE` env var (`lean` | `ha`) that every
lifecycle phase reads — the Lima topology/sizing (`lima:start`), the Cilium render,
the smoke checks, and the kustomize overlay selection (`k8s:apply` renders the
`./lean/` overlay by default, or the HA base under `up:ha`). **You never set
`AI_INFRA_PROFILE` by hand** — the `up` / `up:lean` / `up:ha` tasks set it for you.
The `kubernetes/**` base manifests are the HA profile; the lean profile is the
`kubernetes/**/lean/` overlays layered on top.

## Switching profiles

VM sizing and node count are fixed at **instance-create** time, so switching
profiles on an existing cluster requires a **from-bare recreate**, not a
`down` → `up`:

```sh
mise run lima:recreate:ha     # tear down + recreate as 3-node HA
mise run lima:recreate:lean   # tear down + recreate as single-node lean
```

A plain `mise run down` / `up` preserves whatever topology the VMs were created
with.

## Why single-node for lean

On a 16 GB host, a 3-node lean layout paid the control-plane tax three times
(~2 GiB of apiserver + etcd + Cilium + kube-vip duplicated per node) and then lost
the remainder to cross-node bin-packing — the LiteLLM gateway couldn't hold a node
and was evicted under memory pressure. Collapsing lean to **one larger node** pays
the control-plane cost once and gives every pod a single large allocatable pool, so
the full stack (Langfuse included) schedules and the gateway stays up. Two
single-node specifics are handled automatically under lean: the Cilium operator is
scaled to 1 (its required anti-affinity can't place a 2nd replica on one node), and
**Spegel is skipped** (a peer-to-peer image mirror can't bootstrap — or help — with
no peers).

## Related docs

- [`docs/architecture.md`](architecture.md) — full component + networking architecture.
- [`docs/ha-and-reliability.md`](ha-and-reliability.md) — the HA topology + failure drills.
- [`docs/developer-workflows.md`](developer-workflows.md) — the mise task workflows.
