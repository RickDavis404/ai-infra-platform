#!/opt/homebrew/bin/python3
"""ai-infra-macmon-exporter.py — Apple-Silicon hardware telemetry exporter.

Staged to ~/.local/bin/ alongside the wrapper (TCC constraint §8.4). Runs `macmon`
in line-delimited JSON streaming mode and re-publishes the parsed samples as
Prometheus text bound to loopback only (127.0.0.1:39300).

It deliberately preserves a STABLE `workstation_*` metric schema plus a
`workstation_sample_age_seconds` staleness gauge that the macmon Grafana dashboard
references — macmon's native `serve` uses different metric names and lacks the
sample-age gauge. Only stdlib is used so it runs under the pinned Homebrew
python3 with no extra dependencies.

The macmon JSON shape varies across versions; this exporter reads defensively
(missing keys -> metric simply absent) so a schema drift degrades gracefully
rather than crashing the host service.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND_HOST = os.environ.get("AI_INFRA_MACMON_BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("AI_INFRA_MACMON_BIND_PORT", "39300"))
INTERVAL_MS = int(os.environ.get("AI_INFRA_MACMON_INTERVAL_MS", "1000"))

# Shared latest sample + the wall-clock time it was observed.
_STATE_LOCK = threading.Lock()
_LATEST: dict[str, float] = {}
_LATEST_TS: float = 0.0


def _set_metrics(metrics: dict[str, float]) -> None:
    global _LATEST, _LATEST_TS
    with _STATE_LOCK:
        _LATEST = metrics
        _LATEST_TS = time.time()


def _flatten_sample(sample: dict) -> dict[str, float]:
    """Map a macmon JSON sample to the stable workstation_* schema.

    Reads keys defensively; any absent field is simply omitted from the output.
    """
    out: dict[str, float] = {}

    def put(name: str, value) -> None:
        try:
            out[name] = float(value)
        except (TypeError, ValueError):
            return

    # Power (watts) — common macmon fields.
    put("workstation_power_cpu_watts", sample.get("cpu_power"))
    put("workstation_power_gpu_watts", sample.get("gpu_power"))
    put("workstation_power_ane_watts", sample.get("ane_power"))
    put("workstation_power_total_watts", sample.get("all_power"))
    put("workstation_power_ram_watts", sample.get("ram_power"))

    # Temperature (Celsius).
    temp = sample.get("temp") or {}
    if isinstance(temp, dict):
        put("workstation_temp_cpu_celsius", temp.get("cpu_temp_avg"))
        put("workstation_temp_gpu_celsius", temp.get("gpu_temp_avg"))

    # Frequencies (MHz).
    ecpu = sample.get("ecpu_usage")
    pcpu = sample.get("pcpu_usage")
    gpu = sample.get("gpu_usage")
    if isinstance(ecpu, (list, tuple)) and len(ecpu) >= 2:
        put("workstation_ecpu_freq_mhz", ecpu[0])
        put("workstation_ecpu_utilization_ratio", ecpu[1])
    if isinstance(pcpu, (list, tuple)) and len(pcpu) >= 2:
        put("workstation_pcpu_freq_mhz", pcpu[0])
        put("workstation_pcpu_utilization_ratio", pcpu[1])
    if isinstance(gpu, (list, tuple)) and len(gpu) >= 2:
        put("workstation_gpu_freq_mhz", gpu[0])
        put("workstation_gpu_utilization_ratio", gpu[1])

    # Memory (bytes / ratio).
    mem = sample.get("memory") or {}
    if isinstance(mem, dict):
        put("workstation_memory_used_bytes", mem.get("ram_usage"))
        put("workstation_memory_total_bytes", mem.get("ram_total"))
        put("workstation_swap_used_bytes", mem.get("swap_usage"))
        put("workstation_swap_total_bytes", mem.get("swap_total"))

    return out


def _stream_macmon() -> None:
    """Run `macmon pipe` and update shared state per emitted JSON line.

    Restarts the child with backoff if macmon exits, so a transient failure does
    not permanently stop the exporter.
    """
    macmon = shutil.which("macmon") or "/opt/homebrew/bin/macmon"
    interval = str(max(INTERVAL_MS, 100))
    while True:
        try:
            proc = subprocess.Popen(
                [macmon, "pipe", "--interval", interval],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
        except OSError:
            time.sleep(2.0)
            continue

        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                sample = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(sample, dict):
                _set_metrics(_flatten_sample(sample))

        proc.wait()
        time.sleep(2.0)


def _render() -> str:
    with _STATE_LOCK:
        metrics = dict(_LATEST)
        ts = _LATEST_TS
    lines: list[str] = []
    for name, value in sorted(metrics.items()):
        lines.append(f"# TYPE {name} gauge")
        lines.append(f"{name} {value}")
    age = (time.time() - ts) if ts > 0 else -1.0
    lines.append("# TYPE workstation_sample_age_seconds gauge")
    lines.append(
        "# HELP workstation_sample_age_seconds seconds since the last macmon sample"
    )
    lines.append(f"workstation_sample_age_seconds {age}")
    return "\n".join(lines) + "\n"


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        if self.path.rstrip("/") not in ("", "/metrics"):
            self.send_error(404, "not found")
            return
        body = _render().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:  # silence default request logging
        return


def main() -> None:
    worker = threading.Thread(target=_stream_macmon, daemon=True)
    worker.start()
    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), _Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
