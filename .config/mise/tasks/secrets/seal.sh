#!/usr/bin/env bash
#MISE description="Encrypt secrets/shared.env into the gitignored fnox.local.toml ciphertext (no values printed)."
set -euo pipefail

# .config/mise/tasks/secrets/seal.sh
# Encrypt the plaintext values in the gitignored secrets/shared.env into the GITIGNORED
# repo-root fnox.local.toml ciphertext, using the age recipients in secrets/.agerecipients.
# The committed repo-root fnox.toml stays a marker-only template — no ciphertext is ever
# written to a committed file. Logs key NAMES and counts only — never a value.

# --- Resolve repo root + source the shared helpers (fall back if absent) ------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
_common="${REPO_ROOT}/.config/mise/lib/common.sh"
if [[ -f "$_common" ]]; then
  # shellcheck source=/dev/null
  source "$_common"
fi
_secrets_lib="${REPO_ROOT}/.config/mise/lib/secrets.sh"
if [[ -f "$_secrets_lib" ]]; then
  # shellcheck source=/dev/null
  source "$_secrets_lib"
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
plain="${secrets_dir}/shared.env"
recipients_file="${secrets_dir}/.agerecipients"
# Ciphertext target is the GITIGNORED repo-root fnox.local.toml (created by
# secrets:keygen); the committed fnox.toml template is never written to. The age
# key, shared.env and .agerecipients still live under secrets/.
fnox_local="${REPO_ROOT}/fnox.local.toml"
age_key="${secrets_dir}/age/key.txt"
# Committed placeholder recipient to REFUSE sealing to (single source of truth in
# lib/secrets.sh, already sourced above; literal fallback is a set -u safety net). Was
# a stale rotated-out key (age1zrqtwy…) that no longer matched the committed recipient,
# so this refuse-to-seal guard was dead.
example_recipient="${AI_INFRA_PLACEHOLDER_AGE_RECIPIENT:-age1askmfmrkjf7ln3drgngdz2txt88nd4spgv52f6ekcu9hpv3gpy6skp79sf}"

[[ -f "$plain" ]] || die "secrets/shared.env not found — run 'mise run secrets:generate' first."
[[ -f "$recipients_file" ]] || die "secrets/.agerecipients not found."
[[ -f "$fnox_local" ]] || die "fnox.local.toml not found at repo root — run 'mise run secrets:keygen' first (it creates the gitignored local store)."

# Guard: refuse to seal to the committed docs/example recipient. It is public and
# safe to commit, but unusable for a local operator and would create undecryptable
# ciphertext for this machine.
if grep -qxF "${example_recipient}" "$recipients_file" ||
  grep -qF "${example_recipient}" "$fnox_local"; then
  die "age recipients still include the committed example recipient. Run 'mise run secrets:keygen' to sync your real public recipient first."
fi
if [[ -f "$age_key" ]]; then
  require_cmd age-keygen
  local_pub="$(age-keygen -y "$age_key" 2>/dev/null || true)"
  [[ -n "$local_pub" ]] || die "could not derive public recipient from secrets/age/key.txt"
  grep -qxF "$local_pub" "$recipients_file" ||
    die "secrets/.agerecipients does not include the local age public recipient. Run 'mise run secrets:keygen' to sync it."
  grep -qF "$local_pub" "$fnox_local" ||
    die "fnox.local.toml [providers].age does not include the local age public recipient. Run 'mise run secrets:keygen' to sync it."
fi

# shared.env and .agerecipients live under secrets/, so operate from there; fnox is
# pointed explicitly at the gitignored local store via -c.
cd -- "$secrets_dir"

# Enumerate the key NAMES present in secrets/shared.env without sourcing it and
# without an associative array (bash 3.2-safe). Values are read on demand via
# sv_get so a value is never word-split, run as a command, or logged. Duplicate
# keys collapse to one (sort -u), matching the previous last-write-wins map load.
present_keys=()
while IFS= read -r key; do
  [[ -n "$key" ]] && present_keys+=("$key")
done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$plain" | sed 's/=$//' | sort -u)
[[ "${#present_keys[@]}" -gt 0 ]] || die "no KEY=value lines found in secrets/shared.env"

known_unsealed_keys=(
  GRAFANA_ADMIN_USER
  LANGFUSE_INIT_USER_EMAIL
  LANGFUSE_INIT_USER_NAME
  LANGFUSE_INIT_USER_PASSWORD
  LANGFUSE_INIT_ORG_ID
  LANGFUSE_INIT_PROJECT_ID
  LANGFUSE_INIT_PROJECT_PUBLIC_KEY
  LANGFUSE_INIT_PROJECT_SECRET_KEY
)

missing=()
placeholders=()
for key in "${AI_INFRA_FNOX_SECRET_KEYS[@]}"; do
  if ! val="$(sv_get "$plain" "$key")"; then
    missing+=("${key}")
    continue
  fi
  if ai_infra_secret_is_placeholder "${val}"; then
    placeholders+=("${key}")
  fi
done

if ((${#missing[@]})); then
  log_warn "missing fnox-managed key(s): ${missing[*]}"
fi
if ((${#placeholders[@]})); then
  log_warn "placeholder/uninitialized fnox-managed key(s): ${placeholders[*]}"
fi
if ((${#missing[@]} || ${#placeholders[@]})); then
  die "secrets/shared.env is incomplete — run 'mise run secrets:generate' and then re-run 'mise run secrets:seal'."
fi

unknown=()
for key in "${present_keys[@]}"; do
  if ai_infra_key_in_list "$key" "${AI_INFRA_FNOX_SECRET_KEYS[@]}" ||
    ai_infra_key_in_list "$key" "${AI_INFRA_SHARED_ENV_OPTIONAL_KEYS[@]}" ||
    ai_infra_key_in_list "$key" "${known_unsealed_keys[@]}"; then
    continue
  fi
  unknown+=("$key")
done
if ((${#unknown[@]})); then
  log_warn "unrecognized shared.env key(s) will NOT be sealed: ${unknown[*]}"
fi

log_info "Sealing ${#AI_INFRA_FNOX_SECRET_KEYS[@]} fnox-managed key(s) into fnox.local.toml ciphertext (values never printed):"
for k in "${AI_INFRA_FNOX_SECRET_KEYS[@]}"; do
  log_info "  - ${k}: $(ai_infra_secret_description "$k")"
done
for k in "${AI_INFRA_SHARED_ENV_OPTIONAL_KEYS[@]}"; do
  if val="$(sv_get "$plain" "$k")" && ! ai_infra_secret_is_placeholder "${val}"; then
    log_warn "  - ${k}: present but intentionally NOT sealed ($(ai_infra_secret_description "$k"))"
  fi
done

# Import each plaintext key into fnox under the age provider, encrypting to the
# configured recipients. `fnox set` reads from stdin when VALUE is omitted, so the
# secret never appears in argv (ps) or logs.
sealed=0
for key in "${AI_INFRA_FNOX_SECRET_KEYS[@]}"; do
  sv_get "$plain" "$key" | fnox -c "$fnox_local" set --provider age "$key" >/dev/null ||
    die "fnox set failed for key: ${key}"
  sealed=$((sealed + 1))
done

log_info "Sealed ${sealed} key(s) into the gitignored fnox.local.toml. Keep secrets/shared.env private and gitignored; the committed fnox.toml template is untouched."
log_warn "Reminder: LANGFUSE_SALT and LANGFUSE_ENCRYPTION_KEY are write-once — never rotate after first boot."
