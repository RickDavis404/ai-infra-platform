# OTel Collector — the in-cluster OTLP gateway

The single OpenTelemetry Collector that every in-cluster and Mac-side producer
sends to. It is **the OTLP gateway** for all app-emitted signals (traces, metrics,
logs) **and** the general container-log path. Alloy (sibling component) is
meta-observability only — it ships *this* collector's own pod logs to Loki and
nothing else.

| | |
|---|---|
| Chart | `opentelemetry-collector` |
| Repo | `https://open-telemetry.github.io/opentelemetry-helm-charts` |
| Version (pinned) | `0.164.1` |
| Release | `otel-collector` |
| Namespace | `lgtm` |
| Mode | `daemonset` (one collector per node) |

## Provenance and apply

Inlined via Helm and rendered with kustomize:

```bash
kustomize build --enable-helm kubernetes/lgtm/otel-collector | kubectl apply -f -
```

The pin (`0.164.1`) is exact and does not float. The namespace is `lgtm` (decision
D001) — every datasource and exporter URL resolves under
`*.lgtm.svc.cluster.local`.

## Image choice

The contrib distribution is `otel/opentelemetry-collector-k8s`, not
`otel/opentelemetry-collector-contrib`: upstream stopped publishing the contrib
image to Docker Hub at collector v0.123.1. Re-verify the published tag at install
time.

## Receivers, ports, and the 64 MiB ceiling

- `otlp` gRPC `:4317` (`max_recv_msg_size_mib: 64`) and HTTP `:4318`
  (`max_request_body_size: 67108864`). The HTTP receiver serves the **standard
  `/v1/{traces,metrics,logs}` paths on plain `:4318`** — there is **no `/otel`
  prefix** (that was a remote-Ingress artifact in the source; v7 is localhost +
  `kubectl port-forward`, so clients post to `http://127.0.0.1:34318/v1/*`).
- `filelog` — the general container-log tail (`start_at: beginning`,
  `storeCheckpoints: true`). Checkpoints persist via a `file_storage` extension
  backed by a `local-path` PVC, so a pod restart does not re-tail from the
  beginning.

The **64 MiB ceiling** (`67108864` bytes) is uniform across the chain (OTel → Loki
→ Tempo). It exists because full-capture records carry raw bodies (~1.3 MB peak
observed, ~40x headroom), which the ~4 MiB defaults would silently drop. If you
change it here you MUST change it in Loki and Tempo together and re-verify
end-to-end.

## Processors

`memory_limiter` (75% soft / 25% spike) leads every pipeline, then `batch`
(1024 / 5s). `k8sattributes` (`extract_all_pod_labels: true`) stamps pod metadata.
`deltatocumulative` (`max_stale: 30m`) converts Codex's delta-temporality metrics
to cumulative for Prometheus remote-write.

`transform/claude_code_genai` is the **GenAI OTTL keystone** — it rewrites Claude
Code's proprietary span attributes into OpenTelemetry GenAI semantic conventions so
Langfuse can decode prompts, completions, and token usage:

- `user_prompt` → `gen_ai.prompt.0.content`
- `input_tokens` → `gen_ai.usage.input_tokens`
- `output_tokens` → `gen_ai.usage.output_tokens`
- `cache_read_tokens` → `gen_ai.usage.cache_read_tokens`
- `cache_creation_tokens` → `gen_ai.usage.cache_creation_tokens`

Without it Langfuse receives spans it cannot turn into generations or token costs.

`filter/langfuse_only_claude_code` keeps only `service.name == "claude-code"` and
runs on the `traces/langfuse` pipeline alone.

## Exporters and pipelines

| Exporter | Destination |
|---|---|
| `otlphttp/tempo` | `http://tempo.lgtm.svc.cluster.local:4318` |
| `otlphttp/langfuse` | `http://langfuse-web.langfuse.svc.cluster.local:3000/api/public/otel` |
| `prometheusremotewrite` | `http://prometheus-server.lgtm.svc.cluster.local/prometheus/api/v1/write` |
| `otlphttp/loki` | `http://loki.lgtm.svc.cluster.local:3100/otlp` |
| `debug` | basic verbosity, on every pipeline |

Pipelines (exactly per §13.2.1):

- `traces` → `[otlphttp/tempo, debug]` — every trace, in full.
- `traces/langfuse` → `[otlphttp/langfuse]` — Claude Code spans only.
- `metrics` → `[prometheusremotewrite, debug]` — delta→cumulative first.
- `logs` → `[otlphttp/loki, debug]` — `otlp` + `filelog` receivers.

The `prometheusremotewrite` exporter enables `resource_to_telemetry_conversion`
(so `host.name` / `service.name` / `ai.client.name` become Prometheus labels),
`retry_on_failure`, and a `remote_write_queue` (`num_consumers: 4`,
`queue_size: 5000`) — added after a 894-datapoint loss in the source's audit.

## Langfuse Basic-auth

The `otlphttp/langfuse` exporter's `Authorization: Basic <base64(public:secret)>`
header is injected from secret **`langfuse-otel-basic-auth`** (namespace `lgtm`),
key `OTEL_EXPORTER_OTLP_LANGFUSE_AUTH`, via the `LANGFUSE_OTLP_AUTH_HEADER` env var
referenced with `${env:...}` in the config. It is never a committed literal. The
lead reconciles the Secret.

## Access (port-forward only)

```bash
kubectl -n lgtm port-forward svc/otel-collector 4318:4318
# clients post OTLP/HTTP to http://127.0.0.1:34318/v1/{traces,metrics,logs}
```
