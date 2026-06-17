#!/usr/bin/env bash
#MISE description="Verify chart version pins, then render Helm + kustomize and lint/validate the output."
#MISE depends=["validate:render-warm"]
# .config/mise/tasks/validate/helm-kustomize.sh — pin guard + render + validate the output.
#
# Two client-side (no-cluster) gates:
#   1. Chart-pin guard — every Helm chart inlined via a kustomization `helmCharts:`
#      block MUST pin an exact `version`. Floating/empty/`latest`/range (`~`/`^`/`*`)
#      versions are rejected so an unreviewed upstream bump can never slip in
#      (spec §15.2). This reads the kustomization source directly (no network) and
#      runs FIRST, so an unpinned chart fails fast before any helm-repo fetch.
#   2. Render + structural validity — renders every kubernetes/<component> overlay
#      with `kustomize build --enable-helm` (via .config/mise/lib/render-all.sh) and
#      validates the resulting stream is well-formed YAML (structural parse via
#      yq/python3). The server-side `kubectl apply --dry-run=server` against a live
#      API is a separate cluster-bound step (spec §15.2); offline, this proves the
#      charts render and parse.
#
# Offline helm-repo fetch failures are surfaced with a clear message and fail the
# gate (you cannot prove a chart renders if you cannot fetch it).
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

# --- Gate 1: chart version pins ------------------------------------------------
# Assert every helmCharts entry under kubernetes/**/kustomization.yaml pins an
# exact version. Source-level (independent of the render) so an unpinned chart
# fails before any network fetch. The pin lives only in each kustomization.yaml;
# there is no separate provenance allowlist to keep in sync.
verify_chart_pins() {
  local k8s_dir="${repo_root}/kubernetes"
  if [[ ! -d "${k8s_dir}" ]]; then
    printf 'chart-pins: no kubernetes/ dir yet — nothing to verify.\n'
    return 0
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'ERROR: yq not found on PATH (need 4.53.3) to parse helmCharts blocks.\n' >&2
    return 127
  fi

  local -a kustomizations
  mapfile -t kustomizations < <(
    find "${k8s_dir}" -type f \( -name kustomization.yaml -o -name kustomization.yml \) | sort
  )

  local rc=0 checked=0 kfile rel triple name rest repo version
  local -a triples
  for kfile in "${kustomizations[@]:-}"; do
    [[ -n "${kfile}" ]] || continue
    rel="${kfile#"${repo_root}"/}"
    # Extract each helmCharts entry as "name|repo|version"; skip files with none.
    mapfile -t triples < <(
      yq eval -r \
        '.helmCharts // [] | .[] | (.name // "") + "|" + (.repo // "") + "|" + (.version // "")' \
        "${kfile}" 2>/dev/null || true
    )
    for triple in "${triples[@]:-}"; do
      [[ -z "${triple}" || "${triple}" == "||" ]] && continue
      checked=$((checked + 1))
      name="${triple%%|*}"
      rest="${triple#*|}"
      repo="${rest%%|*}"
      version="${rest##*|}"

      if [[ -z "${version}" || "${version}" == "latest" || "${version}" =~ ^[~^*] ]]; then
        printf 'ERROR: %s: chart %s has a floating/empty version (%s).\n' \
          "${rel}" "${name}" "${version:-<empty>}" >&2
        rc=1
        continue
      fi
      printf 'chart-pins: ok %s -> %s %s (%s)\n' "${rel}" "${name}" "${version}" "${repo}"
    done
  done

  if [[ "${rc}" -ne 0 ]]; then
    printf 'chart-pins: one or more charts are not pinned to an exact version.\n' >&2
    return 1
  fi
  if [[ "${checked}" -eq 0 ]]; then
    printf 'chart-pins: no helmCharts entries found — nothing to verify.\n'
  else
    printf 'chart-pins: clean (%d chart(s) pinned to an exact version).\n' "${checked}"
  fi
  return 0
}

verify_chart_pins

# --- Gate 2: render + structural validity --------------------------------------
render="${repo_root}/.config/mise/lib/render-all.sh"
if [[ ! -x "${render}" && ! -f "${render}" ]]; then
  printf 'ERROR: %s not found.\n' "${render}" >&2
  exit 1
fi

tmp="$(mktemp)"
cleanup_tmp() { rm -f -- "${tmp}"; }
add_exit_trap cleanup_tmp

printf 'helm-kustomize: rendering all overlays (kustomize build --enable-helm)...\n'
if ! bash "${render}" >"${tmp}"; then
  printf 'helm-kustomize: render failed. If this is an offline helm-repo fetch\n' >&2
  printf '                failure, run with network access or pre-populate the\n' >&2
  printf '                helm chart cache, then retry.\n' >&2
  exit 1
fi

if [[ ! -s "${tmp}" ]]; then
  printf 'helm-kustomize: render produced no output (no overlays yet?) — nothing to validate.\n'
  exit 0
fi

# Structural validity of the rendered multi-document stream.
printf 'helm-kustomize: validating rendered manifest stream...\n'
if command -v yq >/dev/null 2>&1; then
  # yq exits non-zero on a malformed document; consume all docs.
  yq eval-all 'true' "${tmp}" >/dev/null
elif command -v python3 >/dev/null 2>&1; then
  python3 - "${tmp}" <<'PY'
import sys
import yaml

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    list(yaml.safe_load_all(fh))
PY
else
  printf 'ERROR: need yq or python3 to validate rendered output.\n' >&2
  exit 127
fi

docs="$(grep -c '^---' "${tmp}" || true)"
printf 'helm-kustomize: rendered stream is valid YAML (%s document separator(s)).\n' "${docs}"
