# Configuration

This page lists the configuration knobs an operator is expected to change. It is a
companion to the task-level workflow in [`developer-workflows.md`](developer-workflows.md)
and the secret model in [`secrets.md`](secrets.md).

## Configuration Precedence

Use the narrowest layer that fits the change:

| Layer | File or source | Purpose | Committed |
| --- | --- | --- | --- |
| Defaults | `.config/mise/conf.d/10-env.toml` | Non-secret lab defaults | Yes |
| Local overrides | `.config/mise/conf.d/99-local.toml` | Per-host IPs and cache address | No |
| Secrets (template) | `fnox.toml` (repo root) | fnox key declarations, marker values only | Yes |
| Secrets (ciphertext) | `fnox.local.toml` (repo root) | fnox + age ciphertext; merged over the template | No |
| Plaintext input | `secrets/shared.env` | Temporary sealing input | No |
| Runtime kubeconfig | `.local/kube/config` | Host kubeconfig written by Lima tasks | No |
| Host service config | `setup/mac-side/*` | launchd, llama-swap, OTel collector | Yes |

Do not put secret values in mise env files, manifests, docs, or task logs. Secret values
belong in fnox + age and are materialized at runtime.

## First-Run Flow

The intended first-run path is:

```bash
mise run init
mise run secrets:check
mise run up
mise run smoke
```

`secrets:check` is cluster-free and validates the required fnox key names before the
expensive host/Lima/Kubernetes work starts. `k8s:apply` still runs `secrets:sync` as the
authoritative Kubernetes Secret materializer.

## Network And VIPs

Defaults live in `.config/mise/conf.d/10-env.toml`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `AI_INFRA_LIMA_NETWORK` | `shared` | Lima network name. |
| `AI_INFRA_SHARED_SUBNET` | `192.168.105.0/24` | socket_vmnet shared subnet. |
| `AI_INFRA_CP_VIP` | `192.168.105.40` | kube-vip API endpoint. |
| `AI_INFRA_LB_RANGE_START` | `192.168.105.200` | Cilium LB-IPAM pool start. |
| `AI_INFRA_LB_RANGE_STOP` | `192.168.105.250` | Cilium LB-IPAM pool stop. |
| `AI_INFRA_LITELLM_VIP` | `192.168.105.200` | LiteLLM service VIP. |
| `AI_INFRA_LANGFUSE_VIP` | `192.168.105.201` | Langfuse web service VIP. |
| `AI_INFRA_GRAFANA_VIP` | `192.168.105.202` | Grafana service VIP. |
| `AI_INFRA_OTEL_VIP` | `192.168.105.203` | OTel Collector service VIP. |
| `AI_INFRA_HUBBLE_VIP` | `192.168.105.204` | Hubble UI service VIP. |

If you change the network plan, re-run `mise run init` or edit the gitignored
`.config/mise/conf.d/99-local.toml`. Then use `mise run lima:recreate`, not just
`lima:start`, because existing Lima instances keep their rendered template.

The VIPs are private-L2 addresses on the local Lima network. They are not public ingress.
Port-forward tasks (`port-forward:*`) remain available as loopback fallback, but they do not prove
HA behavior because a port-forward is tied to one live connection path.

## Kubernetes Security Guardrails

Namespace-level controls live in `kubernetes/namespaces`:

- Pod Security Admission labels are pinned to the kubeadm v1.36 policy version.
  App/data/operator namespaces enforce `baseline`; `lgtm`, `spegel`, and
  `local-path-storage` stay `privileged` where hostPath or node/storage behavior
  makes stricter enforcement unsafe without a live audit.
- ResourceQuota and LimitRange objects are lab guardrails for pod count, PVC
  count/storage, request budget, and LoadBalancer count in `litellm`, `langfuse`,
  `langfuse-data`, and `lgtm`. They are not production capacity plans.
- NetworkPolicy is not installed yet. Treat default-deny plus explicit Cilium
  allowlists as production upgrade work because it must be live-validated against
  service VIPs, kube-dns, app-to-data paths, and LGTM scraping/OTLP fan-out.
- CNPG and ClickHouse backup/restore are documented drills, not proven current
  guarantees. See [`ha-and-reliability.md`](ha-and-reliability.md) before making
  durability claims beyond the lab HA/re-clone behavior.

## Service Ports

Loopback fallback ports:

| Variable | Default | Fallback task |
| --- | --- | --- |
| `LITELLM_PORT` | `34000` | `mise run port-forward:litellm` |
| `LANGFUSE_PORT` | `33000` | `mise run port-forward:langfuse` |
| `GRAFANA_PORT` | `33001` | `mise run port-forward:grafana` |
| `OTEL_HTTP_PORT` | `34318` | `mise run port-forward:otel` |

Primary access should use the service VIP table in [`README.md`](../README.md).

## Registry Cache

The long-lived `ai-registry` Lima VM is separate from the `ai-inf-platform-*` cluster nodes.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AI_INFRA_REGISTRY_ADDR` | `192.168.105.50:5000` | Docker Hub pull-through cache address used by containerd/Spegel. |

`mise run cache:up` discovers the cache VM's DHCP address and writes the value to
`.config/mise/conf.d/99-local.toml`. Optional Docker Hub credentials may be read from
the gitignored `secrets/shared.env`; they are not sealed into fnox and are not Kubernetes
Secrets.

## Secrets

Required platform secret names are documented in [`secrets.md`](secrets.md). The short
operational version:

```bash
mise run secrets:keygen
mise run secrets:generate
mise run secrets:seal
mise run secrets:check
```

Important rules:

- `LANGFUSE_SALT` and `LANGFUSE_ENCRYPTION_KEY` are write-once after first boot.
- `GRAFANA_ADMIN_USER` defaults to `admin` and is non-secret.
- `CODEX_LITELLM_VIRTUAL_KEY`, `CLAUDE_CODE_LITELLM_VIRTUAL_KEY`, and
  `SMOKE_TEST_LITELLM_VIRTUAL_KEY` are client virtual keys, not model provider keys.
- Do not commit `secrets/shared.env`, `secrets/shared.env.dec`, age private keys, or raw
  telemetry captures.

## Host Model Configuration

The default chat alias is:

```text
mac-local/unsloth/qwen3.5-4b-mtp-ud-q8-k-xl-gguf
```

The local model file path is host-specific and must not be committed. Set it through the
host-service environment, for example `AI_INFRA_DEFAULT_CHAT_MODEL_PATH`, before expecting
the default local LiteLLM route to complete a chat request. `host:smoke` checks that the
alias is present; a real route smoke also needs the model artifact to exist.

Run `mise run models:check` before `litellm:smoke` to verify both the default alias and
the local GGUF path. The check first uses `AI_INFRA_DEFAULT_CHAT_MODEL_PATH`; if that is
unset, it reads the installed `com.ai-infra.llama-swap` launchd host-service environment.
If llama-swap runs under launchd, keep that launchd environment in sync with any task-env
override so the preflight and the running backend point at the same file.
There is intentionally no `models:fetch` task yet: the repo has a local path convention,
but no repo-owned download URL, expected size, or checksum convention for the default GGUF.
Place a manually obtained model at the configured path, then rerun `models:check`.

## Useful Runtime Flags

| Variable | Default | Effect |
| --- | --- | --- |
| `AI_INFRA_SKIP_SECRETS` | unset | If `1`, skips `secrets:check` in `up` and `secrets:sync` in `k8s:apply`. Use only when Secrets already exist. |
| `STRICT_VIP` | `0` | Makes service VIP reachability hard-fail in `k8s:health`. |
| `CILIUM_FULL_CONNECTIVITY` | unset | If `1`, runs the heavier Cilium connectivity test. |
| `AI_INFRA_ALLOW_DESTRUCTIVE` | unset | Required for destructive HA smoke tasks. |

## Safe Editing Rules

- Edit committed defaults only when the new value is safe for every checkout.
- Put per-host values in `.config/mise/conf.d/99-local.toml`.
- Put sensitive values in fnox + age, never in `.config/mise/conf.d/*.toml`.
- After changing network/VIP defaults, run `mise run validate:yaml`,
  `mise run validate:helm-kustomize`, `mise run lima:smoke`, and `mise run k8s:health`.
- After changing secrets or launchers, run `mise run secrets:check`, `mise run up`, and
  the relevant component smoke.
