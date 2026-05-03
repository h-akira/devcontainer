#!/bin/bash
set -euo pipefail

# init-tmux.sh
# Place tmux.conf from the bundle into ~/.tmux/, clone TPM, and install plugins.

TMUX_SRC="/opt/devcontainer/config/tmux"
TMUX_DIR="${HOME}/.tmux"
TPM_DIR="${TMUX_DIR}/plugins/tpm"

mkdir -p "${TMUX_DIR}/plugins"

# Place tmux.conf as ~/.tmux.conf (and keep a copy under ~/.tmux/ for clarity)
if [ -f "${TMUX_SRC}/dot.tmux.conf" ]; then
  cp -f "${TMUX_SRC}/dot.tmux.conf" "${HOME}/.tmux.conf"
fi

# Clone TPM if missing
if [ ! -d "${TPM_DIR}" ]; then
  echo "init-tmux: cloning TPM ..."
  git clone --depth 1 https://github.com/tmux-plugins/tpm "${TPM_DIR}"
fi

# Install plugins declared in tmux.conf via TPM
if [ -x "${TPM_DIR}/bin/install_plugins" ]; then
  echo "init-tmux: installing TPM plugins ..."
  "${TPM_DIR}/bin/install_plugins" >/dev/null 2>&1 || true
fi

echo "init-tmux: tmux config installed."
