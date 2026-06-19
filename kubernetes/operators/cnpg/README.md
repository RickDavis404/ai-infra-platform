# CloudNativePG operator (`cnpg-system`)

CloudNativePG (CNPG) is the Postgres operator that reconciles the two transactional
clusters in this platform:

- `langfuse-pg` in `langfuse-data` — Langfuse metadata store.
- `litellm-pg` in `litellm` — LiteLLM gateway state.

A single operator instance watches **all namespaces** (the chart default), so one
deployment reconciles both clusters. The cluster CRs themselves live under
`kubernetes/langfuse-data/cnpg/`.

## Chart provenance & pin

| Field        | Value                                        |
|--------------|----------------------------------------------|
| Chart        | `cloudnative-pg`                             |
| Repo         | `https://cloudnative-pg.github.io/charts`    |
| Version      | `0.29.0` (Postgres 18 line)                 |
| Release name | `cnpg`                                        |
| Namespace    | `cnpg-system`                                |
| CRDs         | installed via `includeCRDs: true`            |

The chart is inlined through kustomize `helmCharts:` and rendered with
`kustomize build --enable-helm`.

## Configuration notes

- `WATCH_NAMESPACE: ""` keeps the operator cluster-wide so it can manage clusters in
  both `langfuse-data` and `litellm`.
- Operator self-metrics stay off (`monitoring.podMonitorEnabled: false`). Per-cluster
  Postgres metrics are exposed by each `Cluster` via pod annotations on port `9187`
  (`/metrics`), scraped by Prometheus.
- CRD lifecycle is owned by kustomize (`includeCRDs: true` + `crds.create: false` in
  values), avoiding a competing chart hook.

## Apply

The operator and its CRDs must be Ready before any `Cluster` CR is applied
(operators-before-custom-resources):

```bash
kubectl create namespace cnpg-system --dry-run=client -o yaml | kubectl apply -f -
kustomize build --enable-helm kubernetes/operators/cnpg | kubectl apply -f -
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg
# Then apply the cluster CRs:
kubectl apply -k kubernetes/langfuse-data/cnpg
```
