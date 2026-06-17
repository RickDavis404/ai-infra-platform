# Brewfile — ai-infra-platform HOST-LEVEL dependencies (macOS / Apple Silicon, Lima-based).
#
# Division of responsibility:
#   Homebrew  = host-level ONLY — things mise cannot manage as a runtime:
#               the VM/network backend (Lima + socket_vmnet), the shell that the
#               scripts require (bash 5.x), the Mac-side model-serving binaries
#               (llama.cpp / llama-swap / mlx-lm), and host telemetry (macmon).
#   mise [tools] = the ENTIRE CLI toolchain — kubectl, kustomize, helm, cilium-cli,
#               age, fnox, jq, yq, shellcheck, shfmt, yamllint, gitleaks, pre-commit,
#               node, python, ripgrep. Pinned in .config/mise/conf.d/00-tools.toml,
#               NOT here. Do not duplicate those formulae in this file.
#
# Workstation GUI casks are intentionally excluded. Secrets use fnox + age (no 1Password).
#
# NOTE on `brew bundle` warnings: if `slp/krun/*` warnings scroll past during
# `brew bundle`, they are a PRE-EXISTING host condition — leftover krunkit VM
# dependencies from an *untapped* `slp/krun` tap on this Mac. They do NOT come from
# this Brewfile (we neither tap slp/krun nor install krun), and `brew bundle`
# proceeds past them normally.

# === Taps ===
tap "mostlygeek/llama-swap"        # llama-swap model router

# === Bootstrap tool/version manager ===
# mise manages the rest of the CLI toolchain but cannot manage itself; install it
# via Homebrew so `mise install` / `mise run ...` exist before anything else.
brew "mise"                        # repo command surface + pinned tool manager

# === Shell runtime ===
# macOS ships bash 3.2 (2007); the repo scripts use bash 4+ features (mapfile,
# associative arrays) per spec §8.2. Homebrew bash lands in /opt/homebrew/bin,
# which precedes /usr/bin on Apple Silicon, so `#!/usr/bin/env bash` resolves to 5.x.
brew "bash"                        # bash 5.x (scripts require bash >= 4)

# === Dotfile/config helper (optional) ===
brew "chezmoi"                     # dotfile/config templating (optional host helper)

# === VM + private network backend (host-level; mise cannot run these) ===
brew "lima"                        # 3-node Lima host VMs
brew "socket_vmnet"                # shared-network backend for the Lima L2 (sudoers-gated)

# === Mac-side model serving (host services, §8.4) ===
brew "llama.cpp"                   # provides llama-server (GGUF)
brew "mlx-lm"                      # provides mlx_lm.server (MLX, Apple Metal)
brew "mostlygeek/llama-swap/llama-swap"  # model auto-swap proxy fronting both

# === Host telemetry (§8.4) ===
brew "macmon"                      # sudoless Apple Silicon hardware metrics
# otelcol-contrib: no homebrew-core formula historically. If unavailable, install the
# pinned prebuilt binary to ~/.local/bin/ (see §8.4 / §8.5). Listed for visibility:
# brew "otelcol-contrib"           # OpenTelemetry Collector (contrib) — verify at impl
