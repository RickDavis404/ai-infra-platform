#!/usr/bin/env bash
#MISE description="Verify the default local chat model path exists before LiteLLM smoke."
# .config/mise/tasks/models/check.sh — preflight the default local model artifact.
#
# The local LiteLLM route forwards mac-local/<alias> to the Mac-side llama-swap
# catalog. llama-swap resolves the GGUF path from AI_INFRA_DEFAULT_CHAT_MODEL_PATH
# or, when that env var is absent in the current task environment, from the
# installed launchd host-service plist.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

readonly DEFAULT_CHAT_MODEL="${AI_INFRA_DEFAULT_CHAT_MODEL:-}"
readonly MODEL_PATH_ENV="${AI_INFRA_DEFAULT_CHAT_MODEL_PATH:-}"
readonly LAUNCHD_PLIST="${AI_INFRA_LLAMA_SWAP_PLIST:-${HOME}/Library/LaunchAgents/com.ai-infra.llama-swap.plist}"
readonly STAGED_LLAMA_SWAP_CFG="${HOME}/.config/ai-infra/llama-swap.yaml"
readonly REPO_LLAMA_SWAP_CFG="${REPO_ROOT}/setup/mac-side/llama-swap.yaml"

fail=0
MODEL_PATH=""
MODEL_PATH_SOURCE=""

note_fail() {
  err "FAIL: $*"
  fail=1
}

display_path() {
  local path="$1"
  local home_marker="~"
  if [[ "${path}" == "${HOME}" ]]; then
    printf '%s\n' "${home_marker}"
  elif [[ "${path}" == "${HOME}/"* ]]; then
    printf '%s/%s\n' "${home_marker}" "${path#"${HOME}/"}"
  else
    printf '%s\n' "${path}"
  fi
}

expand_model_path() {
  local path="$1"
  case "${path}" in
  \~)
    printf '%s\n' "${HOME}"
    ;;
  \~/*)
    printf '%s/%s\n' "${HOME}" "${path#\~/}"
    ;;
  *)
    printf '%s\n' "${path}"
    ;;
  esac
}

read_plist_env_var() {
  local plist="$1"
  local key="$2"

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

resolve_model_path() {
  if [[ -n "${MODEL_PATH_ENV}" ]]; then
    MODEL_PATH="${MODEL_PATH_ENV}"
    MODEL_PATH_SOURCE="AI_INFRA_DEFAULT_CHAT_MODEL_PATH"
    return 0
  fi

  local path
  if path="$(read_plist_env_var "${LAUNCHD_PLIST}" "AI_INFRA_DEFAULT_CHAT_MODEL_PATH")" &&
    [[ -n "${path}" ]]; then
    MODEL_PATH="${path}"
    MODEL_PATH_SOURCE="$(display_path "${LAUNCHD_PLIST}")"
    return 0
  fi

  return 1
}

check_default_model_config() {
  if [[ -z "${DEFAULT_CHAT_MODEL}" ]]; then
    note_fail "AI_INFRA_DEFAULT_CHAT_MODEL is not configured"
    return
  fi

  info "default chat model configured: ${DEFAULT_CHAT_MODEL}"
  if [[ "${DEFAULT_CHAT_MODEL}" != mac-local/* ]]; then
    note_fail "AI_INFRA_DEFAULT_CHAT_MODEL must use the mac-local/ prefix for the default local route"
  fi
}

check_llama_swap_catalog() {
  [[ -n "${DEFAULT_CHAT_MODEL}" ]] || return
  [[ "${DEFAULT_CHAT_MODEL}" == mac-local/* ]] || return

  local alias="${DEFAULT_CHAT_MODEL#mac-local/}"
  local cfg="${STAGED_LLAMA_SWAP_CFG}"
  if [[ ! -f "${cfg}" ]]; then
    cfg="${REPO_LLAMA_SWAP_CFG}"
  fi

  if [[ ! -f "${cfg}" ]]; then
    note_fail "could not find llama-swap config to verify the default alias"
    return
  fi

  info "checking llama-swap catalog in $(display_path "${cfg}")"
  if grep -Fq "\"${alias}\":" "${cfg}"; then
    info "default alias present in llama-swap catalog: ${alias}"
  else
    note_fail "default alias '${alias}' is missing from $(display_path "${cfg}")"
  fi

  if grep -Fq 'AI_INFRA_DEFAULT_CHAT_MODEL_PATH' "${cfg}"; then
    info "default alias resolves its weights from AI_INFRA_DEFAULT_CHAT_MODEL_PATH"
  else
    note_fail "default alias does not reference AI_INFRA_DEFAULT_CHAT_MODEL_PATH in $(display_path "${cfg}")"
  fi
}

check_model_artifact() {
  if ! resolve_model_path; then
    note_fail "AI_INFRA_DEFAULT_CHAT_MODEL_PATH is unset and no installed launchd host-service path was found"
    return
  fi

  local expanded_path
  expanded_path="$(expand_model_path "${MODEL_PATH}")"
  info "model path source: ${MODEL_PATH_SOURCE}"

  if [[ "${expanded_path}" != /* ]]; then
    note_fail "model path must be absolute or use a leading ~/: $(display_path "${MODEL_PATH}")"
    return
  fi

  if [[ "${expanded_path}" == *"__HOME__"* ]]; then
    note_fail "model path still contains the launchd template placeholder __HOME__; run 'mise run host:up'"
    return
  fi

  if [[ ! -e "${expanded_path}" ]]; then
    note_fail "default model artifact is missing at $(display_path "${expanded_path}")"
    return
  fi

  if [[ "${expanded_path}" == *.gguf && ! -f "${expanded_path}" ]]; then
    note_fail "default GGUF path exists but is not a regular file: $(display_path "${expanded_path}")"
    return
  fi

  if [[ -f "${expanded_path}" && ! -s "${expanded_path}" ]]; then
    note_fail "default model artifact is empty: $(display_path "${expanded_path}")"
    return
  fi

  if [[ ! -r "${expanded_path}" ]]; then
    note_fail "default model artifact is not readable: $(display_path "${expanded_path}")"
    return
  fi

  info "default model artifact exists: $(display_path "${expanded_path}")"
}

print_remediation() {
  warn "Remediation:"
  warn "  Run 'mise run models:fetch' to download the default GGUF from its canonical Hugging Face repo"
  warn "  against the pinned sha256 in .config/mise/models.lock (idempotent; verifies checksum)."
  warn "  Alternatively place an already-obtained GGUF at the configured path, or set"
  warn "  AI_INFRA_DEFAULT_CHAT_MODEL_PATH to the real local path."
  warn "  If llama-swap runs under launchd, keep $(display_path "${LAUNCHD_PLIST}") in sync and reload the service."
  warn "  Rerun this check before running 'mise run litellm:smoke'."
  warn "  See docs/configuration.md#host-model-configuration and docs/troubleshooting.md#default-local-model-artifact-is-missing."
}

main() {
  check_default_model_config
  check_llama_swap_catalog
  check_model_artifact

  if [[ "${fail}" -ne 0 ]]; then
    print_remediation
    die "models check FAILED — see failures above"
  fi

  info "models check PASSED"
}

main "$@"
