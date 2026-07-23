# Claude Code extended-thinking capture — `CLAUDE_CODE_EXTRA_BODY` presets

Claude Code's headless/`-p` (`cc_entrypoint=sdk-cli`) mode defaults to
`thinking:{"type":"adaptive","display":"omitted"}` — the model still reasons, but returns **no
summary text** (signature only), so nothing lands in transcripts, spend-logs, or Langfuse.
Interactive (`cc_entrypoint=cli`) defaults to `display:"summarized"` and does return summaries.

`CLAUDE_CODE_EXTRA_BODY` (a JSON object merged into the top level of every API request body —
applies to background/`claude agents`/`--bg` sessions too on Claude Code ≥ v2.1.206) overrides
the `thinking` field, so we can force capture in **all** session types. Each file here is a
verified-valid preset; set it with e.g.:

```sh
export CLAUDE_CODE_EXTRA_BODY="$(cat .config/claude/thinking/claude-opus-4-6.enabled.json)"
```

## Verified matrix (headless `-p`, factoring canary, thinking text captured in transcript)

| model | `type:"enabled"` (RAW, unsummarized CoT) | `adaptive`+`display:"summarized"` (summary) |
|---|---|---|
| `claude-opus-4-6`  | ✅ ~1415 chars — **raw chain-of-thought** | ✅ ~700 chars |
| `claude-haiku-4-5` | ✅ ~1342 chars — **raw chain-of-thought** | ✅ ~1630 chars |
| `claude-opus-4-8`  | ❌ nothing | ✅ ~171 chars |
| `claude-sonnet-5`  | ❌ nothing | ✅ ~344 chars |
| `claude-fable-5`   | ❌ nothing | ✅ ~183 chars |

**Why:** models before the always-adaptive line (Opus 4.6, Haiku 4.5) honor the classic fixed
extended-thinking (`type:"enabled"`) and return the **full, unsummarized** chain-of-thought.
The always-adaptive models (Opus 4.7+, Sonnet 5, Fable 5) ignore `type:"enabled"` (nothing) and
only ever expose a **summary** via `display:"summarized"`. `display:"summarized"` is universal —
it works (returns a summary) on every model tested and errors on none.

## Files (one per VALID `(model, config)` pair)

| file | contents | notes |
|---|---|---|
| `claude-opus-4-6.enabled.json`     | `{"thinking":{"type":"enabled","budget_tokens":8000}}` | RAW CoT |
| `claude-opus-4-6.summarized.json`  | `{"thinking":{"type":"adaptive","display":"summarized"}}` | summary |
| `claude-opus-4-8.summarized.json`  | `{"thinking":{"type":"adaptive","display":"summarized"}}` | summary (default model) |
| `claude-sonnet-5.summarized.json`  | `{"thinking":{"type":"adaptive","display":"summarized"}}` | summary |
| `claude-fable-5.summarized.json`   | `{"thinking":{"type":"adaptive","display":"summarized"}}` | summary |
| `claude-haiku-4-5.enabled.json`    | `{"thinking":{"type":"enabled","budget_tokens":8000}}` | RAW CoT |
| `claude-haiku-4-5.summarized.json` | `{"thinking":{"type":"adaptive","display":"summarized"}}` | summary |

## Default wiring

`.config/mise/conf.d/10-env.toml` sets `CLAUDE_CODE_EXTRA_BODY` to the **summarized** config
(universal; correct for the default `claude-opus-4-8`), so thinking summaries are captured for
every session incl. workflow subagents. To capture **raw** chain-of-thought, run a
`claude-opus-4-6` / `claude-haiku-4-5` session with the matching `*.enabled.json` preset exported.
`budget_tokens` (8000) is the fixed thinking budget for `enabled` — raise toward the model's
max-output-tokens ceiling for deeper raw reasoning.
