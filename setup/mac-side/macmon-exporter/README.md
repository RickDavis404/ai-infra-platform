# macmon exporter (`workstation_*` schema)

Apple-Silicon hardware telemetry for the Mac-side host telemetry shipper (Grafana
Alloy), exposed as Prometheus text bound to loopback only (`127.0.0.1:39300`). See
spec §8.4 / §9.1.

## What this is

`macmon` (Homebrew tap `vladkens/tap`) reads Apple-Silicon power, temperature,
frequency, and memory counters. Two ways to surface them:

1. **Native `macmon serve`** — the simpler v1 default. Exposes `/metrics` on its
   own port and installs its own launchd agent (`macmon serve --install`). It uses
   macmon's own metric names and does **not** publish a sample-age gauge.
2. **This custom exporter** (`ai-infra-macmon-exporter.py`, wrapped by
   `macmon-exporter.sh`) — the documented alternative used when the stable
   `workstation_*` metric schema and a `workstation_sample_age_seconds` staleness
   gauge must be preserved, because the macmon Grafana dashboard references that
   schema. It runs `macmon pipe` (line-delimited JSON streaming) and re-publishes
   the parsed samples as Prometheus text on `127.0.0.1:39300`.

If you adopt the native `macmon serve` instead, the macmon dashboard panels and any
metric relabels must be updated to its metric names and will lose the sample-age
staleness signal.

## Files

| File | Role |
|---|---|
| `macmon-exporter.sh` | Wrapper: sets PATH, picks the explicit Homebrew `python3`, execs the exporter. Staged to `~/.local/bin/ai-infra-macmon-exporter.sh`. |
| `ai-infra-macmon-exporter.py` | The exporter itself (stdlib only). Streams `macmon pipe`, serves `/metrics`. |

## Metrics

Stable `workstation_*` gauges (each emitted only when the source field is present
in the macmon sample, so a schema drift degrades gracefully):

- `workstation_power_{cpu,gpu,ane,ram,total}_watts`
- `workstation_temp_{cpu,gpu}_celsius`
- `workstation_{ecpu,pcpu,gpu}_freq_mhz` and `..._utilization_ratio`
- `workstation_memory_{used,total}_bytes`, `workstation_swap_{used,total}_bytes`
- `workstation_sample_age_seconds` — seconds since the last macmon sample; the
  dashboard alerts on staleness when this climbs.

## Staging and run (TCC requirement)

macOS TCC (Sequoia and later) can **silently hang** a launchd-spawned interpreter
that executes a script under `~/Documents`. Both files MUST be staged to
`~/.local/bin/` (an unprotected path); the launchd `ProgramArguments` reference that
staged path. `scripts/host/up.sh` performs the staging; the launchd plist for this
exporter additionally puts `/usr/sbin` on `PATH` (so `macmon`'s `powermetrics`
dependency resolves) and uses the explicit `/opt/homebrew/bin/python3` interpreter
(the `env python3` shim can resolve to the Command Line Tools stub under launchd).

```sh
install -d "$HOME/.local/bin"
install -m 0755 macmon-exporter.sh        "$HOME/.local/bin/ai-infra-macmon-exporter.sh"
install -m 0644 ai-infra-macmon-exporter.py "$HOME/.local/bin/ai-infra-macmon-exporter.py"
```

## Environment overrides

| Variable | Default | Meaning |
|---|---|---|
| `AI_INFRA_MACMON_BIND_HOST` | `127.0.0.1` | Bind host (loopback only). |
| `AI_INFRA_MACMON_BIND_PORT` | `39300` | Bind port. |
| `AI_INFRA_MACMON_INTERVAL_MS` | `1000` | macmon sample interval (ms). |

## Verify

```sh
curl -fsS http://127.0.0.1:39300/metrics | grep workstation_sample_age_seconds
```

Grafana Alloy scrapes this endpoint as job `macmon` at 5s
(`setup/mac-side/alloy-config.alloy`). It never scrapes any per-model
`/upstream/<model>/metrics` path.
