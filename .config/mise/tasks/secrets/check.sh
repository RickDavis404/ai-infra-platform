#!/usr/bin/env bash
#MISE description="Preflight the fnox+age secret set without applying Kubernetes Secrets."
set -euo pipefail

# secrets:check — fail early if the fnox store cannot produce the key set that
# secrets:sync needs. Values are parsed only in memory and never printed.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/secrets.sh"
install_err_trap

readonly SECRETS_DIR="${REPO_ROOT}/secrets"
# Real ciphertext lives in the GITIGNORED repo-root fnox.local.toml (the committed
# fnox.toml is a marker-only template); the age key still lives under secrets/.
readonly FNOX_LOCAL="${REPO_ROOT}/fnox.local.toml"
readonly AGE_KEY="${SECRETS_DIR}/age/key.txt"
check_dec=""

cleanup() {
  [[ -z "${check_dec}" ]] || rm -f -- "${check_dec}"
}

required_keys=("${AI_INFRA_FNOX_SECRET_KEYS[@]}")

main() {
  require_cmd fnox
  [[ -f "${FNOX_LOCAL}" ]] || die "fnox.local.toml not found at repo root — run 'mise run secrets:keygen' then 'mise run secrets:seal' first."
  if [[ -f "${AGE_KEY}" && -z "${FNOX_AGE_KEY_FILE:-}" ]]; then
    export FNOX_AGE_KEY_FILE="${AGE_KEY}"
  fi

  check_dec="$(mktemp "${TMPDIR:-/tmp}/ai-infra-fnox-check.XXXXXX")"
  add_exit_trap cleanup

  info "checking fnox+age secrets before platform apply (key names only)"
  (
    umask 077
    fnox -c "${FNOX_LOCAL}" export -f env -o "${check_dec}" >/dev/null 2>&1
  ) || die "fnox export failed — is your age identity available (FNOX_AGE_KEY_FILE / Keychain)?"
  chmod 600 "${check_dec}"

  declare -A sv=()
  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%$'\r'}"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value#\"}"
      value="${value%\"}"
    fi
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    sv["${key}"]="${value}"
  done <"${check_dec}"

  local missing=() placeholders=()
  for key in "${required_keys[@]}"; do
    if [[ -z "${sv[${key}]+x}" ]]; then
      missing+=("${key}")
      continue
    fi
    case "${sv[${key}]}" in
    "" | CHANGEME-* | "<fnox+age-managed>") placeholders+=("${key}") ;;
    esac
  done

  if ((${#missing[@]})); then
    err "missing required fnox key(s): ${missing[*]}"
  fi
  if ((${#placeholders[@]})); then
    err "placeholder/uninitialized fnox key(s): ${placeholders[*]}"
  fi
  if ((${#missing[@]} || ${#placeholders[@]})); then
    die "secrets preflight failed — run 'mise run secrets:keygen', 'mise run secrets:generate', then 'mise run secrets:seal'."
  fi

  info "secrets preflight PASSED — ${#required_keys[@]} required key(s) are present"
}

main "$@"
