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

## Agent auth on a fresh Mac (install + login)

The repo does **not** authenticate the `claude` / `codex` CLIs — they auth **out-of-band per
machine, subscription OAuth only (never an API key)**. **Both CLIs are now mise-managed in-repo**
via `npm:` backend pins in `mise.toml` (`npm:@openai/codex` and `npm:@anthropic-ai/claude-code`),
so a plain `mise install` provides both — do **not** `brew install --cask codex` or `npm -g`
either (a global npm install entangles the mise-pinned node). The native Claude installer
(`curl -fsSL https://claude.ai/install.sh | bash` → `~/.local/bin`) stays **optional, for
out-of-repo use only**. **Log in from OUTSIDE the repo** — mise activation makes `cd` into the
repo inject the gateway env + `CODEX_HOME`, so never log in via `mise exec` / `mise run`:

- **Codex:** log in from `~` using the mise-managed binary so `CODEX_HOME` stays the real
  `~/.codex` (not the repo's): `cd ~ && "$(mise --cd <repo-root> which codex)" login` → ChatGPT
  OAuth → the **file** `~/.codex/auth.json` (works over headless ssh). **THEN** `mise run init` to
  wire the repo `CODEX_HOME` symlink — must be **after** login or init silently skips it.
- **Claude:** log in from `~` using the mise-managed binary **by path** (so the gateway env is not
  injected and the keychain item is created/owned by *that* binary):
  `cd ~ && "$(mise --cd <repo-root> which claude)"` then type `/login` → Anthropic Max/Pro OAuth in
  the **macOS login keychain**. **CRITICAL — attended GUI Terminal only, NOT headless ssh:** the
  keychain must be unlocked in that GUI security session, and macOS shows a per-app **keychain ACL
  prompt** ("claude wants to use confidential information…") that must be clicked (**Always Allow** to
  suppress it). **Keychain ACLs are per-BINARY:** the mise-managed `claude` is a *different* binary at
  a version-specific install path, so the FIRST in-repo run after switching to it — and again after
  **every version bump** (the mise install path changes per version) — triggers **one** fresh attended
  ACL approval on each machine; until it is clicked, headless runs return `Not logged in` even with the
  `security unlock-keychain` workaround active. Keychain OAuth is also **not portable** between
  machines — re-login per box. Codex (file-based) is unaffected. *Mitigation (documented, not wired
  up):* `claude setup-token` mints a long-lived OAuth token usable via `CLAUDE_CODE_OAUTH_TOKEN`
  (binary-independent, could be fnox-sealed alongside the other secrets) if per-version ACL
  re-approval proves too costly for headless/ssh use.

Full install / auth / verify steps + troubleshooting: [`docs/agent-auth.md`](docs/agent-auth.md).

## Remote / non-interactive shells — mise env hooks do NOT fire

mise injects the gateway env + `CODEX_HOME` from a **prompt-time hook** (it runs when zsh renders a
prompt), so `ssh <host> <cmd>`, a non-TTY child, or any scripted invocation **never** gets it — the
command then talks **direct** to the provider (or misses `CODEX_HOME`). Apply the env **explicitly**:

```sh
ssh <host> zsh -l -i -c 'cd <repo> && eval "$(mise hook-env -s zsh)" && <command>'
```

For repeated remote calls, multiplex the connection (ssh `ControlMaster auto` + `ControlPath` +
`ControlPersist`) so each reuses one session. When a remote command needs SQL, pipe it over **stdin**
to dodge nested-quoting bugs — e.g. `kubectl -n litellm exec -i pod/litellm-pg-1 -c postgres -- psql
-U postgres -d litellm -At` with the SQL fed on stdin. Fuller pattern in [`AGENTS.md`](AGENTS.md).

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

## Autonomous fix escalation + commit/PR discipline (goal-driven / hands-off runs)

When driving toward a goal or an explicitly hands-off / autonomous run, do **NOT** stop at the
first non-trivial or unclear fix — escalate in-band, **per issue**:

1. The working subagent attempts the fix — **up to 2 attempts**.
2. If still unresolved, spawn a **Fable-model subagent** (Agent tool, `model: fable`) to **review**
   the failure and **recommend** a fix aligned with this project's overall goals/intent (root-cause
   diagnosis + recommended approach, not just a patch).
3. Then spawn a **Fable-model subagent given ONE attempt** to troubleshoot and **directly
   implement** that recommended fix, then verify it.
4. **Only if that final Fable attempt also fails** do you stop and surface it — with the full
   diagnosis, what was tried, and the remaining options.

**Commit/PR discipline:** the moment a fix is verified working, **commit + push** it with a clear,
verbose message (symptom → root cause → resolution). When the run's objective is fully met, write a
**detailed PR description** capturing all required changes — do **NOT** merge (human review). This
policy is Claude-specific (Fable subagents); `AGENTS.md` is intentionally not mirrored for it.
