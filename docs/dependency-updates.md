# Dependency Pins and Auto-Update

This repo pins every third-party artifact — Helm charts, container images, and the
mise toolchain — and keeps those pins current with **Renovate** plus a **kubeconform**
CI gate. This page documents the three pin surfaces, the build mechanism behind them,
the auto-update configuration, and why Renovate (not Dependabot) is the recommended
updater for this stack.

Companion docs: [`chart-selection.md`](chart-selection.md) (chart provenance table),
[`kubernetes/README.md`](../kubernetes/README.md) (render/apply), and
[`developer-workflows.md`](developer-workflows.md) (mise toolchain, pre-commit/CI).

## 1. The three pin surfaces

| Surface | Where the pin lives | Format | Guard |
|---|---|---|---|
| **Helm charts** | `kubernetes/**/kustomization.yaml` → `helmCharts[].version` | exact `version:` (e.g. `18.3.0`) | `validate:helm-kustomize` rejects floating/empty/`latest`/range pins |
| **Raw container images** | `kubernetes/**/*.yaml` (litellm, storage, clickhouse) | `image: repo:tag@sha256:<digest>` | `validate:no-bitnami` + digest audit (task #36) |
| **mise toolchain** | `.config/mise/conf.d/00-tools.toml` → `[tools]` | exact version per tool | `mise install` resolves against the pins |

The `helmCharts:` blocks are the **single source of truth** for chart versions. The
extracted chart tarballs under `kubernetes/**/charts/` are **build cache**, not a pin
surface — see §2.

## 2. Build mechanism (how a chart pin becomes rendered YAML)

Each component is a Kustomize base that inlines its Helm chart:

```yaml
helmCharts:
  - name: loki
    repo: https://grafana-community.github.io/helm-charts
    version: 18.3.0
    valuesFile: values.yaml
```

`kustomize build --enable-helm kubernetes/<component>` fetches the pinned chart into a
sibling `charts/<name>-<version>/` directory (that is what the vendored `charts/` trees
are) and renders it with the local `values.yaml`. `.config/mise/lib/render-all.sh`
does this for every overlay and concatenates the stream; `validate:helm-kustomize`
wraps it with the pin guard and a structural-YAML check.

**Bumping a chart** therefore means editing only the `version:` in the kustomization;
the next `kustomize build --enable-helm` re-vendors `charts/` automatically. This is
exactly the edit Renovate's `kustomize` manager makes — so the vendored `charts/` dirs
are **ignored** by Renovate (`ignorePaths`) to avoid duplicate/incorrect PRs against a
build artifact.

## 3. Auto-update: Renovate (`renovate.json`)

`renovate.json` (repo root) drives four managers, one per pin surface:

| Manager | Covers | Notes |
|---|---|---|
| `kustomize` (built-in) | `helmCharts[].version` | The chart auto-update path; datasource `helm`. |
| `custom.regex` (custom manager) | `image: repo:tag@sha256:…` in `kubernetes/**/*.yaml` | Updates both tag and digest; datasource `docker`. |
| `mise` (built-in) | `[tools]` in `.config/mise/conf.d/*.toml` | `managerFilePatterns` extended to `conf.d/`. Backends mise supports (kubectl, helm, node, …) update; `ubi:`/`pipx:`/`npm:` entries mise-Renovate can't resolve are simply skipped. |
| `github-actions` (built-in) | action refs in `.github/workflows/*` | `helpers:pinGitHubActionDigests` converts tag pins → immutable SHAs. |

**Conservative posture** (all in `renovate.json`):

- Weekly schedule (`before 8am on monday`), `minimumReleaseAge: 3 days` so freshly
  cut / yanked releases are skipped.
- Grouped, non-major PRs per surface; low concurrency (`prConcurrentLimit: 3`).
- **Every major update is held behind `dependencyDashboardApproval`** — nothing major
  opens a PR until you tick it on the dependency dashboard (`minimumReleaseAge: 7 days`).
- Security fixes (`osvVulnerabilityAlerts` + `vulnerabilityAlerts`) bypass the schedule
  and the release-age hold.
- `helm-values` / `helmv3` managers are **disabled**: the only chart pin surface is the
  kustomization `helmCharts.version`; enabling them would fire against the vendored
  build cache and hand-tuned `values.yaml` overrides (noise, not real pins).

Deliberate divergence from the original ask (which said "enable helm-values/helmv3 over
the vendored charts"): for this repo's `helmCharts:`-in-kustomization layout the correct
updater is the `kustomize` manager, so chart auto-update is delivered through that
manager and the vendored charts are ignored. Same intent (charts auto-update), correct
mechanism.

Validate the config locally with `npx --yes renovate-config-validator renovate.json`
(needs network) before relying on it.

## 4. CI gate: kubeconform (`.github/workflows/kubeconform.yaml`)

On PRs and pushes that touch `kubernetes/**` (or the render script / toolchain pin), CI:

1. sets up mise (pinned) and installs **only** the pinned `kustomize` + `helm`,
2. installs a pinned `kubeconform`,
3. renders all overlays via `render-all.sh` (`kustomize build --enable-helm`),
4. schema-validates the stream (`-strict`, built-in schemas + the datreeio CRDs-catalog,
   `-ignore-missing-schemas` for CRDs not in the catalog).

This complements the local `validate:helm-kustomize` structural check with real
Kubernetes/CRD schema validation, and it is what makes a Renovate chart/image bump
**self-checking**: a bump that renders to invalid manifests fails the PR.

Action pins are committed as version tags; Renovate rewrites them to commit SHAs on its
first run. The exact `KUBECONFORM_VERSION` and action tags should be sanity-checked on
the first CI run and then left to Renovate.

## 5. mise lockfile (`mise.lock`)

mise **2026.6.13** supports a lockfile, and it is **enabled**: `lockfile = true` in the
root `mise.toml` `[settings]` block, with `mise.lock` committed at the repo root (next
to `mise.toml`). The lockfile pins every `[tools]` entry across platforms; mise
maintains it automatically on `mise install`, and you can regenerate it explicitly
after changing a pin with `mise lock`.

The former host-telemetry pin (`open-telemetry/opentelemetry-collector-releases`,
briefly on the deprecated `ubi` backend and then the `github:` backend) has been
**removed**. Mac-side host telemetry now runs on **Grafana Alloy**, installed from the
`grafana-alloy` Homebrew formula (see `Brewfile`), so it is no longer a mise `[tools]`
pin — which also removes the transient GitHub-API resolution failures that previously
blocked a reproducible lock.

## 6. Renovate vs Dependabot — recommendation

**Recommendation: Renovate.** This repo mixes Helm-charts-in-kustomization, raw-image
digest pins, and a mise toolchain in TOML; Renovate covers all three from one config,
Dependabot covers none of them well.

| Capability this repo needs | Renovate | Dependabot |
|---|---|---|
| Helm chart `version:` inside a **kustomization `helmCharts:`** block | Native (`kustomize` manager) | Not supported (Dependabot Docker/Helm ecosystems don't parse kustomization `helmCharts`) |
| `image: repo:tag@sha256` **digest** pins in arbitrary manifests | Custom regex manager, tag **and** digest | No custom managers; Kubernetes manifests aren't a supported ecosystem |
| **mise** `[tools]` pins | Native `mise` manager | No mise support |
| Grouping / schedule / **major-hold via dashboard** | Rich (`packageRules`, dependency dashboard) | Coarse (`groups`, `schedule`); no dashboard-approval gate |
| Pin GitHub Actions **tags → SHAs** and keep them fresh | `helpers:pinGitHubActionDigests` | Updates actions, but no automatic tag→digest pinning |

**Dependabot gaps** that specifically bite here: no kustomization-`helmCharts` awareness,
no mise ecosystem, no custom managers for the raw-image digest pins, and no equivalent
of the major-update dashboard-approval hold. Dependabot would only manage the GitHub
Actions in the new workflow — a small slice of the surface. Renovate manages the whole
surface with the conservative controls above.

## Related docs

- [`chart-selection.md`](chart-selection.md) — chart provenance and the version-pin table.
- [`kubernetes/README.md`](../kubernetes/README.md) — apply order and render commands.
- [`developer-workflows.md`](developer-workflows.md) — mise toolchain and pre-commit/CI.
