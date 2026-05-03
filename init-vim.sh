#!/bin/bash
set -euo pipefail

# init-vim.sh
# Place vimrc + autoload/plug.vim + template/ from the bundle into ~/.vim
# Then run :PlugInstall once so plugins are ready.

VIM_SRC="/opt/devcontainer/config/vim"
VIM_DST="${HOME}/.vim"

mkdir -p "${VIM_DST}/autoload" "${VIM_DST}/template"

if [ -f "${VIM_SRC}/dot.vimrc" ]; then
  cp -f "${VIM_SRC}/dot.vimrc" "${HOME}/.vimrc"
fi

if [ -f "${VIM_SRC}/autoload/plug.vim" ]; then
  cp -f "${VIM_SRC}/autoload/plug.vim" "${VIM_DST}/autoload/plug.vim"
fi

if [ -d "${VIM_SRC}/template" ]; then
  cp -rf "${VIM_SRC}/template/." "${VIM_DST}/template/"
fi

# First-time plugin install (idempotent: PlugInstall skips already-installed)
# Run twice as a workaround for occasional first-run glitches.
echo "init-vim: running :PlugInstall ..."
vim +PlugInstall +qall >/dev/null 2>&1 || true
vim +PlugInstall +qall >/dev/null 2>&1 || true

echo "init-vim: vim config installed."
