# CLAUDE.md — ai-inf-platform project guide

Entry-point instructions for Claude Code in this repo. `AGENTS.md` holds the
Codex-specific essentials and is kept consistent with this file; see also `docs/`,
`kubernetes/README.md`, and `.claude/CLAUDE-RATE-LIMITING.md`.

## Critical rule — testing subscription (OAuth) models: use the real agent CLI, NEVER curl

Anthropic (Claude) and OpenAI (Codex) **subscription** models are authenticated by the
original agent CLI's OAuth session — `claude` for Anthropic, `codex` for OpenAI/Codex.
**The agent CLI is the ONLY authorized OAuth client.** A hand-rolled request (`curl`,
ad-hoc scripts, any non-CLI HTTP client) can **NOT** validly test these models — even when
pointed at the LiteLLM gateway — because it cannot reproduce the CLI's OAuth session
handling. Any such result (2xx **or** 4xx/5xx, including 401/429) is **meaningless and must
be discarded** — never cite it as evidence of success or failure.

To test subscription-model routing **through the LiteLLM gateway**
(`http://192.168.105.200:4000`), drive the REAL CLI at the VIP:

- **Claude:** run `claude` **directly** from the repo. mise + fnox export `ANTHROPIC_BASE_URL`
  (the VIP) and `ANTHROPIC_CUSTOM_HEADERS` (`x-litellm-api-key: Bearer <virtual key>`) into the
  shell on `cd` (`conf.d/10-env.toml` + `secret-env.sh`), so a bare `claude` routes through the
  gateway with a real TTY. There is **no `claude:launch` task** — `mise run` gives a task a
  non-TTY stdin, which forces `claude` into `--print`; run it directly instead.
- **Codex:** `mise run codex:launch` — its `#MISE raw=true` connects the TTY, and it injects the
  `-c` provider overrides (`base_url` at the gateway, `wire_api = "responses"`) that Codex ignores
  at the project layer.

**Corollary:** if you run `claude` / `codex` from a shell where mise did **not** populate the env
(outside the repo, or mise not activated), it talks **direct** to the provider, not through
LiteLLM — so "it works" proves only the direct path, not the passthrough. Confirm via a Langfuse
trace or `/status` showing base URL `192.168.105.200:4000`.

## Delegation default — "ultracode" means USE Workflow + subagents

When the user invokes **ultracode**, or asks to use a workflow / subagents / "delegate" /
"preserve your context window", **drive the work through the Workflow tool and subagents** — fan
out, delegate aggressively, keep only conclusions in the main loop, and keep repeating the pattern
until the task list is done (pausing only for real blockers). Do NOT default to long serial
main-loop investigation/implementation; that wastes the main context window and ignores an explicit
instruction. Brief every subagent with full context (never let them investigate blindly).

**Bootstrap exception:** gateway-routed subagents make their model calls through the LiteLLM
`claude-code` virtual key. If that key's budget is exhausted they 429 — so raise the budget first
via the **master-key in-cluster mint Jobs** (`kubernetes/litellm/keys/*.yaml` — budgets are
declarative there; the master key has no budget), then resume delegation.
