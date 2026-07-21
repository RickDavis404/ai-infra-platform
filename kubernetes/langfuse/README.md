# Langfuse (web + worker)

Langfuse v3 observability for the LLM plane, deployed as a split architecture:

- **`langfuse-web`** — Next.js UI + public API / ingestion endpoint (ClusterIP `3000`).
- **`langfuse-worker`** — async queue consumer that drains the Valkey (Redis-protocol)
  queue and writes events into ClickHouse and S3-compatible object storage.

Both deployments come from the official `langfuse/langfuse` chart, inflated through
kustomize `helmCharts:` and rendered with `kustomize build --enable-helm` — never
`helm install`.

## Chart provenance and pin

| Field | Value |
|-------|-------|
| Chart | `langfuse` |
| Repo | `https://langfuse.github.io/langfuse-k8s` |
| Version (pinned exactly) | `1.5.40` |
| appVersion | `3.212.0` |
| releaseName | `langfuse` |
| Namespace | `langfuse` |
| Values | `values.yaml` |

The pin does **not** float. Re-verify the chart's values schema against `1.5.40`
before any bump (the per-deployment affinity, PDB, and externalized-store keys have
moved between minor versions upstream).

## Layout

```
langfuse/
  kustomization.yaml   # helmCharts: pin + namespace + PDB ha patch target
  values.yaml          # §12.1 values: HA, externalized stores, headless bootstrap
  patches/ha.yaml      # JSON-6902: pin PDB minAvailable=1 on web + worker
  README.md
```

## HA topology

- web `replicas: 2`, worker `replicas: 2`.
- A PodDisruptionBudget per component with `minAvailable: 1` (set in `values.yaml`
  and re-asserted by `patches/ha.yaml`) so a node drain or rolling update never
  removes the last replica.
- Required pod anti-affinity on `kubernetes.io/hostname` (set per component under
  `langfuse.web.pod.affinity` / `langfuse.worker.pod.affinity`) spreads each
  component's two replicas onto distinct nodes across the three control-plane nodes.
- App-plane HA is only as strong as the data plane underneath it (CNPG `-rw`
  failover + ClickHouse availability), satisfied by the `langfuse-data` stores.

Resource sizing per replica (requests / limits): `200m`/`512Mi` requests,
`1500m`/`2Gi` limits.

## Service / access

`langfuse.web.service.type` is `ClusterIP` in the chart values, but a kustomize
patch (`patches/lb-service.yaml`) promotes the web Service to a Cilium
**LoadBalancer** pinned to `192.168.105.201:3000` (`loadBalancerClass:
io.cilium/l2-announcer`, announced on `lima0`). The Mac is on the same
`192.168.105.0/24` L2, so the UI is reachable directly at the VIP — no
port-forward. There is **no** chart-native Ingress (`ingress.enabled: false`).

- Primary (HA, no port-forward): browse [`http://192.168.105.201:3000`](http://192.168.105.201:3000) (login required)
- Fallback (non-HA): `mise run port-forward:langfuse` → binds `127.0.0.1:33000`

`nextauth.url` is set to `http://192.168.105.201:3000` (the browser-reachable VIP),
and `AUTH_TRUST_HOST=true` lets next-auth accept the host for session/redirect
validation. If you use the port-forward fallback instead, flip `nextauth.url` to
`http://127.0.0.1:33000` to match.

The native Langfuse MCP endpoint is exposed at
`http://192.168.105.201:3000/api/public/mcp` over streamable HTTP. Codex authenticates
with `Authorization: Basic <base64(public:secret)>`, derived from the existing
Langfuse project API key pair at launch. `LANGFUSE_MCP_ALLOWED_HOSTS` includes the
VIP host/origin so the endpoint accepts the host header used by the direct L2 path.

## Externalized stores

All four bundled data subcharts are **disabled** (`deploy: false`) and Langfuse is
pointed at the HA stores running in the `langfuse-data` namespace:

| Store | Endpoint | Notes |
|-------|----------|-------|
| Postgres (CNPG) | `langfuse-pg-rw.langfuse-data.svc.cluster.local:5432` | `-rw` Service = current primary (HA-aware) |
| ClickHouse (Altinity) | `chi-langfuse-ch-cluster-0-0.langfuse-data.svc.cluster.local` (HTTP `8123`, native `9000`) | `clusterEnabled: true` → ReplicatedMergeTree |
| Valkey (Redis protocol) | `langfuse-valkey-primary.langfuse-data.svc.cluster.local:6379` | queue/cache, DB `0` |
| SeaweedFS S3 | `http://langfuse-seaweedfs-s3.langfuse-data.svc.cluster.local:8333` | filer-embedded S3 on `:8333`, **not** master `:9333`; `forcePathStyle: true` |

S3 buckets: events `langfuse-events`, batch exports `langfuse-batch-exports`,
media `langfuse-media`.

**DATABASE wiring.** Chart `1.5.40` configures Postgres through discrete
`DATABASE_HOST` / `DATABASE_PORT` / `DATABASE_USERNAME` / `DATABASE_PASSWORD` /
`DATABASE_NAME` env (the externalized `postgresql:` block in `values.yaml`), with the
password resolved from the Secret via `existingSecret`. Where a future chart revision
exposes a single `DATABASE_URL`, prefer the CNPG-minted `uri` key
(`secretKeyRef`) so connection-string assembly stays HA-aware; `directUrl` /
`shadowDatabaseUrl` remain fallbacks if the CNPG role lacks `CREATE DATABASE`.

## Credentials

Every credential resolves from a single Secret **`langfuse-app-secrets`** in
namespace `langfuse` (generated from fnox+age via `secretGenerator`,
`disableNameSuffixHash: true` — authored by the secrets lead, not here). Keys
referenced by this component:

| Key | Used for |
|-----|----------|
| `salt` | `SALT` — hashes API keys |
| `encryption-key` | `ENCRYPTION_KEY` — encrypts secret columns |
| `nextauth-secret` | `NEXTAUTH_SECRET` — signs NextAuth/JWT session cookies |
| `postgres-password` | CNPG Postgres password |
| `clickhouse-password` | ClickHouse `default` user password |
| `redis-password` | Valkey password |
| `s3-access-key-id` / `s3-secret-access-key` | SeaweedFS S3 credentials |
| `init-project-public-key` / `init-project-secret-key` | headless project API keys |
| `init-user-password` | headless admin user password |

No Secret manifest and no real values are authored in this subtree.

## Headless bootstrap (login required, no manual first-login)

Langfuse has no anonymous mode. The lab is made turnkey via **headless
initialization**: on first boot, if the named org/project/user/API-keys do not
already exist, they are created from `LANGFUSE_INIT_*` env (set in
`langfuse.additionalEnv`, applied to both web and worker). These take effect only at
startup and only **create** absent resources — they never update existing ones, so
they are idempotent on restart.

- Org and project identifier + display name: `ai-infra-platform`.
- Admin user: `admin@ai-infra-platform.example` (password from the Secret).
- Project public/secret keys come from the Secret so downstream config (the LiteLLM
  Langfuse callback, the agent telemetry env) can reference deterministic keys with
  no manual UI copy step.
- `AUTH_DISABLE_SIGNUP=true` enforces login-required and blocks self-registration
  after the admin is bootstrapped. `AUTH_DISABLE_USERNAME_PASSWORD` is deliberately
  **not** set — that would force SSO and lock the lab out with no SSO provider.
- `LANGFUSE_INIT_PROJECT_RETENTION` is intentionally unset → retain-forever (lab
  default).

**Owner-role caveat (operator check, not a blocker).** The headless-initialized user
may not be marked project OWNER; ingestion keys still work but may not be
rotatable/viewable in the UI. If UI key rotation matters, verify the owner role after
first boot and, if needed, correct it via the Organization Management API.

## SALT / ENCRYPTION_KEY — write-once (HARD CONSTRAINT)

Three security secrets are mandatory and generated with openssl:

- `salt` → `SALT`: `openssl rand -base64 32` (≥256-bit).
- `nextauth-secret` → `NEXTAUTH_SECRET`: `openssl rand -base64 32` (≥256-bit).
- `encryption-key` → `ENCRYPTION_KEY`: `openssl rand -hex 32` — **exactly 64 hex
  chars** (256-bit); a wrong length fails the pod on boot.

**`SALT` and `ENCRYPTION_KEY` must NEVER change after first boot on a live
database.** Rotating `SALT` invalidates every hashed API key; rotating
`ENCRYPTION_KEY` makes encrypted columns undecryptable. Any rotation implies a fresh
database. The fnox+age material for these two keys is generated once and treated as
immutable for the life of the deployment.

## First-boot ordering gate (load-bearing)

`langfuse.clickhouse.migration.autoMigrate: true` means the **worker runs ClickHouse
schema migrations on startup**, and web/worker pods restart a few times while
Postgres and ClickHouse provision. The worker CrashLoops if Postgres and ClickHouse
are not both Ready.

The deployment sequence must therefore gate the Langfuse rollout on the data plane:

1. Apply the CNPG and Altinity operators (Phase A).
2. Apply the four `langfuse-data` store CRs/charts; wait for CNPG `Cluster` Ready,
   CHI Ready, and `kubectl rollout status` on Valkey/SeaweedFS.
3. Only then apply Langfuse (this base).

This restates the phased plan (§16); the worker's migration step is the
load-bearing dependency.

## Apply

```
kustomize build --enable-helm kubernetes/langfuse | kubectl apply -f -
kubectl -n langfuse rollout status deploy/langfuse-web deploy/langfuse-worker
```
