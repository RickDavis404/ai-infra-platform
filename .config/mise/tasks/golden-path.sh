#!/usr/bin/env bash
#MISE description="Run the publish golden path with per-step logs and timing under .local/reports."
set -euo pipefail

# golden-path records the operator-facing publish gate without hiding the cost of
# each phase. Reports stay under .local/ because logs can contain local machine
# paths, private VIPs, or other environment-specific diagnostics.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"

timestamp_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

duration() {
  local start="$1" end="$2"
  printf '%ss' "$((end - start))"
}

append_summary_row() {
  local label="$1" status="$2" elapsed="$3" log_path="$4"
  local rel_log="${log_path#"${REPO_ROOT}"/}"
  printf "| \`%s\` | %s | %s | \`%s\` |\n" "${label}" "${status}" "${elapsed}" "${rel_log}" >>"${SUMMARY_FILE}"
}

run_step() {
  local label="$1"
  shift
  local safe_label="${label//[^[:alnum:]_.-]/_}"
  local log_file="${REPORT_DIR}/${safe_label}.log"
  local start end rc status

  info "=== golden-path: ${label} ==="
  {
    printf '# %s\n' "${label}"
    printf 'started_at=%s\n' "$(timestamp_utc)"
    printf 'command='
    printf '%q ' "$@"
    printf '\n\n'
  } >"${log_file}"

  start="$(date +%s)"
  if "$@" 2>&1 | tee -a "${log_file}"; then
    rc=0
    status="PASS"
  else
    rc=$?
    status="FAIL (${rc})"
  fi
  end="$(date +%s)"

  {
    printf '\nfinished_at=%s\n' "$(timestamp_utc)"
    printf 'duration=%s\n' "$(duration "${start}" "${end}")"
    printf 'exit_code=%s\n' "${rc}"
  } >>"${log_file}"

  append_summary_row "${label}" "${status}" "$(duration "${start}" "${end}")" "${log_file}"
  return "${rc}"
}

main() {
  require_cmd date mkdir mise tee

  local report_root="${AI_INFRA_GOLDEN_REPORT_DIR:-${REPO_ROOT}/.local/reports/golden-path}"
  local run_id
  run_id="$(date -u '+%Y%m%dT%H%M%SZ')"
  REPORT_DIR="${report_root}/${run_id}"
  SUMMARY_FILE="${REPORT_DIR}/summary.md"
  export REPORT_DIR SUMMARY_FILE

  mkdir -p "${REPORT_DIR}"
  {
    printf '# Golden Path Run\n\n'
    printf -- "- Started: \`%s\`\n" "$(timestamp_utc)"
    printf -- "- Repo: \`%s\`\n" "${REPO_ROOT}"
    printf -- "- Include init: \`%s\`\n" "${AI_INFRA_GOLDEN_INCLUDE_INIT:-0}"
    printf -- "- Include HA: \`%s\`\n\n" "${AI_INFRA_GOLDEN_INCLUDE_HA:-0}"
    printf "| Step | Result | Duration | Log |\n"
    printf "| --- | --- | ---: | --- |\n"
  } >"${SUMMARY_FILE}"

  if [[ "${AI_INFRA_GOLDEN_INCLUDE_HA:-0}" == "1" && "${AI_INFRA_ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    die "AI_INFRA_GOLDEN_INCLUDE_HA=1 requires AI_INFRA_ALLOW_DESTRUCTIVE=1"
  fi

  if [[ "${AI_INFRA_GOLDEN_INCLUDE_INIT:-0}" == "1" ]]; then
    run_step "init" mise run init || die "golden path stopped at init; see ${SUMMARY_FILE}"
  fi

  run_step "validate" mise run validate || die "golden path stopped at validate; see ${SUMMARY_FILE}"
  run_step "secrets:check" mise run secrets:check || die "golden path stopped at secrets:check; see ${SUMMARY_FILE}"
  run_step "up" mise run up || die "golden path stopped at up; see ${SUMMARY_FILE}"
  run_step "lima:smoke" mise run lima:smoke || die "golden path stopped at lima:smoke; see ${SUMMARY_FILE}"
  run_step "k8s:health" mise run k8s:health || die "golden path stopped at k8s:health; see ${SUMMARY_FILE}"
  run_step "smoke" mise run smoke || die "golden path stopped at smoke; see ${SUMMARY_FILE}"

  if [[ "${AI_INFRA_GOLDEN_INCLUDE_HA:-0}" == "1" ]]; then
    run_step "smoke:ha" mise run smoke:ha || die "golden path stopped at smoke:ha; see ${SUMMARY_FILE}"
  fi

  printf -- "\n- Finished: \`%s\`\n" "$(timestamp_utc)" >>"${SUMMARY_FILE}"
  info "golden path complete; summary: ${SUMMARY_FILE}"
}

main "$@"
