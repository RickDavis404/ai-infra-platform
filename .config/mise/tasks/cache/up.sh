#!/usr/bin/env bash
#MISE description="Create/start the long-lived ai-registry Docker Hub pull-through cache VM; seed its proxy+auth config and publish its address to 99-local.toml."
set -euo pipefail

# cache:up — idempotently bring up the PERSISTENT Docker Hub pull-through cache.
#
# WHY: repeated cold cluster standups pull ~17-20 docker.io images and hit Docker Hub's
# anonymous rate limit (HTTP 429). A long-lived `ai-registry` Lima VM running
# `registry:2` in pull-through PROXY mode, with its blob store on a host-persistent
# mount, makes subsequent cold standups do ~0 docker.io pulls. The VM is INTENTIONALLY
# NOT an ai-inf-platform-* node, so `lima:delete` / `cluster:teardown` never remove it.
#
# Sequence (every step idempotent):
#   1. mkdir -p the host-persistent data dir <repoRoot>/.local/registry/data (gitignored).
#   2. Seed <repoRoot>/.local/registry/config.yml: the registry:2 PROXY config
#      (remoteurl https://registry-1.docker.io). If DOCKERHUB_USERNAME + DOCKERHUB_TOKEN
#      are present in the gitignored secrets/shared.env, embed them so the proxy
#      authenticates upstream (higher pull limits); otherwise warn and stay anonymous.
#      The token is read at runtime and written ONLY into the gitignored .local mount —
#      it is NEVER printed and NEVER committed.
#   3. Create+start (or start, or leave-running) the ai-registry VM from the template.
#   4. Re-apply the (possibly newly-authenticated) config inside the guest and restart
#      the registry container so the creds take effect.
#   5. Discover the VM's shared-L2 (lima0) DHCP IP and write
#      AI_INFRA_REGISTRY_ADDR=<ip>:5000 into the gitignored 99-local.toml, so lima:start
#      passes it to the cluster template's containerd certs.d mirror.
#
# SECURITY: the Docker Hub token only ever exists in the gitignored secrets/shared.env
# (input) and the gitignored .local/registry/config.yml (output). It is never echoed,
# never logged, and never placed in a committed file. No `set -x` runs over the seed step.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

readonly TEMPLATE="${REPO_ROOT}/lima/templates/registry.yaml"
readonly VM="ai-registry"
readonly NETWORK="${AI_INFRA_LIMA_NETWORK:-shared}"
readonly REGISTRY_DIR="${REPO_ROOT}/.local/registry"
readonly REGISTRY_CONFIG="${REGISTRY_DIR}/config.yml"
readonly SHARED_ENV="${REPO_ROOT}/secrets/shared.env"
readonly LOCAL_OVERRIDE="${REPO_ROOT}/.config/mise/conf.d/99-local.toml"
# Registry listen port + the documented default address (used only as the fallback the
# cluster template carries; the real address is the discovered IP written below).
readonly REGISTRY_PORT="5000"

instance_exists() { limactl list --quiet 2>/dev/null | grep -qx "$1"; }
instance_running() { [ "$(limactl list --format '{{.Status}}' "$1" 2>/dev/null || true)" = "Running" ]; }

# read_shared_env_value <KEY> — print the value of KEY from the gitignored
# secrets/shared.env to stdout, or nothing if the file/key is absent. Parses KEY=value
# ourselves (no `source`) so a value is never word-split or executed, and strips
# surrounding quotes + a trailing CR. The value is captured into a local by the caller
# and NEVER logged.
read_shared_env_value() {
  local key="$1" line v
  [ -f "${SHARED_ENV}" ] || return 0
  # Last assignment wins; match `KEY=` at line start (optional leading whitespace).
  line="$(grep -E "^[[:space:]]*${key}=" "${SHARED_ENV}" 2>/dev/null | tail -n1 || true)"
  [ -n "${line}" ] || return 0
  v="${line#*=}"
  v="${v%$'\r'}"
  if [[ "${v}" == \"*\" && "${v}" == *\" ]]; then
    v="${v#\"}"
    v="${v%\"}"
  fi
  printf '%s' "${v}"
}

# seed_registry_config — write the registry:2 PROXY config to the gitignored
# .local/registry/config.yml. Embeds Docker Hub creds ONLY if both are present in
# secrets/shared.env. Writes under umask 077 (config may carry a token). The token is
# never printed; only its PRESENCE (not value) is reported.
seed_registry_config() {
  local user token
  user="$(read_shared_env_value DOCKERHUB_USERNAME)"
  token="$(read_shared_env_value DOCKERHUB_TOKEN)"

  mkdir -p "${REGISTRY_DIR}/data"
  umask 077

  # Base proxy config (anonymous). delete.enabled lets the GC scheduler reclaim space.
  {
    cat <<'CFG'
version: 0.1
log:
  level: info
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
http:
  addr: :5000
proxy:
  remoteurl: https://registry-1.docker.io
CFG
    # Append auth lines ONLY when BOTH creds are non-empty. Written via a heredoc that
    # interpolates the values directly into the gitignored file — never to a log/stdout.
    if [ -n "${user}" ] && [ -n "${token}" ]; then
      cat <<CFG
  username: "${user}"
  password: "${token}"
CFG
    fi
  } >"${REGISTRY_CONFIG}"
  chmod 600 "${REGISTRY_CONFIG}"

  if [ -n "${user}" ] && [ -n "${token}" ]; then
    info "seeded ${REGISTRY_CONFIG#"${REPO_ROOT}/"} with Docker Hub auth (username present; token NOT logged)"
  else
    warn "DOCKERHUB_USERNAME/DOCKERHUB_TOKEN not both set in secrets/shared.env — registry proxy will run ANONYMOUSLY (lower Docker Hub pull limits). Set them for higher limits, then re-run 'mise run cache:up'."
  fi
}

# discover_ip — print the ai-registry VM's lima0 (shared-L2) IPv4 to stdout, or nothing
# on failure. Reads it inside the guest (authoritative) rather than guessing.
discover_ip() {
  limactl shell "${VM}" sh -c \
    "ip -4 -o addr show dev lima0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1" \
    2>/dev/null | tr -d '[:space:]'
}

# write_registry_addr <ip> — write/update AI_INFRA_REGISTRY_ADDR=<ip>:5000 in the
# gitignored 99-local.toml WITHOUT disturbing any other keys init may have written
# there. mise merges conf.d/*.toml in lexical order, so 99-local.toml wins over the
# committed default in 10-env.toml.
write_registry_addr() {
  local ip="$1" addr="${1}:${REGISTRY_PORT}"
  umask 077
  if [ ! -f "${LOCAL_OVERRIDE}" ]; then
    cat >"${LOCAL_OVERRIDE}" <<EOF
# 99-local.toml — GITIGNORED per-host overrides. mise merges conf.d/*.toml in lexical
# order; this file sorts LAST, so these values override the committed defaults in
# 10-env.toml. Non-secret values only (no secrets ever). Safe to delete + regenerate
# via 'mise run init' / 'mise run cache:up'.

[env]
AI_INFRA_REGISTRY_ADDR  = "${addr}"
EOF
    info "wrote ${LOCAL_OVERRIDE#"${REPO_ROOT}/"} with AI_INFRA_REGISTRY_ADDR=${addr}"
    return 0
  fi
  # File exists. Replace an existing AI_INFRA_REGISTRY_ADDR line in place, or append one
  # under the [env] table (creating [env] if absent). Use a temp file + mv (atomic).
  local tmp
  tmp="$(mktemp "${LOCAL_OVERRIDE}.XXXXXX")"
  if grep -qE '^[[:space:]]*AI_INFRA_REGISTRY_ADDR[[:space:]]*=' "${LOCAL_OVERRIDE}"; then
    sed -E "s|^[[:space:]]*AI_INFRA_REGISTRY_ADDR[[:space:]]*=.*|AI_INFRA_REGISTRY_ADDR  = \"${addr}\"|" \
      "${LOCAL_OVERRIDE}" >"${tmp}"
  elif grep -qE '^[[:space:]]*\[env\]' "${LOCAL_OVERRIDE}"; then
    awk -v line="AI_INFRA_REGISTRY_ADDR  = \"${addr}\"" '
      { print }
      /^[[:space:]]*\[env\][[:space:]]*$/ && !done { print line; done=1 }
    ' "${LOCAL_OVERRIDE}" >"${tmp}"
  else
    cp "${LOCAL_OVERRIDE}" "${tmp}"
    printf '\n[env]\nAI_INFRA_REGISTRY_ADDR  = "%s"\n' "${addr}" >>"${tmp}"
  fi
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${LOCAL_OVERRIDE}"
  info "updated ${LOCAL_OVERRIDE#"${REPO_ROOT}/"} -> AI_INFRA_REGISTRY_ADDR=${addr}"
}

# apply_config_in_guest — copy the freshly-seeded config into the registry container's
# mounted path and restart it so new creds take effect. The config is ALREADY on the
# host mount (the guest sees it at /mnt/registry/config.yml), so we only need to restart
# the container. Best-effort: the provision step also handles first-boot creation.
apply_config_in_guest() {
  info "restarting ai-registry-proxy in-guest so the seeded config takes effect"
  limactl shell "${VM}" sudo sh -c \
    'nerdctl restart ai-registry-proxy >/dev/null 2>&1 || nerdctl start ai-registry-proxy >/dev/null 2>&1 || true' \
    2>/dev/null || warn "could not restart ai-registry-proxy (it may start on its own); check 'mise run cache:status'"
}

main() {
  require_cmd limactl awk sed grep
  [ -f "${TEMPLATE}" ] || die "registry template not found: ${TEMPLATE}"

  # Step 1+2: seed the host-persistent data dir + config BEFORE starting (virtiofs needs
  # the host dir present; the provision step reads config.yml from the mount).
  seed_registry_config

  # Step 3: create+start (or start) the VM. Already-running is a no-op.
  if instance_running "${VM}"; then
    info "${VM} already running; re-seeding config + restarting the proxy container"
    apply_config_in_guest
  elif instance_exists "${VM}"; then
    info "${VM} exists but stopped; starting (data + config preserved)"
    limactl start --tty=false --timeout "${START_TIMEOUT:-600s}" "${VM}"
    apply_config_in_guest
  else
    info "creating + starting ${VM} (network=${NETWORK})"
    limactl start --tty=false --timeout "${START_TIMEOUT:-600s}" \
      --name "${VM}" \
      --set ".param.repoRoot=\"${REPO_ROOT}\" | .networks[0].lima=\"${NETWORK}\"" \
      "${TEMPLATE}"
  fi

  # Step 5: discover the DHCP IP and publish AI_INFRA_REGISTRY_ADDR.
  local ip
  ip="$(discover_ip)"
  if [ -z "${ip}" ]; then
    warn "could not discover ${VM}'s lima0 IP — 99-local.toml NOT updated. The cluster will fall back to the committed default AI_INFRA_REGISTRY_ADDR. Check 'mise run cache:status'."
  else
    write_registry_addr "${ip}"
    info "cache reachable at http://${ip}:${REGISTRY_PORT}/v2/ on the shared L2"
  fi

  info "cache:up complete — ai-registry pull-through cache is up (persists across cluster teardowns)"
}

main "$@"
