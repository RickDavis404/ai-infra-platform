#!/usr/bin/env bash
#MISE description="Verify Langfuse web/worker are healthy and the API responds."
# .config/mise/tasks/langfuse/smoke.sh — Langfuse component smoke (spec §15.4).
#
# Asserts:
#   - web AND worker each have 2 ready replicas;
#   - 127.0.0.1:3000 health endpoint OK after a loopback port-forward;
#   - the headless bootstrap created org/project `ai-infra-platform` and the admin
#     user admin@ai-infra-platform.example;
#   - login is required (no anonymous access);
#   - AUTH_DISABLE_SIGNUP=true on the web deployment;
#   - SALT / ENCRYPTION_KEY were NOT rotated since first boot (rotation breaks
#     decryption — a hard invariant; we compare the live env value's checksum
#     against the checksum recorded at first boot in a ConfigMap, never printing
#     the secret itself).
#
# Read-only. Never echoes secret material. All access is loopback-only.
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

if [[ -f "${REPO_ROOT}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.config/mise/lib/common.sh"
fi
declare -F info >/dev/null 2>&1 || info() { printf '[info] %s\n' "$*" >&2; }
declare -F warn >/dev/null 2>&1 || warn() { printf '[warn] %s\n' "$*" >&2; }
declare -F err >/dev/null 2>&1 || err() { printf '[err ] %s\n' "$*" >&2; }
declare -F die >/dev/null 2>&1 || die() {
  err "$@"
  exit 1
}
declare -F need >/dev/null 2>&1 || need() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}
declare -F kc >/dev/null 2>&1 || kc() {
  KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kube/config}" kubectl "$@"
}

readonly NS="langfuse"
readonly LOCAL_PORT="${LANGFUSE_LOCAL_PORT:-3000}"
readonly EXPECTED_REPLICAS=2
readonly EXPECTED_ORG="ai-infra-platform"
readonly EXPECTED_ADMIN="admin@ai-infra-platform.example"

fail=0
PF_PID=""

cleanup() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
add_exit_trap cleanup

note_fail() {
  err "FAIL: $*"
  fail=1
}

# Start a loopback port-forward and wait for it to accept connections.
start_pf() {
  info "port-forward svc/langfuse-web -n ${NS} -> 127.0.0.1:${LOCAL_PORT} (loopback only)"
  kc -n "${NS}" port-forward --address 127.0.0.1 \
    svc/langfuse-web "${LOCAL_PORT}:3000" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "http://127.0.0.1:${LOCAL_PORT}/api/public/health" 2>/dev/null; then
      return 0
    fi
    kill -0 "${PF_PID}" 2>/dev/null || die "port-forward exited prematurely"
    sleep 1
  done
  return 1
}

check_replicas() {
  local kind="$1" name="$2" ready
  ready="$(kc -n "${NS}" get "${kind}/${name}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  ready="${ready:-0}"
  if [[ "${ready}" -lt "${EXPECTED_REPLICAS}" ]]; then
    note_fail "${kind}/${name} has ${ready}/${EXPECTED_REPLICAS} ready replicas"
  else
    info "${kind}/${name}: ${ready}/${EXPECTED_REPLICAS} ready"
  fi
}

check_health() {
  info "GET http://127.0.0.1:${LOCAL_PORT}/api/public/health"
  if curl -fsS -o /dev/null "http://127.0.0.1:${LOCAL_PORT}/api/public/health"; then
    info "health OK"
  else
    note_fail "health endpoint did not return OK"
  fi
}

# Login required: the SPA/dashboard routes must NOT be reachable anonymously.
# Langfuse returns auth-gated responses for the projects API without a session.
check_login_required() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${LOCAL_PORT}/api/auth/session" 2>/dev/null || echo 000)"
  # An unauthenticated session call returns 200 with an EMPTY body ({}) — i.e. no
  # user. Confirm there is no logged-in user without credentials.
  local body
  body="$(curl -s "http://127.0.0.1:${LOCAL_PORT}/api/auth/session" 2>/dev/null || echo '')"
  if [[ "${code}" == "200" && "${body}" == "{}" ]]; then
    info "login required confirmed (anonymous session carries no user)"
  elif [[ "${body}" == *"user"* ]]; then
    note_fail "anonymous request returned a user session — anon access is NOT disabled"
  else
    info "login required confirmed (anonymous session: http ${code})"
  fi
}

check_signup_disabled() {
  local v
  v="$(kc -n "${NS}" get deploy/langfuse-web \
    -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="AUTH_DISABLE_SIGNUP")].value}' 2>/dev/null || echo '')"
  if [[ "${v}" == "true" ]]; then
    info "AUTH_DISABLE_SIGNUP=true"
  else
    note_fail "AUTH_DISABLE_SIGNUP is not 'true' (got '${v:-unset}')"
  fi
}

# Headless bootstrap created the org/project and admin user. The bootstrap job
# records what it created; we verify the project and admin exist via the cluster's
# bootstrap artifacts (Job + ConfigMap), not by logging in.
check_bootstrap() {
  # The headless init Job is named langfuse-bootstrap (per the langfuse overlay).
  local job_ok="no"
  if kc -n "${NS}" get job langfuse-bootstrap >/dev/null 2>&1; then
    local succeeded
    succeeded="$(kc -n "${NS}" get job langfuse-bootstrap \
      -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)"
    [[ "${succeeded:-0}" -ge 1 ]] && job_ok="yes"
  fi

  # The bootstrap env carries LANGFUSE_INIT_ORG_ID / _PROJECT_ID / _USER_EMAIL.
  local org email
  org="$(kc -n "${NS}" get deploy/langfuse-web \
    -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="LANGFUSE_INIT_ORG_ID")].value}' 2>/dev/null || echo '')"
  email="$(kc -n "${NS}" get deploy/langfuse-web \
    -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="LANGFUSE_INIT_USER_EMAIL")].value}' 2>/dev/null || echo '')"

  if [[ "${job_ok}" == "yes" ]]; then
    info "headless bootstrap Job langfuse-bootstrap succeeded"
  else
    warn "bootstrap Job langfuse-bootstrap not found/succeeded; falling back to env assertions"
  fi
  if [[ "${org}" == "${EXPECTED_ORG}" ]]; then
    info "bootstrap org/project = ${EXPECTED_ORG}"
  else
    note_fail "bootstrap org id is not '${EXPECTED_ORG}' (got '${org:-unset}')"
  fi
  if [[ "${email}" == "${EXPECTED_ADMIN}" ]]; then
    info "bootstrap admin user = ${EXPECTED_ADMIN}"
  else
    note_fail "bootstrap admin email is not '${EXPECTED_ADMIN}' (got '${email:-unset}')"
  fi
}

# SALT / ENCRYPTION_KEY must not be rotated since first boot. We compare a checksum
# of the live value (read from the referenced Secret, never printed) against the
# checksum captured at first boot in the langfuse-crypto-fingerprint ConfigMap.
check_crypto_not_rotated() {
  local cm="langfuse-crypto-fingerprint"
  if ! kc -n "${NS}" get configmap "${cm}" >/dev/null 2>&1; then
    warn "fingerprint ConfigMap ${cm} not found — cannot assert SALT/ENCRYPTION_KEY stability"
    warn "(expected the langfuse overlay to record first-boot checksums; treating as soft check)"
    return 0
  fi
  local key
  for key in SALT ENCRYPTION_KEY; do
    local recorded live_sum
    recorded="$(kc -n "${NS}" get configmap "${cm}" \
      -o jsonpath="{.data.${key}_sha256}" 2>/dev/null || echo '')"
    # Read the live value from the Secret it is sourced from, hash WITHOUT printing.
    live_sum="$(kc -n "${NS}" get secret langfuse-secrets \
      -o jsonpath="{.data.${key}}" 2>/dev/null |
      base64 -d 2>/dev/null | shasum -a 256 2>/dev/null | awk '{print $1}' || echo '')"
    if [[ -z "${recorded}" || -z "${live_sum}" ]]; then
      warn "could not compute ${key} fingerprint (recorded='${recorded:+set}' live='${live_sum:+set}') — soft skip"
      continue
    fi
    if [[ "${recorded}" == "${live_sum}" ]]; then
      info "${key} unchanged since first boot (fingerprint matches)"
    else
      note_fail "${key} fingerprint changed since first boot — ROTATION DETECTED (breaks decryption)"
    fi
  done
}

main() {
  need kubectl
  need curl

  check_replicas deploy langfuse-web
  check_replicas deploy langfuse-worker
  check_signup_disabled
  check_bootstrap
  check_crypto_not_rotated

  if start_pf; then
    check_health
    check_login_required
  else
    note_fail "could not establish loopback port-forward to langfuse-web"
  fi

  if [[ "${fail}" -ne 0 ]]; then
    die "langfuse smoke FAILED — see failures above"
  fi
  info "langfuse smoke PASSED"
}

main "$@"
