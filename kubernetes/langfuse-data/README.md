# langfuse-data — externalized data plane

The `langfuse-data` namespace holds the **externalized stateful backing stores** for
the application plane (Langfuse and LiteLLM). Pulling these out of the app charts
gives each store its own HA topology, lifecycle, and operator, and lets the apps
treat them as managed dependencies (spec §12).

| Store        | Workload                      | Purpose                                        |
|--------------|-------------------------------|------------------------------------------------|
| CNPG         | `langfuse-pg` (+ `litellm-pg` in ns `litellm`) | Transactional Postgres (HA, 3 instances) |
| ClickHouse   | `langfuse-ch` CHI + 3 Keeper  | Analytical store for Langfuse traces/observations |
| Valkey       | `langfuse-valkey`             | Langfuse BullMQ job queue + ephemeral cache    |
| SeaweedFS    | `langfuse-seaweedfs`          | S3-compatible blob store (events/exports/media) |

Each store is a self-contained Kustomize base (`<store>/kustomization.yaml` +
`values.yaml` + `patches/` + `README.md`) that inlines its pinned Helm chart via
`helmCharts:` (CNPG/ClickHouse use raw operator CRs). See each subdirectory's README
for chart provenance, pins, and per-store HA rationale.

## Apply order

The stores depend on their **operators** being Ready, and have a couple of
intra-plane ordering constraints. Apply in this order (the repo wraps this in
the `k8s:*` mise tasks, e.g. `mise run k8s:apply`):

1. **Operators first** — the CloudNativePG operator (`cnpg-system`) and the Altinity
   ClickHouse operator (`clickhouse-system`) from `kubernetes/operators/` must be
   installed and Ready **before** any CR here is applied, or the `Cluster` / `CHI` /
   `CHK` CRs have no controller to reconcile them.
2. **Namespaces** — `langfuse-data` (and `litellm`, for `litellm-pg`) must exist
   (`kubernetes/namespaces/`).
3. **Secrets** — the fnox+age pipeline (`secrets/`) must have generated the store
   Secrets referenced by name here: `langfuse-shared-passwords`, the CNPG
   `*-app` Secrets, and `langfuse-seaweedfs-s3-secret`. Stores will not become Ready
   without them.
4. **ClickHouse: Keeper before CHI** — apply `clickhouse/keeper.yaml` before
   `clickhouse/chi.yaml` so the Keeper quorum Service exists when the CHI references
   it (the base already orders them).
5. **Stores** — apply the aggregate base:

   ```bash
   kustomize build --enable-helm kubernetes/langfuse-data | kubectl apply -f -
   ```

6. **Wait for Ready** — let CNPG report 3 healthy instances, the ClickHouse CHI/CHK
   reconcile, Valkey form its 1-primary/2-replica set, and SeaweedFS bring up the
   3-master Raft quorum + 3 volume + 2 filer pods **before** deploying the apps that
   connect to them (`kubernetes/litellm`, `kubernetes/langfuse`).

> The top-level `kustomization.yaml` here sets **no** `namespace:` — the `cnpg` base
> spans two namespaces (`langfuse-pg` → `langfuse-data`, `litellm-pg` → `litellm`),
> so each child base owns its own namespace.

## Cross-namespace secret coupling (§12.6.3)

Kubernetes Secrets are not cross-namespace, so the same store passwords appear in
both `langfuse-data` (`langfuse-shared-passwords`, `langfuse-pg-app`,
`langfuse-seaweedfs-s3-secret`) and `langfuse` (`langfuse-app-secrets`). The fnox+age
path (§11) is the **single source of truth** that generates both copies from one
shared `.dec`, so a rotation regenerates both in lockstep. The only credentials that
must **never** be rotated post-boot are the Langfuse `SALT` and `ENCRYPTION_KEY`
(§12.1.2).

## Bootstrap — core needs no Job (§12.6.1)

The core Langfuse bootstrap (a login-required instance with a pre-provisioned
org/project/admin and deterministic API keys) is satisfied **entirely** by the
`LANGFUSE_INIT_*` headless-init env on the Langfuse web/worker (§12.1.1) — no separate
provisioning Job. `AUTH_DISABLE_SIGNUP=true` then makes login required and blocks new
self-registration. The only operator-side step afterward is the manual check of the
headless user's project OWNER role if UI key rotation is needed.

## OPTIONAL overlay — Langfuse ↔ LiteLLM eval wiring (§12.6.2)

> Not authored in core. Documented here so operators know it exists and that it is
> deliberately out of the core data plane.

An **optional** Kustomize overlay named **`langfuse-litellm-eval`** couples Langfuse to
LiteLLM for **evals / dataset experiments / playground**. It is **gated on LiteLLM
being deployed** — if evals are out of scope, the overlay is simply not applied. It is
**not** part of the core app/data plane and its Jobs are intentionally **not** authored
in the core tree. When (and only when) it is used it contributes two Jobs:

- **`litellm-eval-key-gen`** — mints a LiteLLM virtual key scoped to the local model
  routes (`models: ["mac-local/*"]`, with a budget cap) via LiteLLM
  `POST /key/generate`, then stores it as Secret `litellm-langfuse-key`. Idempotent
  (GETs the Secret first, skips if present); waits on LiteLLM `/health/readiness`.
  Needs an SA + Role (secrets get/create/patch) + RoleBinding in the `langfuse`
  namespace. Uses a non-Bitnami `python:3.12-slim` image, `ttlSecondsAfterFinished:
  86400`, `backoffLimit: 5`, `restartPolicy: OnFailure`.
- **`langfuse-llm-conn`** — waits (init container) for `litellm-langfuse-key`, then
  `PUT /api/public/llm-connections` (idempotent upsert on `(projectId, provider)`) to
  register provider `litellm-local`, adapter `openai`, baseURL
  `http://litellm.litellm.svc.cluster.local:4000`. Authenticates with the project
  public/secret keys; waits on Langfuse `/api/public/health`.

Hard requirements when the overlay is used:

- The LiteLLM master key, the Langfuse project public/secret keys, and the minted
  virtual key **must** be sourced from Secrets (fnox+age) — never checked-in literals.
- If the connection registers a `customModels` list it mirrors the LiteLLM
  `mac-local/*` catalog and must be kept in sync by hand (a documented maintenance
  liability). Prefer `withDefaultModels: false` with a minimal, secret-sourced list.
- The whitelist env `LANGFUSE_LLM_CONNECTION_WHITELISTED_HOST` (set to the in-cluster
  LiteLLM cluster-DNS host) is required **only** when this overlay is active — it
  bypasses Langfuse's SSRF guard for the RFC1918 in-cluster LiteLLM baseURL. It is
  **omitted** from the core Langfuse env.

Treat this overlay as eval/playground plumbing, not core observability.
