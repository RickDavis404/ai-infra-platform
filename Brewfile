# Brewfile — ai-infra-platform HOST-LEVEL dependencies (macOS / Apple Silicon, Lima-based).
#
# Division of responsibility:
#   Homebrew  = host-level ONLY — things mise cannot manage as a runtime:
#               the VM/network backend (Lima + socket_vmnet), an optional modern
#               shell (bash 5.x), the Mac-side model-serving backend binaries
#               (llama.cpp / mlx-lm), and host telemetry (macmon). NOTE: llama-swap
#               is NO LONGER a brew formula here — its tap refused to load on a
#               fresh `brew bundle` ("untrusted tap"), so it moved to the mise
#               github backend (see mise.toml [tools]).
#   mise [tools] = the CLI toolchain — kubectl, kustomize, helm, cilium-cli,
#               age, fnox, jq, shellcheck, shfmt, yamllint, gitleaks, pre-commit,
#               node, python, ripgrep. Pinned in mise.toml [tools], NOT here. Do not
#               duplicate those formulae in this file. ONE exception — `yq` — is brew,
#               not mise (arch-resolution bug; see the yq block below and mise.toml).
#
# Workstation GUI casks are intentionally excluded. Secrets use fnox + age (no 1Password).
#
# NOTE on `brew bundle` warnings: if `slp/krun/*` warnings scroll past during
# `brew bundle`, they are a PRE-EXISTING host condition — leftover krunkit VM
# dependencies from an *untapped* `slp/krun` tap on this Mac. They do NOT come from
# this Brewfile (we neither tap slp/krun nor install krun), and `brew bundle`
# proceeds past them normally.

# === Bootstrap tool/version manager ===
# mise manages the rest of the CLI toolchain but cannot manage itself; install it
# via Homebrew so `mise install` / `mise run ...` exist before anything else.
brew "mise"                        # repo command surface + pinned tool manager

# === Shell runtime (optional) ===
# macOS ships bash 3.2 (2007). The repo scripts now run on stock macOS bash 3.2 —
# the bash 4+ features (mapfile, associative arrays) were removed — so Homebrew bash
# is NO LONGER REQUIRED. It is kept here only as a harmless convenience: when present
# in /opt/homebrew/bin (ahead of /usr/bin on Apple Silicon) it upgrades
# `#!/usr/bin/env bash` to 5.x, but nothing in this repo depends on that.
brew "bash"                        # bash 5.x — optional; scripts no longer require it

# === CLI utility — normally mise-managed, brew here (arch exception) ===
# yq — the one CLI exception to the mise-managed toolchain. mise's aqua backend resolves the
# wrong-arch asset (yq_darwin_amd64 → "Bad CPU type" on Apple Silicon), and the github backend
# installs it under its asset filename (yq_darwin_arm64) instead of a bare `yq`. Homebrew's yq is
# native-arch and lands as `yq` on PATH. It is only shelled out to AFTER `brew bundle` (init.sh's
# networks.yaml patch + the `up` tasks), never during `mise install`, so brew is the right home.
brew "yq"                          # native-arch `yq` on PATH (see mise.toml note)

# === VM + private network backend (host-level; mise cannot run these) ===
brew "lima"                        # 3-node Lima host VMs
brew "socket_vmnet"                # shared-network backend for the Lima L2 (sudoers-gated)

# === Mac-side model serving (host services, §8.4) ===
brew "llama.cpp"                   # provides llama-server (GGUF)
brew "mlx-lm"                      # provides mlx_lm.server (MLX, Apple Metal)
# NOTE: llama-swap (the model auto-swap proxy fronting both backends) is NOT here —
# it is installed via the mise github backend (mise.toml [tools]); the untrusted
# tap it used aborted `brew bundle` on a fresh Mac.

# === Host telemetry (§8.4) ===
brew "macmon"                      # sudoless Apple Silicon hardware metrics
brew "grafana-alloy"               # Mac-side OTLP telemetry shipper (binary `alloy`); replaced otelcol-contrib
