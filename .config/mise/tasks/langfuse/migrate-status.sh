#!/usr/bin/env bash
#MISE description="READ-ONLY: show Langfuse Prisma migration state in postgres_langfuse (applied/failed counts) + the ClickHouse schema-migration state."
# .config/mise/tasks/langfuse/migrate-status.sh — diagnose the Langfuse migration
# pipeline that the multi-replica deadlock fix (D008) serializes.
#
# Two halves, both READ-ONLY (SELECT-only SQL; no apply/scale/exec-mutation):
#   1) Postgres (CNPG langfuse-pg, db postgres_langfuse): summarize Prisma's
#      `_prisma_migrations` ledger — total / applied (finished_at set) / FAILED
#      (rolled_back_at set OR applied_steps_count=0 with logs) and list the most
#      recent rows. A non-zero failed count is the P3009 crashloop signature.
#   2) ClickHouse (CHI langfuse-ch, cluster `default`): show the migration tracking
#      table Langfuse maintains (schema_migrations) so a half-applied ON CLUSTER
#      migration (the `code:60 Unknown table` symptom) is visible.
#
# It runs the queries by `kubectl exec`-ing the existing CNPG primary / a ClickHouse
# pod and piping SQL on stdin — it never mutates the cluster and never prints any
# secret (psql peer auth inside the pod; the ClickHouse query runs as the pod's
# default user via clickhouse-client, no password echoed).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"

readonly PG_NS="langfuse-data"
readonly PG_CLUSTER="langfuse-pg"
readonly PG_DB="postgres_langfuse"
readonly CH_NS="langfuse-data"
readonly CH_CHI="langfuse-ch"

section() { printf '\n=== %s ===\n' "$*" >&2; }

# pg_primary_pod — print the current CNPG primary pod name (role=primary), or empty.
pg_primary_pod() {
  kc -n "${PG_NS}" get pods \
    -l "cnpg.io/cluster=${PG_CLUSTER},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

postgres_status() {
  section "Prisma migrations — Postgres ${PG_NS}/${PG_DB} (cluster ${PG_CLUSTER})"
  local pod
  pod="$(pg_primary_pod)"
  if [[ -z "${pod}" ]]; then
    warn "no CNPG primary pod for ${PG_CLUSTER} (is langfuse-data up?) — skipping Postgres"
    return 0
  fi
  info "primary pod: ${pod}"

  # Does the _prisma_migrations table exist yet? (Absent => migrations never ran.)
  local exists
  exists="$(kc -n "${PG_NS}" exec "${pod}" -c postgres -- \
    psql -U postgres -d "${PG_DB}" -tAc \
    "SELECT to_regclass('public._prisma_migrations') IS NOT NULL;" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "${exists}" != "t" ]]; then
    warn "  _prisma_migrations table not present yet (migrations have not started)"
    return 0
  fi

  # Counts: total / applied (finished_at set, no rollback) / failed (rolled back or
  # started-but-never-finished). Print as a small labeled table; READ-ONLY SELECTs.
  printf -- '--- counts ---\n' >&2
  kc -n "${PG_NS}" exec "${pod}" -c postgres -- \
    psql -U postgres -d "${PG_DB}" -P pager=off -c "
      SELECT
        count(*)                                                              AS total,
        count(*) FILTER (WHERE finished_at IS NOT NULL
                           AND rolled_back_at IS NULL)                        AS applied,
        count(*) FILTER (WHERE rolled_back_at IS NOT NULL)                    AS rolled_back,
        count(*) FILTER (WHERE finished_at IS NULL
                           AND rolled_back_at IS NULL)                        AS in_progress_or_failed
      FROM public._prisma_migrations;" 2>/dev/null || warn "  could not query _prisma_migrations counts"

  printf -- '--- most recent migrations ---\n' >&2
  kc -n "${PG_NS}" exec "${pod}" -c postgres -- \
    psql -U postgres -d "${PG_DB}" -P pager=off -c "
      SELECT migration_name,
             finished_at,
             rolled_back_at,
             applied_steps_count
      FROM public._prisma_migrations
      ORDER BY started_at DESC NULLS LAST
      LIMIT 10;" 2>/dev/null || warn "  could not list recent migrations"

  # Flag the P3009 signature explicitly.
  local failed
  failed="$(kc -n "${PG_NS}" exec "${pod}" -c postgres -- \
    psql -U postgres -d "${PG_DB}" -tAc \
    "SELECT count(*) FROM public._prisma_migrations
       WHERE rolled_back_at IS NOT NULL
          OR (finished_at IS NULL AND started_at < now() - interval '5 minutes');" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "${failed}" && "${failed}" != "0" ]]; then
    err "  ${failed} migration(s) rolled back or stuck — the multi-replica deadlock / P3009 signature (see D008)"
    return 1
  fi
  info "  no failed/stuck Prisma migrations detected"
}

# ch_pod — print a ClickHouse server pod name for the CHI, or empty.
ch_pod() {
  kc -n "${CH_NS}" get pods -l "clickhouse.altinity.com/chi=${CH_CHI}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

clickhouse_status() {
  section "ClickHouse migration state — ${CH_NS}/${CH_CHI} (cluster default)"
  local pod
  pod="$(ch_pod)"
  if [[ -z "${pod}" ]]; then
    warn "no ClickHouse pod for ${CH_CHI} — skipping ClickHouse"
    return 0
  fi
  info "clickhouse pod: ${pod}"

  # Langfuse tracks applied CH migrations in `schema_migrations`. Show whether the
  # table exists on the queried replica and the latest applied versions. The
  # clickhouse-client connects to localhost as the pod's configured default user;
  # no credential is passed on the command line (read from the pod's own config).
  local has_tbl
  has_tbl="$(kc -n "${CH_NS}" exec "${pod}" -c clickhouse -- \
    clickhouse-client --query \
    "EXISTS TABLE default.schema_migrations" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "${has_tbl}" != "1" ]]; then
    warn "  default.schema_migrations not present on ${pod} (CH migrations not yet applied, or applied on only one replica — the 'code:60' symptom)"
    return 0
  fi
  printf -- '--- latest applied ClickHouse migrations ---\n' >&2
  kc -n "${CH_NS}" exec "${pod}" -c clickhouse -- \
    clickhouse-client --query \
    "SELECT version, toString(any(_part)) AS marker
       FROM default.schema_migrations
       GROUP BY version ORDER BY version DESC LIMIT 10 FORMAT PrettyCompactMonoBlock" \
    2>/dev/null ||
    kc -n "${CH_NS}" exec "${pod}" -c clickhouse -- \
      clickhouse-client --query \
      "SELECT * FROM default.schema_migrations ORDER BY 1 DESC LIMIT 10 FORMAT PrettyCompactMonoBlock" 2>/dev/null ||
    warn "  could not read default.schema_migrations contents"
  info "  ClickHouse schema_migrations present on the queried replica"
}

main() {
  require_cmd kubectl
  local rc=0
  postgres_status || rc=1
  clickhouse_status || rc=1
  section "summary"
  if [[ "${rc}" -ne 0 ]]; then
    err "migration status: problems detected (see above)"
    exit 1
  fi
  info "migration status: Postgres + ClickHouse migrations look healthy"
}

main "$@"
