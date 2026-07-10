#!/usr/bin/env bash
#MISE description="Assert the §8c spend-log credential scrub is active: newest chatgpt/anthropic passthrough rows are masked and no cleartext OAuth credential survives in any header carrier."
# .config/mise/tasks/litellm/verify-scrub.sh — §8c credential-scrub regression assertion.
#
# WHY THIS EXISTS
# ---------------
# kubernetes/litellm/pylogging-config.yaml §8c wraps litellm's
# `add_litellm_data_to_request` to mask the forwarded subscription credentials
# (Claude Max OAuth token, ChatGPT OAuth JWT + chatgpt-account-id) out of the
# `LiteLLM_SpendLogs.proxy_server_request` snapshot before it is persisted. That
# patch is VERSION-COUPLED and FAIL-OPEN: if a future litellm image renames/moves
# the wrapped symbol or reshapes the snapshot, the patch silently no-ops and the
# cleartext credentials return to the DB (and the admin Logs API) with only a
# warning log. Nothing else would notice. This task is the loud tripwire: run it
# after gateway traffic exists and it asserts the credentials are actually masked.
#
# WHAT IT ASSERTS (Postgres db `litellm`, table "LiteLLM_SpendLogs")
# ------------------------------------------------------------------
# The persisted `proxy_server_request` jsonb IS the request body snapshot (no
# `body` wrapper on disk — litellm stores just `psr["body"]`). §8c masks credential
# VALUES under three header CARRIER paths and drops a duplicate carrier:
#   - extra_headers                         (codex/Responses passthrough carrier)
#   - litellm_metadata.headers              (claude carrier)
#   - metadata.headers                      (defence-in-depth carrier)
#   - provider_specific_header  (KEY dropped entirely from the snapshot)
# So, scoping STRICTLY to those carrier paths (never message content — prompts can
# legitimately mention token-shaped strings, which a whole-row LIKE would false-flag):
#   (1) the newest chatgpt/* row AND the newest anthropic/* row that carry a header
#       path must show the ***REDACTED*** mask, must NOT contain a cleartext
#       credential, and must NOT retain the provider_specific_header key;
#   (2) ZERO rows total may carry a cleartext credential in any carrier path —
#       sk-ant-oat (Claude token), `Bearer ey` (ChatGPT JWT), or a UUID-shaped
#       chatgpt-account-id value. A present-but-leaking row is a HARD failure that
#       names the offending request_id(s).
# If NO carrier-bearing gateway row exists yet (fresh cluster, pre-traffic) the
# assertion is explicitly SKIPPED (logged) — a skip is never reported as a pass.
#
# Read-only: a single SELECT over a `kubectl exec -i` psql stdin pipe into the CNPG
# primary. No mutations, no port-forward, no secrets echoed.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
# shellcheck source=.config/mise/lib/common.sh
source "${REPO_ROOT}/.config/mise/lib/common.sh"

install_err_trap

readonly NS="${LITELLM_NAMESPACE:-litellm}"
readonly PG_CLUSTER="${LITELLM_PG_CLUSTER:-litellm-pg}"
readonly PG_DB="${LITELLM_PG_DB:-litellm}"

# Discover the CNPG primary from the cluster's pod labels (data-integrity.sh idiom).
pg_primary() {
  kc -n "${NS}" get pods \
    -l "cnpg.io/cluster=${PG_CLUSTER},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ''
}

# run_scrub_query <primary> — pipe the assertion SQL over stdin into the primary's
# psql (-At: unaligned, tuples-only) and echo the labeled result lines. The three
# leak patterns are LIKE/regex over ONLY the header-carrier sub-objects, so a prompt
# that merely mentions a token string cannot produce a false positive. None of the
# patterns contains a LIKE metacharacter (% or _), so no ESCAPE clause is needed.
run_scrub_query() {
  local primary="$1"
  kc -n "${NS}" exec -i "${primary}" -c postgres -- \
    psql -U postgres -d "${PG_DB}" -At 2>/dev/null <<'SQL'
WITH carrier AS (
  SELECT
    request_id,
    "startTime" AS st,
    model,
    (proxy_server_request ? 'provider_specific_header') AS has_psh,
    -- Header carrier paths ONLY — never messages/response (avoids content false-positives).
    concat_ws(' ',
      (proxy_server_request -> 'extra_headers')::text,
      (proxy_server_request #> '{litellm_metadata,headers}')::text,
      (proxy_server_request #> '{metadata,headers}')::text,
      (proxy_server_request -> 'provider_specific_header')::text
    ) AS ct,
    ( (proxy_server_request ? 'extra_headers')
      OR (proxy_server_request #> '{litellm_metadata,headers}') IS NOT NULL
      OR (proxy_server_request #> '{metadata,headers}') IS NOT NULL
      OR (proxy_server_request ? 'provider_specific_header') ) AS has_carrier
  FROM "LiteLLM_SpendLogs"
),
leak AS (
  SELECT request_id FROM carrier
  WHERE ct LIKE '%sk-ant-oat%'                              -- Claude Max OAuth token
     OR ct LIKE '%Bearer ey%'                               -- ChatGPT OAuth JWT (codex)
     OR ct ~ 'chatgpt-account-id"\s*:\s*"[0-9a-f]{8}-'      -- codex account-id UUID value
),
gw AS (
  SELECT
    CASE WHEN model LIKE 'chatgpt/%' THEN 'chatgpt'
         WHEN model LIKE 'anthropic/%' THEN 'anthropic' END AS provider,
    request_id, st, has_psh, ct
  FROM carrier
  WHERE (model LIKE 'chatgpt/%' OR model LIKE 'anthropic/%') AND has_carrier
),
newest AS (
  SELECT DISTINCT ON (provider) provider, request_id, has_psh,
    (ct LIKE '%***REDACTED***%') AS has_redacted,
    (ct LIKE '%sk-ant-oat%'
     OR ct LIKE '%Bearer ey%'
     OR ct ~ 'chatgpt-account-id"\s*:\s*"[0-9a-f]{8}-') AS has_clear
  FROM gw
  ORDER BY provider, st DESC
)
SELECT 'GWROWS|' || (SELECT count(*) FROM gw)::text
UNION ALL
SELECT 'LEAK|' || COALESCE((SELECT string_agg(request_id, ',') FROM leak), '')
UNION ALL
SELECT 'NEWEST|' || provider || '|' || request_id || '|'
       || has_redacted::text || '|' || has_psh::text || '|' || has_clear::text
FROM newest
ORDER BY 1;
SQL
}

main() {
  require_cmd kubectl

  local primary
  primary="$(pg_primary)"
  [[ -n "${primary}" ]] ||
    die "no ${PG_CLUSTER} primary pod in ns ${NS} — is the litellm CNPG cluster up?"
  info "querying spend-log credential scrub state on ${primary} (db ${PG_DB})"

  local out
  out="$(run_scrub_query "${primary}")" || out=""
  [[ -n "${out}" ]] ||
    die "scrub query returned no rows — could not read \"LiteLLM_SpendLogs\" on ${primary}"

  local gwrows="0" leak=""
  local -a newest=()
  local line
  while IFS= read -r line; do
    case "${line}" in
    'GWROWS|'*) gwrows="${line#GWROWS|}" ;;
    'LEAK|'*) leak="${line#LEAK|}" ;;
    'NEWEST|'*) newest+=("${line#NEWEST|}") ;;
    esac
  done <<<"${out}"

  # (0) No gateway traffic yet -> explicit SKIP (never a pass).
  if [[ "${gwrows}" == "0" ]]; then
    warn "SKIP: no chatgpt/* or anthropic/* passthrough row with a header carrier exists yet"
    warn "SKIP: run a codex/claude gateway canary first (e.g. mise run codex:verify-gateway), then re-run"
    info "litellm:verify-scrub SKIPPED (no gateway traffic to assert against)"
    return 0
  fi

  local fail=0

  # (1) Global leak scan: ANY carrier path holding a cleartext credential is a hard fail.
  if [[ -n "${leak}" ]]; then
    err "FAIL: cleartext OAuth credential present in a spend-log header carrier"
    err "FAIL: offending request_id(s): ${leak}"
    err "FAIL: the §8c scrub (kubernetes/litellm/pylogging-config.yaml) is not masking —"
    err "FAIL: a litellm image bump likely renamed/reshaped add_litellm_data_to_request"
    fail=1
  fi

  # (2) Per-provider newest carrier-bearing row: must be masked, no leak, no duplicate carrier.
  local saw_chatgpt=0 saw_anthropic=0 rec provider request_id has_redacted has_psh has_clear
  for rec in "${newest[@]}"; do
    IFS='|' read -r provider request_id has_redacted has_psh has_clear <<<"${rec}"
    [[ "${provider}" == "chatgpt" ]] && saw_chatgpt=1
    [[ "${provider}" == "anthropic" ]] && saw_anthropic=1
    if [[ "${has_clear}" == "t" || "${has_clear}" == "true" ]]; then
      err "FAIL: newest ${provider} row ${request_id} carries a cleartext credential (scrub regressed)"
      fail=1
    elif [[ "${has_psh}" == "t" || "${has_psh}" == "true" ]]; then
      err "FAIL: newest ${provider} row ${request_id} retains provider_specific_header (§8c drop regressed)"
      fail=1
    elif [[ "${has_redacted}" != "t" && "${has_redacted}" != "true" ]]; then
      # Carrier present but no ***REDACTED*** and no cleartext: the snapshot shape moved
      # out from under §8c (masking now targets a path that no longer holds the header).
      err "FAIL: newest ${provider} row ${request_id} shows no ***REDACTED*** mask in any carrier — snapshot shape drift, §8c no longer covers it"
      fail=1
    else
      info "PASS: newest ${provider} row ${request_id} masked (***REDACTED***, no provider_specific_header, no cleartext)"
    fi
  done

  [[ "${saw_chatgpt}" -eq 1 ]] || warn "no chatgpt/* carrier-bearing row present — skipped that provider (run a codex canary to cover it)"
  [[ "${saw_anthropic}" -eq 1 ]] || warn "no anthropic/* carrier-bearing row present — skipped that provider (run a claude canary to cover it)"

  if [[ "${fail}" -ne 0 ]]; then
    die "litellm:verify-scrub FAILED — §8c credential scrub is not protecting spend logs"
  fi
  info "litellm:verify-scrub PASSED (§8c credential scrub active; ${gwrows} gateway carrier row(s) all masked)"
}

main "$@"
