#!/usr/bin/env bash
# setup/mac-side/macmon-exporter/macmon-exporter.sh
#
# Staged to ~/.local/bin/ai-infra-macmon-exporter.sh (TCC constraint §8.4: runnable
# host-service scripts MUST live OUTSIDE ~/Documents).
#
# A custom exporter that preserves the stable `workstation_*` Prometheus metric
# schema plus a `sample_age` staleness gauge that the macmon Grafana dashboard
# expects (macmon's native `serve` uses different metric names and lacks the
# sample-age gauge). It runs `macmon` in streaming mode and re-publishes the parsed
# samples as Prometheus text bound to loopback only (127.0.0.1:39300).
#
# launchd note (§8.4): the launchd job for this exporter MUST include /usr/sbin on
# PATH (macmon shells out to powermetrics there) and use an EXPLICIT
# /opt/homebrew/bin/python3 interpreter — the `env python3` shim can resolve to the
# CLT stub under launchd. This wrapper exports that PATH defensively and invokes the
# pinned interpreter directly so it behaves the same whether launched by hand or by
# launchd.
set -euo pipefail

# /usr/sbin first so `powermetrics` (which macmon drives) resolves; keep Homebrew
# and the user bin dir on PATH too.
export PATH="/usr/sbin:/opt/homebrew/bin:${HOME}/.local/bin:${PATH}"

# Bind host/port (127.0.0.1 only) and scrape cadence are overridable via env.
export AI_INFRA_MACMON_BIND_HOST="${AI_INFRA_MACMON_BIND_HOST:-127.0.0.1}"
export AI_INFRA_MACMON_BIND_PORT="${AI_INFRA_MACMON_BIND_PORT:-39300}"
export AI_INFRA_MACMON_INTERVAL_MS="${AI_INFRA_MACMON_INTERVAL_MS:-1000}"

# Explicit Homebrew python3 (NOT `env python3`) per the launchd TCC/shim note.
python_bin="/opt/homebrew/bin/python3"
if [[ ! -x "${python_bin}" ]]; then
  printf '[err ] %s not found — install python3 via Homebrew\n' "${python_bin}" >&2
  exit 1
fi

# The exporter source lives next to this wrapper; when staged to ~/.local/bin both
# files are copied together, so resolve relative to this script's own directory.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
exporter_py="${script_dir}/ai-infra-macmon-exporter.py"
if [[ ! -f "${exporter_py}" ]]; then
  printf '[err ] exporter not found at %s\n' "${exporter_py}" >&2
  exit 1
fi

exec "${python_bin}" "${exporter_py}"
