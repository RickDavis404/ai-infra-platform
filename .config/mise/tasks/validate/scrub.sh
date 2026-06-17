#!/usr/bin/env bash
#MISE description="Fail if any forbidden publication-unsafe token survives the scrub layers."
#MISE depends=["validate:render-warm"]
# .config/mise/tasks/validate/scrub.sh — exit 1 if any forbidden publication-unsafe token is present.
# Only GENERIC pattern literals live here (the guard self-excludes). Truly private
# literals (org/customer/device names) belong in the gitignored
# .config/mise/lib/forbidden-names.txt, scanned by layer 2 (private-names.sh) —
# so the committed guard reveals nothing about what it scrubs.
#
# Top-level publication-safety scan over the tracked tree (spec §15.1). It combines:
#   1. the named-token scrub list below (NAMED entities + token PREFIXES that the
#      shape-based gitleaks scan will not flag),
#   2. the private-names rg guard (operator-maintained literals),
#   3. the rendered no-Bitnami proof, and
#   4. the rendered no-NodePort proof.
# Any forbidden token in any layer fails the gate.
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

if ! command -v rg >/dev/null 2>&1; then
  printf 'ERROR: ripgrep (rg) not found on PATH.\n' >&2
  exit 127
fi

PATTERNS=(
  # --- identity / org names ---
  # Specific org / customer / handle / device literals are NOT listed here: they
  # live in the gitignored forbidden-names.txt (layer 2, private-names.sh) so the
  # committed guard does not itself disclose them. Only generic shapes below.
  'customer-[a-z0-9]'
  # --- network identity ---
  '\.ts\.net' # any tailnet hostname (the lab's prior tailnet host is scrubbed)
  'tailscale|tailnet'
  # --- real host / user paths ---
  # (?-i: …) keeps this ONE pattern case-sensitive under the global -i: macOS home
  # paths are literally "/Users/…", while lowercase "…/users/…" appears in benign
  # prose (e.g. "dashboards/users/annotations") and URL paths.
  '(?-i:/Users/[A-Za-z0-9._-]+)' # real absolute home paths -> require <repo-root>/$HOME/mac-local
  'MacBook-Pro\.local'           # default-form macOS device hostname (add custom short names to forbidden-names.txt)
  # --- runtime assumption forbidden by spec (lab is Lima, not colima) ---
  '\bcolima\b'
  # --- legacy / forbidden infra artifacts ---
  'bitnamilegacy'         # frozen/paywalled Bitnami images
  ':3090[0-9]|:3091[0-9]' # NodePorts (30903/30904/30911/30917) — port-forward only
  # --- credential / token prefixes (lab secrets must be fnox+age, never literals) ---
  'sk-lm-'                    # LM Studio token prefix
  'pk-lf-|sk-lf-'             # Langfuse public/secret key prefixes
  'sk-litellm-'               # LiteLLM key prefix
  'sk-ant-[A-Za-z0-9_-]{20,}' # Anthropic key shape
  '\bsk-[A-Za-z0-9_-]{20,}'   # generic OpenAI-style key shape
  '(ghp|gho|ghs|ghr|github_pat)_[0-9A-Za-z_]{20,}'
  'AKIA[0-9A-Z]{16}'
  'BEGIN ([A-Z]+ )?PRIVATE KEY'
  '-dev-2026' # the lab's old deterministic dev-secret suffix
  # --- emails: allow ONLY the placeholder domain ---
  '[A-Za-z0-9._%+-]+@(?!ai-infra-platform\.example)[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
)

# Scope: scan the PUBLISHABLE working tree. Excluded by definition (not published
# as-is, so their literals are not leaks):
#   - the guard/validator tasks themselves (.config/mise/tasks/validate/*,
#     .config/mise/lib/render-all.sh) — they MUST name the forbidden forms
#     (type: NodePort, .ts.net, colima, …) to check for them;
#   - the lib data files (forbidden-names.txt[.example]) — operator pattern lists;
#   - the codex/claude smoke tasks + the secret generator (lib/secrets.sh) — they
#     MUST name the key/host FORMATS (sk-litellm-*, pk-lf-*, sk-lf-*) they generate
#     or grep for; the actual secret values are random and never live here;
#   - helm chart CACHES (kubernetes/<c>/charts/**) — fetched upstream build
#     artifacts, gitignored, not authored content;
#   - planning/** — the pre-publication source-of-truth specs that the guard exists
#     to scrub FROM; they intentionally contain the raw literals.
# NOT excluded (real leaks must surface here): .claude/, .codex/, docs/, README.md,
# and every authored kubernetes/ manifest.
EXCLUDES=(
  -g '!.git'
  -g '!.config/mise/tasks/validate/*'
  -g '!.config/mise/lib/render-all.sh'
  -g '!.config/mise/lib/forbidden-names.txt'
  -g '!.config/mise/lib/forbidden-names.txt.example'
  -g '!.config/mise/tasks/codex/smoke.sh'
  -g '!.config/mise/tasks/claude/smoke.sh'
  -g '!.config/mise/lib/secrets.sh'

  -g '!**/charts/**'
  -g '!planning/**'
  -g '!.agents/skills/**'
)

fail=0
for p in "${PATTERNS[@]}"; do
  # -P (PCRE2) needed for the email negative-lookahead. -i so case variants
  # (Colima, Tailscale, Bitnamilegacy, …) cannot slip past. `-e "$p"` is REQUIRED so
  # a pattern that begins with a dash (e.g. -dev-2026) is treated as a pattern, not a flag.
  if rg -nPi --hidden --no-heading "${EXCLUDES[@]}" -e "$p" .; then
    echo "SCRUB GUARD: forbidden pattern matched: $p" >&2
    fail=1
  fi
done

# Layer 2: operator-maintained private-names rg guard (if present).
if [[ -f "${repo_root}/.config/mise/tasks/validate/private-names.sh" && -f "${repo_root}/.config/mise/lib/forbidden-names.txt" ]]; then
  if ! bash "${repo_root}/.config/mise/tasks/validate/private-names.sh"; then
    echo "SCRUB GUARD: private-names guard failed." >&2
    fail=1
  fi
fi

# Layers 3 + 4: rendered no-Bitnami and no-NodePort proofs (only if a render is
# possible — skip cleanly when there are no overlays or helm repos are offline).
if [[ -f "${repo_root}/.config/mise/lib/render-all.sh" && -d "${repo_root}/kubernetes" ]]; then
  if rendered="$(bash "${repo_root}/.config/mise/lib/render-all.sh" 2>/dev/null)" && [[ -n "${rendered}" ]]; then
    if printf '%s' "${rendered}" | rg -n 'bitnami(legacy)?/|docker\.io/bitnami/|registry-1\.docker\.io/bitnamicharts'; then
      echo "SCRUB GUARD: Bitnami reference survived into rendered output." >&2
      fail=1
    fi
    # NodePort is forbidden in rendered output (port-forward only). hostPort/0.0.0.0
    # are NOT checked here: the Cilium CNI agent legitimately uses hostPort and the
    # in-pod Envoy metrics listener binds 0.0.0.0 in its own netns; matching those in
    # rendered upstream charts would false-positive. Authored-YAML bind hygiene is
    # covered by the source PATTERNS scan above.
    # nodePort: matched only with a numeric value — a bare `nodePort:` key appears in
    # CRD openAPIV3Schema field definitions (not a real NodePort Service).
    if printf '%s' "${rendered}" | rg -n 'type:[[:space:]]*NodePort|nodePort:[[:space:]]*[0-9]'; then
      echo "SCRUB GUARD: NodePort survived into rendered output." >&2
      fail=1
    fi
  else
    echo "scrub-guard: skipping rendered checks (no overlays or helm repos offline)." >&2
  fi
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "scrub-guard: clean (no forbidden publication-unsafe tokens)."
fi
exit "$fail"
