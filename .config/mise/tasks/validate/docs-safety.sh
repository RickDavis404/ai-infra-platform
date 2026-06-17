#!/usr/bin/env bash
#MISE description="Fail on unsafe public docs: placeholders, stale terms, broken links, private names."
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
# shellcheck source=.config/mise/lib/common.sh
source "${script_dir}/../../lib/common.sh"

REPO_ROOT="${MISE_PROJECT_ROOT:-$(repo_root)}"
cd "${REPO_ROOT}"

require_cmd rg

python_bin=""
if command -v python3 >/dev/null 2>&1; then
  python_bin="python3"
elif command -v python >/dev/null 2>&1; then
  python_bin="python"
else
  die "required command 'python3' not found on PATH - install it via mise install"
fi

docs_sources=()
[[ -f README.md ]] && docs_sources+=(README.md)
if [[ -d docs ]]; then
  while IFS= read -r md; do
    docs_sources+=("${md}")
  done < <(find docs -maxdepth 1 -type f -name '*.md' | sort)
fi

review_index="docs/reviews/2026-06-23-adversarial/README.md"
[[ -f "${review_index}" ]] && docs_sources+=("${review_index}")

if [[ "${#docs_sources[@]}" -eq 0 ]]; then
  warn "docs-safety: no public markdown sources found"
  exit 0
fi

fail=0

check_rg() {
  local label="$1"
  shift
  if rg -n --no-heading "$@" "${docs_sources[@]}"; then
    err "docs-safety: ${label} found above"
    fail=1
  else
    info "docs-safety: ${label} clean"
  fi
}

check_rg "visible media placeholders" -P \
  -e '\[(DIAGRAM|SCREENSHOT|GIF)(:|\])'

check_rg "stale substrate/access terms" -i -P \
  -e '\bk3s\b' \
  -e 'localhost-only' \
  -e 'loopback-only' \
  -e 'port-forward[ -]only' \
  -e 'no LoadBalancer external IP'

private_name_list="${REPO_ROOT}/.config/mise/lib/forbidden-names.txt"
if [[ ! -f "${private_name_list}" ]]; then
  die ".config/mise/lib/forbidden-names.txt not found; cannot run docs private-name guard"
fi

mapfile -t private_patterns < <(grep -vE '^[[:space:]]*(#|$)' "${private_name_list}")
if [[ "${#private_patterns[@]}" -gt 0 ]]; then
  private_pat="$(
    IFS='|'
    echo "${private_patterns[*]}"
  )"
  check_rg "private-name leaks" -e "${private_pat}"
else
  warn "docs-safety: no private-name patterns configured"
fi

if ! "${python_bin}" - "${REPO_ROOT}" "${docs_sources[@]}" <<'PY'; then
import re
import string
import sys
from pathlib import Path
from urllib.parse import unquote

repo = Path(sys.argv[1]).resolve()
sources = [Path(p) for p in sys.argv[2:]]
link_re = re.compile(r'!?\[[^\]\n]+\]\(([^)\n]+)\)')
scheme_re = re.compile(r'^[A-Za-z][A-Za-z0-9+.-]*:')
heading_re = re.compile(r'^(#{1,6})\s+(.+?)\s*#*\s*$')


def rel(path):
    try:
        return str(path.resolve().relative_to(repo))
    except ValueError:
        return str(path)


def split_target(raw):
    raw = raw.strip()
    if not raw:
        return ""
    if raw.startswith("<") and ">" in raw:
        return raw[1:raw.find(">")]
    return raw.split()[0]


def is_local(target):
    return not (
        scheme_re.match(target)
        or target.startswith("//")
        or target.startswith("mailto:")
        or target.startswith("tel:")
    )


def slugify(heading):
    heading = re.sub(r'<[^>]+>', '', heading)
    heading = re.sub(r'`([^`]*)`', r'\1', heading)
    heading = heading.strip().lower()
    allowed = set(string.ascii_lowercase + string.digits + " -_")
    heading = "".join(ch for ch in heading if ch in allowed)
    heading = re.sub(r'\s+', '-', heading)
    heading = re.sub(r'-+', '-', heading)
    return heading.strip("-")


anchor_cache = {}


def anchors_for(path):
    path = path.resolve()
    if path in anchor_cache:
        return anchor_cache[path]
    anchors = set()
    seen = {}
    if path.suffix.lower() == ".md":
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            lines = path.read_text().splitlines()
        for line in lines:
            match = heading_re.match(line)
            if not match:
                continue
            base = slugify(match.group(2))
            if not base:
                continue
            count = seen.get(base, 0)
            seen[base] = count + 1
            anchors.add(base if count == 0 else f"{base}-{count}")
    anchor_cache[path] = anchors
    return anchors


def iter_links(source):
    in_fence = False
    try:
        lines = source.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        lines = source.read_text().splitlines()
    for line_no, line in enumerate(lines, 1):
        if re.match(r'\s*```', line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for match in link_re.finditer(line):
            target = split_target(match.group(1))
            if target:
                yield line_no, target


errors = []
for source in sources:
    source_path = (repo / source).resolve()
    for line_no, target in iter_links(source_path):
        if not is_local(target):
            continue
        path_part, hash_mark, fragment = target.partition("#")
        if path_part:
            resolved = (source_path.parent / unquote(path_part)).resolve()
        else:
            resolved = source_path
        try:
            resolved.relative_to(repo)
        except ValueError:
            errors.append(f"{rel(source_path)}:{line_no}: local link escapes repo: {target}")
            continue
        if not resolved.exists():
            errors.append(f"{rel(source_path)}:{line_no}: broken local link: {target}")
            continue
        if hash_mark and fragment:
            anchor = unquote(fragment).strip().lower()
            if resolved.is_file() and resolved.suffix.lower() == ".md" and anchor not in anchors_for(resolved):
                errors.append(f"{rel(source_path)}:{line_no}: missing markdown anchor: {target}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY
  err "docs-safety: broken local markdown links found above"
  fail=1
else
  info "docs-safety: local markdown links clean"
fi

if [[ "${fail}" -ne 0 ]]; then
  die "docs-safety: failed"
fi

info "docs-safety: clean (${#docs_sources[@]} public markdown source(s))"
