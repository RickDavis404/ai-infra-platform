# Kubernetes manifests

This directory holds the in-cluster surface of the ai-infra-platform lab: the
operators, CNI, namespaces, data plane, application plane, observability plane,
and ingress, all expressed as Kustomize bases that inline pinned Helm charts via
`helmCharts:`. LiteLLM is the single exception — it is shipped as **raw
manifests** (no chart) to avoid any Bitnami dependency, direct or transitive.

Everything is rendered and applied through `mise` tasks; the commands below are
the underlying primitives those tasks wrap.

## Apply order (hard requirement)

Components have ordering dependencies (operators before the CRs they reconcile,
CNI before workloads, stores before the apps that connect to them). Apply in
this exact order; teardown reverses it.

1. **operators** — CloudNativePG operator (`cnpg-system`) and the Altinity
   ClickHouse operator (`clickhouse-system`). Install CRDs first so later CRs
   reconcile.
2. **cilium** — Cilium CNI + Hubble into `kube-system`, plus the LB-IPAM pool and
   L2-announcement policy. kubeadm runs **kube-proxy-free** (`--skip-phases=addon/kube-proxy`),
   so the cluster has no pod networking AND no service proxy until Cilium is ready
   (`kubeProxyReplacement: true`, `k8sServiceHost` = the kube-vip control-plane VIP).
3. **namespaces** — create `litellm`, `langfuse`, `langfuse-data`, and `lgtm`
   (plus any labels/quota).
4. **langfuse-data** (stores) — the externalized data plane: CNPG Postgres
   clusters (`litellm-pg`, `langfuse-pg`), ClickHouse (`langfuse-ch` + Keeper),
   Valkey (`langfuse-valkey`), and SeaweedFS S3 (`langfuse-seaweedfs`). Wait for
   each store to reach its target replica/quorum count before proceeding.
5. **litellm / langfuse** (application plane) — the LiteLLM gateway (raw
   manifests) and Langfuse web + worker. These consume the store credentials
   (CNPG-minted `uri` secrets, object-store keys) created in the previous step.
6. **lgtm** (observability) — Grafana, Loki, Tempo, Prometheus, the in-cluster
   OpenTelemetry Collector, and the Alloy self-log shipper, in the `lgtm`
   namespace.
7. **ingress** — additive host-access Services for private-L2 VIPs plus the
   loopback port-forward fallback targets; no NodePort or public bind.

The `k8s:apply` task encodes this order; `k8s:diff` previews it as a
server-side dry-run; `k8s:status` reports rollout health.

## Namespace map

| Namespace            | Workloads                                                                                          |
|----------------------|----------------------------------------------------------------------------------------------------|
| `kube-system`        | Cilium + Hubble (CNI, observability)                                                                |
| `cnpg-system`        | CloudNativePG operator                                                                              |
| `clickhouse-system`  | Altinity ClickHouse operator                                                                        |
| `litellm`            | LiteLLM gateway + `litellm-pg` (CNPG Postgres)                                                      |
| `langfuse`           | Langfuse web + Langfuse worker                                                                      |
| `langfuse-data`      | `langfuse-pg` (CNPG), `langfuse-ch` ClickHouse + Keeper, `langfuse-valkey`, `langfuse-seaweedfs` S3 |
| `lgtm`               | Grafana, Loki, Tempo, Prometheus, in-cluster OTel Collector, Alloy                                  |

## Namespace security guardrails

The `kubernetes/namespaces` base installs conservative namespace-level controls:

- **Pod Security Admission** labels enforce `baseline` for the app/data/operator
  namespaces (`litellm`, `langfuse`, `langfuse-data`, `cnpg-system`,
  `clickhouse-system`) and audit/warn `restricted`. `lgtm` enforces
  `privileged` and audit/warn `baseline` because the OTel Collector DaemonSet uses
  hostPath checkpoint storage.
- **ResourceQuota** and **LimitRange** objects cover `litellm`, `langfuse`,
  `langfuse-data`, and `lgtm`. The quotas are lab ceilings for pod count, PVC
  count/storage, request budget, and LoadBalancer count. LimitRanges only default
  low CPU/memory requests; they do not inject runtime limits into chart sidecars.
- **Deferred namespaces:** `kube-system` is pre-existing and hosts Cilium,
  kube-vip, Hubble, and control-plane-adjacent pods; `local-path-storage` and
  `spegel` are managed by their own bases and enforce privileged PSA because they
  are node/storage infrastructure.
- **NetworkPolicy backlog:** no default-deny NetworkPolicy is installed yet.
  A safe policy set needs live validation of Cilium service VIP traffic, kube-dns,
  operator reconciliation, LGTM scraping/OTLP paths, and app-to-data flows. Treat
  default-deny plus explicit Cilium `NetworkPolicy` / `CiliumNetworkPolicy` allows
  as production upgrade work, not a proven current control.

## Rendering a component

Each component is a Kustomize base that inlines its Helm chart. Render any single
component (with CRDs and the inlined chart expanded) using:

```bash
kustomize build --enable-helm kubernetes/<component>
```

For example:

```bash
kustomize build --enable-helm kubernetes/cilium
kustomize build --enable-helm kubernetes/operators
kustomize build --enable-helm kubernetes/langfuse-data
```

`--enable-helm` is required because the bases use the `helmCharts:` field; the
charts are pinned by `name`/`repo`/`version`/`releaseName`/`namespace` and a
`valuesFile`, with `includeCRDs: true` where the operator needs it. Each
component directory carries its own `README.md` documenting chart provenance,
the exact version pin, and apply notes.

## Guard notes

These invariants are enforced by the validation suite (`mise run validate:*`)
and the pre-commit hooks; they apply to every manifest and every rendered chart
in this tree:

- **No Bitnami.** No Bitnami chart or image is permitted, direct or transitive.
  The `validate:no-bitnami` guard greps the **rendered** output
  (`kustomize build --enable-helm`), not the chart cache, so any transitive
  Bitnami image (including the frozen legacy registry) is caught before apply. Langfuse's
  bundled subcharts are all disabled; the data plane is externalized precisely
  to avoid Bitnami.
- **No NodePort / no public ingress.** No NodePort Services, no fixed node-port
  numbers, no host-port bind, and no all-interfaces bind appear in any rendered
  manifest. Primary host access uses Cilium `LoadBalancer` service VIPs on the
  private Lima L2 (`192.168.105.200-.204`); `port-forward:*` tasks remain a loopback
  fallback bound to `127.0.0.1`. UIs require credentials; there is no anonymous
  Grafana.
- **Pinned charts.** Every `helmCharts:` entry pins an exact `version`; floating
  tags or `latest` are rejected by `validate:helm-kustomize`.
- **No inlined secrets.** Secret material is never written into a manifest.
  `secretGenerator.envs` consumes gitignored `.env`/`.dec` files produced by
  `fnox`; CNPG mints the Postgres `uri` secret consumed via `secretKeyRef`.
