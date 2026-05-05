#!/bin/bash
set -euo pipefail

# init-vim.sh
# Place vim config from /opt/devcontainer/config/vim into ~/.vim and ~/.vimrc.
#
# Two install modes (matching init-zsh.sh):
#   - "always overwrite": files that are part of the devcontainer's responsibility
#     (.vimrc body, vim-plug binary in autoload/, template/). Editing these
#     directly does not survive a container rebuild — edit config/vim/* instead.
#   - "install only if missing": user-extension points (~/.vim/add.vimrc,
#     ~/.vim/add.plugin.vimrc). Once placed, subsequent starts leave them
#     untouched so user edits persist. dot.vimrc sources both via filereadable().

VIM_SRC="/opt/devcontainer/config/vim"
VIM_DST="${HOME}/.vim"

mkdir -p "${VIM_DST}/autoload" "${VIM_DST}/template"

install_if_missing() {
  local src="$1"
  local dst="$2"
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    echo "init-vim: installed ${dst} from template"
  fi
}

# Always overwrite — devcontainer-managed files
if [ -f "${VIM_SRC}/dot.vimrc" ]; then
  cp -f "${VIM_SRC}/dot.vimrc" "${HOME}/.vimrc"
fi
if [ -f "${VIM_SRC}/autoload/plug.vim" ]; then
  cp -f "${VIM_SRC}/autoload/plug.vim" "${VIM_DST}/autoload/plug.vim"
fi
if [ -d "${VIM_SRC}/template" ]; then
  cp -rf "${VIM_SRC}/template/." "${VIM_DST}/template/"
fi

# Install only if missing — user extension points
if [ -f "${VIM_SRC}/add.vimrc" ]; then
  install_if_missing "${VIM_SRC}/add.vimrc" "${VIM_DST}/add.vimrc"
fi
if [ -f "${VIM_SRC}/add.plugin.vimrc" ]; then
  install_if_missing "${VIM_SRC}/add.plugin.vimrc" "${VIM_DST}/add.plugin.vimrc"
fi

# First-time plugin install. Two passes are required because vim-plug installs
# plugins in declaration order, and some plugins (notably denops-based ones)
# need their dependencies installed first; the second pass picks up the rest.
# See https://github.com/h-akira/vim README for the rationale.
# We do NOT silence output and do NOT swallow failures with `|| true`, so that
# install failures stay visible in the postStart log. PlugInstall is otherwise
# idempotent — re-runs are no-ops on already-installed plugins.
echo "init-vim: running :PlugInstall (1/2) ..."
if ! vim +PlugInstall +qall; then
  echo "init-vim: WARN: first PlugInstall returned non-zero; continuing to second pass"
fi
echo "init-vim: running :PlugInstall (2/2) ..."
if ! vim +PlugInstall +qall; then
  echo "init-vim: WARN: second PlugInstall returned non-zero; plugins may be incomplete"
fi

echo "init-vim: vim config installed."
