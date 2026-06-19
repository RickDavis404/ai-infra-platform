#!/usr/bin/env bash
#MISE description="Generate a new age key (one-time); print only the PUBLIC recipient."
set -euo pipefail

# .config/mise/tasks/secrets/keygen.sh
# Idempotent age key setup. Writes the age SECRET key to the gitignored
# secrets/age/key.txt when missing, derives the PUBLIC recipient when present,
# and keeps secrets/.agerecipients plus the GITIGNORED repo-root fnox.local.toml
# in sync (creating it from the committed fnox.toml template when missing). The
# committed template itself is never modified. Never prints the secret key.

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

require_cmd age-keygen

age_dir="${REPO_ROOT}/secrets/age"
key_file="${age_dir}/key.txt"
recipients_file="${REPO_ROOT}/secrets/.agerecipients"
# Recipients are synced into the GITIGNORED repo-root fnox.local.toml (created here
# when missing); the committed fnox.toml template is never modified.
fnox_local="${REPO_ROOT}/fnox.local.toml"
example_recipient="age1zrqtwyccjmjl9607qvthjm06c3vm3vu9egual3yzj33czh38nvkqw0wgvq"

toml_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

sync_recipient_files() {
  local pub="$1"
  local recipients=("${pub}")
  local line seen

  if [[ -f "${recipients_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -n "${line}" ]] || continue
      [[ "${line}" == "${example_recipient}" ]] && continue
      seen=0
      local r
      for r in "${recipients[@]}"; do
        [[ "${r}" == "${line}" ]] && seen=1
      done
      ((seen)) || recipients+=("${line}")
    done <"${recipients_file}"
  fi

  local tmp
  tmp="$(mktemp "${REPO_ROOT}/secrets/.agerecipients.tmp.XXXXXX")"
  {
    printf '# age public recipients (one per line). Committed; safe to publish.\n'
    printf '%s\n' "${recipients[@]}"
  } >"${tmp}"
  mv -f -- "${tmp}" "${recipients_file}"
  log_info "synced ${#recipients[@]} public recipient(s) into secrets/.agerecipients"

  # Bootstrap the gitignored local store on first run: a minimal self-contained
  # config ([providers].age placeholder replaced just below + empty [secrets]
  # that secrets:seal populates with ciphertext). 600 perms — owner-only.
  if [[ ! -f "${fnox_local}" ]]; then
    umask 077
    # shellcheck disable=SC2016  # backticks below are literal doc text, not expansions
    {
      printf '# fnox.local.toml — GITIGNORED local secret store (real age ciphertext lives here).\n'
      printf '# Created by `mise run secrets:keygen`; populated by `mise run secrets:seal`.\n'
      printf '# fnox merges this over the committed fnox.toml template (local wins).\n'
      printf 'default_provider = "age"\n\n'
      printf '[providers]\n'
      printf 'age = { type = "age", recipients = [] }\n\n'
      printf '[secrets]\n'
    } >"${fnox_local}"
    chmod 600 "${fnox_local}"
    log_info "created gitignored fnox.local.toml (local secret store)"
  fi
  local joined="" q
  for line in "${recipients[@]}"; do
    q="$(toml_quote "${line}")"
    if [[ -z "${joined}" ]]; then
      joined="${q}"
    else
      joined="${joined}, ${q}"
    fi
  done

  local replacement="age = { type = \"age\", recipients = [${joined}] }"
  tmp="$(mktemp "${REPO_ROOT}/fnox.local.toml.tmp.XXXXXX")"
  if ! awk -v replacement="${replacement}" '
    /^\[providers\]$/ { in_providers = 1; print; next }
    /^\[/ && $0 != "[providers]" { in_providers = 0 }
    in_providers && $0 ~ /^[[:space:]]*age[[:space:]]*=/ {
      print replacement
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        exit 42
      }
    }
  ' "${fnox_local}" >"${tmp}"; then
    rm -f -- "${tmp}"
    die "could not update [providers].age recipients in fnox.local.toml"
  fi
  mv -f -- "${tmp}" "${fnox_local}"
  chmod 600 "${fnox_local}" # mktemp/mv may loosen perms; keep owner-only
  log_info "synced public recipient list into fnox.local.toml [providers].age"
}

generate_new_key() {
  umask 077
  # age-keygen writes the secret key to the file and the public key line to stderr.
  age-keygen -o "$key_file" >/dev/null 2>"${key_file}.pub.tmp"
  chmod 600 "$key_file" # macOS/BSD chmod rejects `--`

  # Extract ONLY the public recipient line; never echo the secret key.
  pub="$(grep -Ei 'public key:' "${key_file}.pub.tmp" | sed -E 's/.*(age1[0-9a-z]+).*/\1/' || true)"
  rm -f -- "${key_file}.pub.tmp"

  if [[ -z "$pub" ]]; then
    # Fallback: derive the public recipient from the secret key without printing the key.
    pub="$(age-keygen -y "$key_file" 2>/dev/null || true)"
  fi
  [[ -n "$pub" ]] || die "could not determine age public recipient from generated key"
  log_info "age secret key written to secrets/age/key.txt (gitignored, mode 600)"
}

mkdir -p -- "$age_dir"
chmod 700 "$age_dir" # NOTE: macOS/BSD chmod rejects the `--` separator

pub=""
if [[ -f "$key_file" ]]; then
  pub="$(age-keygen -y "$key_file" 2>/dev/null || true)"
  [[ -n "$pub" ]] || die "could not derive age public recipient from existing secrets/age/key.txt"
  if [[ "$pub" == "$example_recipient" ]]; then
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup="${key_file}.backup-${stamp}"
    if [[ -e "$backup" ]]; then
      backup="${backup}.$$"
    fi
    mv "$key_file" "$backup"
    chmod 600 "$backup" # macOS/BSD chmod rejects `--`
    log_warn "existing age key matches the committed example recipient; moved it to ${backup#"$REPO_ROOT"/}"
    pub=""
  else
    log_info "age secret key already present at secrets/age/key.txt (not overwritten)"
  fi
fi

if [[ -z "$pub" ]]; then
  generate_new_key
fi

sync_recipient_files "$pub"

log_info "PUBLIC recipient:"
printf '%s\n' "$pub"

log_info "Reminder: never commit secrets/age/key.txt; recipients file is at ${recipients_file#"$REPO_ROOT"/}"
