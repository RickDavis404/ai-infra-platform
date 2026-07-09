#!/usr/bin/env bash
#MISE description="Download the default GGUF chat model (pinned sha256 from models.lock) into the local models cache."
# .config/mise/tasks/models/fetch.sh — idempotent, checksum-pinned download of the
# default local chat model artifact.
#
# The repo's download URL + checksum convention lives in .config/mise/models.lock
# (versioned manifest). This task:
#   1. resolves the target path — AI_INFRA_DEFAULT_CHAT_MODEL_PATH if set, else the
#      installed llama-swap launchd plist, else the repo default cache path
#      (~/.cache/ai-infra/models/<filename from models.lock>);
#   2. if the file already exists, verifies its sha256 against the manifest and
#      exits 0 on match (no re-download);
#   3. otherwise downloads from the canonical Hugging Face URL to a .part file
#      (resumable), verifies the pinned sha256, then atomically moves it in place.
#
# A checksum mismatch is always fatal — the bad file is left as *.part (download)
# or reported (pre-existing) and never silently used.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

readonly MODELS_LOCK="${REPO_ROOT}/.config/mise/models.lock"
readonly LAUNCHD_PLIST="${AI_INFRA_LLAMA_SWAP_PLIST:-${HOME}/Library/LaunchAgents/com.ai-infra.llama-swap.plist}"

# Read a KEY=VALUE entry from the manifest without sourcing it.
lock_value() {
  local key="$1" value
  value="$(grep -E "^${key}=" "${MODELS_LOCK}" | head -n1 | cut -d= -f2-)"
  [[ -n "${value}" ]] || die "missing ${key} in $(basename -- "${MODELS_LOCK}")"
  printf '%s\n' "${value}"
}

expand_model_path() {
  local path="$1"
  case "${path}" in
  \~) printf '%s\n' "${HOME}" ;;
  \~/*) printf '%s/%s\n' "${HOME}" "${path#\~/}" ;;
  *) printf '%s\n' "${path}" ;;
  esac
}

read_plist_env_var() {
  local plist="$1" key="$2"
  [[ -f "${plist}" ]] || return 1
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:${key}" "${plist}" 2>/dev/null
    return $?
  fi
  if command -v plutil >/dev/null 2>&1; then
    plutil -extract "EnvironmentVariables.${key}" raw -o - "${plist}" 2>/dev/null
    return $?
  fi
  return 1
}

sha256_of() {
  shasum -a 256 -- "$1" | awk '{print $1}'
}

resolve_target_path() {
  local filename="$1" path
  if [[ -n "${AI_INFRA_DEFAULT_CHAT_MODEL_PATH:-}" ]]; then
    expand_model_path "${AI_INFRA_DEFAULT_CHAT_MODEL_PATH}"
    return 0
  fi
  if path="$(read_plist_env_var "${LAUNCHD_PLIST}" "AI_INFRA_DEFAULT_CHAT_MODEL_PATH")" &&
    [[ -n "${path}" && "${path}" != *"__HOME__"* ]]; then
    expand_model_path "${path}"
    return 0
  fi
  printf '%s/.cache/ai-infra/models/%s\n' "${HOME}" "${filename}"
}

main() {
  [[ -f "${MODELS_LOCK}" ]] || die "manifest not found: ${MODELS_LOCK}"
  require_cmd curl shasum

  local filename url want_sha want_size target dir part got_sha
  filename="$(lock_value DEFAULT_CHAT_MODEL_FILENAME)"
  url="$(lock_value DEFAULT_CHAT_MODEL_URL)"
  want_sha="$(lock_value DEFAULT_CHAT_MODEL_SHA256)"
  want_size="$(lock_value DEFAULT_CHAT_MODEL_SIZE_BYTES)"
  target="$(resolve_target_path "${filename}")"
  dir="$(dirname -- "${target}")"

  info "default chat model target: ${target}"
  info "pinned sha256: ${want_sha} (${want_size} bytes)"

  if [[ -f "${target}" ]]; then
    info "artifact already present; verifying checksum (may take a moment)"
    got_sha="$(sha256_of "${target}")"
    if [[ "${got_sha}" == "${want_sha}" ]]; then
      info "checksum OK — nothing to do"
      info "run 'mise run models:check' to confirm the full model preflight"
      return 0
    fi
    die "existing ${target} has sha256 ${got_sha}, expected ${want_sha} — move it aside and re-run models:fetch"
  fi

  mkdir -p "${dir}"
  part="${target}.part"
  info "downloading (resumable) from ${url}"
  curl -fL --retry 5 --retry-delay 5 -C - -o "${part}" "${url}"

  info "verifying downloaded checksum"
  got_sha="$(sha256_of "${part}")"
  if [[ "${got_sha}" != "${want_sha}" ]]; then
    die "downloaded file sha256 ${got_sha} does not match pinned ${want_sha} — refusing to install (partial file kept at ${part})"
  fi

  mv -f "${part}" "${target}"
  info "installed ${target}"
  info "run 'mise run models:check' to confirm the full model preflight"
}

main "$@"
