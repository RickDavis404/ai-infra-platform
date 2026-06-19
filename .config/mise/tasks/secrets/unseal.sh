#!/usr/bin/env bash
#MISE description="Decrypt the fnox+age set into the gitignored secrets/shared.env.dec (names only logged)."
set -euo pipefail

# .config/mise/tasks/secrets/unseal.sh
# Decrypt the fnox+age sensitive set into the GITIGNORED secrets/shared.env.dec.
# Logs key NAMES and counts only — never a value. The caller is responsible for
# removing the .dec when done (the sync task does so under a trap).

# --- Resolve repo root + source the shared helpers (fall back if absent) ------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
_common="${REPO_ROOT}/.config/mise/lib/common.sh"
if [[ -f "$_common" ]]; then
  # shellcheck source=/dev/null
  source "$_common"
fi
if ! declare -F log_info >/dev/null 2>&1; then
  log_info() { printf '[info] %s\n' "$*" >&2; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn() { printf '[warn] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() {
    printf '[error] %s\n' "$*" >&2
    exit 1
  }
fi
if ! declare -F require_cmd >/dev/null 2>&1; then
  require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
fi

require_cmd fnox

secrets_dir="${REPO_ROOT}/secrets"
# Real ciphertext lives in the GITIGNORED repo-root fnox.local.toml (the committed
# fnox.toml is a marker-only template); the age key + .dec output stay under secrets/.
fnox_local="${REPO_ROOT}/fnox.local.toml"
age_key="${secrets_dir}/age/key.txt"
dec="${secrets_dir}/shared.env.dec" # GITIGNORED

[[ -f "$fnox_local" ]] || die "fnox.local.toml not found at repo root — run 'mise run secrets:keygen' then 'mise run secrets:seal' first."
if [[ -f "$age_key" && -z "${FNOX_AGE_KEY_FILE:-}" ]]; then
  export FNOX_AGE_KEY_FILE="$age_key"
fi

# The .dec output lives under secrets/, so operate from there; fnox is pointed
# explicitly at the local (ciphertext) store via -c — it is self-contained.
cd -- "$secrets_dir"

# Decrypt with a tight umask so the transient file is owner-only.
umask 077
# fnox export emits KEY=value lines for the whole sensitive set into the .dec file.
fnox -c "$fnox_local" export -f env -o "$dec" >/dev/null 2>&1 ||
  die "fnox export failed — is your age identity available (FNOX_AGE_KEY_FILE / Keychain)?"
chmod 600 "$dec" # macOS/BSD chmod rejects `--`

# Log key NAMES + count only; never the values.
mapfile -t keys < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$dec" | sed -E 's/=.*//' | sort -u)
log_info "Decrypted ${#keys[@]} key(s) into secrets/shared.env.dec (gitignored). Key names:"
for k in "${keys[@]}"; do
  log_info "  - ${k}"
done
log_warn "secrets/shared.env.dec contains DECRYPTED values — never commit it; remove it after use."
