#!/bin/bash
set -euo pipefail

# init-zsh.sh
# Place zsh config files from /opt/devcontainer/config/zsh into ~/.zsh and ~/
# Files use a "dot.<name>" convention in the bundle to avoid hidden files in git.

ZSH_SRC="/opt/devcontainer/config/zsh"
ZSH_DST="${HOME}/.zsh"

mkdir -p "$ZSH_DST"

# Copy non-dotfile config into ~/.zsh
for f in zinitrc bindkeyrc dircolors add.zshrc; do
  if [ -f "${ZSH_SRC}/${f}" ]; then
    cp -f "${ZSH_SRC}/${f}" "${ZSH_DST}/${f}"
  fi
done

# Place dotfiles in $HOME (translate "dot.<name>" -> ".<name>")
if [ -f "${ZSH_SRC}/dot.zshrc" ]; then
  cp -f "${ZSH_SRC}/dot.zshrc" "${HOME}/.zshrc"
fi
if [ -f "${ZSH_SRC}/dot.p10k.zsh" ]; then
  cp -f "${ZSH_SRC}/dot.p10k.zsh" "${HOME}/.p10k.zsh"
fi

echo "init-zsh: zsh config installed."
echo "init-zsh: Zinit will auto-install on first zsh start (see zinitrc)."
