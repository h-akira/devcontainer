#!/bin/bash
set -euo pipefail

# init-nvim.sh
# Place neovim config from /opt/devcontainer/config/nvim into ~/.config/nvim/.
#
# Two install modes (matching init-zsh.sh):
#   - "always overwrite": init.lua, lua/config/lazy.lua, lua/plugins/init.lua,
#     template/. Editing these directly does not survive container rebuild —
#     edit config/nvim/* instead.
#   - "install only if missing": ~/.config/nvim/add.lua and
#     ~/.config/nvim/lua/plugins/add.lua. Once placed, subsequent starts leave
#     them untouched so user edits persist.

NVIM_SRC="/opt/devcontainer/config/nvim"
NVIM_DST="${HOME}/.config/nvim"

mkdir -p "${NVIM_DST}/lua/config" "${NVIM_DST}/lua/plugins" "${NVIM_DST}/template"

install_if_missing() {
  local src="$1"
  local dst="$2"
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    echo "init-nvim: installed ${dst} from template"
  fi
}

# Always overwrite — devcontainer-managed files
if [ -f "${NVIM_SRC}/init.lua" ]; then
  cp -f "${NVIM_SRC}/init.lua" "${NVIM_DST}/init.lua"
fi
if [ -f "${NVIM_SRC}/lua/config/lazy.lua" ]; then
  cp -f "${NVIM_SRC}/lua/config/lazy.lua" "${NVIM_DST}/lua/config/lazy.lua"
fi
if [ -f "${NVIM_SRC}/lua/plugins/init.lua" ]; then
  cp -f "${NVIM_SRC}/lua/plugins/init.lua" "${NVIM_DST}/lua/plugins/init.lua"
fi
if [ -d "${NVIM_SRC}/template" ]; then
  cp -rf "${NVIM_SRC}/template/." "${NVIM_DST}/template/"
fi

# Install only if missing — user extension points
if [ -f "${NVIM_SRC}/add.lua" ]; then
  install_if_missing "${NVIM_SRC}/add.lua" "${NVIM_DST}/add.lua"
fi
if [ -f "${NVIM_SRC}/lua/plugins/add.lua" ]; then
  install_if_missing "${NVIM_SRC}/lua/plugins/add.lua" "${NVIM_DST}/lua/plugins/add.lua"
fi

# First-time plugin install via lazy.nvim. Idempotent: already-installed
# plugins are no-ops on rerun. We do NOT silence output and do NOT swallow
# failures — install errors stay visible in the postStart log.
echo "init-nvim: running :Lazy sync ..."
if ! nvim --headless "+Lazy! sync" "+qa"; then
  echo "init-nvim: WARN: Lazy sync returned non-zero; plugins may be incomplete"
fi

echo "init-nvim: nvim config installed."
