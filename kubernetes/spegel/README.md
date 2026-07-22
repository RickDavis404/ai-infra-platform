# Spegel — peer-to-peer OCI registry mirror

[Spegel](https://github.com/spegel-org/spegel) runs as a DaemonSet on every node of
the three-node HA **kubeadm** cluster (`ai-inf-platform-0/1/2`) and turns each node's
containerd content store into a peer-shared OCI mirror. Once any node has pulled an
image, the other nodes pull its layers from that peer over the cluster pod network
instead of re-hitting docker.io. The goal: a single cold cluster build does **~one
docker.io pull per image cluster-wide**, with the persistent pull-through cache VM as
the next fallback.

This requires two containerd preconditions that the Lima `k8s-cilium` template already
sets (step 2):

- `registry.config_path = /etc/containerd/certs.d` — the per-registry `hosts.toml`
  mirror dir Spegel writes into.
- `discard_unpacked_layers = false` — keeps the compressed layer blobs in the content
  store so they can be served to peers (the containerd default `true` discards them
  after unpack and breaks peer mirroring).

## Chart provenance and pin

| Field        | Value                                     |
|--------------|-------------------------------------------|
| Chart        | `spegel`                                  |
| Repo         | `oci://ghcr.io/spegel-org/helm-charts`    |
| Version      | **`0.7.4`** (pinned; appVersion `v0.7.4`) |
| Release name | `spegel`                                  |
| Namespace    | `spegel`                                  |
| Values       | `values.yaml`                             |
| CRDs         | `includeCRDs: true`                       |

The chart is an **OCI artifact** (not a classic HTTP repo). The version is pinned
exactly in `kustomization.yaml` and enforced by `validate:helm-kustomize` (which
rejects any unpinned/floating version); it does **not** float. Re-verify the values
schema on any bump.

## Render and apply

This base inlines the Helm chart via `helmCharts:` and must be rendered with
`--enable-helm`:

```bash
kustomize build --enable-helm kubernetes/spegel | kubectl apply --server-side -f -
```

The repo wraps this (idempotent render + namespace create + apply + DaemonSet
rollout wait) in the **`k8s:spegel`** mise task, which `lima:start` invokes **after**
Cilium (Spegel needs pod networking) and **before** the app stack is applied (Spegel
must be up before the heavy app images are pulled).

## Containerd config path (matches the template)

`spegel.containerdRegistryConfigPath: /etc/containerd/certs.d` matches
`lima/templates/k8s-cilium.yaml` step 2 exactly, so Spegel's generated `hosts.toml`
entries land in the same dir containerd already reads. `spegel.containerdMirrorAdd:
true` lets Spegel manage that config on each node.

## Cache fallback — additionalMirrorTargets + prependExisting

The template already wrote `/etc/containerd/certs.d/docker.io/hosts.toml` pointing at
the persistent pull-through cache (`[host."http://<registryAddr>"]`, plain HTTP,
`skip_verify`). Spegel layers on top of that:

- **`spegel.prependExisting: true`** — Spegel PREPENDS its peer-mirror `[host]` entry
  ABOVE the pre-existing cache entry instead of overwriting the file. Per-pull
  resolution order becomes: **Spegel peers → persistent cache → docker.io** (the
  upstream `server`).
- **`spegel.additionalMirrorTargets: ["http://<registryAddr>"]`** — additionally
  appends the cache as a mirror target for EVERY registry Spegel manages (not just
  docker.io), so ghcr.io / registry.k8s.io / quay.io pulls also fall through to the
  cache after peers. Belt-and-suspenders with `prependExisting`.

### registryAddr substitution (committed default + sed at apply)

The committed `values.yaml` carries the **default** cache address
`http://192.168.105.50:5000` (matching `conf.d/10-env.toml`'s `AI_INFRA_REGISTRY_ADDR`
default and the template's `registryAddr` param default) so this dir renders
standalone with `kustomize build --enable-helm`. At apply time `k8s:spegel` copies the
dir to a temp render dir and `sed`s the default to `${AI_INFRA_REGISTRY_ADDR}` — the
cache VM's DISCOVERED DHCP IP that `cache:up` wrote into the gitignored
`conf.d/99-local.toml`. This is the same env-driven-default + sed-override mechanism
`k8s:cilium` uses for the VIP. A no-op when the env equals the default.

## Scheduling — all nodes are control-plane

All three nodes are control-plane. The chart's default `tolerations`
(`CriticalAddonsOnly` + `NoExecute`/`NoSchedule` Exists), pinned explicitly in
`values.yaml`, let the DaemonSet pod run on every node regardless of taints — so
Spegel covers all 3 nodes even if the control-plane taint is re-applied. (`lima:start`
removes that taint at bring-up anyway.)

## Vendored chart

Like the other Helm charts in this repo, the unpacked chart is pulled under
`kubernetes/spegel/charts/` by `kustomize build --enable-helm` and is **gitignored**
(`kubernetes/**/charts/`). The validation step renders, then prunes the unpacked
charts with `find kubernetes -type d -name charts -prune -exec rm -rf {} +`.
