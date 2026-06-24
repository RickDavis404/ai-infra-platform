# Claude Code rate-limiting & observability tuning

Reference for the resilience + telemetry-verbosity knobs tuned for this project,
why they're set the way they are, and each setting's **stock default**.

## Background: the incident this addresses

A high-fan-out "ultra-code" run hit an Anthropic **`429 rate_limit_error`**
("Server is temporarily limiting requests"). Root cause: it came **from
Anthropic**, relayed through LiteLLM (LiteLLM was not the limiter — the session
used the master key, no rpm/tpm cap). The binding constraint was
**input-tokens-per-minute** (~550k/min, ~95% cache reads), not request count —
many parallel subagents each re-sending large cached contexts. A normal
single-threaded session won't hit this.

Levers: **resilience** = ride out 429s without hard-stopping; **prevention** =
keep fan-out modest (no per-fan-out setting exists — control it in prompts;
the ultra-code Workflow runtime self-caps at `min(16, cpu_cores − 2)`).

## Resilience settings (`.claude/settings.json` → `env`)

| Setting | Default | Set to | Why |
|---|---|---|---|
| `CLAUDE_CODE_MAX_RETRIES` | **10** | `100` | Retries 429/transient errors with built-in **exponential backoff** (count only — backoff scales with it). Rides out longer Anthropic rate-limit windows instead of surfacing an error + halting. |
| `MAX_STRUCTURED_OUTPUT_RETRIES` | **undocumented** (low, ~2–3) | `50` | Separate retry budget for structured-output recovery (a tool/schema response that didn't parse). Independent of `CLAUDE_CODE_MAX_RETRIES`. |
| `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY` | **10** | *not set* | Caps parallel tool calls per turn (incl. subagent dispatch). Left at default — clamping it throttles all parallelism; fan-out is better controlled per-prompt. |

Notes: there is **no** `MAX_PARALLEL_SUBAGENTS` setting and **no** auto-resume
hook. Exponential backoff is built in — only the retry *count* is configurable.

## Telemetry verbosity (`.claude/settings.json`)

| Setting | Default | Set to | Captures |
|---|---|---|---|
| `showThinkingSummaries` (top-level key) | **false** | `true` | Extended thinking summaries in the UI |
| `OTEL_LOG_USER_PROMPTS` (env) | **disabled** | `1` | User prompt text (else `<REDACTED>`) |
| `OTEL_LOG_TOOL_DETAILS` (env) | **disabled** | `1` | Tool params/inputs, Bash commands, tool/skill/subagent names, full error msgs |
| `OTEL_LOG_TOOL_CONTENT` (env) | **disabled** | `1` | Tool input+output bodies in spans — **hard 60 KB cap per attribute** |
| `OTEL_LOG_RAW_API_BODIES` (env) | **disabled** | *not set in committed config* | Full Anthropic request/response JSON (incl. thinking). If enabled locally, use `file:<outside-repo-dir>` so raw bodies never land in the repo tree. |
| `CC_LANGFUSE_MAX_CHARS` (env, langfuse plugin) | **20000** | `67108864` (64 MiB) | Per-field capture cap before the plugin truncates |

> **The 60 KB cap on `OTEL_LOG_TOOL_CONTENT` (and inline `=1` raw bodies) is
> hardcoded in Claude Code — no client or server setting raises it.** The only
> way to capture untruncated bodies is `OTEL_LOG_RAW_API_BODIES=file:<dir>`
> (to local disk). Keep that directory outside the repo tree. Secrets
> (`LANGFUSE_*_KEY`) live in the gitignored `settings.local.json`, never here.

## Server-side pipeline ceiling — **64 MiB everywhere** (configured in the k8s repo, `lgtm/values-*.yaml`)

One uniform 64 MiB (`67108864`) ceiling across the OTel→Loki/Tempo pipeline so
no hop is a smaller bottleneck.

| Component / key | Default | Set to |
|---|---|---|
| OTel collector `otlp.grpc.max_recv_msg_size_mib` | **4** (MiB) | `64` |
| OTel collector `otlp.http.max_request_body_size` | **20 MiB** (20,971,520) | `67108864` (64 MiB) |
| Loki `limits_config.max_line_size` | **256 KB** | `64MB` |
| Loki `server.grpc_server_max_recv/send_msg_size` | **4 MB** (4,194,304) | `67108864` (64 MiB) |
| Tempo `overrides.defaults.global.max_bytes_per_trace` | **5 MB** (5,000,000) | `67108864` (64 MiB) |

Langfuse ingestion/ingress was **not** bumped — large events offload to S3
(configured) and real events are ≪ 64 MiB; verify empirically (watch for a 413)
only if needed.

## Why 64 MiB? (real-world audit, 2026-06-18)

Measured max content sizes across **current + ~3 months of history** of all
local Claude Code & Codex session data (≈3.4 GB, ~8,900 session files, all
accounts) — sizes only, no content inspected:

| Dimension | Global max | + 25% buffer |
|---|---|---|
| Single record / JSONL line | **~1.31 MB** | ~1.64 MB |
| Single captured field | ~1.05 MB (largest claude field ~132 KB) | ~1.31 MB |
| Single turn | ~600 KB | ~750 KB |
| Whole session file | ~78 MB (entire multi-hour session, not one event) | — |

So **64 MiB ≈ 40× the largest single thing ever recorded** — generous headroom,
zero local-dev downside. (The previous `CC_LANGFUSE_MAX_CHARS=100M` was ~75×
the real max field and risked oversized-event 413s; 64 MiB is the sane uniform
ceiling.) Claude Code's own tool caps also bound capture: MCP outputs 60 KB,
Bash 30 KB.
