# launchd user agents (Mac-side host services)

These are representative launchd **user agents** for the three Mac-side host
services. Per spec §9.1 the lab uses hand-written launchd agents rather than
`brew services`, because each service needs custom `ProgramArguments`,
`EnvironmentVariables`, and explicit log paths that a generic brew service block
cannot express.

| Plist | Service | Bind | Notes |
|---|---|---|---|
| `com.ai-infra.llama-swap.plist` | llama-swap proxy | `127.0.0.1:38080` | Homebrew binary; config + staged wrapper outside `~/Documents`. |
| `com.ai-infra.otelcol.plist` | Mac OTel Collector | no inbound port | `otelcol-contrib` staged to `~/.local/bin/` (no Homebrew formula). |
| `com.ai-infra.macmon-exporter.plist` | macmon exporter | `127.0.0.1:39300` | `/usr/sbin` on PATH; explicit Homebrew `python3` via the wrapper. |

## `__HOME__` placeholder

The plists are committed with a `__HOME__` placeholder instead of a real home
path (publication safety — the repo never commits a literal `/Users/<name>`
path). `scripts/host/up.sh` substitutes the running user's `$HOME` when it installs
each plist into `~/Library/LaunchAgents/`. The `ProgramArguments` always reference
binaries/scripts under `~/.local/bin` or `/opt/homebrew/bin` — **never** a copy
under `~/Documents` (macOS TCC can silently hang a launchd-spawned interpreter that
executes a script inside the protected `~/Documents` tree).

## Why not `brew services`

`brew services` would manage the service binaries, but:

- The Mac OTel Collector has no Homebrew formula — its binary is staged manually to
  `~/.local/bin/`, so there is no brew service to wrap.
- llama-swap and the macmon exporter need custom argv (config path, explicit bind),
  custom environment (`AI_INFRA_DEFAULT_CHAT_MODEL_PATH`, the `/usr/sbin` PATH for
  the exporter), and explicit log file paths the Mac OTel Collector's `filelog`
  receiver tails. Hand-written agents express all of this directly.

macmon's native `macmon serve --install` (which installs its own agent) remains the
simpler v1 default for hardware telemetry; the custom exporter + its plist here are
the documented alternative that preserves the `workstation_*` schema and the
sample-age gauge (see `../macmon-exporter/README.md`).

## Install / load / unload

```sh
# up.sh does this after substituting __HOME__ -> $HOME:
launchctl bootstrap   "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ai-infra.llama-swap.plist"
launchctl bootstrap   "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ai-infra.otelcol.plist"
launchctl bootstrap   "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ai-infra.macmon-exporter.plist"

# down.sh unloads them:
launchctl bootout     "gui/$(id -u)/com.ai-infra.llama-swap"     || true
```

The `host:up` / `host:down` / `host:status` mise tasks wrap
`scripts/host/{up,down,status}.sh`, which perform the staging, `__HOME__`
substitution, and `launchctl` calls.
