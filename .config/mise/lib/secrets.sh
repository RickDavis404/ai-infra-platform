#!/usr/bin/env bash
# .config/mise/lib/secrets.sh -- shared secret inventory and generation helpers.
#
# Source this from task scripts after common.sh. The functions here log only key
# names and descriptions; callers must never print generated values.
set -euo pipefail

_AI_INFRA_SECRETS_SH_SOURCED=1

# Sensitive values sealed into fnox+age. Keep this list aligned with
# secrets:sync/check and the host-side launchers.
# shellcheck disable=SC2034 # sourced by task scripts
AI_INFRA_FNOX_SECRET_KEYS=(
  LITELLM_MASTER_KEY
  CLAUDE_CODE_LITELLM_VIRTUAL_KEY
  CODEX_LITELLM_VIRTUAL_KEY
  SMOKE_TEST_LITELLM_VIRTUAL_KEY
  GRAFANA_ADMIN_PASSWORD
  LANGFUSE_ADMIN_PASSWORD
  LANGFUSE_PUBLIC_KEY
  LANGFUSE_SECRET_KEY
  LANGFUSE_SALT
  LANGFUSE_NEXTAUTH_SECRET
  LANGFUSE_ENCRYPTION_KEY
  LANGFUSE_PG_PASSWORD
  LITELLM_PG_PASSWORD
  GRAFANA_PG_PASSWORD
  CLICKHOUSE_PASSWORD
  VALKEY_PASSWORD
  SEAWEEDFS_S3_ACCESS_KEY
  SEAWEEDFS_S3_SECRET_KEY
)

# Optional plaintext-only values consumed by cache:up. These are deliberately not
# sealed into fnox and not materialized as Kubernetes Secrets.
# shellcheck disable=SC2034 # sourced by task scripts
AI_INFRA_SHARED_ENV_OPTIONAL_KEYS=(
  DOCKERHUB_USERNAME
  DOCKERHUB_TOKEN
)

# The age PUBLIC recipient committed as a placeholder in the tracked fnox.toml
# [providers].age and secrets/.agerecipients. It is NOT a usable operator key:
# secrets:keygen must EXCLUDE it from the operator's recipient set, and secrets:seal
# must REFUSE to seal to it. Keep byte-for-byte identical to the value committed in
# fnox.toml / secrets/.agerecipients (single source of truth for both guards).
# SCRUB NOTE: the current value is a real operator public recipient carried in from a
# key rotation (the stale guards referenced the pre-rotation age1zrqtwy… key). It is a
# publication de-identification item — rotate to a clearly-synthetic throwaway
# recipient in a coordinated change (this constant + fnox.toml + secrets/.agerecipients).
# Tracked for human review; NOT rotated here.
# shellcheck disable=SC2034 # sourced by task scripts
AI_INFRA_PLACEHOLDER_AGE_RECIPIENT="age1askmfmrkjf7ln3drgngdz2txt88nd4spgv52f6ekcu9hpv3gpy6skp79sf"

ai_infra_secret_description() {
  case "$1" in
  LITELLM_MASTER_KEY) printf '%s\n' "LiteLLM admin/master key for gateway administration and key minting" ;;
  CLAUDE_CODE_LITELLM_VIRTUAL_KEY) printf '%s\n' "fixed LiteLLM virtual key used by the host-side Claude Code launcher" ;;
  CODEX_LITELLM_VIRTUAL_KEY) printf '%s\n' "fixed LiteLLM virtual key used by the host-side Codex launcher" ;;
  SMOKE_TEST_LITELLM_VIRTUAL_KEY) printf '%s\n' "fixed LiteLLM virtual key used by local smoke-test clients" ;;
  GRAFANA_ADMIN_PASSWORD) printf '%s\n' "Grafana admin login password" ;;
  LANGFUSE_ADMIN_PASSWORD) printf '%s\n' "Langfuse bootstrap admin login password" ;;
  LANGFUSE_PUBLIC_KEY) printf '%s\n' "Langfuse project public key used by LiteLLM and telemetry clients" ;;
  LANGFUSE_SECRET_KEY) printf '%s\n' "Langfuse project secret key used by LiteLLM and telemetry clients" ;;
  LANGFUSE_SALT) printf '%s\n' "Langfuse API-key hashing salt; generate once and never rotate after first boot" ;;
  LANGFUSE_NEXTAUTH_SECRET) printf '%s\n' "Langfuse NextAuth/JWT session signing secret" ;;
  LANGFUSE_ENCRYPTION_KEY) printf '%s\n' "Langfuse field encryption key; exactly 64 hex chars, generate once and never rotate" ;;
  LANGFUSE_PG_PASSWORD) printf '%s\n' "CloudNativePG app password for the Langfuse Postgres cluster" ;;
  LITELLM_PG_PASSWORD) printf '%s\n' "CloudNativePG app password for the LiteLLM Postgres cluster" ;;
  GRAFANA_PG_PASSWORD) printf '%s\n' "CloudNativePG app password for the Grafana Postgres cluster" ;;
  CLICKHOUSE_PASSWORD) printf '%s\n' "ClickHouse default-user password for the Langfuse analytics store" ;;
  VALKEY_PASSWORD) printf '%s\n' "Valkey password for the Langfuse queue/cache store" ;;
  SEAWEEDFS_S3_ACCESS_KEY) printf '%s\n' "SeaweedFS embedded-S3 access key shared by Langfuse, Loki, and Tempo" ;;
  SEAWEEDFS_S3_SECRET_KEY) printf '%s\n' "SeaweedFS embedded-S3 secret key shared by Langfuse, Loki, and Tempo" ;;
  DOCKERHUB_USERNAME) printf '%s\n' "optional Docker Hub username for the local pull-through registry cache; not sealed" ;;
  DOCKERHUB_TOKEN) printf '%s\n' "optional Docker Hub access token for the local pull-through registry cache; not sealed" ;;
  *) printf '%s\n' "unclassified local value" ;;
  esac
}

ai_infra_secret_is_placeholder() {
  case "${1:-}" in
  "" | CHANGEME-* | "<fnox+age-managed>") return 0 ;;
  *) return 1 ;;
  esac
}

_ai_infra_rand_b64url() {
  local bytes="$1"
  openssl rand -base64 "${bytes}" | tr '+/' '-_' | tr -d '=\n'
}

_ai_infra_rand_hex() {
  local bytes="$1"
  openssl rand -hex "${bytes}" | tr -d '\n'
}

ai_infra_generate_secret_value() {
  case "$1" in
  LITELLM_MASTER_KEY) printf 'sk-litellm-master-%s\n' "$(_ai_infra_rand_b64url 36)" ;;
  CLAUDE_CODE_LITELLM_VIRTUAL_KEY) printf 'sk-litellm-claude-code-%s\n' "$(_ai_infra_rand_b64url 36)" ;;
  CODEX_LITELLM_VIRTUAL_KEY) printf 'sk-litellm-codex-%s\n' "$(_ai_infra_rand_b64url 36)" ;;
  SMOKE_TEST_LITELLM_VIRTUAL_KEY) printf 'sk-litellm-smoke-test-%s\n' "$(_ai_infra_rand_b64url 36)" ;;
  LANGFUSE_PUBLIC_KEY) printf 'pk-lf-%s\n' "$(_ai_infra_rand_b64url 32)" ;;
  LANGFUSE_SECRET_KEY) printf 'sk-lf-%s\n' "$(_ai_infra_rand_b64url 40)" ;;
  LANGFUSE_ENCRYPTION_KEY) _ai_infra_rand_hex 32 ;;
  SEAWEEDFS_S3_ACCESS_KEY) printf 'sw-%s\n' "$(_ai_infra_rand_b64url 24)" ;;
  *) _ai_infra_rand_b64url 36 ;;
  esac
}

ai_infra_key_in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

# --- KEY=value file readers (bash 3.2-safe; no associative arrays) -------------
# sv_get and sv_has parse a KEY=value file with the SAME rules the secrets tasks
# have always used: skip comment (leading '#') and blank lines; split each line on
# the FIRST '='; strip a trailing CR; strip ONE surrounding pair of double quotes;
# and accept only a shell-safe key name (^[A-Za-z_][A-Za-z0-9_]*$). On a duplicate
# key the LAST occurrence wins, matching the previous single-pass array load.
# Neither function ever logs a value.

# sv_get <file> <key> — print the value for <key> (which may be empty) and return 0
# when the key is present; print nothing and return 1 when the key is ABSENT. The
# value is emitted with no trailing newline so it can be piped straight to a
# consumer (e.g. `fnox set`) byte-for-byte.
sv_get() {
  awk -v key="$2" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      eq = index($0, "=")
      if (eq == 0) next
      k = substr($0, 1, eq - 1)
      if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
      if (k != key) next
      v = substr($0, eq + 1)
      sub(/\r$/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      found = 1
      val = v
    }
    END {
      if (found) { printf "%s", val; exit 0 }
      exit 1
    }
  ' "$1"
}

# sv_has <file> <key> — return 0 if <key> is present, 1 otherwise. Never prints.
sv_has() {
  sv_get "$1" "$2" >/dev/null
}

: "${_AI_INFRA_SECRETS_SH_SOURCED}"
