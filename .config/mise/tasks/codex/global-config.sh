#!/usr/bin/env bash
#MISE description="Merge the ai-infra [otel]/[history]/[hooks]/trust/provider blocks into the real ~/.codex/config.toml (timestamped backup, idempotent)."
# .config/mise/tasks/codex/global-config.sh — USER-layer Codex config merge.
#
# The repo no longer overrides CODEX_HOME, so bare `codex` reads ~/.codex/config.toml.
# `[otel]` (and, like it, the git-context `[hooks]` and the max-capture `[history]` pin)
# is DENIED / not-the-loaded-copy at the project layer (.codex/config.toml), and hooks are
# trust-gated, so the ONLY reliable place the telemetry exporters + persistence pin +
# git-context hook + project trust + inert litellm_local provider definition can live is
# the USER config. This task merges those blocks in, parse-aware and idempotent: a block
# that already exists is SKIPPED (a naive duplicate `[otel]` table would be a TOML parse
# error), unrelated keys are never touched, and the pre-merge file is backed up with a UTC
# timestamp. No secret is written — the LiteLLM auth header is injected at launch by the
# wrapper / launch task, never persisted here.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap
require_cmd python3

# Codex loads config from $CODEX_HOME/config.toml (default ~/.codex). Honoring
# CODEX_HOME keeps this task pointed at the same file codex reads AND gives tests a
# temp target; the repo no longer sets CODEX_HOME, so in practice this is ~/.codex.
codex_home="${CODEX_HOME:-${HOME}/.codex}"
config_toml="${codex_home}/config.toml"

# VIPs: substitute from the AI_INFRA_* env (init writes them to 99-local.toml) with the
# committed defaults — LB range start .200 => litellm .200, otel-collector .203.
litellm_vip="${AI_INFRA_LITELLM_VIP:-192.168.105.200}"
otel_vip="${AI_INFRA_OTEL_VIP:-192.168.105.203}"

mkdir -p "${codex_home}"

# --- Parse-aware, idempotent merge (python3 tomllib) ---------------------------
# Per-block presence check against the parsed existing TOML: append ONLY missing
# blocks, verify the merged result parses before writing. The timestamped backup
# (idiom: cluster/teardown.sh backup_plaintext_secrets — cp the RESOLVED,
# symlink-followed file, never overwrite an existing backup) is taken INSIDE the
# python step, and ONLY when >=1 block will actually be appended — so a fully
# idempotent re-run (nothing to merge) leaves the codex home untouched instead of
# accumulating an identical backup on every invocation.
CODEX_CONFIG_TOML="${config_toml}" \
  CODEX_ABS_REPO="${REPO_ROOT}" \
  CODEX_LITELLM_VIP="${litellm_vip}" \
  CODEX_OTEL_VIP="${otel_vip}" \
  python3 - <<'PY'
import datetime, os, shutil, sys, tomllib

path = os.environ["CODEX_CONFIG_TOML"]
abs_repo = os.environ["CODEX_ABS_REPO"]
litellm_vip = os.environ["CODEX_LITELLM_VIP"]
otel_vip = os.environ["CODEX_OTEL_VIP"]

try:
    with open(path, "rb") as fh:
        existing = fh.read()
    data = tomllib.loads(existing.decode("utf-8"))
    file_existed = True
except FileNotFoundError:
    existing = b""
    data = {}
    file_existed = False
except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
    sys.exit(f"refusing to merge: existing {path} is not valid UTF-8 TOML ({e})")


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


blocks = []

# [projects."<abs-repo>"] trust — marks THIS clone trusted so its project-layer
# .codex/config.toml is honored.
if data.get("projects", {}).get(abs_repo) is None:
    blocks.append(f'[projects."{esc(abs_repo)}"]\ntrust_level = "trusted"')
else:
    print(f'skip [projects."{abs_repo}"] (already present)', file=sys.stderr)

# [otel] — endpoints used VERBATIM (each carries its full /v1/* path); `protocol` is
# REQUIRED (no serde default). [otel] takes no timeout/flush keys (deny_unknown_fields);
# the x5 OTLP timeouts arrive via the shared env vars codex's exporters honor.
if "otel" not in data:
    blocks.append(
        "[otel]\n"
        'environment = "ai-infra-platform-local"\n'
        "log_user_prompt = true\n"
        f'exporter         = {{ otlp-http = {{ endpoint = "http://{otel_vip}:4318/v1/logs",    protocol = "binary" }} }}\n'
        f'trace_exporter   = {{ otlp-http = {{ endpoint = "http://{otel_vip}:4318/v1/traces",  protocol = "binary" }} }}\n'
        "# MANDATORY override: metrics default to statsig -> ships to OpenAI. otlp-http keeps them local.\n"
        f'metrics_exporter = {{ otlp-http = {{ endpoint = "http://{otel_vip}:4318/v1/metrics", protocol = "binary" }} }}'
    )
else:
    print("skip [otel] (already present)", file=sys.stderr)

# [analytics] — disable codex's own product analytics.
if "analytics" not in data:
    blocks.append("[analytics]\nenabled = false")
else:
    print("skip [analytics] (already present)", file=sys.stderr)

# [model_providers.litellm_local] — inert DEFINITION only; model_provider is NOT set
# here (selection is via the wrapper/tasks' -c overrides). No secrets written.
if data.get("model_providers", {}).get("litellm_local") is None:
    blocks.append(
        "[model_providers.litellm_local]\n"
        'name = "LiteLLM Local"\n'
        f'base_url = "http://{litellm_vip}:4000/v1"\n'
        "requires_openai_auth = true\n"
        'wire_api = "responses"\n'
        "supports_websockets = false\n"
        "stream_idle_timeout_ms = 900000"
    )
else:
    print("skip [model_providers.litellm_local] (already present)", file=sys.stderr)

# [history] — pin persistence EXPLICITLY to save-all (max-capture). max_bytes is
# DELIBERATELY omitted: its default is uncapped, so pinning it could only shrink the
# retained ~/.codex/history.jsonl. This USER-config copy is the one codex actually loads.
if "history" not in data:
    blocks.append('[history]\npersistence = "save-all"')
else:
    print("skip [history] (already present)", file=sys.stderr)

# [hooks] — codex git-context correlation hook (Lane D3). Codex reads the USER config once
# CODEX_HOME is retired, denies telemetry-class blocks at the project layer, and gates hooks
# behind per-machine trust, so — exactly like [otel] — the ONLY reliable, trusted home for a
# committed hook is here. PostToolUse / matcher "Bash|shell|local_shell" runs the shared
# script on shell tool-calls. The matcher is WIDENED (vs Claude's plain "Bash") because
# codex names its shell tool "shell"/"local_shell", NOT "Bash" (see otel-git-context.py
# ~L194) — a bare "Bash" would silently never fire the codex lane. The alternation stays
# targeted while covering both names; even so the script's command-payload regex is the real
# gate (it reads the codex hook JSON on stdin — session id, tool cmd/response — and emits an
# OTLP correlation span/metric/log keyed by session id). `timeout` is in SECONDS (900 == the
# plugin-hook ceiling). Only `command` handlers are honored (codex does not yet support
# async/prompt/agent hooks). A one-time "Hooks need review" trust approval is required per
# machine (or `codex ... --dangerously-bypass-hook-trust` for vetted automation).
if "hooks" not in data:
    hook_cmd = f'python3 "{abs_repo}/.config/hooks/otel-git-context.py"'
    blocks.append(
        "[[hooks.PostToolUse]]\n"
        'matcher = "Bash|shell|local_shell"\n'
        f'hooks = [{{ type = "command", command = "{esc(hook_cmd)}", timeout = 900 }}]'
    )
else:
    print("skip [hooks] (already present)", file=sys.stderr)

if not blocks:
    print("all ai-infra blocks already present; nothing to merge", file=sys.stderr)
    sys.exit(0)

header = existing
sep = b"" if (not header or header.endswith(b"\n")) else b"\n"
addition = (
    "\n# --- ai-infra-platform: codex USER-layer telemetry / history / hooks / trust / provider "
    "(managed by `mise run codex:global-config`) ---\n"
    + "\n\n".join(blocks)
    + "\n"
)
merged = header + sep + addition.encode("utf-8")

# Verify the merged result parses BEFORE writing (guards any block-construction slip).
try:
    tomllib.loads(merged.decode("utf-8"))
except tomllib.TOMLDecodeError as e:
    sys.exit(f"merge produced invalid TOML, aborting without write ({e})")

# Back up the pre-merge file — reached ONLY when >=1 block will be appended (the
# `if not blocks: sys.exit(0)` guard above returns first on an idempotent no-op run),
# so re-runs that merge nothing never litter the codex home with identical backups.
# cp -L semantics: copyfile reads THROUGH a symlink and writes a plain regular file;
# never overwrite an existing backup (append the pid on a same-second collision).
if file_existed:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = f"{path}.backup-{stamp}"
    if os.path.exists(backup):
        backup = f"{backup}.{os.getpid()}"
    shutil.copyfile(path, backup)
    os.chmod(backup, 0o600)
    print(f"backed up {path} -> {os.path.basename(backup)}", file=sys.stderr)
else:
    print(f"no existing {path}; a fresh one will be created", file=sys.stderr)

with open(path, "wb") as fh:
    fh.write(merged)

print(f"merged {len(blocks)} block(s) into {path}", file=sys.stderr)
PY

# No secrets are written, but keep the user config owner-only regardless of prior perms.
chmod 600 "${config_toml}"
info "codex:global-config complete (${config_toml})"
