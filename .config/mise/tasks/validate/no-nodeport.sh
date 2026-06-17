#!/usr/bin/env bash
#MISE description="Fail on any NodePort surface in rendered manifests (port-forward only)."
#MISE depends=["validate:render-warm"]
# .config/mise/tasks/validate/no-nodeport.sh — fail on NodePort in rendered manifests (spec §15).
#
# Access to the lab is localhost + `kubectl port-forward` ONLY. No Service of
# `type: NodePort`, no `nodePort:` field, and no fixed NodePort numbers may survive
# into the rendered output. This renders every overlay and greps the final stream.
#
# Scope note: this guard targets the NodePort Service surface only. `hostPort:` and
# `0.0.0.0` are NOT matched here because the Cilium CNI agent DaemonSet legitimately
# uses hostPort (host-networked CNI) and the in-pod Envoy metrics listener binds
# 0.0.0.0 inside its own network namespace — both are upstream-chart-emitted and are
# not externally reachable. Authored-manifest binding hygiene (no 0.0.0.0 / hostPort
# in OUR YAML) is enforced by the source scrub guard, not against rendered upstream
# charts (which would false-positive on Cilium/Envoy internals).
set -euo pipefail

# shellcheck source=.config/mise/lib/common.sh
REPO_ROOT="${MISE_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." >/dev/null 2>&1 && pwd -P)}"
. "${REPO_ROOT}/.config/mise/lib/common.sh"
repo_root="${REPO_ROOT}"
cd "${repo_root}"

render="${repo_root}/.config/mise/lib/render-all.sh"

rendered="$(bash "${render}")" || {
  printf 'no-nodeport: render failed (offline helm-repo fetch?). Cannot prove clean.\n' >&2
  exit 1
}

# Match the NodePort Service type, an ASSIGNED per-port nodePort value, and the fixed
# NodePort numbers the lab previously used (30903/30904/30911/30917). A bare
# `nodePort:` key (no value) appears in CRD openAPIV3Schema field definitions and is
# NOT a real NodePort Service, so the value form `nodePort:[[:space:]]*[0-9]` is used.
if printf '%s' "${rendered}" | grep -nE \
  -e 'type:[[:space:]]*NodePort' \
  -e 'nodePort:[[:space:]]*[0-9]' \
  -e ':3090[0-9]|:3091[0-9]'; then
  printf 'ERROR: NodePort reference found in rendered output.\n' >&2
  exit 1
fi
printf 'no-nodeport: clean (port-forward only).\n'
