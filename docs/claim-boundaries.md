# Public Claim Boundaries

This note defines the public-safe positioning for this repository. Use it before
turning the repo into blog, resume, portfolio, or social copy.

## Table of Contents

- [Default Positioning](#default-positioning)
- [Safe Public Claims](#safe-public-claims)
- [Proof-Gated Claims](#proof-gated-claims)
- [Claims To Avoid](#claims-to-avoid)
- [Publication Checklist](#publication-checklist)
- [Related Docs](#related-docs)

## Default Positioning

Use this as the default public frame:

> A personal AI infrastructure lab that gives one engineer a production-shaped
> gateway, tracing, metrics, logs, secrets workflow, and failure-drill surface
> for coding agents on a single Mac.

This project is stronger as an integrated infrastructure proof than as a generic
local model stack, Kubernetes homelab, or hosted observability clone. The point is
the surrounding platform discipline: gateway control, traceability, operational
checks, secret handling, profile tradeoffs, and bounded publication hygiene.

## Safe Public Claims

These claims are safe when they are phrased as repo capabilities or design
choices, not as live availability guarantees:

- macOS / Apple-Silicon local AI infrastructure lab for one operator.
- LiteLLM gateway with local-model and subscription-passthrough routes.
- Langfuse plus LGTM observability: Grafana, Loki, Tempo, Prometheus, and
  OpenTelemetry Collector.
- Lima-hosted kubeadm cluster with Cilium service VIPs on a private local L2.
- `session.id` correlation across Langfuse, logs, traces, and Prometheus time
  windows.
- Runtime secret discipline with fnox + age; no intended committed plaintext
  secret values.
- Lean default profile for constrained hosts and a 3-node HA-shaped profile for
  larger hosts.
- Full-capture telemetry documented as a local-lab debugging posture with an
  explicit privacy caveat.

## Proof-Gated Claims

Use these only after checking current evidence in this repo and, where needed, a
fresh run on the target machine.

| Claim area | Proof gate before publishing |
| --- | --- |
| Single Lima VM loss keeps host-facing services available | Run `mise run up:ha` and `mise run smoke:ha` or the relevant `smoke:ha:*` task, then keep sanitized evidence from the same run. |
| Codex or Claude routes through LiteLLM subscription passthrough | Test with the real agent CLI, never `curl`; confirm the gateway route with current Langfuse or LiteLLM evidence. |
| One session appears across Langfuse, Loki, Tempo, and Prometheus windows | Use one fresh `session.id` and follow the demo drilldown from Langfuse to Loki to Tempo, then the Prometheus time window. |
| Lean profile fits constrained hardware | Run or render the default lean profile and cite the current check, not an old note. |
| Backup, restore, or PITR works | Complete and record a fresh restore drill; until then this is upgrade backlog, not public proof. |
| The full validation surface is green | Run `mise run validate` for repo-wide validation, or state the narrower task that passed. |

## Claims To Avoid

Do not use these unless a future change adds current, public proof:

- Production-ready.
- Enterprise-grade HA.
- Full HA on one physical host.
- Survives Mac hardware failure.
- Privacy-preserving observability.
- PII redaction.
- Publicly accessible dashboard.
- Backup/restore works.
- All agent flows are green.
- No secrets anywhere, without qualifying it as no intended committed plaintext
  secret values.

## Publication Checklist

Before publishing content based on this repo:

- Lead with "personal AI infrastructure lab" or "production-shaped local AI
  infrastructure lab."
- Say "HA-shaped profile" unless the current HA smoke evidence is part of the
  artifact.
- Keep the single physical Mac as the failure-domain caveat.
- Keep full capture framed as local-lab debugging, not a privacy guarantee.
- Use generic labels for private identifiers, local auth state, and unpublished
  captures.
- Redact sensitive copied content, credentials, local paths, and host-specific
  values from screenshots or snippets.
- Run the cheap publication checks when editing public docs:
  `mise run validate:docs-safety` and `mise run validate:private-names`.
- Prefer links to existing proof docs over broad claims:
  [`architecture.md`](architecture.md), [`profiles.md`](profiles.md),
  [`observability-taxonomy.md`](observability-taxonomy.md),
  [`demo-walkthrough.md`](demo-walkthrough.md), [`ha-and-reliability.md`](ha-and-reliability.md),
  and [`secrets.md`](secrets.md).

## Related Docs

- [`architecture.md`](architecture.md) - topology, planes, and data flows.
- [`profiles.md`](profiles.md) - lean default and 3-node HA profile differences.
- [`observability-taxonomy.md`](observability-taxonomy.md) - telemetry identity,
  signal routing, and privacy caveat.
- [`demo-walkthrough.md`](demo-walkthrough.md) - session-correlation proof path.
- [`ha-and-reliability.md`](ha-and-reliability.md) - HA shape, failure drills, and
  exceptions.
- [`configuration.md`](configuration.md) - network, security guardrails, and
  tunables.
- [`secrets.md`](secrets.md) - runtime secret model and hard rules.
