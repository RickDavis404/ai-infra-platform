# Mac-side host services

The model-serving and host-telemetry stack runs on the Apple-Silicon host, outside
the Lima k3s VM. The cluster reaches the host model endpoint over the Lima host
bridge `host.lima.internal:38080`. Every host endpoint binds `127.0.0.1` only — the
lab is localhost + `kubectl port-forward` only. See spec §8.4 / §9.1 / §9.6 /
§13.2.3.

## Topology

```
                          ┌──────────────────────── Apple-Silicon host ───────────────────────┐
  in-cluster OTel  <───── │  Mac OTel Collector (otelcol-contrib)                              │
  Collector              │    receivers: prometheus(llama-swap:38080, macmon:39300),           │
  http://127.0.0.1:4318  │               hostmetrics, filelog(llama-swap + llama-server)     │
  /v1/{traces,metrics,   │    exporters: otlphttp -> http://127.0.0.1:4318/v1/*              │
        logs}            │                                                                   │
                         │  llama-swap (127.0.0.1:38080, aggregate /metrics)                  │
                         │    ├─ llama-server (GGUF) via stderr-tee wrapper, --metrics        │
                         │    └─ mlx_lm.server (MLX), /v1 only, no /metrics                   │
                         │  macmon exporter (127.0.0.1:39300, workstation_* + sample_age)      │
                         └───────────────────────────────────────────────────────────────────┘
```

A single `llama-swap` proxy fronts both backend server types and JIT-launches
exactly one child per request, swapping idle children under an idle TTL (10m). GGUF
models spawn `llama-server` (through the stderr wrapper, with `--metrics`); MLX
models spawn `mlx_lm.server` directly (no wrapper, no `--metrics` — MLX exposes no
metrics endpoint).

## Files

| Path | Role |
|---|---|
| `llama-swap.yaml` | llama-swap proxy config: `127.0.0.1:38080`, 10m TTL, model catalog. |
| `llama-server-wrapper.sh` | stderr-tee wrapper for GGUF backends; staged to `~/.local/bin/`. |
| `otelcol-config.yaml` | Mac OTel Collector config. |
| `macmon-exporter/` | `workstation_*` Prometheus exporter + wrapper + README. |
| `launchd/` | Representative launchd user agents + brew-services-vs-launchd notes. |

## Default chat model — `AI_INFRA_DEFAULT_CHAT_MODEL_PATH`

The v1 default chat alias is `mac-local/unsloth/qwen3.5-4b-mtp-ud-q8-k-xl-gguf`.
The actual on-disk weights path is supplied to **llama-swap** (not LiteLLM) via the
environment variable `AI_INFRA_DEFAULT_CHAT_MODEL_PATH` — there is **no** hardcoded
absolute model path anywhere in the repo. LiteLLM forwards the bare
`openai/unsloth/qwen3.5-4b-mtp-ud-q8-k-xl-gguf` name; `llama-swap` resolves the path
from the env var when it spawns the child. The launchd agent sets this variable;
override it to point at your local weights.

There is **no default embedding model** in v1. The `gpustack/bge-m3` route
(`llama-server --embedding`) is kept and exercised ONLY by an opt-in smoke test when
embeddings are explicitly enabled.

## The stderr wrapper (why it exists)

llama-swap (a Go parent) does NOT proxy a child `llama-server`'s stderr — on a crash
you see only the exit code (`[WARN] <model> ExitError >> exit status 1`); the actual
error text is lost. `llama-server-wrapper.sh` `exec`s `llama-server` and tees its
stderr to `${TMPDIR}/ai-infra-llama-server.err.log`, which the Mac OTel Collector's
`filelog` receiver ships under `service.name=llama-server`. It also expands a leading
`~/` in the model-path arg (llama-swap execs argv directly with no shell expansion)
and uses `exec` so it stays out of the process tree (llama-swap PID tracking still
works).

## TCC: runnable scripts MUST live in `~/.local/bin`

macOS TCC (Sequoia and later) intercepts code-execution syscalls on files under
`~/Documents`, causing a launchd-spawned interpreter to **silently hang** — no
error, no log. Therefore every runnable host-service script (the llama-server
wrapper, the macmon exporter, the `otelcol-contrib` binary) MUST be staged to
`~/.local/bin/` (an unprotected path), and the launchd `ProgramArguments` reference
that staged path — never a copy under `~/Documents`. `scripts/host/up.sh` performs
the staging. The macmon exporter agent additionally puts `/usr/sbin` on `PATH` and
uses the explicit `/opt/homebrew/bin/python3` interpreter (the `env python3` shim can
resolve to the Command Line Tools stub under launchd).

## Do NOT scrape per-model `/metrics`

Hitting a per-model endpoint through llama-swap's `/upstream/<model>/...` path
AUTO-LOADS the model (spawns a fresh `llama-server`) on every scrape. The Mac OTel
Collector scrapes ONLY the aggregate `127.0.0.1:38080/metrics` (job `llama-swap`) and
the macmon exporter `127.0.0.1:39300/metrics` (job `macmon`). Never add upstream
per-model targets — `scripts/smoke/host.sh` asserts none are configured.

## No inline comments inside `cmd:` blocks

The `llama-server-stub` macro routes the command through a `/bin/zsh -lc 'exec …
"$@"'` layer. A stray inline `#` comment on a `cmd:` argument line can survive into
the shell layer and silently swallow the rest of the command. Comments live ABOVE
the `cmd:` key (or in the macro's leading comment lines) — never on an argument
line. Keep `cmd:` blocks as bare one-token-per-line argv.

## Lifecycle

| Task | Script | Action |
|---|---|---|
| `host:up` | `scripts/host/up.sh` | Stage scripts to `~/.local/bin`, install + load launchd agents. |
| `host:down` | `scripts/host/down.sh` | Unload the launchd agents (staged scripts left in place). |
| `host:status` | `scripts/host/status.sh` | Show each agent's launchd state + endpoint reachability. |
| `host:smoke` | `scripts/smoke/host.sh` | Verify `:38080/v1/models`, default alias, `:39300/metrics`, wrapper, no per-model scrape. |

Config files are staged to `~/.config/ai-infra/` by `up.sh`; logs land in
`~/Library/Logs/ai-infra/`.
