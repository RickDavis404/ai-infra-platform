#!/usr/bin/env bash
# .config/mise/lib/common.sh - shared helper library for ai-infra-platform tasks.
#
# This file is meant to be sourced by task scripts:
#   source "${REPO_ROOT}/.config/mise/lib/common.sh"
#
# It provides structured stderr logging, task-native persisted logs, composable
# cleanup traps, repo-root resolution, command assertions, a kubectl wrapper, and
# fnox decrypt helpers that never log plaintext secret material.
set -euo pipefail

# Idempotent source marker. Re-sourcing redefines functions but does not install a
# second stream logger or reset already-registered cleanup hooks.
_AI_INFRA_COMMON_SH_SOURCED=1

if [[ -z "${_AI_INFRA_EXIT_TRAPS_READY:-}" ]]; then
  _AI_INFRA_USER_EXIT_TRAPS=()
  _AI_INFRA_EXIT_TRAPS_READY=1
fi

# --- Colors (disabled when not a TTY or NO_COLOR is set) -----------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _c_reset=$'\033[0m'
  _c_red=$'\033[31m'
  _c_yellow=$'\033[33m'
  _c_blue=$'\033[34m'
  _c_dim=$'\033[2m'
else
  _c_reset='' _c_red='' _c_yellow='' _c_blue='' _c_dim=''
fi

# --- Small primitives ----------------------------------------------------------
_ai_infra_timestamp_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_ai_infra_epoch() {
  date +%s
}

_ai_infra_shell_quote() {
  printf '%q' "$1"
}

_ai_infra_absolute_path() {
  local path="$1" dir base
  dir="$(dirname -- "${path}")"
  base="$(basename -- "${path}")"
  if [[ -d "${dir}" ]]; then
    printf '%s/%s\n' "$(cd -- "${dir}" >/dev/null 2>&1 && pwd -P)" "${base}"
  else
    printf '%s\n' "${path}"
  fi
}

_ai_infra_safe_name() {
  printf '%s' "$1" | sed -E 's#[^A-Za-z0-9._=-]+#_#g'
}

_ai_infra_safe_path() {
  local path="$1"
  path="${path#/}"
  path="${path%/}"
  path="$(printf '%s' "${path}" | sed -E 's#[^A-Za-z0-9._=/-]+#_#g; s#(^|/)\.\.(/|$)#_#g; s#/{2,}#/#g')"
  if [[ -z "${path}" ]]; then
    printf 'unknown\n'
  else
    printf '%s\n' "${path}"
  fi
}

# ai_infra_redact_log - best-effort redaction filter for persisted task logs.
# Keep this bash+sed only so logging works before optional tooling is installed.
ai_infra_redact_log() {
  sed -E \
    -e 's#([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*([Bb][Ee][Aa][Rr][Ee][Rr]|[Bb][Aa][Ss][Ii][Cc])[[:space:]]+)[A-Za-z0-9._~+/=-]+#\1<redacted>#g' \
    -e 's#(^|[^A-Za-z0-9_])([Bb][Ee][Aa][Rr][Ee][Rr]|[Bb][Aa][Ss][Ii][Cc])[[:space:]]+[A-Za-z0-9._~+/=-]{12,}#\1\2 <redacted>#g' \
    -e 's#(^|[^A-Z0-9])(AGE-SECRET-KEY-)[A-Z0-9]+#\1\2<redacted>#g' \
    -e 's#(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{16,}#\1<redacted>#g' \
    -e 's#([A-Za-z][A-Za-z0-9+.-]*://[^:/[:space:]@]+:)[^@/[:space:]]+@#\1<redacted>@#g' \
    -e 's#-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----#-----BEGIN <redacted> PRIVATE KEY-----#g' \
    -e 's#([Aa][Nn][Tt][Hh][Rr][Oo][Pp][Ii][Cc]_[Cc][Uu][Ss][Tt][Oo][Mm]_[Hh][Ee][Aa][Dd][Ee][Rr][Ss][[:space:]]*=[[:space:]]*)["'\'']?.*#\1<redacted>#g' \
    -e "s#((\"?)([Xx]-[Ll]itellm-[Aa]pi-[Kk]ey|authorization|api[_-]?key|secret([_-]?key)?|access[_-]?key|private[_-]?key|auth[_-]?token|token|password|passwd|pwd)\"?[[:space:]]*:[[:space:]]*([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]*)?)[\"']?[^\"',;[:space:]}]+[\"']?#\1<redacted>#g" \
    -e "s#(([Xx]-[Ll]itellm-[Aa]pi-[Kk]ey|authorization|api[_-]?key|secret([_-]?key)?|access[_-]?key|private[_-]?key|auth[_-]?token|token|password|passwd|pwd)[[:space:]]*=[[:space:]]*)[\"']?[^\"',;[:space:]}]+[\"']?#\1<redacted>#g" \
    -e "s#([A-Z0-9_]*(API_KEY|SECRET|TOKEN|PASSWORD|PASS|PRIVATE_KEY|ACCESS_KEY|AUTH_HEADER)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*)[\"']?[^\"',;[:space:]}]+[\"']?#\1<redacted>#g"
}

# --- Repo root resolution ------------------------------------------------------
# repo_root - print the absolute repo root. Prefers git, then walks upward from
# this library location, then falls back to three levels above .config/mise/lib.
repo_root() {
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
  if command -v git >/dev/null 2>&1 &&
    git -C "${here}" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "${here}" rev-parse --show-toplevel
    return 0
  fi

  local dir="${here}"
  while [[ "${dir}" != "/" ]]; do
    if [[ -e "${dir}/.git" ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
    dir="$(dirname -- "${dir}")"
  done
  printf '%s\n' "$(cd -- "${here}/../../.." >/dev/null 2>&1 && pwd -P)"
}

# --- Task-native persistent logging -------------------------------------------
_ai_infra_mise_metadata_set() {
  local key="$1" value="${2:-}"
  [[ -n "${_AI_INFRA_MISE_METADATA_FILE:-}" ]] || return 0
  [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  {
    printf '%s=' "${key}"
    _ai_infra_shell_quote "${value}"
    printf '\n'
  } >>"${_AI_INFRA_MISE_METADATA_FILE}" 2>/dev/null || true
}

_ai_infra_mise_write_event() {
  local level="$1"
  shift || true
  [[ -n "${_AI_INFRA_MISE_EVENTS_FILE:-}" ]] || return 0
  {
    printf '%s [%s] %s\n' "$(_ai_infra_timestamp_utc)" "${level}" "$*"
  } | ai_infra_redact_log >>"${_AI_INFRA_MISE_EVENTS_FILE}" 2>/dev/null || true
}

_ai_infra_mise_task_path_from_source() {
  local source_path="$1" root="$2" rel
  [[ -n "${source_path}" ]] || return 1
  source_path="$(_ai_infra_absolute_path "${source_path}")"
  case "${source_path}" in
  "${root}/.config/mise/tasks/"*.sh) ;;
  *) return 1 ;;
  esac

  rel="${source_path#"${root}/.config/mise/tasks/"}"
  rel="${rel%.sh}"
  case "${rel}" in
  */_default) rel="${rel%/_default}" ;;
  _default) rel="default" ;;
  esac
  _ai_infra_safe_path "${rel}"
}

_ai_infra_mise_log_finalize() {
  local rc="${1:-$?}" finished duration current_epoch
  [[ -n "${_AI_INFRA_MISE_METADATA_FILE:-}" ]] || return 0
  [[ "${_AI_INFRA_MISE_FINALIZED:-0}" != "1" ]] || return 0
  _AI_INFRA_MISE_FINALIZED=1

  finished="$(_ai_infra_timestamp_utc)"
  duration=0
  if [[ -n "${_AI_INFRA_MISE_STARTED_EPOCH:-}" ]]; then
    current_epoch="$(_ai_infra_epoch)"
    duration="$((current_epoch - _AI_INFRA_MISE_STARTED_EPOCH))"
  fi
  _ai_infra_mise_metadata_set "finished_at" "${finished}"
  _ai_infra_mise_metadata_set "duration_seconds" "${duration}"
  _ai_infra_mise_metadata_set "exit_code" "${rc}"
  _ai_infra_mise_write_event "info" "task finished exit=${rc} duration_seconds=${duration}"
}

mise_log_handoff() {
  local target="${1:-exec}"
  _ai_infra_mise_metadata_set "handoff_at" "$(_ai_infra_timestamp_utc)"
  _ai_infra_mise_metadata_set "handoff_to" "${target}"
  _ai_infra_mise_write_event "info" "task handed off via exec to ${target}"
}

_ai_infra_run_exit_traps() {
  local rc="${1:-$?}" i hook
  trap - EXIT
  set +e

  if [[ "${#_AI_INFRA_USER_EXIT_TRAPS[@]}" -gt 0 ]]; then
    for ((i = ${#_AI_INFRA_USER_EXIT_TRAPS[@]} - 1; i >= 0; i--)); do
      hook="${_AI_INFRA_USER_EXIT_TRAPS[$i]}"
      "${hook}"
    done
  fi

  _ai_infra_mise_log_finalize "${rc}"
  exit "${rc}"
}

_ai_infra_install_exit_trap_dispatcher() {
  if [[ "${_AI_INFRA_EXIT_TRAP_INSTALLED:-0}" != "1" ]]; then
    trap '_ai_infra_run_exit_traps "$?"' EXIT
    _AI_INFRA_EXIT_TRAP_INSTALLED=1
  fi
}

add_exit_trap() {
  if [[ "$#" -ne 1 || -z "${1:-}" ]]; then
    printf '[err ] add_exit_trap expects one no-argument cleanup function name\n' >&2
    return 2
  fi
  case "$1" in
  *[!A-Za-z0-9_]*)
    printf '[err ] add_exit_trap cleanup hook must be a function name: %s\n' "$1" >&2
    return 2
    ;;
  esac
  _AI_INFRA_USER_EXIT_TRAPS+=("$1")
  _ai_infra_install_exit_trap_dispatcher
}

clear_exit_traps() {
  _AI_INFRA_USER_EXIT_TRAPS=()
  _ai_infra_install_exit_trap_dispatcher
}

_ai_infra_mise_pump_stderr() {
  local fifo="$1" out_file="$2" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line}" >&9
    printf '%s\n' "${line}"
  done <"${fifo}" | ai_infra_redact_log >>"${out_file}"
}

_ai_infra_mise_pump_stdout() {
  local fifo="$1" out_file="$2" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line}" >&8
    printf '%s\n' "${line}"
  done <"${fifo}" | ai_infra_redact_log >>"${out_file}"
}

_ai_infra_mise_redirect_stderr() {
  [[ -n "${_AI_INFRA_MISE_STDERR_FILE:-}" ]] || return 0
  command -v mkfifo >/dev/null 2>&1 || return 0
  local fifo="${_AI_INFRA_MISE_TASK_LOG_DIR}/stderr.$$.fifo"
  if ! mkfifo "${fifo}" 2>/dev/null; then
    return 0
  fi
  exec 9>&2
  _ai_infra_mise_pump_stderr "${fifo}" "${_AI_INFRA_MISE_STDERR_FILE}" &
  exec 2>"${fifo}"
  rm -f -- "${fifo}" 2>/dev/null || true
}

_ai_infra_mise_redirect_stdout() {
  [[ -n "${_AI_INFRA_MISE_STDOUT_FILE:-}" ]] || return 0
  command -v mkfifo >/dev/null 2>&1 || return 0
  local fifo="${_AI_INFRA_MISE_TASK_LOG_DIR}/stdout.$$.fifo"
  if ! mkfifo "${fifo}" 2>/dev/null; then
    return 0
  fi
  exec 8>&1
  _ai_infra_mise_pump_stdout "${fifo}" "${_AI_INFRA_MISE_STDOUT_FILE}" &
  exec 1>"${fifo}"
  rm -f -- "${fifo}" 2>/dev/null || true
}

_ai_infra_mise_logging_init() {
  [[ "${_AI_INFRA_MISE_LOG_INITIALIZED:-0}" != "1" ]] || return 0
  _AI_INFRA_MISE_LOG_INITIALIZED=1

  local root source_path task_path task_name requested_mode effective_mode sensitive i
  root="$(repo_root)"
  task_path=""
  for ((i = 1; i < ${#BASH_SOURCE[@]}; i++)); do
    source_path="${BASH_SOURCE[$i]:-}"
    if task_path="$(_ai_infra_mise_task_path_from_source "${source_path}" "${root}")"; then
      break
    fi
    task_path=""
  done
  if [[ -z "${task_path}" ]]; then
    return 0
  fi

  task_name="${task_path//\//:}"
  requested_mode="${AI_INFRA_MISE_LOG_MODE:-default}"
  case "${requested_mode}" in
  default | debug | metadata | off) ;;
  *)
    printf '[warn] unknown AI_INFRA_MISE_LOG_MODE=%s; using default\n' "${requested_mode}" >&2
    requested_mode="default"
    ;;
  esac

  sensitive=0
  case "${task_name}" in
  secrets:* | codex:* | claude:*) sensitive=1 ;;
  esac

  effective_mode="${requested_mode}"
  if [[ "${effective_mode}" != "off" && "${sensitive}" == "1" ]]; then
    effective_mode="metadata"
  fi
  [[ "${effective_mode}" != "off" ]] || return 0

  local log_root run_date run_id run_root task_log_dir tasks_link_dir
  log_root="${AI_INFRA_MISE_LOG_DIR:-${root}/.local/logs/mise}"
  case "${log_root}" in
  /*) ;;
  *) log_root="${root}/${log_root}" ;;
  esac

  run_date="${AI_INFRA_MISE_LOG_RUN_DATE:-$(date -u '+%Y-%m-%d')}"
  run_id="${AI_INFRA_MISE_LOG_RUN_ID:-$(date -u '+%Y%m%dT%H%M%SZ')-$$}"
  run_date="$(_ai_infra_safe_name "${run_date}")"
  run_id="$(_ai_infra_safe_name "${run_id}")"
  export AI_INFRA_MISE_LOG_RUN_DATE="${run_date}"
  export AI_INFRA_MISE_LOG_RUN_ID="${run_id}"

  run_root="${log_root}/runs/${run_date}/${run_id}"
  task_log_dir="${run_root}/${task_path}"
  tasks_link_dir="${log_root}/tasks/${task_path}"
  if ! mkdir -p -- "${task_log_dir}" "${tasks_link_dir}" 2>/dev/null; then
    printf '[warn] could not create mise log directory under %s; persistent logging disabled\n' "${log_root}" >&2
    return 0
  fi

  _AI_INFRA_MISE_TASK_NAME="${task_name}"
  _AI_INFRA_MISE_TASK_PATH="${task_path}"
  _AI_INFRA_MISE_LOG_ROOT="${log_root}"
  _AI_INFRA_MISE_RUN_ROOT="${run_root}"
  _AI_INFRA_MISE_TASK_LOG_DIR="${task_log_dir}"
  _AI_INFRA_MISE_LOG_MODE="${effective_mode}"
  _AI_INFRA_MISE_STARTED_AT="$(_ai_infra_timestamp_utc)"
  _AI_INFRA_MISE_STARTED_EPOCH="$(_ai_infra_epoch)"
  _AI_INFRA_MISE_METADATA_FILE="${task_log_dir}/metadata.env"

  {
    printf 'task_name=%s\n' "$(_ai_infra_shell_quote "${task_name}")"
    printf 'task_path=%s\n' "$(_ai_infra_shell_quote "${task_path}")"
    printf 'run_id=%s\n' "$(_ai_infra_shell_quote "${run_id}")"
    printf 'run_date=%s\n' "$(_ai_infra_shell_quote "${run_date}")"
    printf 'log_mode_requested=%s\n' "$(_ai_infra_shell_quote "${requested_mode}")"
    printf 'log_mode_effective=%s\n' "$(_ai_infra_shell_quote "${effective_mode}")"
    printf 'sensitive_task=%s\n' "$(_ai_infra_shell_quote "${sensitive}")"
    printf 'started_at=%s\n' "$(_ai_infra_shell_quote "${_AI_INFRA_MISE_STARTED_AT}")"
    printf 'started_epoch=%s\n' "$(_ai_infra_shell_quote "${_AI_INFRA_MISE_STARTED_EPOCH}")"
    printf 'pid=%s\n' "$(_ai_infra_shell_quote "$$")"
  } >"${_AI_INFRA_MISE_METADATA_FILE}" 2>/dev/null || true

  ln -sfn "${run_root}" "${log_root}/latest-run" 2>/dev/null || true
  ln -sfn "${task_log_dir}" "${tasks_link_dir}/latest" 2>/dev/null || true

  if [[ "${effective_mode}" == "default" || "${effective_mode}" == "debug" ]]; then
    _AI_INFRA_MISE_EVENTS_FILE="${task_log_dir}/events.log"
    _AI_INFRA_MISE_STDERR_FILE="${task_log_dir}/stderr.log"
    : >"${_AI_INFRA_MISE_EVENTS_FILE}" 2>/dev/null || true
    : >"${_AI_INFRA_MISE_STDERR_FILE}" 2>/dev/null || true
    _ai_infra_mise_write_event "info" "task started"
    _ai_infra_mise_redirect_stderr
    if [[ "${effective_mode}" == "debug" ]]; then
      _AI_INFRA_MISE_STDOUT_FILE="${task_log_dir}/stdout.log"
      : >"${_AI_INFRA_MISE_STDOUT_FILE}" 2>/dev/null || true
      _ai_infra_mise_redirect_stdout
    fi
  fi

  _ai_infra_install_exit_trap_dispatcher
}

_ai_infra_mise_logging_init

# --- Logging (terminal stderr plus structured persisted events) ----------------
# Usage: log [LEVEL] <message...>. With one argument, LEVEL defaults to "log".
log() {
  local level message
  if [[ "$#" -eq 0 ]]; then
    return 0
  elif [[ "$#" -eq 1 ]]; then
    level="log"
    message="$1"
  else
    level="$1"
    shift
    message="$*"
  fi
  _ai_infra_mise_write_event "${level}" "${message}"
  printf '%s[%s]%s %s\n' "${_c_dim}" "${level}" "${_c_reset}" "${message}" >&2
}

info() {
  _ai_infra_mise_write_event "info" "$*"
  printf '%s[info]%s %s\n' "${_c_blue}" "${_c_reset}" "$*" >&2
}

warn() {
  _ai_infra_mise_write_event "warn" "$*"
  printf '%s[warn]%s %s\n' "${_c_yellow}" "${_c_reset}" "$*" >&2
}

err() {
  _ai_infra_mise_write_event "err" "$*"
  printf '%s[err ]%s %s\n' "${_c_red}" "${_c_reset}" "$*" >&2
}

# die <message...> - log an error and exit non-zero.
die() {
  err "$@"
  exit 1
}

# --- Binary presence assertions -----------------------------------------------
# need <binary> [hint] - assert a command exists on PATH, else die with guidance.
need() {
  local bin="$1"
  local hint="${2:-install it via Homebrew or 'mise install'}"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    die "required command '${bin}' not found on PATH - ${hint}"
  fi
}

# require_cmd <binary...> - assert each named command exists.
require_cmd() {
  local bin
  for bin in "$@"; do
    need "${bin}"
  done
}

# --- Error trap helper ---------------------------------------------------------
# on_err <line> - default handler invoked by the ERR trap. It deliberately omits
# BASH_COMMAND so persisted stderr never records command argv.
on_err() {
  local line="${1:-?}"
  local status=$?
  err "command failed (exit ${status}) at ${BASH_SOURCE[1]:-script}:${line}"
  exit "${status}"
}

# install_err_trap - install the standard ERR trap in the calling script.
install_err_trap() {
  trap 'on_err "${LINENO}"' ERR
}

# --- kubectl wrapper -----------------------------------------------------------
# kc <args...> - KUBECONFIG-aware kubectl. Honors an exported KUBECONFIG or falls
# back to the repo-local kubeconfig written by lima:kubeconfig.
kc() {
  need kubectl
  local kubeconfig="${KUBECONFIG:-$(repo_root)/.local/kube/config}"
  KUBECONFIG="${kubeconfig}" kubectl "$@"
}

# --- fnox secret decrypt helper (no secret echoed) -----------------------------
# fnox_decrypt <key> - resolve one age-encrypted secret via fnox and print only
# the plaintext value to stdout for callers to capture. Diagnostics go to stderr;
# the plaintext is never interpolated into a log line here.
fnox_decrypt() {
  need fnox
  local key="$1"
  if [[ -z "${key}" ]]; then
    die "fnox_decrypt: missing secret key argument"
  fi
  local age_key_file="${FNOX_AGE_KEY_FILE:-$(repo_root)/secrets/age/key.txt}"
  # `fnox get` resolves fnox.toml by walking up from CWD, so a caller invoked from a
  # temp dir OUTSIDE the repo (codex smoke + verify-gateway both `cd` to a mktemp
  # workdir before running the codex wrapper) fails with "No configuration file
  # found". Pin the config path to the repo copy rather than depending on CWD.
  local fnox_config
  fnox_config="$(repo_root)/fnox.toml"
  if [[ -f "${age_key_file}" ]]; then
    if ! FNOX_AGE_KEY_FILE="${age_key_file}" fnox get --config "${fnox_config}" "${key}" </dev/null; then
      die "fnox_decrypt: failed to resolve secret '${key}' (check age identity and fnox store)"
    fi
  elif ! fnox get --config "${fnox_config}" "${key}" </dev/null; then
    die "fnox_decrypt: failed to resolve secret '${key}' (check age identity and fnox store)"
  fi
}

# --- CNPG application-database name -------------------------------------------
# cnpg_app_db <namespace> <cluster> - print the application database name the CNPG
# cluster bootstraps. CNPG's own default is `app`, but this platform's langfuse
# cluster overrides it (spec.bootstrap.initdb.database), so callers that hardcode
# `psql -d app` fail with `database "app" does not exist`. Read it from the CR.
cnpg_app_db() {
  local ns="$1" cluster="$2" db
  db="$(kc -n "${ns}" get cluster "${cluster}" \
    -o jsonpath='{.spec.bootstrap.initdb.database}' 2>/dev/null || echo '')"
  printf '%s\n' "${db:-app}"
}

: "${_AI_INFRA_COMMON_SH_SOURCED}"
