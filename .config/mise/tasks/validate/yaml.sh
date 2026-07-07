#!/usr/bin/env bash
#MISE description="Lint all YAML with yamllint (multi-doc aware)."
# .config/mise/tasks/validate/yaml.sh — lint all YAML with yamllint (multi-doc aware) (spec §15.1).
#
# Runs `yamllint -c .yamllint.yaml` over the repo's YAML. K8s manifests and Helm
# values use `---` multi-document streams (yamllint handles those natively). A
# structural multi-doc parse via PyYAML is also run as a second gate.
#
# Generated/rendered artifacts and decrypted secret intermediates are skipped:
#   *.dec, *.env, secrets/age/**, any rendered/ output, .git, helm chart caches.
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

config="${repo_root}/.yamllint.yaml"
if [[ ! -f "${config}" ]]; then
  printf 'ERROR: .yamllint.yaml not found at repo root.\n' >&2
  exit 1
fi

if ! command -v yamllint >/dev/null 2>&1; then
  printf 'ERROR: yamllint not found on PATH (need 1.38.0).\n' >&2
  exit 127
fi

# Gather candidate YAML files, excluding generated/secret/cache paths.
yamls=()
while IFS= read -r yaml_file; do
  yamls+=("${yaml_file}")
done < <(
  find . \
    -type d \( \
    -name .git -o \
    -path './secrets/age' -o \
    -name 'rendered' -o \
    -name 'charts' -o \
    -name '.kustomize' \
    \) -prune -o \
    -type f \( -name '*.yaml' -o -name '*.yml' \) \
    ! -name '*.dec' ! -name '*.env' \
    -print | sort
)

if [[ "${#yamls[@]}" -eq 0 ]]; then
  printf 'WARNING: no YAML files found to lint.\n' >&2
  exit 0
fi

printf 'yamllint: linting %d file(s) with %s ...\n' "${#yamls[@]}" "${config#"${repo_root}"/}"
yamllint -c "${config}" -- "${yamls[@]}"

# Structural multi-document parse (catches separators yamllint may pass).
# yamllint is installed via the mise `pipx:yamllint` backend (uv under the hood),
# which bundles PyYAML inside the tool's own venv. Resolve that venv interpreter so
# `import yaml` works without polluting any host/mise python. The launcher shebang
# varies by installer/version — a direct `#!/…/venv/bin/python`, sometimes with a
# trailing `-E`, and newer uv writes a `#!/bin/sh` polyglot wrapper — so resolve it
# defensively before falling back to a host python3.
yaml_py=""
yl_bin="$(command -v yamllint)"

# (1) The shebang's FIRST token (drop any `-E`/flags so the -x test still matches).
shebang_interp="$(sed -n '1s/^#![[:space:]]*//p' "${yl_bin}" | awk '{print $1}')"
if [[ -n "${shebang_interp}" && -x "${shebang_interp}" ]] &&
  "${shebang_interp}" -c 'import yaml' >/dev/null 2>&1; then
  yaml_py="${shebang_interp}"
fi

# (2) uv's `#!/bin/sh` wrapper hides the interpreter; the venv `python` still sits
#     beside the resolved entry-point. Follow the symlink chain by hand (stock macOS
#     `readlink` has no -f) and try that sibling `python`.
if [[ -z "${yaml_py}" ]]; then
  link="${yl_bin}"
  while [[ -L "${link}" ]]; do
    target="$(readlink "${link}")"
    case "${target}" in
    /*) link="${target}" ;;
    *) link="${link%/*}/${target}" ;;
    esac
  done
  venv_py="${link%/*}/python"
  if [[ -x "${venv_py}" ]] && "${venv_py}" -c 'import yaml' >/dev/null 2>&1; then
    yaml_py="${venv_py}"
  fi
fi

# (3) Fall back to a plain python3 only if it can already import yaml.
if [[ -z "${yaml_py}" ]] && command -v python3 >/dev/null 2>&1 &&
  python3 -c 'import yaml' >/dev/null 2>&1; then
  yaml_py="python3"
fi

if [[ -n "${yaml_py}" ]]; then
  printf 'yaml: structural multi-document parse...\n'
  "${yaml_py}" - "${yamls[@]}" <<'PY'
import sys
import yaml

bad = 0
for path in sys.argv[1:]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            list(yaml.safe_load_all(fh))
    except yaml.YAMLError as exc:
        print(f"YAML parse error in {path}: {exc}", file=sys.stderr)
        bad += 1
sys.exit(1 if bad else 0)
PY
fi

printf 'yaml: clean\n'
