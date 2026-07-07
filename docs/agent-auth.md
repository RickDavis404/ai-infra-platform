# Agent OAuth setup (per machine)

This document is the per-machine setup guide for the two coding-agent CLIs the lab
drives through the LiteLLM gateway — **Codex** (OpenAI / ChatGPT) and **Claude
Code** (Anthropic). It covers installing the CLIs, authenticating them, and
verifying that their requests route through the gateway. It is the companion to
[`developer-workflows.md`](developer-workflows.md) §6 (the passthrough
*configuration*) and to the repo-root [`CLAUDE.md`](../CLAUDE.md) hard rule on
testing subscription models.

> **The repo does not install or authenticate these CLIs.** `claude` and `codex`
> live on the base login PATH and are authenticated **out-of-band, per machine,
> with subscription OAuth only — never an API key.** Every additional MacBook in
> the fleet repeats the steps below; nothing here is shared or portable between
> machines.

## 1. Install the CLIs (mise-independent)

Install both agents on the **host login PATH**, independent of mise. **Do not**
`npm install -g` either CLI — a global npm install entangles the mise-pinned
`node` toolchain and drifts when that pin moves.

| Agent | Install command | Lands in |
|---|---|---|
| **Codex** | `brew install --cask codex` | `/opt/homebrew/bin` (already on PATH) |
| **Claude Code** | `curl -fsSL https://claude.ai/install.sh \| bash` | native arm64 build → `~/.local/bin` |

Ensure **`~/.local/bin` is on PATH** for the Claude install (add it in `~/.zshrc`
before the mise activation line if it is not already there). Confirm both resolve:

```sh
command -v codex claude
```

## 2. Authenticate (subscription OAuth, from outside the repo)

Log in from a directory **outside the repo** (e.g. `~`). mise activation in
`~/.zshrc` means a `cd` into the repo injects the gateway passthrough env **and**
`CODEX_HOME`; you want the login to write your *real* provider session, so **never**
authenticate via `mise exec` / `mise run` or from inside the repo tree.

### Codex (ChatGPT) — file-based, headless-OK

```sh
cd ~            # outside the repo
codex login     # opens ChatGPT subscription OAuth in the browser
```

This writes the OAuth session to the **file** `~/.codex/auth.json`, which works
fine over a headless ssh session. **Then**, and only then, wire the repo's Codex
config-home symlink so the gateway launch path picks up your session:

```sh
cd <repo-root>
mise run init   # wires .config/codex/auth.json -> ~/.codex/auth.json
# equivalently: ln -s ~/.codex/auth.json <repo-root>/.config/codex/auth.json
```

**Ordering matters:** run this **after** `codex login`. If the symlink step runs
before `~/.codex/auth.json` exists, it silently skips and the repo's `CODEX_HOME`
ends up with no session.

### Claude Code (Anthropic) — login keychain, attended GUI only

```sh
cd ~            # outside the repo
claude          # then type: /login  -> Anthropic Max/Pro subscription OAuth
```

Claude stores its OAuth session in the **macOS login keychain** (not a file). This
carries the single most surprising gotcha in the whole setup:

> **Claude can only be logged in — and routing-tested — from an ATTENDED GUI
> Terminal** (Terminal.app locally or over screen-share), **not from a headless ssh
> session.** Two GUI-only gates apply:
>
> 1. The **login keychain must be unlocked in that GUI security session.**
>    `security unlock-keychain` run in a *different* session does not cross the
>    boundary.
> 2. Even with the keychain unlocked, macOS shows a per-app **keychain ACL prompt**
>    — *"claude wants to use confidential information stored in your keychain"* —
>    that must be clicked. Click **Always Allow** to suppress it on future runs.
>
> Over headless ssh, **gate 1 alone is fatal**: the login keychain stays *locked* in the
> ssh security session (separate from the GUI/Aqua session), so `claude` reports
> `Not logged in · Please run /login` even though the session exists in the keychain — and
> **even if the ACL was already approved**. Approving the ACL in an attended session only
> suppresses the repeat prompt for future *attended* runs; it does **not** grant ssh access.
> *(Verified 2026-07-07: after clicking the keychain popup, a headless `claude --print` still
> returned `Not logged in`.)* The only headless workaround is to unlock the keychain in that
> ssh session first: `security unlock-keychain login.keychain-db` (interactive password).

Claude's keychain OAuth is **not portable** between machines — re-login on every
box. Codex is unaffected by all of this because its auth is the plain
`~/.codex/auth.json` file.

## 3. Verify routing through the gateway

Test with the **real CLI only** — per [`CLAUDE.md`](../CLAUDE.md), a hand-rolled
`curl` against a subscription model proves nothing and its result must be
discarded. Run each agent from the **repo root** (so mise has injected the gateway
env) and confirm the request lands at the LiteLLM VIP:

```sh
cd <repo-root>
mise exec -- codex exec "say hello in one word" </dev/null   # Codex, non-interactive
claude --print "say hello in one word"                        # Claude, ATTENDED GUI only
```

Then confirm the passthrough actually traversed the gateway (not the direct
provider path):

- A LiteLLM `/spend/logs` row for the call, with `key_alias` `codex` /
  `claude-code` and the subscription passthrough recorded.
- The matching **Langfuse trace** for the session.
- (Interactive spot-check) `claude`'s `/status` shows base URL
  `192.168.105.200:4000`.

For the fuller interactive routing test (`mise run codex:launch`, and running
`claude` directly with a real TTY), see [`developer-workflows.md`](developer-workflows.md)
§6 and the [`CLAUDE.md`](../CLAUDE.md) "testing subscription models" rule.

## 4. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `claude`: `Not logged in · Please run /login` (even after logging in) | Running over headless ssh: the keychain is locked in this session, or the keychain ACL prompt was never approved | Use an **attended GUI Terminal**; unlock the login keychain in that GUI session; click **Always Allow** on the "claude wants to use confidential information" prompt |
| `command not found: claude` / `codex` | Install dir not on PATH | Ensure `~/.local/bin` (Claude) and `/opt/homebrew/bin` (Codex) are on PATH in `~/.zshrc`; re-open the shell |
| Codex works, but the repo's `CODEX_HOME` has no session | The symlink step ran **before** `codex login` and silently skipped | Re-run `mise run init` (or `ln -s ~/.codex/auth.json <repo-root>/.config/codex/auth.json`) **after** `~/.codex/auth.json` exists |
| "It works" but you can't tell it used the gateway | Ran the CLI from outside the repo / mise env not populated → it talks **direct** to the provider | Run from the repo root; confirm via a Langfuse trace or `/status` base URL `192.168.105.200:4000` |
| Tempted to `curl` the gateway to "test" a model | curl cannot reproduce the CLI OAuth session — the result is meaningless | Test with the real `claude` / `codex` CLI only (see [`CLAUDE.md`](../CLAUDE.md)) |

## Related docs

- [`developer-workflows.md`](developer-workflows.md) — §6 agent passthrough configuration and the full mise task surface.
- [`secrets.md`](secrets.md) — the fnox + age secrets model (the gateway virtual keys, distinct from the agent OAuth session).
- [`CLAUDE.md`](../CLAUDE.md) — the hard rule on testing subscription (OAuth) models with the real CLI.
- [`README.md`](../README.md) — quickstart and the service access table.
