#!/bin/bash
set -euo pipefail

# init-zsh.sh
# Place zsh config files from /opt/devcontainer/config/zsh into ~/.zsh and ~/.
# Files use a "dot.<name>" convention in the bundle to avoid hidden files in git.
#
# Two install modes:
#   - "always overwrite": files that are part of the devcontainer's responsibility
#     (zshrc body, plugin definitions, key bindings, dircolors). Editing these
#     directly does not survive a container rebuild — edit config/zsh/* instead.
#   - "install only if missing": user-extension points (p10k.zsh, add.zshrc).
#     Once placed, subsequent starts leave them untouched so user edits persist.

ZSH_SRC="/opt/devcontainer/config/zsh"
ZSH_DST="${HOME}/.zsh"

mkdir -p "$ZSH_DST"

install_if_missing() {
  local src="$1"
  local dst="$2"
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    echo "init-zsh: installed ${dst} from template"
  fi
}

# Always overwrite — devcontainer-managed files
for f in zinitrc bindkeyrc dircolors; do
  if [ -f "${ZSH_SRC}/${f}" ]; then
    cp -f "${ZSH_SRC}/${f}" "${ZSH_DST}/${f}"
  fi
done
if [ -f "${ZSH_SRC}/dot.zshrc" ]; then
  cp -f "${ZSH_SRC}/dot.zshrc" "${HOME}/.zshrc"
fi

# Install only if missing — user extension points
if [ -f "${ZSH_SRC}/dot.p10k.zsh" ]; then
  install_if_missing "${ZSH_SRC}/dot.p10k.zsh" "${HOME}/.p10k.zsh"
fi
if [ -f "${ZSH_SRC}/add.zshrc" ]; then
  install_if_missing "${ZSH_SRC}/add.zshrc" "${ZSH_DST}/add.zshrc"
fi

echo "init-zsh: zsh config installed."
echo "init-zsh: Zinit will auto-install on first zsh start (see zinitrc)."
