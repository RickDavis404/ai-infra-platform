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

: "${_AI_INFRA_SECRETS_SH_SOURCED}"
