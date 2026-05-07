#!/bin/bash
set -euo pipefail

# init-all.sh
# Aggregator script for postStartCommand.
# Runs each init step in order, fail-close: if any step exits non-zero, the
# whole postStart aborts and the user can see in the log which step failed.
#
# Network-fetch steps inside individual init-*.sh (e.g. vim +PlugInstall, TPM
# install_plugins) are responsible for their own warn-level fallback. This
# script only escalates hard failures of the init scripts themselves.

run_step() {
  local name="$1"
  local cmd="$2"
  echo "==> [${name}] start"
  if ! eval "$cmd"; then
    echo "==> [${name}] FAILED — aborting postStart" >&2
    exit 1
  fi
  echo "==> [${name}] ok"
}

run_step "firewall" "sudo /usr/local/bin/init-firewall.sh"
run_step "claude"   "/usr/local/bin/init-claude.sh"
run_step "zsh"      "/usr/local/bin/init-zsh.sh"
run_step "nvim"     "/usr/local/bin/init-nvim.sh"
run_step "tmux"     "/usr/local/bin/init-tmux.sh"
run_step "mcp"      "/usr/local/bin/init-mcp.sh"

echo "==> all init steps completed"
