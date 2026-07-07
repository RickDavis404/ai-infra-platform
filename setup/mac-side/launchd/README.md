# launchd user agents (Mac-side host services)

These are representative launchd **user agents** for the three Mac-side host
services. Per spec §9.1 the lab uses hand-written launchd agents rather than
`brew services`, because each service needs custom `ProgramArguments`,
`EnvironmentVariables`, and explicit log paths that a generic brew service block
cannot express.

| Plist | Service | Bind | Notes |
|---|---|---|---|
| `com.ai-infra.llama-swap.plist` | llama-swap proxy | `127.0.0.1:38080` | mise-managed binary (github backend); `host:up` bakes the resolved path into `__LLAMA_SWAP_BIN__`. Config + staged wrapper outside `~/Documents`. |
| `com.ai-infra.alloy.plist` | Grafana Alloy (host telemetry) | UI on `127.0.0.1:12345`, no OTLP inbound | Homebrew `grafana-alloy` binary `alloy`; River config staged to `~/.config/ai-infra/`. |
| `com.ai-infra.macmon-exporter.plist` | macmon exporter | `127.0.0.1:39300` | `/usr/sbin` on PATH; explicit Homebrew `python3` via the wrapper. |

## `__HOME__` placeholder

The plists are committed with a `__HOME__` placeholder instead of a real home
path (publication safety — the repo never commits a literal `/Users/<name>`
path). `scripts/host/up.sh` substitutes the running user's `$HOME` when it installs
each plist into `~/Library/LaunchAgents/`. The `ProgramArguments` always reference
binaries/scripts under `~/.local/bin`, `/opt/homebrew/bin`, or a mise tool-install
path (llama-swap, resolved by `host:up` via `mise which`) — **never** a copy under
`~/Documents` (macOS TCC can silently hang a launchd-spawned interpreter that
executes a script inside the protected `~/Documents` tree).

## Why not `brew services`

`brew services` would manage the service binaries, but each service needs custom
argv, environment, and explicit log paths a generic brew service block cannot express:

- Grafana Alloy needs custom run flags — the staged River config path,
  `--storage.path` (a writable dir, since launchd runs the agent with CWD=`/`),
  `--server.http.listen-addr=127.0.0.1:12345` (no public port), and
  `--stability.level=public-preview` (the config's `otelcol.receiver.filelog` is
  public-preview) — so it runs as a hand-written agent even though the
  `grafana-alloy` formula ships a brew service.
- llama-swap and the macmon exporter need custom argv (config path, explicit bind),
  custom environment (`AI_INFRA_DEFAULT_CHAT_MODEL_PATH`, the `/usr/sbin` PATH for
  the exporter), and explicit log file paths that Alloy's `otelcol.receiver.filelog`
  tails. Hand-written agents express all of this directly.

macmon's native `macmon serve --install` (which installs its own agent) remains the
simpler v1 default for hardware telemetry; the custom exporter + its plist here are
the documented alternative that preserves the `workstation_*` schema and the
sample-age gauge (see `../macmon-exporter/README.md`).

## Install / load / unload

```sh
# up.sh does this after substituting __HOME__ -> $HOME:
launchctl bootstrap   "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ai-infra.llama-swap.plist"
launchctl bootstrap   "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ai-infra.alloy.plist"
launchctl bootstrap   "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ai-infra.macmon-exporter.plist"

# down.sh unloads them:
launchctl bootout     "gui/$(id -u)/com.ai-infra.llama-swap"     || true
```

The `host:up` / `host:down` / `host:status` mise tasks wrap
`scripts/host/{up,down,status}.sh`, which perform the staging, `__HOME__`
substitution, and `launchctl` calls.
