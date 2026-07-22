# AGENTS.md — Codex repo instructions

This file is Codex's first-turn repo context. It is walked from the project root down to
the working directory; where no nested `AGENTS.md` exists, Codex falls back to `CLAUDE.md`
(`project_doc_fallback_filenames = ["CLAUDE.md"]` in `.codex/config.toml`). The two
instruction surfaces are deliberately consistent — read `CLAUDE.md` for the full project
guide; this file states the Codex-specific essentials.

## First run: the trust gate

The committed `.codex/config.toml` is **inert until you mark this project trusted.** On an
untrusted project Codex skips all project-scoped `.codex/` layers (config, MCP servers,
rules) and uses only your user/system config. On first launch Codex prompts to trust the
project; approving it records `trust_level = "trusted"` for this path in your **global**
`~/.codex/config.toml` (never in the repo). If you never grant trust, the repo's model
defaults and MCP server definitions silently do not apply.

`CODEX_HOME` stays at its default (`~/.codex`) — the repo does **not** repoint it. The repo ships
project policy via `.codex/config.toml`, and `mise run codex:global-config` merges the telemetry /
trust / `[analytics]` blocks (plus an inert `litellm_local` provider definition) into your real
`~/.codex/config.toml` with a UTC-timestamped backup; your credentials and history stay in your
user home.

## What this repo is

A **local AI infrastructure lab**: a 3-node upstream **kubeadm** control plane on Lima
VMs (`ai-inf-platform-0/1/2`) on one Mac, with stacked etcd, a kube-vip API VIP, Cilium in
kube-proxy-free mode, LiteLLM, Langfuse, and an LGTM observability stack. Coding agents run
through the local LiteLLM gateway and every request/tool turn can be correlated through
Langfuse, Loki, Tempo, Prometheus, and Grafana. There is no public ingress and no NodePort
surface. Namespaces: `litellm`, `langfuse` / `langfuse-data`, `lgtm`,
`cnpg-system`, `clickhouse-system`, `local-path-storage`, `spegel`, plus Cilium,
Hubble, kube-vip, and core control-plane support in `kube-system`.

## Access (private L2 service VIPs + loopback fallback)

Primary host access uses Cilium `LoadBalancer` VIPs on the Lima shared L2
(`192.168.105.0/24` by default). These VIPs are reachable only from the host/private
VM network, not from the public internet:

- Kubernetes API: kube-vip `https://192.168.105.40:6443`.
- LiteLLM gateway: `http://192.168.105.200:4000/v1`.
- Langfuse: `http://192.168.105.201:3000`.
- Grafana: `http://192.168.105.202:3000`.
- OTel Collector OTLP/HTTP: `http://192.168.105.203:4318`.
- Hubble UI: `http://192.168.105.204`.

Loopback port-forward tasks (`port-forward:*`) remain as a non-HA fallback for UI access and
debugging. Keep port-forwards bound to `127.0.0.1`; they cannot prove service-VIP failover.

## How Codex reaches the gateway

The committed `.codex/config.toml` cannot wire the provider: Codex ignores
`model_provider`, `model_providers`, `openai_base_url`, and `chatgpt_base_url` at the
project layer. Provider wiring is injected at **launch** by a committed `.config/bin/codex`
wrapper — prepended to `PATH` via mise `[env]` `_.path`, so it shadows the mise-managed binary —
which applies `-c/--config` overrides (strongest precedence) pointing Codex at the LiteLLM gateway
with `wire_api = "responses"` and the proxy-auth header
`X-Litellm-Api-Key = "Bearer <CODEX_LITELLM_VIRTUAL_KEY>"`. The OpenAI/Codex subscription itself is
handled server-side by LiteLLM's native `chatgpt/` provider (device-flow OAuth), not by a key in
this repo.

Because the wrapper is on `PATH`, a **bare `codex` in a repo shell already routes through the
gateway** — no task required. Equivalent explicit launchers:

```bash
mise run codex             # raw=true TTY task; execs the same wrapper (codex:launch runs it too)
mise run codex:no-gateway  # drops the -c overrides -> built-in ChatGPT provider, telemetry still on
```

One-time per machine, `mise run codex:global-config` merges the repo's `[otel]` exporters, project
trust, `[analytics] enabled=false`, and an inert `litellm_local` provider definition into your real
`~/.codex/config.toml` (UTC-timestamped backup) so bare-`codex` telemetry ships to the local
collector instead of OpenAI statsig. `CODEX_HOME` is **not** repointed — `~/.codex` is the only
Codex home.

Also one-time per machine, `mise run codex:install-plugins` installs + enables the Langfuse
**codex-observability-plugin** into `~/.codex` (idempotent; also offered by `mise run init`). It
captures codex CLIENT-SIDE — a codex `Stop` hook uploads each turn's rollout to Langfuse as a
**separate** trace (assistant output, reasoning, tool I/O, subagents, tokens), session-grouped and
correlated to the gateway trace by codex session id — the practical fix for the Langfuse sink, since
the gateway cannot capture codex `/responses` streaming output (spend-logs/s3/gateway traces are
covered by the §8d recovery). Enablement lives in the USER config (`codex plugin add` writes it),
like `[otel]`; the tracing env (`TRACE_TO_LANGFUSE` + `LANGFUSE_*`) flows via mise. Needs Node ≥ 22
(repo pins node 24) and a **one-time hook-trust approval** on the first interactive `codex` turn
(headless uses `codex exec --dangerously-bypass-hook-trust`).

## Remote / non-interactive shells — apply the mise env explicitly

mise wires the gateway provider env — and prepends the `.config/bin/codex` wrapper to `PATH` — from
a **prompt-time shell hook** (it fires when zsh renders an interactive prompt on `cd`). Over
`ssh <host> <cmd>`, inside a non-TTY child, or in any scripted / `-c` invocation, that hook **never
runs** — so a bare `codex` there resolves to the unwrapped binary and talks **direct** to the
provider (bypassing LiteLLM). Apply the env explicitly by sourcing `mise hook-env` inside a login
shell:

```bash
ssh <host> zsh -l -i -c 'cd <repo> && eval "$(mise hook-env -s zsh)" && codex exec "…" </dev/null'
```

For repeated remote commands, multiplex the ssh connection so each reuses one session (in
`~/.ssh/config`):

```
Host <host>
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

When a remote command needs SQL, feed it over **stdin** rather than embedding it as an argument —
this sidesteps the nested single/double-quote bugs that ssh + `zsh -c` layering creates:

```bash
kubectl -n litellm exec -i pod/litellm-pg-1 -c postgres -- \
  psql -U postgres -d litellm -At <<'SQL'
SELECT 1;
SQL
```

## Testing subscription (OAuth) models — real CLI only, NEVER curl

The Claude and OpenAI/Codex **subscription** models are authenticated by the original agent
CLI's OAuth session (`claude` / `codex`). The CLI is the **only** authorized OAuth client: a
`curl` or any hand-rolled HTTP client can **not** validly test a subscription model — even
through the LiteLLM gateway — because it cannot reproduce the CLI's OAuth session handling.
Discard any such result (2xx or 4xx/5xx). To test passthrough, drive the real CLI at the
gateway VIP (Codex: `mise run codex`, or a bare `codex` in a repo shell; Claude: `claude` with
`ANTHROPIC_BASE_URL=http://192.168.105.200:4000`). A launch that does not set the base URL to
the VIP runs **direct** to the provider, so "it works" proves only the direct path, not the
passthrough.

## Secrets — fnox + age

No plaintext secret is committed. The authoritative store is the repo-root `fnox.toml`
(fnox + age ciphertext; fnox discovers it by walking up from any subdir). The first-run flow is:

```bash
mise run init           # host prereqs, Lima networking, age key guidance, secret sealing
mise run secrets:check  # fast preflight: key names only, no values printed
mise run up             # host services -> Lima/kubeadm/Cilium -> k8s overlays
```

`secrets:sync` materializes namespaced Kubernetes Secrets during `k8s:apply`; launch tasks
resolve agent virtual keys and MCP credentials from fnox at runtime. The committed MCP
server definitions in `.codex/config.toml` must contain only non-secret hosts/toggles;
credentials are injected at launch.

## Conventions

- Shell scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, 2-space indent; pass
  `shellcheck -s bash` and `shfmt -i 2`; source `.config/mise/lib/common.sh`. Never echo a
  secret.
- Kustomize bases inline Helm via `helmCharts:` with exact pinned versions; LiteLLM is raw
  manifests.
- Telemetry identity: `deployment.environment=ai-infra-platform-local`, `ai.client.name`
  of `codex` / `claude-code` / `smoke-test`, `session.id` as the universal join key.

See `CLAUDE.md` for the full project guide, the mise task surface, and the apply order
documented in `kubernetes/README.md`.
