#!/usr/bin/env bash
#MISE description="READ-ONLY: ClickHouse Keeper (CHK) pods + Raft quorum health via direct in-pod 4lw probes (mntr/ruok on 127.0.0.1:2181)."
# .config/mise/tasks/clickhouse/keeper-status.sh — inspect the Raft coordination
# ensemble that backs the langfuse-ch CHI.
#
# Two READ-ONLY views:
#   1) CHK pods: the 3 Keeper StatefulSet pods (Ready/phase) — a 3-node ensemble
#      tolerates one loss (2/3 retains quorum).
#   2) Raft quorum: each Keeper is probed DIRECTLY via `kubectl exec` with the
#      4-letter-word commands `ruok` + `mntr` against 127.0.0.1:2181 (the Keeper
#      client port). The probe prefers `nc` and falls back to a bash /dev/tcp
#      redirection (the fallback must run under `bash -c`, NOT `sh -c`: /bin/sh in
#      the keeper image is busybox and has no /dev/tcp). Per node we report
#      zk_server_state (leader|follower) and, on the leader, zk_synced_followers
#      (followers only publish these counters on the leader). The overall verdict
#      is PASS only when exactly one leader is elected, every node answers `imok`,
#      and the leader reports all (N-1) followers synced.
#
# All probes are 4-letter-word reads (ruok/mntr) over a local TCP connection made
# from INSIDE each pod. NO mutations, no credentials needed, no secrets printed.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"

readonly NS="langfuse-data"
readonly CHK_LABEL="clickhouse-keeper.altinity.com/chk=langfuse-keeper"
readonly KEEPER_CLIENT_PORT="2181"

section() { printf '\n=== %s ===\n' "$*" >&2; }

# fourletter <pod> <word> — send a Keeper 4-letter-word command to the local
# client port from INSIDE the pod and print the response. Prefers nc; falls back
# to a bash /dev/tcp redirection when nc is absent. Read-only by construction.
fourletter() {
  local pod="$1" word="$2"
  # shellcheck disable=SC2016 # the single-quoted script expands inside the pod's bash
  kc -n "${NS}" exec "${pod}" -- bash -c '
    word="$1" port="$2"
    if command -v nc >/dev/null 2>&1; then
      printf "%s" "${word}" | nc -w 3 127.0.0.1 "${port}"
    else
      exec 3<>"/dev/tcp/127.0.0.1/${port}" || exit 1
      printf "%s" "${word}" >&3
      cat <&3
    fi
  ' probe "${word}" "${KEEPER_CLIENT_PORT}" 2>/dev/null || true
}

keeper_pods() {
  section "Keeper CHK pods (${NS})"
  if ! kc -n "${NS}" get pods -l "${CHK_LABEL}" >/dev/null 2>&1; then
    die "no Keeper pods for langfuse-keeper found in ${NS} (is langfuse-data up?)"
  fi
  kc -n "${NS}" get pods -l "${CHK_LABEL}" -o wide 2>/dev/null || true
}

raft_quorum() {
  section "Raft quorum (direct 4lw on 127.0.0.1:${KEEPER_CLIENT_PORT}: ruok + mntr)"
  local pods pod state synced leaders=0 total=0 imok_count=0 leader_synced=""
  pods="$(kc -n "${NS}" get pods -l "${CHK_LABEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "${pods}" ]]; then
    err "  no Keeper pods to query"
    return 1
  fi
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    total=$((total + 1))
    local mntr ruok
    ruok="$(fourletter "${pod}" "ruok" | tr -d '[:space:]')"
    mntr="$(fourletter "${pod}" "mntr")"
    state="$(printf '%s\n' "${mntr}" | awk '$1 == "zk_server_state" {print $2; exit}')"
    synced="$(printf '%s\n' "${mntr}" | awk '$1 == "zk_synced_followers" {print $2; exit}')"
    if [[ "${ruok}" == "imok" ]]; then
      imok_count=$((imok_count + 1))
    fi
    case "${state}" in
    leader)
      leaders=$((leaders + 1))
      leader_synced="${synced:-}"
      info "  ${pod}: zk_server_state=leader ruok=${ruok:-?} zk_synced_followers=${synced:-?}"
      ;;
    "")
      warn "  ${pod}: no mntr response (ruok=${ruok:-?}) — pod not serving?"
      ;;
    *)
      info "  ${pod}: zk_server_state=${state} ruok=${ruok:-?}"
      ;;
    esac
  done <<<"${pods}"

  printf -- '--- quorum verdict ---\n' >&2
  local expected_followers=$((total - 1))
  if [[ "${leaders}" -eq 1 && "${imok_count}" -eq "${total}" &&
    "${leader_synced}" == "${expected_followers}" ]]; then
    info "  PASS: 1 leader, ${imok_count}/${total} imok, ${leader_synced}/${expected_followers} followers synced"
    return 0
  fi
  if [[ "${leaders}" -gt 1 ]]; then
    err "  FAIL: SPLIT-BRAIN — ${leaders} leaders reported across ${total} keepers"
  elif [[ "${leaders}" -eq 0 ]]; then
    err "  FAIL: NO LEADER elected (${imok_count}/${total} imok) — quorum lost"
  else
    err "  FAIL: degraded — 1 leader but imok=${imok_count}/${total}, synced_followers=${leader_synced:-?}/${expected_followers}"
  fi
  return 1
}

main() {
  require_cmd kubectl awk
  local rc=0
  keeper_pods
  raft_quorum || rc=1
  section "summary"
  if [[ "${rc}" -ne 0 ]]; then
    err "keeper status: FAIL (see above)"
    exit 1
  fi
  info "keeper status: PASS — Raft quorum healthy"
}

main "$@"
