#!/usr/bin/env bash
# .config/mise/lib/preflight.sh — host-resource preflight for the ai-infra-platform.
#
# Sourced by the `preflight:resources` report task and by the interactive `up`
# dispatcher. It compares the host's CPU / RAM / disk against each topology
# profile's requirements, renders a table, warns on shortfalls, and recommends a
# profile. Pure computation + rendering — NO prompting, NO bring-up (the prompt
# lives in the `up` task so this stays safely testable stand-alone).
#
# Requirements are CURATED from the real VM sizing (the honest host-level gate is
# the Lima VM footprint, which is pre-allocated up front — not the sum of in-VM pod
# requests, which macOS/Lima never sees). Keep these in sync with:
#   - lima/templates/k8s-cilium.yaml   (HA per-node cpus/memory/disk)
#   - .config/mise/tasks/lima/start.sh (lean SIZE_OVERRIDE + node count)
#
# Per-profile totals (cluster VMs + a modest Mac-side host-service allowance):
#   lean : 1 node  x (6 vCPU / 12 GiB / 50 GiB)  + ~0.5 GiB host svcs (alloy+macmon;
#          llama-swap is skipped under lean) -> 6 vCPU / 12.5 GiB / 50 GiB
#   ha   : 3 nodes x (3 vCPU /  9 GiB / 50 GiB)  + ~1.5 GiB host svcs (alloy+macmon+
#          llama-swap idle)                      -> 9 vCPU / 28.5 GiB / 150 GiB
#   (+ transient during image pulls: the ai-registry cache VM, 2 vCPU / 2 GiB / 40 GiB)
#
# bash 3.2 compatible (stock macOS): no associative arrays, no mapfile.

# macOS headroom kept for the OS + apps when deciding what RAM is usable for the
# platform. macOS aggressively reclaims file cache, so total-RAM-minus-reserve is a
# far more reliable sizing gate than the instantaneous vm_stat "available".
PF_MACOS_RESERVE_GIB="3.0"

# --- small float helpers (bash can't compare floats) ---
_pf_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }        # a >= b ?
_pf_sub() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", a-b}'; } # a - b (1 dp)
_pf_b2g() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }  # bytes -> GiB

# _pf_req <profile> -> "vcpu mem_gib disk_gib nodes per_cpu per_mem per_disk"
# per_* are the per-NODE VM sizing (for the "N x c/m/d" display); the leading three
# are the profile TOTAL requirement incl. the host-service allowance.
_pf_req() {
  case "$1" in
  lean) echo "6 12.5 50 1 6 12 50" ;;
  ha) echo "9 28.5 150 3 3 9 50" ;;
  *) echo "" ;;
  esac
}

# preflight_collect_host — populate PF_* host facts (GiB, 1 dp; cores int).
preflight_collect_host() {
  PF_OS="$(uname -s 2>/dev/null || echo unknown)"
  PF_CORES="$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 0)"
  local mem_bytes page free inact spec purg avail_bytes used_bytes
  mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  page="$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)"
  # vm_stat page counts (values have a trailing '.'). available ~= free + inactive
  # + speculative + purgeable (reclaimable) pages.
  read -r free inact spec purg <<EOF
$(vm_stat 2>/dev/null | awk '
    /Pages free/        {gsub(/\./,"",$NF); f=$NF}
    /Pages inactive/    {gsub(/\./,"",$NF); i=$NF}
    /Pages speculative/ {gsub(/\./,"",$NF); s=$NF}
    /Pages purgeable/   {gsub(/\./,"",$NF); p=$NF}
    END{printf "%s %s %s %s", f+0, i+0, s+0, p+0}')
EOF
  avail_bytes="$(awk -v f="${free:-0}" -v i="${inact:-0}" -v s="${spec:-0}" -v p="${purg:-0}" -v ps="${page}" \
    'BEGIN{printf "%.0f", (f+i+s+p)*ps}')"
  used_bytes="$(awk -v t="${mem_bytes}" -v a="${avail_bytes}" 'BEGIN{u=t-a; if(u<0)u=0; printf "%.0f", u}')"
  PF_MEM_TOTAL_GIB="$(_pf_b2g "${mem_bytes}")"
  PF_MEM_AVAIL_GIB="$(_pf_b2g "${avail_bytes}")"
  PF_MEM_USED_GIB="$(_pf_b2g "${used_bytes}")"
  PF_USABLE_GIB="$(_pf_sub "${PF_MEM_TOTAL_GIB}" "${PF_MACOS_RESERVE_GIB}")"
  # Disk free (GiB) on the volume that holds the Lima images (~/.lima).
  PF_DISK_TARGET="${HOME}"
  PF_DISK_AVAIL_GIB="$(df -g "${HOME}" 2>/dev/null | awk 'NR==2{print $4}')"
  [ -n "${PF_DISK_AVAIL_GIB:-}" ] || PF_DISK_AVAIL_GIB="0"
}

# _pf_verdict <profile> — sets PF_V_* strings for the row + returns 0 if it FITS
# (RAM + disk satisfied; CPU overcommit is a soft warning, never a hard fail).
_pf_verdict() {
  local prof="$1" req rvcpu rmem rdisk
  req="$(_pf_req "${prof}")"
  rvcpu="$(echo "${req}" | awk '{print $1}')"
  rmem="$(echo "${req}" | awk '{print $2}')"
  rdisk="$(echo "${req}" | awk '{print $3}')"
  local mem_ok disk_ok cpu_ok
  _pf_ge "${PF_USABLE_GIB}" "${rmem}" && mem_ok=1 || mem_ok=0
  _pf_ge "${PF_DISK_AVAIL_GIB}" "${rdisk}" && disk_ok=1 || disk_ok=0
  _pf_ge "${PF_CORES}" "${rvcpu}" && cpu_ok=1 || cpu_ok=0
  PF_V_NOTES=""
  [ "${mem_ok}" = 0 ] && PF_V_NOTES="${PF_V_NOTES}RAM(need ${rmem}, usable ${PF_USABLE_GIB}) "
  [ "${disk_ok}" = 0 ] && PF_V_NOTES="${PF_V_NOTES}disk(need ${rdisk}, free ${PF_DISK_AVAIL_GIB}) "
  [ "${cpu_ok}" = 0 ] && PF_V_NOTES="${PF_V_NOTES}cpu-overcommit(${rvcpu}vCPU on ${PF_CORES}) "
  if [ "${mem_ok}" = 1 ] && [ "${disk_ok}" = 1 ]; then
    PF_V_FIT="FITS"
    [ "${cpu_ok}" = 1 ] || PF_V_FIT="FITS*"
    return 0
  fi
  PF_V_FIT="SHORT"
  return 1
}

# preflight_render — print the table, set PF_LEAN_FITS / PF_HA_FITS / PF_RECOMMENDED.
# Writes to stderr (like the rest of the task logging). Never prompts.
preflight_render() {
  preflight_collect_host
  local y="${_c_yellow:-}" b="${_c_blue:-}" d="${_c_dim:-}" r="${_c_reset:-}"

  if [ "${PF_OS}" != "Darwin" ]; then
    warn "resource preflight: non-macOS host (${PF_OS}); skipping host sizing check, assuming lean."
    PF_LEAN_FITS=1
    PF_HA_FITS=0
    PF_RECOMMENDED="lean"
    return 0
  fi

  {
    printf '%s=== ai-infra-platform resource preflight ===%s\n' "${b}" "${r}"
    printf 'Host: %s cores | RAM %s GiB (in use %s, avail %s) | Disk free %s GiB (%s)\n' \
      "${PF_CORES}" "${PF_MEM_TOTAL_GIB}" "${PF_MEM_USED_GIB}" "${PF_MEM_AVAIL_GIB}" \
      "${PF_DISK_AVAIL_GIB}" "${PF_DISK_TARGET}"
    printf '%smacOS reserve assumed %s GiB -> %s GiB usable for the platform%s\n\n' \
      "${d}" "${PF_MACOS_RESERVE_GIB}" "${PF_USABLE_GIB}" "${r}"
    printf '%-7s %-22s %-30s %s\n' "Profile" "Cluster VMs" "Required (vCPU / RAM / disk)" "Verdict"
  } >&2

  local prof req nodes pcpu pmem pdisk tvcpu tmem tdisk vms fit
  PF_LEAN_FITS=0
  PF_HA_FITS=0
  for prof in lean ha; do
    req="$(_pf_req "${prof}")"
    tvcpu="$(echo "${req}" | awk '{print $1}')"
    tmem="$(echo "${req}" | awk '{print $2}')"
    tdisk="$(echo "${req}" | awk '{print $3}')"
    nodes="$(echo "${req}" | awk '{print $4}')"
    pcpu="$(echo "${req}" | awk '{print $5}')"
    pmem="$(echo "${req}" | awk '{print $6}')"
    pdisk="$(echo "${req}" | awk '{print $7}')"
    vms="${nodes} x ${pcpu}vCPU/${pmem}GiB/${pdisk}G"
    if _pf_verdict "${prof}"; then
      [ "${prof}" = lean ] && PF_LEAN_FITS=1 || PF_HA_FITS=1
      fit="${PF_V_FIT}"
    else
      fit="${PF_V_FIT}: ${PF_V_NOTES}"
    fi
    printf '%-7s %-22s %-30s %s\n' \
      "${prof}" "${vms}" "${tvcpu} / ${tmem} GiB / ${tdisk} GiB" "${fit}" >&2
  done

  # Recommend the richest profile that fits; else lean (closest) with a caution.
  if [ "${PF_HA_FITS}" = 1 ]; then
    PF_RECOMMENDED="ha"
  elif [ "${PF_LEAN_FITS}" = 1 ]; then
    PF_RECOMMENDED="lean"
  else
    PF_RECOMMENDED="lean"
  fi

  {
    printf '\n%sRecommended: %s%s\n' "${y}" "${PF_RECOMMENDED}" "${r}"
    printf '%sFITS* = fits but CPU is overcommitted (acceptable on these Macs).%s\n' "${d}" "${r}"
    printf '%sTransient during image pulls: ai-registry cache VM 2 vCPU / 2 GiB / 40 GiB.%s\n' "${d}" "${r}"
    printf '%sNote: macOS reclaims file cache on demand, so total-RAM headroom (not the%s\n' "${d}" "${r}"
    printf '%s      instantaneous "avail") is the reliable sizing gate.%s\n' "${d}" "${r}"
    [ "${PF_LEAN_FITS}" = 0 ] &&
      printf '%sWARNING: host is below the lean minimum — proceed with caution or abort.%s\n' "${y}" "${r}"
  } >&2
  return 0
}
