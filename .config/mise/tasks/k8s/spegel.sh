#!/usr/bin/env bash
#MISE description="Install/upgrade Spegel 0.7.4 (peer-to-peer OCI mirror), wait for the DaemonSet rollout."
set -euo pipefail

# k8s:spegel — install Spegel (https://github.com/spegel-org/spegel) 0.7.4, a
# peer-to-peer OCI registry mirror that runs as a DaemonSet on every node, idempotent.
#
# Spegel turns each node's containerd content store into a peer-shared mirror: once
# one node has pulled an image, the others pull its layers from that peer over the pod
# network instead of re-hitting docker.io. A single cold cluster build therefore does
# ~one docker.io pull per image cluster-wide, with the persistent pull-through cache VM
# as the next fallback. This needs pod networking (Cilium) AND two containerd settings
# the Lima template already enables (registry config_path=/etc/containerd/certs.d,
# discard_unpacked_layers=false) — see kubernetes/spegel/README.md.
#
# Order:
#   1. Render the spegel kustomize base with `kustomize build --enable-helm` into a
#      temp dir, sed-substituting the env cache address into additionalMirrorTargets
#      (direct-helm fallback if kustomize is unavailable). The base creates the spegel
#      namespace and inlines the chart.
#   2. Apply server-side.
#   3. Wait for the Spegel DaemonSet rollout.
#
# Pin and values live in kubernetes/spegel/{kustomization,values}.yaml.
#
# CACHE-ADDR substitution (LITERAL DEFAULT + sed override at apply): the committed
# values.yaml carries the DEFAULT cache address http://192.168.105.50:5000 so the dir
# renders standalone with `kustomize build --enable-helm`. At apply time we copy the
# spegel dir to a temp render dir and `sed` the default host:port to the env value:
#   - values.yaml  additionalMirrorTargets  http://192.168.105.50:5000 -> http://${AI_INFRA_REGISTRY_ADDR}
# AI_INFRA_REGISTRY_ADDR is cache:up's DISCOVERED DHCP IP (gitignored 99-local.toml),
# the same env-driven-default + sed-override mechanism k8s:cilium uses for the VIP.
# A no-op when the env equals the default (bare checkout renders the documented addr).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/.config/mise/lib/common.sh"
install_err_trap

readonly SPEGEL_DIR="${REPO_ROOT}/kubernetes/spegel"
readonly SPEGEL_NS="spegel"
readonly SPEGEL_RELEASE="spegel"
readonly SPEGEL_REPO="oci://ghcr.io/spegel-org/helm-charts"
readonly SPEGEL_VERSION="0.7.4"
readonly WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"

# Default cache address as committed in kubernetes/spegel/values.yaml. The env
# override (cache:up's discovered DHCP IP) replaces this. Default matches
# conf.d/10-env.toml's AI_INFRA_REGISTRY_ADDR default + the template's registryAddr.
readonly DEF_REGISTRY_ADDR="192.168.105.50:5000"
readonly REGISTRY_ADDR="${AI_INFRA_REGISTRY_ADDR:-${DEF_REGISTRY_ADDR}}"
render_dir_for_cleanup=""

cleanup_render_dir() {
  [[ -z "${render_dir_for_cleanup}" ]] || rm -rf -- "${render_dir_for_cleanup}"
}

# Render the spegel kustomize dir into a temp copy with the env cache address
# substituted; echo the temp dir path on stdout. Caller cleans up. Keeps committed
# files untouched (default preserved for standalone `kustomize build`).
render_spegel_dir() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spegel-render.XXXXXX")"
  cp -R "${SPEGEL_DIR}/." "${tmp}/"
  sed -i.bak -E "s#${DEF_REGISTRY_ADDR}#${REGISTRY_ADDR}#g" "${tmp}/values.yaml"
  rm -f "${tmp}"/*.bak
  printf '%s\n' "${tmp}"
}

apply_via_kustomize() {
  local render_dir="$1"
  info "rendering Spegel chart via kustomize build --enable-helm (cache mirror target=http://${REGISTRY_ADDR})"
  kustomize build --enable-helm "${render_dir}" |
    kc apply --server-side --force-conflicts -f -
}

apply_via_helm() {
  local render_dir="$1"
  info "kustomize unavailable; installing Spegel directly via helm (idempotent upgrade --install)"
  # OCI chart: no `helm repo add` needed — reference the registry directly. Ensure
  # the namespace exists first (the kustomize path creates it from namespace.yaml).
  kc create namespace "${SPEGEL_NS}" --dry-run=client -o yaml | kc apply -f -
  helm upgrade --install "${SPEGEL_RELEASE}" "${SPEGEL_REPO}/spegel" \
    --version "${SPEGEL_VERSION}" \
    --namespace "${SPEGEL_NS}" \
    --values "${render_dir}/values.yaml" \
    --wait --timeout "${WAIT_TIMEOUT}"
}

wait_ready() {
  info "waiting for the Spegel DaemonSet rollout (all nodes)"
  kc -n "${SPEGEL_NS}" rollout status ds/spegel --timeout="${WAIT_TIMEOUT}" ||
    die "spegel DaemonSet did not become ready"
}

main() {
  require_cmd kubectl
  [ -d "${SPEGEL_DIR}" ] || die "Spegel base not found: ${SPEGEL_DIR}"

  local render_dir
  render_dir="$(render_spegel_dir)"
  render_dir_for_cleanup="${render_dir}"
  add_exit_trap cleanup_render_dir

  if command -v kustomize >/dev/null 2>&1; then
    apply_via_kustomize "${render_dir}"
  elif command -v helm >/dev/null 2>&1; then
    apply_via_helm "${render_dir}"
  else
    die "neither kustomize nor helm found; cannot install Spegel"
  fi

  wait_ready
  info "Spegel ${SPEGEL_VERSION} installed/updated and ready (peer mirror -> cache http://${REGISTRY_ADDR} -> docker.io)"
}

main "$@"
