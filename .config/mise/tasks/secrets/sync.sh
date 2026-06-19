#!/usr/bin/env bash
#MISE description="Materialize all namespaced Kubernetes Secrets from the fnox+age set (authoritative)."
set -euo pipefail

# .config/mise/tasks/secrets/sync.sh — AUTHORITATIVE Kubernetes Secret materializer.
#
# Decrypts the fnox+age sensitive set into a transient, GITIGNORED
# secrets/shared.env.dec (removed under a trap), then creates EACH namespaced
# Secret with the EXACT key names its consumer expects. This is an explicit sync,
# not a kustomize secretGenerator, because:
#   - the secretGenerator cannot RENAME keys, but several consumers need a k8s key
#     name that differs from the fnox key (e.g. fnox LANGFUSE_SALT -> k8s `salt`,
#     fnox VALKEY_PASSWORD -> k8s `redis-password`); and
#   - the CNPG `<cluster>-app` Secrets need `kubernetes.io/basic-auth` type with
#     specific `username`/`password` keys, and the SeaweedFS config Secret needs a
#     composed `seaweedfs_s3_config` JSON — neither of which a flat env generator
#     can produce.
#
# Each Secret is applied with `kubectl create secret … --dry-run=client -o yaml |
# kubectl apply --server-side -f -` (idempotent create-or-update). The CNPG
# operator ADOPTS the pre-created username+password on the `-app` Secrets, but it
# does NOT add a `uri` key to an externally-created (adopted) Secret — so this
# script MINTS the `uri` itself (see apply_basic_auth). litellm consumes that key.
#
# PUBLICATION-SAFE / HYGIENE: this script logs key NAMES and counts ONLY, never a
# value. There is no `set -x` over any decrypt or create step, and no `echo` of a
# secret. The full key→value map is documented in
# planning/.../validation/secret-map.md.

# --- Resolve repo root + source the shared helpers (fall back if absent) ------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
_common="${REPO_ROOT}/.config/mise/lib/common.sh"
if [[ -f "$_common" ]]; then
  # shellcheck source=/dev/null
  source "$_common"
fi
_secrets_lib="${REPO_ROOT}/.config/mise/lib/secrets.sh"
if [[ -f "$_secrets_lib" ]]; then
  # shellcheck source=/dev/null
  source "$_secrets_lib"
fi
if ! declare -F info >/dev/null 2>&1; then
  info() { printf '[info] %s\n' "$*" >&2; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '[warn] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() {
    printf '[error] %s\n' "$*" >&2
    exit 1
  }
fi
if ! declare -F require_cmd >/dev/null 2>&1; then
  require_cmd() {
    local _b
    for _b in "$@"; do
      command -v "$_b" >/dev/null 2>&1 || die "required command not found: $_b"
    done
  }
fi

require_cmd fnox kubectl

secrets_dir="${REPO_ROOT}/secrets"
# Real ciphertext lives in the GITIGNORED repo-root fnox.local.toml (the committed
# fnox.toml is a marker-only template); the age key + .dec output stay under secrets/.
fnox_local="${REPO_ROOT}/fnox.local.toml"
age_key="${secrets_dir}/age/key.txt"
dec="${secrets_dir}/shared.env.dec" # GITIGNORED, transient

[[ -f "$fnox_local" ]] || die "fnox.local.toml not found at repo root — run 'mise run secrets:keygen' then 'mise run secrets:seal' first."
if [[ -f "$age_key" && -z "${FNOX_AGE_KEY_FILE:-}" ]]; then
  export FNOX_AGE_KEY_FILE="$age_key"
fi

# ALWAYS remove the decrypted file on exit (success or failure).
cleanup() { rm -f -- "$dec"; }
add_exit_trap cleanup

# The .dec output lives under secrets/, so operate from there; fnox is pointed
# explicitly at the local (ciphertext) store via -c — it is self-contained.
cd -- "$secrets_dir"

# 1) Decrypt the sensitive set into the transient .dec (values never printed).
umask 077
fnox -c "$fnox_local" export -f env -o "$dec" >/dev/null 2>&1 ||
  die "fnox export failed — is your age identity available (FNOX_AGE_KEY_FILE / Keychain)?"
# Note: no `--` end-of-options here — macOS/BSD chmod rejects it. $dec is a
# repo-controlled path that never begins with `-`, so this is safe.
chmod 600 "$dec"

# 2) Load the .dec into an associative array WITHOUT echoing values. We parse
#    KEY=value lines ourselves rather than `source`-ing, so a value can never be
#    word-split or run as a command.
declare -A SV=()
while IFS= read -r _line || [[ -n "$_line" ]]; do
  [[ "$_line" =~ ^[[:space:]]*# ]] && continue
  [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
  [[ "$_line" == *=* ]] || continue
  _k="${_line%%=*}"
  _v="${_line#*=}"
  # Trim surrounding quotes fnox may emit, then trim a trailing CR.
  _v="${_v%$'\r'}"
  if [[ "$_v" == \"*\" && "$_v" == *\" ]]; then
    _v="${_v#\"}"
    _v="${_v%\"}"
  fi
  [[ "$_k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  SV["$_k"]="$_v"
done <"$dec"

# Non-secret default: the Grafana admin USERNAME lives in mise (non-secret); allow
# it to be absent from fnox and default to the documented placeholder `admin`.
: "${SV[GRAFANA_ADMIN_USER]:=admin}"

info "Decrypted $(printf '%s' "${#SV[@]}") key(s) into transient secrets/shared.env.dec. Key names:"
for _k in $(printf '%s\n' "${!SV[@]}" | sort); do
  info "  - ${_k}"
done

# require_keys <KEY...> — fail fast (by NAME) if any required fnox key is missing.
require_keys() {
  local _miss=() _k
  for _k in "$@"; do
    [[ -n "${SV[$_k]+x}" ]] || _miss+=("$_k")
  done
  if ((${#_miss[@]})); then
    die "missing required fnox key(s): ${_miss[*]} — seal them first (mise run secrets:seal)."
  fi
}

require_keys "${AI_INFRA_FNOX_SECRET_KEYS[@]}"

# --- apply helpers -------------------------------------------------------------
# All secret VALUES travel as positional args to a function and are passed straight
# to `kubectl create secret`; they are never interpolated into a log line. kubectl
# argv is not logged here and the pods run inside the local cluster only.

# apply_generic <name> <ns> <k=fnoxval>... — create-or-update an Opaque Secret.
apply_generic() {
  local name="$1" ns="$2"
  shift 2
  local args=(create secret generic "$name" --namespace "$ns")
  local kv
  for kv in "$@"; do
    args+=(--from-literal="$kv")
  done
  args+=(--dry-run=client -o yaml)
  kubectl "${args[@]}" | kubectl apply --server-side --force-conflicts -f - >/dev/null
  info "applied Secret ${ns}/${name}"
}

# urlencode_stdin — percent-encode stdin for safe embedding in a URL userinfo
# component. Reads the value from stdin (NEVER an argv) and writes the encoded form
# to stdout, so a credential never appears on a command line or in `ps` output.
# Defensive: the passwords are currently URL-safe, but a future rotation may not be.
urlencode_stdin() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import urllib.parse,sys;sys.stdout.write(urllib.parse.quote(sys.stdin.read(),safe=""))'
  else
    # Pure-bash fallback (no external deps): encode every byte that is not an
    # RFC 3986 unreserved character.
    local data c i
    data="$(cat)"
    for ((i = 0; i < ${#data}; i++)); do
      c="${data:i:1}"
      case "$c" in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
      esac
    done
  fi
}

# apply_basic_auth <name> <ns> <username> <password> <database> — basic-auth type
# Secret that CNPG adopts. CNPG does NOT add a `uri` key to an externally-created
# (adopted) Secret, so we MINT it ourselves here. The `uri` is the libpq
# connection string against the cluster's primary (`-rw`) Service:
#   postgresql://<user>:<urlencoded-pass>@<cluster>-rw.<ns>.svc.cluster.local:5432/<db>
# where <cluster> is the Secret name minus the trailing `-app` (e.g.
# litellm-pg-app -> litellm-pg). Only litellm consumes `uri` today, but minting it
# uniformly for all `-app` Secrets is harmless and consistent. The password is
# URL-encoded via stdin (never on a command line), and the composed `uri` is passed
# straight to `kubectl create secret --from-literal`, never echoed to a log line.
apply_basic_auth() {
  local name="$1" ns="$2" user="$3" pass="$4" db="$5"
  local cluster="${name%-app}"
  local enc_pass uri
  enc_pass="$(printf '%s' "$pass" | urlencode_stdin)"
  uri="postgresql://${user}:${enc_pass}@${cluster}-rw.${ns}.svc.cluster.local:5432/${db}"
  kubectl create secret generic "$name" \
    --namespace "$ns" \
    --type=kubernetes.io/basic-auth \
    --from-literal=username="$user" \
    --from-literal=password="$pass" \
    --from-literal=uri="$uri" \
    --dry-run=client -o yaml |
    kubectl apply --server-side --force-conflicts -f - >/dev/null
  info "applied Secret ${ns}/${name} (basic-auth + uri)"
}

# json_escape <string> — minimal JSON string escaper (backslash + double-quote)
# for embedding a credential into the seaweedfs_s3_config document.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

info "Materializing namespaced Secrets (key names remapped to consumer expectations)..."

# --- langfuse (app plane) ------------------------------------------------------
apply_generic langfuse-app-secrets langfuse \
  "salt=${SV[LANGFUSE_SALT]}" \
  "encryption-key=${SV[LANGFUSE_ENCRYPTION_KEY]}" \
  "nextauth-secret=${SV[LANGFUSE_NEXTAUTH_SECRET]}" \
  "postgres-password=${SV[LANGFUSE_PG_PASSWORD]}" \
  "clickhouse-password=${SV[CLICKHOUSE_PASSWORD]}" \
  "redis-password=${SV[VALKEY_PASSWORD]}" \
  "s3-access-key-id=${SV[SEAWEEDFS_S3_ACCESS_KEY]}" \
  "s3-secret-access-key=${SV[SEAWEEDFS_S3_SECRET_KEY]}" \
  "init-project-public-key=${SV[LANGFUSE_PUBLIC_KEY]}" \
  "init-project-secret-key=${SV[LANGFUSE_SECRET_KEY]}" \
  "init-user-password=${SV[LANGFUSE_ADMIN_PASSWORD]}"

# --- langfuse-data (stores) ----------------------------------------------------
apply_generic langfuse-shared-passwords langfuse-data \
  "clickhouse-password=${SV[CLICKHOUSE_PASSWORD]}" \
  "redis-password=${SV[VALKEY_PASSWORD]}"

apply_basic_auth langfuse-pg-app langfuse-data langfuse "${SV[LANGFUSE_PG_PASSWORD]}" postgres_langfuse

# SeaweedFS embedded-S3 config Secret. The filer mounts `seaweedfs_s3_config`; the
# bucket hook + the Loki/Tempo S3 config read the access/secret keys. Identity name
# is GENERIC (`langfuse-admin`), never a real/dev credential.
_sw_ak="$(json_escape "${SV[SEAWEEDFS_S3_ACCESS_KEY]}")"
_sw_sk="$(json_escape "${SV[SEAWEEDFS_S3_SECRET_KEY]}")"
_sw_cfg="$(
  cat <<JSON
{
  "identities": [
    {
      "name": "langfuse-admin",
      "credentials": [
        {
          "accessKey": "${_sw_ak}",
          "secretKey": "${_sw_sk}"
        }
      ],
      "actions": ["Admin", "Read", "Write"]
    }
  ]
}
JSON
)"
apply_generic langfuse-seaweedfs-s3-secret langfuse-data \
  "SEAWEEDFS_S3_ACCESS_KEY=${SV[SEAWEEDFS_S3_ACCESS_KEY]}" \
  "SEAWEEDFS_S3_SECRET_KEY=${SV[SEAWEEDFS_S3_SECRET_KEY]}" \
  "admin_access_key_id=${SV[SEAWEEDFS_S3_ACCESS_KEY]}" \
  "admin_secret_access_key=${SV[SEAWEEDFS_S3_SECRET_KEY]}" \
  "seaweedfs_s3_config=${_sw_cfg}"

# --- litellm -------------------------------------------------------------------
apply_basic_auth litellm-pg-app litellm litellm "${SV[LITELLM_PG_PASSWORD]}" litellm

apply_generic litellm-app-secrets litellm \
  "LITELLM_MASTER_KEY=${SV[LITELLM_MASTER_KEY]}" \
  "CLAUDE_CODE_LITELLM_VIRTUAL_KEY=${SV[CLAUDE_CODE_LITELLM_VIRTUAL_KEY]}" \
  "CODEX_LITELLM_VIRTUAL_KEY=${SV[CODEX_LITELLM_VIRTUAL_KEY]}" \
  "SMOKE_TEST_LITELLM_VIRTUAL_KEY=${SV[SMOKE_TEST_LITELLM_VIRTUAL_KEY]}" \
  "LANGFUSE_PUBLIC_KEY=${SV[LANGFUSE_PUBLIC_KEY]}" \
  "LANGFUSE_SECRET_KEY=${SV[LANGFUSE_SECRET_KEY]}"

# --- lgtm (observability) ------------------------------------------------------
apply_basic_auth grafana-pg-app lgtm grafana "${SV[GRAFANA_PG_PASSWORD]}" grafana

apply_generic grafana-admin lgtm \
  "admin-user=${SV[GRAFANA_ADMIN_USER]}" \
  "admin-password=${SV[GRAFANA_ADMIN_PASSWORD]}"

# Cross-namespace mirror of the SeaweedFS S3 credentials for Loki and Tempo.
apply_generic loki-s3-creds lgtm \
  "SEAWEEDFS_S3_ACCESS_KEY=${SV[SEAWEEDFS_S3_ACCESS_KEY]}" \
  "SEAWEEDFS_S3_SECRET_KEY=${SV[SEAWEEDFS_S3_SECRET_KEY]}"

apply_generic tempo-s3-creds lgtm \
  "SEAWEEDFS_S3_ACCESS_KEY=${SV[SEAWEEDFS_S3_ACCESS_KEY]}" \
  "SEAWEEDFS_S3_SECRET_KEY=${SV[SEAWEEDFS_S3_SECRET_KEY]}"

# OTel Collector → Langfuse OTLP HTTP Basic-auth header: `Basic base64(public:secret)`.
_otel_auth="Basic $(printf '%s:%s' "${SV[LANGFUSE_PUBLIC_KEY]}" "${SV[LANGFUSE_SECRET_KEY]}" | base64 | tr -d '\n')"
apply_generic langfuse-otel-basic-auth lgtm \
  "OTEL_EXPORTER_OTLP_LANGFUSE_AUTH=${_otel_auth}"

info "All namespaced Secrets materialized."
warn "Transient secrets/shared.env.dec will be removed on exit (never committed)."
