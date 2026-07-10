# LiteLLM gateway (`litellm` namespace)

LiteLLM is the single OpenAI/Anthropic-compatible gateway for the platform. It is
the one front door for every model call: local models on the Mac host, the Claude
Code Max subscription passthrough, and the Codex/ChatGPT passthrough all enter
through `svc/litellm:4000`.

## Why raw manifests, not the Helm chart

This component is authored as **raw Kubernetes manifests** (Deployment + Service +
ConfigMaps + PodDisruptionBudget + provisioning Jobs) rather than the official
LiteLLM Helm chart. The chart bundles its own Postgres and Redis subcharts, which
this platform forbids. Instead:

- Postgres is the dedicated **CloudNativePG** cluster `litellm-pg` in this same
  namespace, reached as `litellm-pg-rw` and consumed via the CNPG-minted
  `litellm-pg-app` Secret (`uri` key) as `DATABASE_URL`.
- The `init` container uses the upstream community Postgres client image
  (`postgres:18-alpine`) to run `pg_isready` before the gateway boots. The
  forbidden legacy-vendor init image from the source is explicitly replaced.

The container image is pinned (by tag **and** sha256 digest in `deployment.yaml`) to
`ghcr.io/berriai/litellm-database:v1.92.0-rc.2` (the `-database` variant bakes in
Prisma/Postgres support for `store_model_in_db`).
Re-verify the digest at deploy time and pin/verify by digest in CI. The PyPI
releases `1.82.7` / `1.82.8` were flagged for a supply-chain incident and MUST be
avoided; the platform consumes LiteLLM only via this vetted container image and
never `pip install`s it at runtime.

## Files

| File | Purpose |
|---|---|
| `kustomization.yaml`    | Gateway base (Deployment, Service, ConfigMaps, PDB). |
| `deployment.yaml`       | 2 replicas, RollingUpdate `maxUnavailable:0`, anti-affinity, probes, init wait-for-postgres. |
| `service.yaml`          | LoadBalancer VIP `192.168.105.200:4000` (Cilium L2, port `http`) + Prometheus scrape annotations. |
| `proxy-config.yaml`     | ConfigMap `litellm-config` → `proxy_config.yaml` (general/litellm settings + model_list). |
| `pylogging-config.yaml` | ConfigMap `litellm-pylogging` → `sitecustomize.py` (§8a structured uvicorn access logs + §8b ChatGPT client-OAuth passthrough patch). |
| `pdb.yaml`              | PodDisruptionBudget `minAvailable: 1`. |
| `keys/`                 | Virtual-key provisioning base (separate apply; see below). |

## Exposure and access

Exposed as a Cilium **LoadBalancer** with a pinned VIP on the Lima shared L2:
`192.168.105.200:4000` (`loadBalancerClass: io.cilium/l2-announcer`, announced by
the `lima-lb-l2` CiliumL2AnnouncementPolicy). The Mac host sits on the same
`192.168.105.0/24` segment, so clients reach the gateway directly at the VIP — no
port-forward needed. There is no Ingress.

```bash
# Primary (HA, no port-forward): reach the LoadBalancer VIP directly —
#   OpenAI/Anthropic API + admin UI at http://192.168.105.200:4000
# Fallback (non-HA, debug): loopback via kubectl port-forward
mise run port-forward:litellm   # binds 127.0.0.1:34000 -> svc/litellm:4000
```

Prometheus scrapes `GET /metrics/` on port 4000 (the trailing slash matters). The
metrics endpoint is unauthenticated by design; it is reachable only on the private
`192.168.105.0/24` L2 (the Mac + the cluster VMs), never the public internet.

## Master key vs virtual keys

Two-level credential model:

- **Master key** (`LITELLM_MASTER_KEY`, from the generated `litellm-app-secrets`
  Secret) is admin-only. It gates `/key/*`, `/team/*`, `/user/*` and the admin UI.
  No client (Codex, Claude Code, smoke-test) is ever configured with it for normal
  traffic — it is used only by the provisioning Jobs and ad-hoc operator admin
  calls.
- **Per-client virtual keys** are minted at runtime by the `keys/` Jobs against the
  running gateway's database (`POST /key/generate`, master-key auth). They are a
  distinct secret class from the `fnox`/`age` set and are NOT produced by kustomize.

Proxy auth uses the DEFAULT `x-litellm-api-key` header. A custom
`litellm_key_header_name` is deliberately NOT set: the litellm-database image tag
pinned in `deployment.yaml` hardcodes `x-litellm-api-key` when deciding which header
authenticated the proxy and then refuses to forward that header, so authenticating
with the default name lets the client's `Authorization` (subscription OAuth) survive
forwarding to the upstream.

No `ANTHROPIC_API_KEY` is set anywhere — not even as an empty literal. A configured
key would force the anthropic provider down the `x-api-key` path and break OAuth
forwarding; the `claude-*` route is subscription/OAuth-only by design.

## Virtual-key provisioning (`keys/`)

Apply the `keys/` base **after** the gateway Deployment is Ready (the Jobs curl the
live gateway):

```bash
kubectl apply -k kubernetes/litellm
kubectl -n litellm rollout status deploy/litellm
kubectl apply -k kubernetes/litellm/keys
```

Order within `keys/` (enforced by initContainers, not kustomize):

1. `team-job.yaml` creates teams `agents` and `service` (`POST /team/new`) and
   writes their IDs into Secret `litellm-team-ids` (keys `agents`, `service`).
2. `key-job-codex`, `key-job-claude-code`, `key-job-smoke-test` each init-wait on
   `litellm-team-ids` + gateway readiness, then mint one virtual key
   (`POST /key/generate`) and write the plaintext into Secret
   `litellm-key-<alias>` (field `key`).

| Alias | Team | Used by | Scope |
|---|---|---|---|
| `claude-code` | `agents`  | Claude Code Max client (proxy auth) | `claude-*` + local routes |
| `codex`       | `agents`  | Codex client (proxy auth)           | `gpt-*` wildcard (with explicit `gpt-5.3-codex` → `gpt-5.3-codex-spark` slug rewrite) + local routes |
| `smoke-test`  | `service` | §15 smoke/validation harness        | local routes only |

The Jobs run under the `litellm-key-provisioner` ServiceAccount, scoped to
`get/create/patch` Secrets in the `litellm` namespace only. Each Job sets
`ttlSecondsAfterFinished: 86400`, `backoffLimit: 5`, `restartPolicy: OnFailure`.
The minting logic is shared in the `litellm-keymint-script` ConfigMap so the
idempotency contract lives in exactly one place.

The host-side clients (Codex, Claude Code) run OUTSIDE the cluster and read their
key from `fnox`/`age` under the matching name
(`CODEX_LITELLM_VIRTUAL_KEY`, `CLAUDE_CODE_LITELLM_VIRTUAL_KEY`,
`SMOKE_TEST_LITELLM_VIRTUAL_KEY`). On every (re)mint the operator re-encrypts the
new plaintext into `fnox` so the cluster Secret and the `fnox` store stay in sync.

## Idempotency contract

The minting Jobs are idempotent via **GET-then-PATCH-or-POST**, NOT skip-if-exists.
Skip-if-exists caused silent drift: when the `LiteLLM_VerificationToken` table is
re-bootstrapped (CNPG re-init, prisma drop) the table is empty while a stale Secret
lingers, and consumers would 401 on next restart. Re-running a Job regenerates a
fresh plaintext and overwrites the Secret; the team Job likewise reuses an existing
team by alias and create-or-patches `litellm-team-ids`.

## Recovery runbook

When keys are out of sync (consumers 401, table wiped, or a forced rotation):

1. Delete the stale virtual keys via the admin API:
   ```bash
   curl -s -X POST http://192.168.105.200:4000/key/delete \
     -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     -H "Content-Type: application/json" \
     -d '{"key_aliases": ["codex", "claude-code", "smoke-test"]}'
   ```
2. Delete the stale Secrets:
   ```bash
   kubectl -n litellm delete secret \
     litellm-key-codex litellm-key-claude-code litellm-key-smoke-test \
     litellm-team-ids --ignore-not-found
   ```
3. Re-apply the provisioning base (re-runs all Jobs):
   ```bash
   kubectl delete -k kubernetes/litellm/keys --ignore-not-found
   kubectl apply  -k kubernetes/litellm/keys
   ```
4. Re-encrypt the freshly minted plaintexts into `fnox`, then rollout-restart the
   host-side consumers so they pick up the new keys.

## Telemetry

- `JSON_LOGS=True` plus `sitecustomize.py` (loaded via `PYTHONPATH`) rewrite the
  uvicorn access log into structured JSON.
- Langfuse success+failure callbacks capture every request and failure;
  `langfuse_session_id_header: X-Claude-Code-Session-Id` cross-links LiteLLM traces
  with Claude Code turn traces in the Langfuse Sessions view.
- OTLP/HTTP traces/metrics/logs are exported to the in-cluster OTel Collector in the
  `lgtm` plane on plain `:4318` with `/v1/{traces,metrics,logs}` paths.

## ChatGPT passthrough (shipped) + examples-only exclusions

The `sitecustomize.py` here ships BOTH responsibilities: the structured-access-log
rewrite (§8a) AND the ChatGPT per-request client-OAuth passthrough monkeypatch (§8b).
The §8b patch IS live in this config (mounted via `pylogging-config.yaml`, loaded on
`PYTHONPATH`): it is experimental and version-coupled to the chatgpt-provider
internals, but wholly best-effort — every import/override is guarded so a future
image bump can never block or crash proxy startup — and default-on (opt out with
`CHATGPT_PASSTHROUGH_PATCH=0`). It makes the `gpt-*` / `gpt-5.3-codex` routes reuse
the Codex-forwarded ChatGPT subscription OAuth (`Authorization: Bearer` +
`chatgpt-account-id`) instead of running a blocking device-flow at model-load, so the
routes load hands-off on a headless cluster. Still excluded from the live
`proxy_config.yaml`: BYOK hosted-provider routes, vector-store registry, the
MCP-servers gateway, and the bake-off virtual-key fan-out.
