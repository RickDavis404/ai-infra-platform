# ClickHouse operator (Altinity)

The [Altinity ClickHouse operator][altinity] reconciles the `ClickHouseInstallation`
(CHI) and `ClickHouseKeeperInstallation` (CHK) custom resources that back
Langfuse's analytics/event store. The custom resources themselves live in
[`../../langfuse-data/clickhouse/`](../../langfuse-data/clickhouse/); this base
installs only the operator.

## Provenance & pin

| Field        | Value                                            |
|--------------|--------------------------------------------------|
| Chart        | `altinity-clickhouse-operator`                   |
| Repo         | `https://helm.altinity.com`                      |
| Version      | `0.27.1` (exact pin; ships ClickHouse 25.8 LTS)  |
| Release name | `clickhouse-operator`                            |
| Namespace    | `clickhouse-system`                              |
| CRDs         | `includeCRDs: true`                              |

The pin does not float. Re-verify the operator/ClickHouse compatibility matrix
and the CRD-hook image tag on any bump.

## Overrides (`values.yaml`)

- **`replicaCount: 1`** — the operator is a control-plane reconciler, not a
  data-path component. A second replica only duplicates watches.

- **Watch all namespaces** (`configs.files.config.yaml.watch.namespaces.include:
  [".*"]`). An Altinity operator that does **not** run in `kube-system` watches
  only its own namespace by default. This operator runs in `clickhouse-system`,
  so without this override it would silently ignore the CHI and CHK in
  `langfuse-data` and nothing would reconcile.

- **Pinned, freely-pullable CRD-hook image.** The chart's CRD install/upgrade
  hook Job defaults to a frozen free-tier kubectl image on a non-reproducible
  `latest` tag. `values.yaml` overrides `crdHook.image` to a pinned
  `rancher/kubectl:v1.33.0` from an open registry. `patches/images.yaml`
  re-applies the same image as a strategic-merge patch on the hook Job so the
  override is guaranteed in the rendered output even if the values block is
  later edited.

## Render & apply

This base is part of the `operators` apply stage, which runs first in the
documented apply order (operators → cilium → namespaces → stores → apps → lgtm →
ingress). The `clickhouse-system` namespace is created by the `namespaces` base;
apply that before the operator if rendering standalone.

```sh
# Render (validates the inlined chart + patch):
kustomize build --enable-helm kubernetes/operators/clickhouse-operator

# Apply:
kustomize build --enable-helm kubernetes/operators/clickhouse-operator \
  | kubectl apply --server-side -f -
```

Once the operator is `Available`, apply the custom resources in
`../../langfuse-data/clickhouse/`.

[altinity]: https://github.com/Altinity/clickhouse-operator
