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

## Resilience settings (`conf.d/10-env.toml` `[env]`)

| Setting | Default | Set to | Why |
|---|---|---|---|
| `CLAUDE_CODE_RETRY_WATCHDOG` | **unset** (built-in 15-retry hard cap) | `1` | Retry watchdog (v2.1.199+): lifts the **15-retry hard cap** — which had silently clamped the old `CLAUDE_CODE_MAX_RETRIES=100` since v2.1.186 — and raises non-capacity transient-error retries to **300**, still with built-in exponential backoff. Rides out longer Anthropic rate-limit windows instead of surfacing an error + halting. **Supersedes** `CLAUDE_CODE_MAX_RETRIES` (a no-op past the cap). |
| `MAX_STRUCTURED_OUTPUT_RETRIES` | **undocumented** (low, ~2–3) | `50` | Separate retry budget for structured-output recovery (a tool/schema response that didn't parse). Independent of the transient-error retry budget (`CLAUDE_CODE_RETRY_WATCHDOG`). |
| `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY` | **10** | *not set* | Caps parallel tool calls per turn (incl. subagent dispatch). Left at default — clamping it throttles all parallelism; fan-out is better controlled per-prompt. |

Notes: there is **no** `MAX_PARALLEL_SUBAGENTS` setting and **no** auto-resume
hook. Exponential backoff is built in — only the retry *count* is configurable.

## Telemetry verbosity (`conf.d/10-env.toml` `[env]`; `showThinkingSummaries` in `.claude/settings.json`)

| Setting | Default | Set to | Captures |
|---|---|---|---|
| `showThinkingSummaries` (top-level key) | **false** | `true` | Extended thinking summaries in the UI |
| `OTEL_LOG_USER_PROMPTS` (env) | **disabled** | `1` | User prompt text (else `<REDACTED>`) |
| `OTEL_LOG_TOOL_DETAILS` (env) | **disabled** | `1` | Tool params/inputs, Bash commands, tool/skill/subagent names, full error msgs |
| `OTEL_LOG_TOOL_CONTENT` (env) | **disabled** | `1` | Tool input+output bodies in spans — default **60 KB per-attribute** cap, raised to 64 MiB by `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` (below) |
| `OTEL_LOG_ASSISTANT_RESPONSES` (env, v2.1.193+) | **disabled** | `1` | Assistant response text (would inherit `OTEL_LOG_USER_PROMPTS`; pinned explicit) |
| `OTEL_LOG_RAW_API_BODIES` (env) | **disabled** | `file:{{config_root}}/.local/logs/claude/otel-raw-bodies` | Full Anthropic request/response JSON, untruncated, one file per call, into the gitignored `.local/` tree — only a `body_ref` attr rides OTLP; the host alloy filelog ships the files to Loki. **File mode keeps raw bodies out of the repo tree; thinking is `<REDACTED>` in these logs by design — the full summarized thinking is preserved unredacted in the on-disk transcripts instead (see [`observability-taxonomy.md`](../docs/observability-taxonomy.md) §7).** |
| `CLAUDE_CODE_EXTRA_BODY` (env, ≥v2.1.206) | **unset** (headless/`-p` → `thinking.display="omitted"`, no summary text) | `{"thinking":{"type":"adaptive","display":"summarized"}}` | Forces the thinking-summary capture below to apply to headless/background sessions too, not just interactive ones — see the dedicated section below |
| `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` (env) | **60 KB** | `67108864` (64 MiB) | The real content lever — raises the 60 KB per-body OTLP content cap (`OTEL_LOG_TOOL_CONTENT` / inline bodies) to match the pipeline (Loki 64 MB) and `CC_LANGFUSE_MAX_CHARS` |
| `CC_LANGFUSE_MAX_CHARS` (env, langfuse plugin) | **20000** | `67108864` (64 MiB) | Per-field capture cap before the plugin truncates |

> **`CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` is the content lever** — it raises the
> default **60 KB** per-attribute cap on `OTEL_LOG_TOOL_CONTENT` and inline `=1` raw
> bodies to **64 MiB**, matching the server-side pipeline ceiling (the earlier claim
> that "no setting raises the 60 KB cap" is superseded by this var). For genuinely
> untruncated request/response bodies, `OTEL_LOG_RAW_API_BODIES=file:<dir>` still
> writes them to local disk — keep that directory outside the repo tree (here the
> gitignored `.local/` tree). Secrets (`LANGFUSE_*_KEY`) live in the gitignored
> `settings.local.json`, never here.

### Extended-thinking capture (`CLAUDE_CODE_EXTRA_BODY`)

Interactive sessions (`cc_entrypoint=cli`) default to `thinking.display="summarized"` and
capture a summary out of the box. Headless/`-p` sessions (`cc_entrypoint=sdk-cli` — every
workflow subagent) default to `display="omitted"` instead: the model still reasons, but
returns no summary text (signature only), so nothing lands in transcripts, spend-logs, or
Langfuse. `CLAUDE_CODE_EXTRA_BODY` is a JSON object merged into the top level of every API
request body (applies to background/`claude agents`/`--bg` sessions too on Claude Code
≥ v2.1.206); it overrides the `thinking` field, forcing capture in **all** session types.

`conf.d/10-env.toml` sets it project-wide to the universal summarized config:

```
CLAUDE_CODE_EXTRA_BODY = '{"thinking":{"type":"adaptive","display":"summarized"}}'
```

which is correct for the default model (`claude-opus-4-8`) and captures a summary on
every session, including headless workflow subagents. A verified per-model preset
library lives at `.config/claude/thinking/*.json` (one file per verified-valid
`(model, config)` pair), documented in `.config/claude/thinking/README.md`:

| model | `type:"enabled"` (RAW, unsummarized CoT) | `adaptive`+`display:"summarized"` (summary) |
|---|---|---|
| `claude-opus-4-6`  | raw chain-of-thought captured | summary captured |
| `claude-haiku-4-5` | raw chain-of-thought captured | summary captured |
| `claude-opus-4-8` (default) | nothing (ignored) | summary captured |
| `claude-sonnet-5`  | nothing (ignored) | summary captured |
| `claude-fable-5`   | nothing (ignored) | summary captured |

**Why:** models before the always-adaptive line — `claude-opus-4-6` and
`claude-haiku-4-5` — honor the classic fixed extended-thinking config
(`{"thinking":{"type":"enabled","budget_tokens":8000}}`) and return the **full,
unsummarized** chain-of-thought. The always-adaptive models (`claude-opus-4-8`,
`claude-sonnet-5`, `claude-fable-5`) ignore `type:"enabled"` entirely and only ever
expose a summary via `display:"summarized"`, which is universal — it works on every
model tested and errors on none. To capture raw CoT, export the matching
`claude-opus-4-6.enabled.json` / `claude-haiku-4-5.enabled.json` preset before running a
session with that model; `budget_tokens` (8000) is the fixed thinking budget for
`enabled` — raise it toward the model's max-output-tokens ceiling for deeper raw
reasoning. See [`observability-taxonomy.md`](../docs/observability-taxonomy.md) §7 for
how this interacts with the raw-body logger's unconditional `<REDACTED>` thinking
redaction.

## SDK export, batch-queue, and attribute-limit tuning (`conf.d/10-env.toml` `[env]`)

Beyond the capture toggles, the committed env pins the OTel SDK's export cadence,
raises the batch queues so bursts don't silently drop events, and widens the
per-signal attribute count limits. **Anti-drop is the biggest "stop losing events"
win** — the SDK default queue of **2048** silently drops records under a high-fan-out
burst. The `OTEL_BSP_*` / `OTEL_BLRP_*` and interval vars are **shared OTel-SDK knobs
codex also honors** (see the codex-scope note in `10-env.toml`); the `CLAUDE_CODE_*`
vars are Claude-only.

| Setting | Default | Set to | Why |
|---|---|---|---|
| `CLAUDE_CODE_OTEL_DIAG_STDERR` | **off** | `1` | Print OTLP exporter errors to stderr (surface silent export failures) |
| `CLAUDE_CODE_OTEL_SHUTDOWN_TIMEOUT_MS` | **short** | `600000` (600s) | Let the batch processors drain fully on exit — nothing lost at shutdown |
| `CLAUDE_CODE_OTEL_FLUSH_TIMEOUT_MS` | **short** | `600000` (600s) | Same budget for an explicit force-flush |
| `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE` | **off** | `1` | Persist session state (stable session join key across the run) |
| `CLAUDE_CODE_FORWARD_SUBAGENT_TEXT` | **off** | `1` | Forward subagent text into the parent trace (else it's dropped from the session view) |
| `CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS` | **short** | `3600000` (1h) | Tolerate hour-long async-agent stalls without abandoning capture |
| `TASK_MAX_OUTPUT_LENGTH` | **lower** | `160000` | Lift the Task-tool output cap |
| `OTEL_METRIC_EXPORT_INTERVAL` | **60000** | `60000` | Explicit-default pin (metrics flush cadence — pinned so an SDK change can't drift it) |
| `OTEL_LOGS_EXPORT_INTERVAL` | **5000** | `5000` | Explicit-default pin (logs flush cadence) |
| `OTEL_TRACES_EXPORT_INTERVAL` | **5000** | `5000` | Explicit-default pin (traces flush cadence) |
| `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` | **delta** | `delta` | Explicit-default pin — delta temporality (`deltatocumulative` converts before Prometheus remote-write) |
| `OTEL_BLRP_MAX_QUEUE_SIZE` | **2048** | `16384` | Anti-drop: log-record batch queue (BatchLogRecordProcessor) |
| `OTEL_BLRP_MAX_EXPORT_BATCH_SIZE` | **512** | `2048` | Log-record export batch size (≤ queue) |
| `OTEL_BSP_MAX_QUEUE_SIZE` | **2048** | `16384` | Anti-drop: span batch queue (BatchSpanProcessor) |
| `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | **512** | `2048` | Span export batch size (≤ queue) |
| `OTEL_ATTRIBUTE_COUNT_LIMIT` | **128** | `512` | Count-limit margin so attribute-rich records aren't clipped (codex is fixed at 128) |
| `OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT` | **128** | `512` | Per-span attribute count margin |
| `OTEL_LOGRECORD_ATTRIBUTE_COUNT_LIMIT` | **128** | `512` | Per-log-record attribute count margin |
| `CLAUDE_CODE_TMPDIR` | **system tmp** | `{{config_root}}/.local/tmp-claude` | Project-local scratch dir (created by `init.sh` + `host/up.sh`; `.local/` gitignored) |

### Deliberately unset (documented — max-capture posture)

Some knobs are intentionally **left unset** because setting them could only *reduce*
capture:

- **Attribute value-length limits** — `OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT`,
  `OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT`,
  `OTEL_LOGRECORD_ATTRIBUTE_VALUE_LENGTH_LIMIT`: unset = **unlimited = max**. The real
  content cap is `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` (above); any value here could
  only truncate.
- **The `DISABLE_*` family** (`DISABLE_TELEMETRY`, `DISABLE_COST_WARNINGS`, …) and
  `OTEL_SDK_DISABLED`: **any non-empty value — including `"0"` / `"false"` — disables
  the feature**, so they stay UNSET, never `"0"`. (Likewise `OTEL_TRACES_SAMPLER` stays
  unset → the `parentbased_always_on` default captures every trace.)

## Server-side pipeline ceiling — **64 MiB everywhere** (configured in the k8s repo, `lgtm/values-*.yaml`)

One uniform 64 MiB (`67108864`) ceiling across the OTel→Loki/Tempo pipeline so
no hop is a smaller bottleneck.

| Component / key | Default | Set to |
|---|---|---|
| OTel collector `otlp.grpc.max_recv_msg_size_mib` | **4** (MiB) | `64` |
| OTel collector `otlp.http.max_request_body_size` | **20 MiB** (20,971,520) | `67108864` (64 MiB) |
| Loki `limits_config.max_line_size` | **256 KB** | `64MB` |
| Loki `limits_config.max_line_size_truncate` | **false** (drop) | `true` (truncate + keep) |
| Loki `server.grpc_server_max_recv/send_msg_size` | **4 MB** (4,194,304) | `67108864` (64 MiB) |
| Tempo `overrides.defaults.global.max_bytes_per_trace` | **5 MB** (5,000,000) | `67108864` (64 MiB) |

> **Loki `max_line_size_truncate: true` is the safety net.** Measured history on this
> cluster has included lines up to **~10.8 MiB** (codex tool outputs) and Loki has
> never actually dropped a line at the 64 MB ceiling, so `max_line_size` stays at
> `64MB` (do **not** reduce it). If a line ever *does* exceed 64 MB, `truncate=true`
> makes Loki truncate-and-keep (log-shipped) rather than drop it outright.

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
