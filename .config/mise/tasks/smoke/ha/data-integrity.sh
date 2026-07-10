#!/usr/bin/env bash
#MISE description="Write then read across a store restart to confirm no data loss."
# .config/mise/tasks/smoke/ha/data-integrity.sh — write-then-read across a store restart with
# no data loss (spec §15.6 stateful surfaces table).
#
# For each in-scope stateful store, write a uniquely-tagged canary, snapshot its
# fingerprint (checksum / row-count), RESTART the store, then re-read and assert a
# match. Any mismatch is corruption and fails the test. The three stores exercised:
#   - langfuse-pg (langfuse-data) and litellm-pg (litellm) — both CloudNativePG
#     clusters (the operator owns the instance pods directly; there is NO
#     StatefulSet), restarted via the CNPG-native `kubectl.kubernetes.io/restartedAt`
#     cluster annotation (rolls replicas first, primary last — quorum-preserving, no
#     kubectl-cnpg plugin dependency). One parameterized pg_* pass runs against each.
#     litellm-pg's restart transiently disrupts the gateway (its wait-for-postgres
#     init re-blocks until the primary serves), but that is in-policy here: the phase
#     is already gated behind AI_INFRA_ALLOW_DESTRUCTIVE=1 and the pod-loss phase
#     already cycles CNPG pods.
#   - ClickHouse — an Altinity CHI whose replicas ARE StatefulSets; a peer replica
#     is `rollout restart`ed (the survivor keeps serving reads — quorum-preserving)
#     and the replicated canary is read back from every replica after it recovers.
#
# Semantics (no silent skips): a store that is PRESENT but whose canary/restart/read
# fails is a HARD failure; a store that is genuinely ABSENT is an explicit logged
# skip and blocks the final PASSED line (the proof is then incomplete, not passed).
# The PASSED line therefore prints ONLY when all three stores were present, canaried,
# restarted, and re-read with a matching fingerprint.
#
# GATED behind AI_INFRA_ALLOW_DESTRUCTIVE=1 (a rolling restart is disruptive).
# Restores/cleans the canary after. No secrets echoed (the ClickHouse password is
# read INSIDE the pod from its injected env, never crossing the shell); loopback-only.
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

readonly DATA_NS="langfuse-data"
readonly RTO_TIMEOUT="${HA_RTO_TIMEOUT:-300}"
CANARY_TAG="ha-integ-$(date +%s)"
readonly CANARY_TAG
# The two in-scope CNPG stores as "namespace:cluster" pairs (the k8s/health.sh idiom).
# The pg_* helpers below are fully parameterized by (ns, cluster) and replay the same
# write -> restart -> read pass against each.
readonly PG_STORES=("langfuse-data:langfuse-pg" "litellm:litellm-pg")
FP_CH=""
# The ClickHouse pod that holds the canary (items[0] = chi-langfuse-ch-default-0-0-0);
# captured at write time so cleanup/restart target it deterministically.
CH_CANARY_POD=""
fail=0

# Per-store scratch (fingerprint + resolved application-DB name) is stashed in indirect
# variables keyed by the cluster name with dashes folded to underscores (the ${!var} /
# printf -v idiom already used in claude/smoke.sh and otel/smoke.sh), so the phased
# write/verify calls for the two clusters never clobber each other's state.
pg_key() { printf '%s' "${1//-/_}"; }

guard() {
  if [[ "${AI_INFRA_ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    die "refusing to run: DESTRUCTIVE test (rolling restarts). Set AI_INFRA_ALLOW_DESTRUCTIVE=1."
  fi
}
note_fail() {
  err "FAIL: $*"
  fail=1
}

# canary_db <ns> <cluster> — CNPG bootstraps each cluster's application DB under a
# non-default name (spec.bootstrap.initdb.database), so resolve it (once, lazily, per
# cluster) from the CR instead of assuming `app`.
canary_db() {
  local ns="$1" cluster="$2" var
  var="DB_$(pg_key "${cluster}")"
  [[ -n "${!var:-}" ]] || printf -v "${var}" '%s' "$(cnpg_app_db "${ns}" "${cluster}")"
  printf '%s\n' "${!var}"
}

# pg_present <ns> <cluster> — true iff the CNPG Cluster resource exists (the ABSENT
# vs PRESENT-but-broken distinction: absent is a logged skip, present-but-broken is a
# hard failure).
pg_present() {
  local ns="$1" cluster="$2"
  kc -n "${ns}" get cluster "${cluster}" >/dev/null 2>&1
}

pg_primary() {
  local ns="$1" cluster="$2"
  kc -n "${ns}" get pods \
    -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ''
}

ch_pod() {
  kc -n "${DATA_NS}" get pods -l 'clickhouse.altinity.com/chi=langfuse-ch' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ''
}

# --- Postgres (CNPG) ---
# pg_write <ns> <cluster> — assumes the cluster is PRESENT (main checks pg_present
# first). On any present-but-broken failure it records note_fail and returns 1 (so the
# other store's pass + cleanup still run, and the final FAILED gate fires); on success
# it stashes the fingerprint in FP_<cluster> and returns 0.
pg_write() {
  local ns="$1" cluster="$2" primary db fp var
  primary="$(pg_primary "${ns}" "${cluster}")"
  if [[ -z "${primary}" ]]; then
    note_fail "Postgres: ${ns}/${cluster} present but has no primary to write the canary"
    return 1
  fi
  db="$(canary_db "${ns}" "${cluster}")"
  info "Postgres: writing canary row ${CANARY_TAG} to ${ns}/${cluster} (db ${db})"
  if ! kc -n "${ns}" exec "${primary}" -c postgres -- \
    psql -At -d "${db}" -c \
    "CREATE TABLE IF NOT EXISTS ha_canary(tag text primary key, ts timestamptz default now());
     INSERT INTO ha_canary(tag) VALUES ('${CANARY_TAG}') ON CONFLICT DO NOTHING;" >/dev/null; then
    note_fail "Postgres: ${ns}/${cluster} canary write failed"
    return 1
  fi
  fp="$(kc -n "${ns}" exec "${primary}" -c postgres -- \
    psql -At -d "${db}" -c "SELECT count(*)||':'||md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
  if [[ -z "${fp}" ]]; then
    note_fail "Postgres: ${ns}/${cluster} could not snapshot the canary fingerprint"
    return 1
  fi
  var="FP_$(pg_key "${cluster}")"
  printf -v "${var}" '%s' "${fp}"
  return 0
}

# CNPG owns the cluster's pods directly (there is NO <cluster> StatefulSet), so the
# plugin-free equivalent of `kubectl cnpg restart` is to stamp the cluster with the
# restartedAt annotation the operator watches — it then rolls every instance (replicas
# first, primary last). A fresh timestamp + --overwrite guarantees the value changes so
# the roll always fires. We capture ONE replica pod's UID first and wait for it to
# disappear (proves the restart was not a no-op) AND for the operator to report the
# cluster healthy again — this closes the vacuous instant-pass the old dead-STS path had.
# Records any failure via note_fail (the `fail` accumulator is the single hard-fail
# signal, as with pg_verify) and always returns 0, so the bare call in main() cannot
# trip `set -e` and skip cleanup + the final FAILED gate.
pg_restart() {
  local ns="$1" cluster="$2" old_replica_uid
  old_replica_uid="$(kc -n "${ns}" get pods \
    -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=replica" \
    -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || echo '')"
  if [[ -z "${old_replica_uid}" ]]; then
    note_fail "Postgres: no ${ns}/${cluster} replica pod to observe across restart"
    return 0
  fi
  info "Postgres: CNPG rolling restart of cluster ${ns}/${cluster} (restartedAt annotation)"
  if ! kc -n "${ns}" annotate cluster "${cluster}" \
    "kubectl.kubernetes.io/restartedAt=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --overwrite >/dev/null; then
    note_fail "Postgres: failed to annotate cluster ${ns}/${cluster} for restart"
    return 0
  fi
  if pg_wait_restarted "${ns}" "${cluster}" "${old_replica_uid}"; then
    info "Postgres: CNPG rolling restart of ${ns}/${cluster} complete (replica cycled, cluster healthy)"
  else
    note_fail "Postgres: CNPG rolling restart of ${ns}/${cluster} did not complete within ${RTO_TIMEOUT}s"
  fi
  return 0
}

# Wait until (a) the captured replica UID is gone from the cluster's pod set (the pod
# was actually recreated — not an instant no-op) AND (b) the operator reports the
# cluster healthy with every instance ready. Bounded by RTO so a genuine stuck restart
# still fails the phase.
pg_wait_restarted() {
  local ns="$1" cluster="$2" old_uid="$3" elapsed=0 present phase ready instances
  while :; do
    present="$(kc -n "${ns}" get pods -l "cnpg.io/cluster=${cluster}" \
      -o jsonpath="{.items[?(@.metadata.uid=='${old_uid}')].metadata.uid}" 2>/dev/null || echo '')"
    phase="$(kc -n "${ns}" get cluster "${cluster}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    ready="$(kc -n "${ns}" get cluster "${cluster}" \
      -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo '')"
    instances="$(kc -n "${ns}" get cluster "${cluster}" \
      -o jsonpath='{.status.instances}' 2>/dev/null || echo '')"
    if [[ -z "${present}" && "${phase}" == "Cluster in healthy state" &&
      -n "${instances}" && "${instances}" != "0" && "${ready}" == "${instances}" ]]; then
      return 0
    fi
    if [[ "${elapsed}" -ge "${RTO_TIMEOUT}" ]]; then
      err "Postgres: ${ns}/${cluster} rolling restart incomplete after ${RTO_TIMEOUT}s (old-replica-still-present=${present:+yes}, phase='${phase}', ready=${ready:-?}/${instances:-?})"
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

pg_verify() {
  local ns="$1" cluster="$2" primary fp var want
  var="FP_$(pg_key "${cluster}")"
  want="${!var:-}"
  primary="$(pg_primary "${ns}" "${cluster}")"
  if [[ -z "${primary}" ]]; then
    note_fail "Postgres: no ${ns}/${cluster} primary after restart"
    return
  fi
  fp="$(kc -n "${ns}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db "${ns}" "${cluster}")" -c "SELECT count(*)||':'||md5(string_agg(tag,'')) FROM ha_canary;" 2>/dev/null || echo '')"
  if [[ -n "${want}" && "${fp}" == "${want}" ]]; then
    info "Postgres: ${ns}/${cluster} fingerprint match after restart"
  else
    note_fail "Postgres: ${ns}/${cluster} fingerprint MISMATCH after restart (${fp} != ${want})"
  fi
}
pg_cleanup() {
  local ns="$1" cluster="$2" primary
  primary="$(pg_primary "${ns}" "${cluster}")"
  [[ -n "${primary}" ]] || return 0
  kc -n "${ns}" exec "${primary}" -c postgres -- \
    psql -At -d "$(canary_db "${ns}" "${cluster}")" -c "DELETE FROM ha_canary WHERE tag='${CANARY_TAG}';" >/dev/null 2>&1 || true
}

# --- ClickHouse (Replicated table) ---
# ch_client <pod> <sql> — run a query inside a CH pod authenticated with the pod's
# OWN injected default-user password. The secret is read inside the pod and never
# crosses the shell boundary; stderr is NOT suppressed so real ClickHouse errors
# (auth, DDL, distributed-DDL) surface and fail the phase.
ch_client() {
  local pod="$1" sql="$2"
  # shellcheck disable=SC2016 # $CONFIGURATION_USERS_DEFAULT_PASSWORD expands inside the pod, not here
  kc -n "${DATA_NS}" exec "${pod}" -- env CH_SQL="${sql}" bash -c \
    'clickhouse-client --user default --password "$CONFIGURATION_USERS_DEFAULT_PASSWORD" -q "$CH_SQL"'
}

ch_write() {
  CH_CANARY_POD="$(ch_pod)"
  if [[ -z "${CH_CANARY_POD}" ]]; then
    warn "ClickHouse: no pod found — component ABSENT, skipping CH integrity"
    return 1
  fi
  info "ClickHouse: creating ON CLUSTER replicated canary + writing row ${CANARY_TAG}"
  # ON CLUSTER default creates the table on every replica via the distributed-DDL
  # queue; the ReplicatedMergeTree {shard}/{replica} macros give a single shard path
  # with per-replica names, so the INSERT below actually replicates (the old plain
  # CREATE landed on one replica only and never exercised replication).
  ch_client "${CH_CANARY_POD}" \
    "CREATE TABLE IF NOT EXISTS default.ha_canary ON CLUSTER default (tag String, ts DateTime DEFAULT now())
       ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/ha_canary','{replica}') ORDER BY tag;
     INSERT INTO default.ha_canary(tag) VALUES ('${CANARY_TAG}');" >/dev/null ||
    die "ClickHouse canary write failed (pod present — hard failure)"
  FP_CH="$(ch_client "${CH_CANARY_POD}" \
    "SELECT count() FROM default.ha_canary WHERE tag='${CANARY_TAG}';" || echo '')"
  [[ -n "${FP_CH}" ]] || die "ClickHouse: could not snapshot canary fingerprint"
  return 0
}

# Restart the replica StatefulSet that does NOT own the canary pod (discovered
# dynamically — the STS names are chi-langfuse-ch-default-0-<r>, never hardcoded),
# so the survivor keeps serving reads while its peer restarts (quorum-preserving).
ch_restart() {
  local owner peer_sts sts
  owner="$(kc -n "${DATA_NS}" get pod "${CH_CANARY_POD}" \
    -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || echo '')"
  peer_sts=""
  while IFS= read -r sts; do
    [[ -n "${sts}" ]] || continue
    [[ "${sts}" == "${owner}" ]] && continue
    peer_sts="${sts}"
    break
  done < <(kc -n "${DATA_NS}" get sts -l 'clickhouse.altinity.com/chi=langfuse-ch' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [[ -z "${peer_sts}" ]]; then
    # Single-replica CH: no peer to restart, so restart the canary's own replica (still
    # a genuine restart — the read-back after it recovers proves on-disk durability).
    peer_sts="${owner}"
    warn "ClickHouse: only one replica StatefulSet; restarting the canary's own replica"
  fi
  if [[ -z "${peer_sts}" ]]; then
    note_fail "ClickHouse: could not resolve a replica StatefulSet to restart"
    return 0
  fi
  info "ClickHouse: rolling restart statefulset/${peer_sts} (peer replica; quorum preserved)"
  if ! kc -n "${DATA_NS}" rollout restart "statefulset/${peer_sts}" >/dev/null; then
    note_fail "ClickHouse: rollout restart ${peer_sts} failed"
    return 0
  fi
  if ! kc -n "${DATA_NS}" rollout status "statefulset/${peer_sts}" --timeout="${RTO_TIMEOUT}s" >/dev/null; then
    note_fail "ClickHouse: rollout status ${peer_sts} did not complete within ${RTO_TIMEOUT}s"
    return 0
  fi
  return 0
}

# Read the canary back from EVERY replica after the restart: the survivor proves reads
# never lost the row (quorum preserved), and the restarted replica proves the
# replicated row survived that pod's restart (on-disk durability).
ch_verify() {
  local pods pod fp seen=0
  pods="$(kc -n "${DATA_NS}" get pods -l 'clickhouse.altinity.com/chi=langfuse-ch' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "${pods}" ]]; then
    note_fail "ClickHouse: no pods after restart"
    return
  fi
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    seen=1
    fp="$(ch_client "${pod}" \
      "SELECT count() FROM default.ha_canary WHERE tag='${CANARY_TAG}';" || echo '')"
    if [[ -n "${fp}" && "${fp}" == "${FP_CH}" ]]; then
      info "ClickHouse: canary present on ${pod} after restart (count match: ${fp})"
    else
      note_fail "ClickHouse: canary count MISMATCH on ${pod} after restart (${fp} != ${FP_CH})"
    fi
  done <<<"${pods}"
  [[ "${seen}" -eq 1 ]] || note_fail "ClickHouse: no pod to verify canary after restart"
}
ch_cleanup() {
  [[ -n "${CH_CANARY_POD}" ]] || return 0
  ch_client "${CH_CANARY_POD}" \
    "ALTER TABLE default.ha_canary ON CLUSTER default DELETE WHERE tag='${CANARY_TAG}';" >/dev/null 2>&1 || true
}

main() {
  guard
  need kubectl
  info "=== DATA-INTEGRITY (write -> restart -> read) proof ==="

  # PRESENT-BUT-BROKEN is a hard failure (note_fail -> fail=1); genuinely ABSENT is a
  # logged skip that blocks the final PASSED line. Both CNPG stores (langfuse-pg,
  # litellm-pg) and ClickHouse are gated identically. Successfully-canaried stores are
  # collected as "ns:cluster" so restart/verify/cleanup replay the exact same pass;
  # absent stores are recorded to block PASSED.
  local pair ns cluster
  local -a pg_ok=() pg_absent=()
  for pair in "${PG_STORES[@]}"; do
    ns="${pair%%:*}"
    cluster="${pair#*:}"
    if ! pg_present "${ns}" "${cluster}"; then
      warn "Postgres: CNPG cluster ${ns}/${cluster} not found — component ABSENT, skipping"
      pg_absent+=("${ns}/${cluster}")
      continue
    fi
    if pg_write "${ns}" "${cluster}"; then
      pg_ok+=("${pair}")
    fi
  done

  local ch_present=0
  if ch_write; then
    ch_present=1
  fi

  # Restart each present store (quorum preserved: CNPG rolls one instance at a time,
  # one cluster at a time; the CH peer restart leaves the canary's replica serving).
  if [[ "${#pg_ok[@]}" -gt 0 ]]; then
    for pair in "${pg_ok[@]}"; do
      pg_restart "${pair%%:*}" "${pair#*:}"
    done
  fi
  [[ "${ch_present}" -eq 1 ]] && ch_restart

  # Re-read across the restart.
  if [[ "${#pg_ok[@]}" -gt 0 ]]; then
    for pair in "${pg_ok[@]}"; do
      pg_verify "${pair%%:*}" "${pair#*:}"
    done
  fi
  [[ "${ch_present}" -eq 1 ]] && ch_verify

  # Clean up the canaries.
  if [[ "${#pg_ok[@]}" -gt 0 ]]; then
    for pair in "${pg_ok[@]}"; do
      pg_cleanup "${pair%%:*}" "${pair#*:}"
    done
  fi
  [[ "${ch_present}" -eq 1 ]] && ch_cleanup

  if [[ "${fail}" -ne 0 ]]; then
    die "data-integrity proof FAILED — see failures above"
  fi

  # Every in-scope store must have been PRESENT and verified; any ABSENT store leaves
  # the proof incomplete (cannot certify no-data-loss for that store).
  local -a absent=()
  if [[ "${#pg_absent[@]}" -gt 0 ]]; then
    absent+=("${pg_absent[@]}")
  fi
  [[ "${ch_present}" -eq 1 ]] || absent+=("langfuse-data/langfuse-ch")
  if [[ "${#absent[@]}" -gt 0 ]]; then
    die "data-integrity proof INCOMPLETE — ABSENT (skipped): ${absent[*]}; cannot certify no-data-loss across a store restart for all in-scope stores"
  fi

  info "data-integrity proof PASSED (no data loss across restart of langfuse-pg + litellm-pg + ClickHouse)"
}

main "$@"
