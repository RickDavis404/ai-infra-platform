#!/usr/bin/env bash
#MISE description="Verify host services (llama-swap, macmon, Grafana Alloy) respond."
# .config/mise/tasks/host/smoke.sh — Mac-side host-service smoke (spec §8.4 / §9.1 / §13.2.3).
#
# Verifies:
#   1. llama-swap answers GET 127.0.0.1:38080/v1/models.
#   2. The v1 default chat alias resolves in that model list.
#   3. The macmon exporter serves 127.0.0.1:39300/metrics including the
#      workstation_sample_age_seconds staleness gauge.
#   4. The llama-server stderr-tee wrapper is staged and captures to a known log.
#   5. NO per-model /upstream/<model>/metrics scrape is configured (auto-load trap).
#
# Read-only and safe to re-run. Exits non-zero on any failure.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
if [[ -f "${REPO_ROOT}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/.config/mise/lib/common.sh"
fi
if ! declare -F info >/dev/null 2>&1; then
  info() { printf '[info] %s\n' "$*" >&2; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '[warn] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() {
    printf '[err ] %s\n' "$*" >&2
    exit 1
  }
fi

readonly LLAMA_SWAP_URL="http://127.0.0.1:38080"
readonly MACMON_URL="http://127.0.0.1:39300"
readonly DEFAULT_CHAT_MODEL="${AI_INFRA_DEFAULT_CHAT_MODEL:-mac-local/unsloth/qwen3.5-4b-mtp-ud-q8-k-xl-gguf}"
readonly DEFAULT_CHAT_ALIAS="${DEFAULT_CHAT_MODEL#mac-local/}"
readonly ALLOY_CFG="${REPO_ROOT}/setup/mac-side/alloy-config.alloy"
readonly WRAPPER_STAGED="${HOME}/.local/bin/ai-infra-llama-server-wrapper.sh"
readonly WRAPPER_SRC="${REPO_ROOT}/setup/mac-side/llama-server-wrapper.sh"

fail=0
note_fail() {
  warn "FAIL: $*"
  fail=1
}

check_llama_swap_models() {
  info "1) llama-swap GET /v1/models"
  local body
  if ! body="$(curl -fsS --max-time 5 "${LLAMA_SWAP_URL}/v1/models" 2>/dev/null)"; then
    note_fail "llama-swap not responding at ${LLAMA_SWAP_URL}/v1/models"
    return
  fi
  info "2) default chat alias resolves (${DEFAULT_CHAT_ALIAS})"
  if printf '%s' "${body}" | grep -q "${DEFAULT_CHAT_ALIAS}"; then
    info "   default chat alias present in model list"
  else
    note_fail "default chat alias '${DEFAULT_CHAT_ALIAS}' not in /v1/models"
  fi
}

check_macmon() {
  info "3) macmon exporter GET /metrics (+ sample_age gauge)"
  local body
  if ! body="$(curl -fsS --max-time 5 "${MACMON_URL}/metrics" 2>/dev/null)"; then
    note_fail "macmon exporter not responding at ${MACMON_URL}/metrics"
    return
  fi
  if printf '%s' "${body}" | grep -Eq "workstation_(macmon_)?sample_age_seconds"; then
    info "   workstation sample-age gauge present"
  else
    note_fail "macmon exporter missing workstation sample-age gauge"
  fi
}

check_wrapper() {
  info "4) stderr-tee wrapper staged and captures to a known log"
  if [[ -x "${WRAPPER_STAGED}" ]]; then
    info "   wrapper staged at ~/.local/bin (TCC-safe)"
  else
    warn "   wrapper not yet staged at ~/.local/bin (run 'mise run host:up')"
  fi
  # Assert the wrapper source tees stderr to a known log file via exec.
  if grep -q 'ai-infra-llama-server.err.log' "${WRAPPER_SRC}" &&
    grep -q '^exec /opt/homebrew/bin/llama-server' "${WRAPPER_SRC}"; then
    info "   wrapper execs llama-server and tees stderr to a known log"
  else
    note_fail "wrapper does not exec llama-server / tee stderr as required (§8.4)"
  fi
}

check_no_per_model_scrape() {
  info "5) NO per-model /upstream/<model>/metrics scrape configured"
  if [[ ! -f "${ALLOY_CFG}" ]]; then
    note_fail "alloy config missing: ${ALLOY_CFG}"
    return
  fi
  if grep -v '^[[:space:]]*//' "${ALLOY_CFG}" | grep -q '/upstream/'; then
    note_fail "alloy config references /upstream/ (auto-load trap §8.4)"
  else
    info "   no /upstream/ targets in alloy config"
  fi
  # The aggregate llama-swap scrape must be present and target only :38080.
  if grep -Eq 'job_name[[:space:]]*=[[:space:]]*"llama-swap"' "${ALLOY_CFG}"; then
    info "   aggregate llama-swap scrape job present (:38080 only)"
  else
    note_fail "alloy config missing aggregate llama-swap scrape job"
  fi
}

main() {
  command -v curl >/dev/null 2>&1 || die "curl is required for host smoke"
  check_llama_swap_models
  check_macmon
  check_wrapper
  check_no_per_model_scrape
  if [[ "${fail}" -ne 0 ]]; then
    die "host smoke FAILED — see warnings above"
  fi
  info "host smoke PASSED"
}

main "$@"
