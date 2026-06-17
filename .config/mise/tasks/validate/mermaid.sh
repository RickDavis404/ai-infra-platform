#!/usr/bin/env bash
#MISE description="Validate every fenced mermaid block in README + docs parses/renders with mmdc."
set -euo pipefail

# Self-contained mermaid syntax gate: extracts every ```mermaid fenced block from
# README.md + docs/**/*.md and renders each with mmdc, failing on any parse error.
# Does NOT depend on the design-doc-mermaid skill's Python. Uses the committed
# puppeteer config (--no-sandbox) so it also works on Linux/CI/Lima.
#
# file-tasks run with cwd = config_root = repo root, so relative paths resolve here.

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
pcfg="${repo_root}/.config/mermaid/puppeteer-config.json"

if ! command -v mmdc >/dev/null 2>&1; then
  printf 'mermaid: mmdc not found on PATH — run: mise run tools:mmdc-setup\n' >&2
  exit 127
fi
if [[ ! -f "${pcfg}" ]]; then
  printf 'mermaid: puppeteer config missing at %s\n' "${pcfg}" >&2
  exit 1
fi

# Collect markdown sources: README.md + everything under docs/.
mapfile -t mds < <(
  {
    [[ -f "${repo_root}/README.md" ]] && printf '%s\n' "${repo_root}/README.md"
    [[ -d "${repo_root}/docs" ]] && find "${repo_root}/docs" -type f -name '*.md'
  } | sort
)

if [[ "${#mds[@]}" -eq 0 ]]; then
  printf 'mermaid: no markdown sources found — nothing to validate.\n'
  exit 0
fi

tmpdir="$(mktemp -d)"
cleanup_tmpdir() { rm -rf -- "${tmpdir}"; }
add_exit_trap cleanup_tmpdir

# Build a runtime Puppeteer config. Mermaid CLI defaults to `headless: "shell"`,
# which requires an exact chrome-headless-shell revision; that cache can be brittle
# on macOS. Prefer a complete Chrome-for-Testing executable when one is available.
runtime_pcfg="${tmpdir}/puppeteer-config.json"
node - "${pcfg}" "${runtime_pcfg}" <<'NODE'
const fs = require('fs')
const path = require('path')

const [basePath, outPath] = process.argv.slice(2)
const cfg = JSON.parse(fs.readFileSync(basePath, 'utf8'))

function existsExecutable(p) {
  try {
    fs.accessSync(p, fs.constants.X_OK)
    return true
  } catch {
    return false
  }
}

function macChromeCandidates(cacheRoot) {
  const chromeRoot = path.join(cacheRoot, 'chrome')
  if (!fs.existsSync(chromeRoot)) return []
  return fs.readdirSync(chromeRoot)
    .filter((entry) => entry.startsWith('mac_'))
    .sort()
    .reverse()
    .map((entry) => {
      const version = entry.replace(/^mac_[^-]+-/, '')
      return path.join(
        chromeRoot,
        entry,
        'chrome-mac-arm64',
        'Google Chrome for Testing.app',
        'Contents',
        'MacOS',
        'Google Chrome for Testing'
      )
    })
}

function hasMacFramework(exePath) {
  const appRoot = exePath.split('/Contents/MacOS/')[0]
  if (appRoot === exePath) return true
  const versions = path.join(appRoot, 'Contents', 'Frameworks', 'Google Chrome for Testing Framework.framework', 'Versions')
  return fs.existsSync(versions) && fs.readdirSync(versions).length > 0
}

let executablePath = process.env.PUPPETEER_EXECUTABLE_PATH
if (!executablePath || !existsExecutable(executablePath)) {
  const cacheRoot = process.env.PUPPETEER_CACHE_DIR || path.join(process.env.HOME || '', '.cache', 'puppeteer')
  executablePath = macChromeCandidates(cacheRoot).find((candidate) => existsExecutable(candidate) && hasMacFramework(candidate))
}

if (executablePath) {
  cfg.executablePath = executablePath
}

fs.writeFileSync(outPath, `${JSON.stringify(cfg, null, 2)}\n`)
NODE

total=0
fail=0

# Extract fenced ```mermaid blocks from one file into numbered .mmd files.
# Emits the path of each extracted block on stdout.
extract_blocks() {
  local md="$1" out_prefix="$2"
  awk -v prefix="${out_prefix}" '
    BEGIN { inblk = 0; n = 0 }
    /^[[:space:]]*```[[:space:]]*mermaid[[:space:]]*$/ {
      inblk = 1; n++; file = prefix "-" n ".mmd"; next
    }
    inblk && /^[[:space:]]*```[[:space:]]*$/ {
      inblk = 0; close(file); print file; next
    }
    inblk { print > file }
  ' "${md}"
}

for md in "${mds[@]}"; do
  rel="${md#"${repo_root}"/}"
  base="${tmpdir}/$(printf '%s' "${rel}" | tr '/.' '__')"
  while IFS= read -r block; do
    [[ -n "${block}" ]] || continue
    total=$((total + 1))
    if mmdc -p "${runtime_pcfg}" -i "${block}" -o "${block}.svg" >/dev/null 2>&1; then
      :
    else
      printf 'mermaid: FAILED to render a block in %s (%s)\n' "${rel}" "$(basename "${block}")" >&2
      mmdc -p "${runtime_pcfg}" -i "${block}" -o "${block}.svg" 2>&1 | sed 's/^/    /' >&2 || true
      fail=$((fail + 1))
    fi
  done < <(extract_blocks "${md}" "${base}")
done

if [[ "${total}" -eq 0 ]]; then
  printf 'mermaid: no fenced mermaid blocks found — nothing to validate.\n'
  exit 0
fi

if [[ "${fail}" -ne 0 ]]; then
  printf 'mermaid: %d of %d block(s) failed to parse/render.\n' "${fail}" "${total}" >&2
  exit 1
fi
printf 'mermaid: clean (%d block(s) parsed/rendered OK).\n' "${total}"
