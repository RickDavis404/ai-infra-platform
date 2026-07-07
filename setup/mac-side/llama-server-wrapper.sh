#!/usr/bin/env bash
# setup/mac-side/llama-server-wrapper.sh
#
# Staged to ~/.local/bin/ai-infra-llama-server-wrapper.sh (TCC constraint §8.4:
# runnable host-service scripts MUST live OUTSIDE ~/Documents, or a launchd-spawned
# interpreter can silently hang).
#
# Purpose (POC lesson §8.4): llama-swap (the Go parent) does NOT proxy a child
# llama-server's stderr — on a crash you see only the exit code, the actual error
# text is lost. This wrapper `exec`s llama-server and tees its stderr to a known
# log file, which Grafana Alloy's otelcol.receiver.filelog ships under
# service.name=llama-server. Using `exec` keeps the wrapper out of the process
# tree so llama-swap's PID tracking still works. The wrapper also expands a leading
# `~/` in the model-path arg, because llama-swap execs argv directly with no shell
# expansion.
set -euo pipefail

# Expand a leading ~/ in the first arg (the model path) to $HOME.
args=("$@")
if [[ ${#args[@]} -gt 0 ]]; then
  args[0]="${args[0]/#\~\//${HOME}/}"
fi

# Known stderr log file Grafana Alloy's filelog receiver tails. Kept in
# $TMPDIR (falls back to /tmp) so it is outside any TCC-protected tree.
err_log="${TMPDIR:-/tmp}/ai-infra-llama-server.err.log"

exec /opt/homebrew/bin/llama-server "${args[@]}" 2>>"${err_log}"
