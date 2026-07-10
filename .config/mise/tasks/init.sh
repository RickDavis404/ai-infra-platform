#!/usr/bin/env bash
#MISE description="Interactive first-time setup: prereqs, brew, mise, mmdc, lima sudoers, network + VIP/LB plan (writes a gitignored 99-local.toml), age key, secrets."
# .config/mise/tasks/init.sh — one-time interactive bootstrap for the kubeadm + Cilium HA lab.
#
# Walks a first-time operator through every host-level prerequisite the cluster needs,
# one checkable, skippable step at a time. Each step is idempotent: it detects whether
# the work is already done and, if so, reports "OK" and moves on.
#
# Privileged / host-global actions are NEVER run silently. The Lima sudoers file is only
# tested (the managed /etc/sudoers.d/lima must exist AND `limactl sudoers --check` must pass —
# the check alone false-passes on stale passwordless rules) — if it is missing/stale, init
# PRINTS the exact command for the operator to run under their own sudo and stops there. The
# host-global `~/.lima/_config/networks.yaml` is user-owned (no sudo), and init makes ONE
# surgical, idempotent edit to it: it sets `.paths.socketVMNet` to the root-owned
# /opt/socket_vmnet path. Lima auto-generates that key pointing at the uid-owned Homebrew
# Cellar path, which Lima then REJECTS ("not owned by root") — breaking `lima:start` and
# emitting an empty /etc/sudoers.d/lima — so the fix must land BEFORE the sudoers step.
# Network definitions are still only inspected (`limactl network list`) and, on consent,
# created (`limactl network create`); init never rewrites those by hand.
#
# Steps:
#   1. Assert bash >= 3.2 (stock macOS) and macOS / Apple Silicon (arm64).
#   2. brew bundle (Brewfile) — bash, socket_vmnet, lima, and the rest.
#   3. mise install + mise trust (materialize the pinned [tools]).
#   4. tools:mmdc-setup — puppeteer-managed Chrome for mermaid-cli (mmdc).
#   5. socket_vmnet secure path + networks.yaml socketVMNet fixup + Lima sudoers
#      (limactl sudoers --check), in that order.
#   6. Network + VIP/LB IP plan — confirm/override the network, subnet, CP VIP, LB range;
#      write the chosen values to the gitignored .config/mise/conf.d/99-local.toml.
#   7. age key generation + guidance for sealing real secret values into the fnox store.
#   8. Point the operator at `mise run up`.
#
# No secret material is ever echoed. All logging goes through common.sh (info/warn/die).
set -euo pipefail

REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"
if [[ -f "${REPO_ROOT}/.config/mise/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/.config/mise/lib/common.sh"
fi
if [[ -f "${REPO_ROOT}/.config/mise/lib/secrets.sh" ]]; then
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/.config/mise/lib/secrets.sh"
fi
# Defensive fallbacks so the script is robust even if common.sh is unavailable.
if ! declare -F info >/dev/null 2>&1; then
  info() { printf '[info] %s\n' "$*" >&2; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '[warn] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() {
    printf '[err ] %s\n' "$*" >&2
    exit 1
  }
fi

cd "${REPO_ROOT}"

# --- Committed defaults (conf.d/10-env.toml owns these; init only confirms/overrides) ---
readonly DEFAULT_LIMA_NETWORK="shared"
readonly DEFAULT_SHARED_SUBNET="192.168.105.0/24"
readonly DEFAULT_CP_VIP="192.168.105.40"
readonly DEFAULT_LB_RANGE_START="192.168.105.200"
readonly DEFAULT_LB_RANGE_STOP="192.168.105.250"
readonly SOCKET_VMNET_BIN="/opt/socket_vmnet/bin/socket_vmnet"
readonly LIMA_NETWORKS_YAML="${HOME}/.lima/_config/networks.yaml"
readonly AGE_KEY="${REPO_ROOT}/secrets/age/key.txt"
readonly LOCAL_OVERRIDE="${REPO_ROOT}/.config/mise/conf.d/99-local.toml"
readonly GITIGNORE="${REPO_ROOT}/.gitignore"
readonly GITIGNORE_LINE=".config/mise/conf.d/99-local.toml"

# --- Prompt helpers ------------------------------------------------------------
# ask_yn <prompt> [default:Y|N] — return 0 for yes, 1 for no. Non-interactive
# (no TTY) auto-answers the default so the task can run unattended in CI.
ask_yn() {
  local prompt="$1" default="${2:-N}" reply
  local hint
  if [[ "${default}" == "Y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  if [[ ! -t 0 ]]; then
    info "${prompt} ${hint} — non-interactive shell, assuming ${default}."
    [[ "${default}" == "Y" ]]
    return
  fi
  printf '%s %s ' "${prompt}" "${hint}" >&2
  read -r reply || reply=""
  reply="${reply:-${default}}"
  case "${reply}" in
  [Yy] | [Yy][Ee][Ss]) return 0 ;;
  *) return 1 ;;
  esac
}

# ask_val <prompt> <default> — print the operator's answer (or the default) to
# stdout. Non-interactive (no TTY) returns the default unchanged. The prompt and
# the chosen default are echoed to stderr so stdout stays clean for capture.
ask_val() {
  local prompt="$1" default="$2" reply
  if [[ ! -t 0 ]]; then
    info "${prompt} [${default}] — non-interactive shell, using default."
    printf '%s\n' "${default}"
    return
  fi
  printf '%s [%s]: ' "${prompt}" "${default}" >&2
  read -r reply || reply=""
  printf '%s\n' "${reply:-${default}}"
}

# step <n> <title> — print a section header.
step() {
  printf '\n=== Step %s: %s ===\n' "$1" "$2" >&2
}

# run_task_or_script <mise-task> <script-path> — prefer the task when mise has
# discovered it, otherwise run the file directly. This keeps init robust when a
# newly added file-task is present but not yet visible to mise for any reason.
run_task_or_script() {
  local task="$1" script="$2"
  if command -v mise >/dev/null 2>&1 &&
    mise tasks ls --all 2>/dev/null | awk '{print $1}' | grep -qxF "${task}"; then
    mise run "${task}"
  else
    bash "${script}"
  fi
}

# --- IP helpers (pure bash; no external deps) ----------------------------------
# ip_to_int <a.b.c.d> — print the 32-bit integer for a dotted IPv4, or empty on
# a malformed address (caller treats empty as invalid).
ip_to_int() {
  local ip="$1" a b c d
  IFS='.' read -r a b c d <<<"${ip}"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "${o}" =~ ^[0-9]+$ ]] || return 1
    ((o >= 0 && o <= 255)) || return 1
  done
  printf '%s\n' "$(((a << 24) | (b << 16) | (c << 8) | d))"
}

# ip_in_cidr <ip> <cidr> — return 0 if ip is inside the cidr network, else 1.
ip_in_cidr() {
  local ip="$1" cidr="$2" net prefix ip_i net_i mask
  net="${cidr%/*}"
  prefix="${cidr#*/}"
  [[ "${prefix}" =~ ^[0-9]+$ ]] && ((prefix >= 0 && prefix <= 32)) || return 1
  ip_i="$(ip_to_int "${ip}")" || return 1
  net_i="$(ip_to_int "${net}")" || return 1
  [[ -n "${ip_i}" && -n "${net_i}" ]] || return 1
  if ((prefix == 0)); then
    return 0
  fi
  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  [[ $((ip_i & mask)) -eq $((net_i & mask)) ]]
}

# ip_add <base.ip> <n> — print the IPv4 that is <n> addresses above base.ip
# (used to derive the 5 per-service VIPs from the LB range start).
ip_add() {
  local ip="$1" n="$2" base
  base="$(ip_to_int "${ip}")" || return 1
  local sum=$((base + n))
  printf '%d.%d.%d.%d\n' \
    $(((sum >> 24) & 255)) $(((sum >> 16) & 255)) $(((sum >> 8) & 255)) $((sum & 255))
}

# warn_if_busy <ip> <label> — best-effort liveness probe; warn (do not fail) if
# the address already answers ping (someone else may own it).
warn_if_busy() {
  local ip="$1" label="$2"
  command -v ping >/dev/null 2>&1 || return 0
  if ping -c1 -t1 "${ip}" >/dev/null 2>&1; then
    warn "address ${ip} (${label}) already responds to ping — possible collision; pick a different IP or stop the other owner."
    return 1
  fi
  return 0
}

# --- Step 1: platform assertions ----------------------------------------------
# The task scripts avoid mapfile and associative arrays, so the stock macOS bash
# (3.2) is sufficient — no Homebrew bash on PATH is required.
step 1 "Platform prerequisites (bash >= 3.2, macOS arm64)"
if [[ "${BASH_VERSINFO[0]:-0}" -gt 3 || ("${BASH_VERSINFO[0]:-0}" -eq 3 && "${BASH_VERSINFO[1]:-0}" -ge 2) ]]; then
  info "bash ${BASH_VERSION} (>= 3.2) OK"
else
  die "bash ${BASH_VERSION:-unknown} is too old (need >= 3.2, the stock macOS version)."
fi
if [[ "$(uname -s)" == "Darwin" ]]; then
  info "platform: macOS (Darwin) OK"
else
  die "this lab targets macOS (Darwin); got $(uname -s)."
fi
if [[ "$(uname -m)" == "arm64" ]]; then
  info "architecture: Apple Silicon (arm64) OK"
else
  die "this lab targets Apple Silicon (arm64); got $(uname -m)."
fi

# --- Step 2: brew bundle ------------------------------------------------------
step 2 "Homebrew dependencies (brew bundle)"
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew is not on PATH. Run 'mise run bootstrap' first (it installs Homebrew), then re-run 'mise run init'."
elif ask_yn "Run 'brew bundle' to install host dependencies (bash, socket_vmnet, lima, ...)?" Y; then
  brew bundle --file "${REPO_ROOT}/Brewfile"
  info "brew bundle complete"
else
  info "Skipped brew bundle (assuming host dependencies are already installed)."
fi

# --- Step 3: mise install + trust ---------------------------------------------
step 3 "mise toolchain (install + trust)"
if command -v mise >/dev/null 2>&1; then
  mise trust --yes "${REPO_ROOT}" >/dev/null 2>&1 || true
  if ask_yn "Run 'mise install' to materialize the pinned [tools] versions?" Y; then
    mise install
    info "mise install complete"
  else
    info "Skipped mise install (assuming the pinned toolchain is already present)."
  fi
else
  warn "mise is not on PATH. Install it (brew install mise) and re-run, or run 'mise run bootstrap' first."
fi

# --- Step 4: mermaid-cli Chrome (tools:mmdc-setup) ----------------------------
step 4 "Mermaid renderer (mmdc + headless Chrome)"
if command -v mmdc >/dev/null 2>&1; then
  if ask_yn "Run 'tools:mmdc-setup' to install the puppeteer-managed Chrome mermaid-cli needs?" Y; then
    mise run tools:mmdc-setup
    info "mmdc Chrome setup complete"
  else
    info "Skipped mmdc setup (diagram validation 'validate:mermaid' will need it later)."
  fi
else
  warn "mmdc is not on PATH yet — run 'mise install' (step 3) first, then re-run init for the Chrome setup."
fi

# --- Step 5: socket_vmnet path + networks.yaml + Lima sudoers ------------------
# Order matters: (a) socket_vmnet at the root-owned /opt path, (b) networks.yaml
# .paths.socketVMNet pointed at that same /opt path, THEN (c) the Lima sudoers file —
# so the sudoers rules reference the corrected path and come out non-empty.
step 5 "Lima shared network (socket_vmnet + networks.yaml + sudoers)"
info "The cluster uses a Lima socket_vmnet network — real L2 — so the Mac reaches the control-plane VIP and the Cilium service VIPs directly."

# (a) socket_vmnet secure binary. Homebrew installs it under /opt/homebrew, but Lima
# only accepts a root-owned copy under /opt/socket_vmnet — so it must be copied there
# with sudo (init never runs sudo; it prints the exact commands).
if [[ -x "${SOCKET_VMNET_BIN}" ]]; then
  info "socket_vmnet secure binary present at ${SOCKET_VMNET_BIN} OK"
else
  warn "socket_vmnet secure binary is MISSING at ${SOCKET_VMNET_BIN}."
  warn "Homebrew installs socket_vmnet under /opt/homebrew, but Lima requires it at a"
  warn "root-owned path. Copy it there with YOUR sudo in another shell:"
  # Instructional text: the $(brew --prefix …) must print literally for the operator to run.
  # shellcheck disable=SC2016
  printf '\n    sudo mkdir -p /opt/socket_vmnet/bin\n    sudo cp "$(brew --prefix socket_vmnet)/bin/socket_vmnet" /opt/socket_vmnet/bin/socket_vmnet\n    sudo chown -R root:wheel /opt/socket_vmnet\n    sudo chmod 755 /opt/socket_vmnet/bin/socket_vmnet\n\n' >&2
  warn "init does NOT run sudo for you. Run the commands above, then re-run 'mise run init' (or 'mise run up')."
fi

# (b) networks.yaml .paths.socketVMNet -> the root-owned /opt path. Lima auto-generates
# this key with the uid-owned Homebrew Cellar path, which it then REJECTS ("not owned by
# root") — that breaks lima:start AND makes `limactl sudoers` write an empty
# /etc/sudoers.d/lima. Set ONLY that one key (preserve everything else Lima generated).
# No sudo needed; the file is user-owned. Idempotent (safe to re-run).
if command -v yq >/dev/null 2>&1; then
  # Materialize Lima's default networks.yaml first if it doesn't exist yet.
  if [[ ! -f "${LIMA_NETWORKS_YAML}" ]] && command -v limactl >/dev/null 2>&1; then
    limactl network list >/dev/null 2>&1 || true
  fi
  if [[ -f "${LIMA_NETWORKS_YAML}" ]]; then
    current_socketvmnet="$(yq '.paths.socketVMNet // ""' "${LIMA_NETWORKS_YAML}" 2>/dev/null || true)"
    if [[ "${current_socketvmnet}" == "${SOCKET_VMNET_BIN}" ]]; then
      info "networks.yaml .paths.socketVMNet already ${SOCKET_VMNET_BIN} OK"
    elif yq -i ".paths.socketVMNet = \"${SOCKET_VMNET_BIN}\"" "${LIMA_NETWORKS_YAML}"; then
      info "Set networks.yaml .paths.socketVMNet -> ${SOCKET_VMNET_BIN} (was: ${current_socketvmnet:-<unset>})."
    else
      warn "Failed to patch ${LIMA_NETWORKS_YAML}; set .paths.socketVMNet to ${SOCKET_VMNET_BIN} by hand before 'mise run up'."
    fi
  else
    warn "Lima networks.yaml not found at ${LIMA_NETWORKS_YAML} and could not be generated (limactl missing?)."
    warn "After 'brew bundle' installs Lima, re-run init so it can set .paths.socketVMNet to ${SOCKET_VMNET_BIN}."
  fi
else
  warn "yq not on PATH — cannot set .paths.socketVMNet in ${LIMA_NETWORKS_YAML}."
  warn "Run 'mise install' (step 3) then re-run init, or set it by hand to ${SOCKET_VMNET_BIN}."
fi

# (c) Lima sudoers — runs AFTER (a)+(b) so its rules reference the corrected path.
if command -v limactl >/dev/null 2>&1; then
  # `limactl sudoers --check` ALONE is NOT sufficient: it returns OK whenever ANY
  # passwordless sudo exists (e.g. leftover NOPASSWD rules for an OLDER socket_vmnet
  # path layout), so it can pass while `limactl start` still dies on
  # `mkdir /private/var/run/lima: a password is required`. Lima's shared network
  # needs Lima's OWN managed rules for the namespaced /private/var/run/lima/...
  # socket_vmnet commands — so REQUIRE the managed file AND the check.
  if [[ -f /etc/sudoers.d/lima ]] && limactl sudoers --check >/dev/null 2>&1; then
    info "Lima sudoers OK (/etc/sudoers.d/lima present and current) — nothing to do."
  else
    if [[ -f /etc/sudoers.d/lima ]]; then
      warn "Lima sudoers file exists but is out of date (limactl sudoers --check failed)."
    else
      warn "Lima sudoers file /etc/sudoers.d/lima is MISSING."
      warn "NOTE: 'limactl sudoers --check' may still print OK if you have older passwordless sudo"
      warn "rules — but socket_vmnet needs Lima's own rules for the /private/var/run/lima paths, so"
      warn "'mise run up' WILL fail on 'mkdir /private/var/run/lima: a password is required' without it."
    fi
    warn "Generate/refresh it with YOUR sudo in another shell (this authorizes socket_vmnet):"
    printf '\n    limactl sudoers | sudo tee /etc/sudoers.d/lima >/dev/null\n    limactl sudoers --check\n\n' >&2
    warn "init does NOT run sudo for you. Run the commands above, then re-run 'mise run init' (or 'mise run up')."
  fi
else
  warn "limactl is not on PATH yet — install Lima via 'brew bundle' (step 2), then re-run init to check sudoers."
fi

# --- Step 6: network + VIP/LB IP plan -----------------------------------------
step 6 "Network + VIP / LoadBalancer IP plan"

# Show existing networks (read-only). Aside from the single .paths.socketVMNet key
# corrected in Step 5, init does not hand-edit ~/.lima/_config/networks.yaml — network
# definitions are inspected and created through Lima's CLI.
if command -v limactl >/dev/null 2>&1; then
  info "Existing Lima networks (limactl network list, read-only):"
  limactl network list >&2 || warn "limactl network list failed — continuing with defaults."
else
  warn "limactl not on PATH — cannot list networks; continuing with the committed defaults."
fi

# Seed the plan from an existing 99-local.toml (idempotent re-run) or the committed defaults.
lima_network="${DEFAULT_LIMA_NETWORK}"
shared_subnet="${DEFAULT_SHARED_SUBNET}"
cp_vip="${DEFAULT_CP_VIP}"
lb_start="${DEFAULT_LB_RANGE_START}"
lb_stop="${DEFAULT_LB_RANGE_STOP}"

reuse_existing="no"
if [[ -f "${LOCAL_OVERRIDE}" ]]; then
  info "Found an existing local override at ${LOCAL_OVERRIDE#"${REPO_ROOT}/"}; its current values:"
  # Print only the AI_INFRA_* lines (no secrets live here).
  grep -E '^\s*AI_INFRA_[A-Z_]+\s*=' "${LOCAL_OVERRIDE}" >&2 || true
  # Pull the values we manage so "keep" preserves them.
  read_local() { sed -nE "s/^\s*$1\s*=\s*\"?([^\"#]+)\"?.*/\1/p" "${LOCAL_OVERRIDE}" | head -n1 | tr -d '[:space:]'; }
  v="$(read_local AI_INFRA_LIMA_NETWORK)" && [[ -n "${v}" ]] && lima_network="${v}"
  v="$(read_local AI_INFRA_SHARED_SUBNET)" && [[ -n "${v}" ]] && shared_subnet="${v}"
  v="$(read_local AI_INFRA_CP_VIP)" && [[ -n "${v}" ]] && cp_vip="${v}"
  v="$(read_local AI_INFRA_LB_RANGE_START)" && [[ -n "${v}" ]] && lb_start="${v}"
  v="$(read_local AI_INFRA_LB_RANGE_STOP)" && [[ -n "${v}" ]] && lb_stop="${v}"
  if ask_yn "Keep these existing local override values?" Y; then
    reuse_existing="yes"
    info "Keeping the existing local override unchanged."
  fi
fi

if [[ "${reuse_existing}" == "no" ]]; then
  # Network name. Default to the existing 'shared' network; allow a dedicated one.
  lima_network="$(ask_val "Lima network name to use" "${lima_network}")"

  # If the chosen network is not in `limactl network list`, offer to create it
  # (shared mode) via the CLI — never by editing networks.yaml.
  if command -v limactl >/dev/null 2>&1; then
    if ! limactl network list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${lima_network}"; then
      warn "Network '${lima_network}' does not exist yet."
      if ask_yn "Create a dedicated shared-mode network '${lima_network}' via 'limactl network create'?" N; then
        create_gw="$(ask_val "Gateway CIDR for '${lima_network}' (e.g. 192.168.107.1/24)" "192.168.107.1/24")"
        if limactl network create "${lima_network}" --mode shared --gateway "${create_gw}" >&2; then
          info "Created network '${lima_network}' (--mode shared --gateway ${create_gw})."
          # Default the subnet to the .0 of the gateway CIDR for the prompt below.
          gw_ip="${create_gw%/*}"
          shared_subnet="${gw_ip%.*}.0/${create_gw#*/}"
        else
          warn "limactl network create failed — falling back to the existing default network/subnet."
          lima_network="${DEFAULT_LIMA_NETWORK}"
        fi
      else
        info "Not creating '${lima_network}'. Falling back to '${DEFAULT_LIMA_NETWORK}'."
        lima_network="${DEFAULT_LIMA_NETWORK}"
      fi
    else
      # Display the chosen network's subnet (read-only) from the CLI.
      net_gw="$(limactl network list 2>/dev/null | awk -v n="${lima_network}" '$1==n {print $3}')"
      if [[ -n "${net_gw}" && "${net_gw}" != "-" ]]; then
        info "Network '${lima_network}' gateway/subnet (read-only): ${net_gw}"
        gw_ip="${net_gw%/*}"
        shared_subnet="${gw_ip%.*}.0/${net_gw#*/}"
      fi
    fi
  fi

  # Subnet, CP VIP, LB range — confirm or override.
  shared_subnet="$(ask_val "Shared subnet (CIDR)" "${shared_subnet}")"
  cp_vip="$(ask_val "Control-plane VIP" "${cp_vip}")"
  lb_start="$(ask_val "LB-IPAM pool start" "${lb_start}")"
  lb_stop="$(ask_val "LB-IPAM pool stop" "${lb_stop}")"
fi

# Validate the plan (subnet membership) regardless of reuse/fresh.
if ! ip_in_cidr "${cp_vip}" "${shared_subnet}"; then
  die "control-plane VIP ${cp_vip} is not inside subnet ${shared_subnet} — fix the values and re-run init."
fi
if ! ip_in_cidr "${lb_start}" "${shared_subnet}"; then
  die "LB pool start ${lb_start} is not inside subnet ${shared_subnet} — fix the values and re-run init."
fi
if ! ip_in_cidr "${lb_stop}" "${shared_subnet}"; then
  die "LB pool stop ${lb_stop} is not inside subnet ${shared_subnet} — fix the values and re-run init."
fi
if [[ "$(ip_to_int "${lb_start}")" -gt "$(ip_to_int "${lb_stop}")" ]]; then
  die "LB pool start ${lb_start} is above stop ${lb_stop} — swap them and re-run init."
fi

# Derive the 5 per-service VIPs from the LB range start (start+0..+4).
litellm_vip="$(ip_add "${lb_start}" 0)"
langfuse_vip="$(ip_add "${lb_start}" 1)"
grafana_vip="$(ip_add "${lb_start}" 2)"
otel_vip="$(ip_add "${lb_start}" 3)"
hubble_vip="$(ip_add "${lb_start}" 4)"
for v in "${litellm_vip}" "${langfuse_vip}" "${grafana_vip}" "${otel_vip}" "${hubble_vip}"; do
  if ! ip_in_cidr "${v}" "${shared_subnet}"; then
    die "derived service VIP ${v} (from LB start ${lb_start}) is outside subnet ${shared_subnet} — widen the pool or move the start."
  fi
done

info "Plan:"
info "  network            : ${lima_network}"
info "  subnet             : ${shared_subnet}"
info "  control-plane VIP  : ${cp_vip}"
info "  LB-IPAM pool       : ${lb_start} - ${lb_stop}"
info "Service URLs (clickable in most terminals):"
info "  Kubernetes API     : https://${cp_vip}:6443"
info "  LiteLLM gateway    : http://${litellm_vip}:4000/v1"
info "  Langfuse UI        : http://${langfuse_vip}:3000"
info "  Grafana            : http://${grafana_vip}:3000"
info "  OTel Collector     : http://${otel_vip}:4318"
info "  Hubble UI          : http://${hubble_vip}"

# Best-effort liveness probe (warn only — never fail the plan on a ping reply).
warn_if_busy "${cp_vip}" "control-plane VIP" || true
warn_if_busy "${lb_start}" "LB pool start" || true
warn_if_busy "${lb_stop}" "LB pool stop" || true

# Write the confirmed values to the GITIGNORED local override (mise auto-loads
# conf.d/*.toml in lexical order, so 99-local.toml wins over 10-env.toml).
if [[ "${reuse_existing}" == "yes" ]]; then
  info "Local override kept as-is (no write)."
else
  umask 077
  cat >"${LOCAL_OVERRIDE}" <<EOF
# 99-local.toml — GITIGNORED per-host overrides written by 'mise run init'.
#
# mise merges every .config/mise/conf.d/*.toml in lexical order; this file sorts
# LAST, so these values override the committed defaults in 10-env.toml. It holds
# ONLY non-secret network/IP plan values (no secrets ever). Safe to delete and
# regenerate via 'mise run init'.

[env]
AI_INFRA_LIMA_NETWORK   = "${lima_network}"
AI_INFRA_SHARED_SUBNET  = "${shared_subnet}"
AI_INFRA_CP_VIP         = "${cp_vip}"
AI_INFRA_LB_RANGE_START = "${lb_start}"
AI_INFRA_LB_RANGE_STOP  = "${lb_stop}"
AI_INFRA_LITELLM_VIP    = "${litellm_vip}"
AI_INFRA_LANGFUSE_VIP   = "${langfuse_vip}"
AI_INFRA_GRAFANA_VIP    = "${grafana_vip}"
AI_INFRA_OTEL_VIP       = "${otel_vip}"
AI_INFRA_HUBBLE_VIP     = "${hubble_vip}"
EOF
  info "Wrote ${LOCAL_OVERRIDE#"${REPO_ROOT}/"} (gitignored)."
fi

# Ensure the override is gitignored (ADD one line only; never rewrite .gitignore).
if [[ -f "${GITIGNORE}" ]] && ! grep -qxF "${GITIGNORE_LINE}" "${GITIGNORE}"; then
  printf '\n# --- init-written per-host network/IP override (never commit) ---\n%s\n' "${GITIGNORE_LINE}" >>"${GITIGNORE}"
  info "Added '${GITIGNORE_LINE}' to .gitignore."
fi

# --- Step 7: age key + secret sealing -----------------------------------------
step 7 "Secrets (age key + fnox store)"
if [[ -f "${AGE_KEY}" ]]; then
  info "age key already present at secrets/age/key.txt OK (never committed; mode 600)"
  if ask_yn "Sync the age PUBLIC recipient into secrets/.agerecipients and the gitignored fnox.local.toml?" Y; then
    run_task_or_script secrets:keygen "${REPO_ROOT}/.config/mise/tasks/secrets/keygen.sh"
  fi
else
  warn "No age key found at secrets/age/key.txt — secrets cannot be decrypted without one."
  if ask_yn "Generate a new age key now (writes the gitignored secrets/age/key.txt and syncs only the PUBLIC recipient)?" Y; then
    run_task_or_script secrets:keygen "${REPO_ROOT}/.config/mise/tasks/secrets/keygen.sh"
  else
    info "Skipped age key generation. Run 'mise run secrets:keygen' when ready."
  fi
fi

info "Fnox-managed secret values required for the lab (names only unless the purpose is non-obvious):"
info "  LiteLLM virtual keys — fixed client tokens for host-side launchers and smoke tests:"
info "    - CLAUDE_CODE_LITELLM_VIRTUAL_KEY"
info "    - CODEX_LITELLM_VIRTUAL_KEY"
info "    - SMOKE_TEST_LITELLM_VIRTUAL_KEY"
info "  Standard passwords — ordinary generated login/database/cache passwords:"
info "    - GRAFANA_ADMIN_PASSWORD"
info "    - LANGFUSE_ADMIN_PASSWORD"
info "    - LANGFUSE_PG_PASSWORD"
info "    - LITELLM_PG_PASSWORD"
info "    - GRAFANA_PG_PASSWORD"
info "    - CLICKHOUSE_PASSWORD"
info "    - VALKEY_PASSWORD"
info "  Other keys with special handling:"
info "    - LITELLM_MASTER_KEY: LiteLLM admin key used by automation to create teams and mint client keys. Treat it as higher privilege than a normal client key."
info "    - LANGFUSE_PUBLIC_KEY: project public API key used by LiteLLM and telemetry clients when sending traces to Langfuse."
info "    - LANGFUSE_SECRET_KEY: project secret API key paired with LANGFUSE_PUBLIC_KEY; lets clients authenticate trace ingestion."
info "    - LANGFUSE_SALT: write-once hash salt for Langfuse API keys. If it changes after first boot, existing API keys can no longer be verified."
info "    - LANGFUSE_NEXTAUTH_SECRET: signs Langfuse browser sessions/JWTs; rotating it logs users out but does not corrupt stored data."
info "    - LANGFUSE_ENCRYPTION_KEY: write-once 64-hex-character key for encrypted Langfuse fields. If it changes after first boot, previously encrypted values become undecryptable."
info "    - SEAWEEDFS_S3_ACCESS_KEY: S3 access key ID for SeaweedFS object storage, shared by Langfuse, Loki, and Tempo."
info "    - SEAWEEDFS_S3_SECRET_KEY: S3 secret access key paired with SEAWEEDFS_S3_ACCESS_KEY."
info "Optional plaintext-only values (not sealed into fnox):"
for k in "${AI_INFRA_SHARED_ENV_OPTIONAL_KEYS[@]}"; do
  info "  - ${k}: $(ai_infra_secret_description "${k}")"
done

info "secrets/shared.env is gitignored plaintext input. Init generates strong random values for missing fnox-managed keys and preserves existing non-placeholder values."
if ask_yn "Generate/repair secrets/shared.env now?" Y; then
  run_task_or_script secrets:generate "${REPO_ROOT}/.config/mise/tasks/secrets/generate.sh"
else
  info "Skipped secrets/shared.env generation. Run 'mise run secrets:generate' before sealing."
fi

if [[ -f "${REPO_ROOT}/secrets/shared.env" ]]; then
  if ask_yn "Seal fnox-managed values from secrets/shared.env into the gitignored fnox.local.toml now?" Y; then
    run_task_or_script secrets:seal "${REPO_ROOT}/.config/mise/tasks/secrets/seal.sh"
    info "Sealed. Keep secrets/shared.env private; cluster:teardown backs it up with a timestamp instead of deleting it."
  else
    info "Skipped sealing. Run 'mise run secrets:seal' after secrets/shared.env is complete."
  fi
fi
warn "Write-once values LANGFUSE_SALT and LANGFUSE_ENCRYPTION_KEY must NEVER be rotated after first boot."

# Claude Code raw API bodies target: OTEL_LOG_RAW_API_BODIES (conf.d/10-env.toml)
# points here but claude does NOT create the directory, so it must pre-exist. Also
# created by host/up.sh and the claude launch tasks — all idempotent.
mkdir -p "${REPO_ROOT}/.local/logs/claude/otel-raw-bodies" # Claude Code OTEL_LOG_RAW_API_BODIES target (must pre-exist; claude does not create it)

# --- Codex global config (~/.codex/config.toml) ---------------------------------
# The repo no longer overrides CODEX_HOME. Instead, `codex:global-config` merges the
# minimal project blocks ([projects] trust, [otel] exporters, [analytics] off, inert
# litellm_local provider definition) into the REAL ~/.codex/config.toml, taking a
# UTC-timestamped backup before it appends anything (and no backup at all on an
# idempotent re-run that merges nothing).
# NOTE: this prompt defaults to Y, and ask_yn AUTO-ACCEPTS the default in a
# non-interactive shell — so any unattended/scripted `mise run init` (the headless
# remote fresh-clone deploy relies on this) DOES merge into the operator's real
# ~/.codex/config.toml. That is intentional and safe (idempotent merge + backup); to
# avoid touching a personal ~/.codex, run init attended and answer 'n', or run
# `codex:global-config` separately.
if ask_yn "Merge the ai-infra [otel]/trust blocks into ~/.codex/config.toml now (timestamped backup)?" Y; then
  run_task_or_script codex:global-config "${REPO_ROOT}/.config/mise/tasks/codex/global-config.sh"
else
  info "Skipped. Run 'mise run codex:global-config' before using bare codex telemetry."
fi

# --- Step 8: next step --------------------------------------------------------
step 8 "Next"
info "First-time setup complete."
info "Bring up the whole lab (cluster + planes + host services) with:"
printf '\n    mise run up\n\n' >&2
info "Then: 'mise run smoke' to verify, and 'mise run down' to tear it down."
