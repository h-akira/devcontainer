# Container-specific additions to zsh.
# Visual marker so the user can tell the container shell apart from the host shell.

# Show a "[DEV]" marker in the right prompt's first segment if powerlevel10k is active.
# This is in addition to the directory color change in dot.p10k.zsh.

# Shell-side marker: prefix shell title with the container hostname.
case $TERM in
  xterm*|rxvt*|screen*|tmux*)
    precmd() { print -Pn "\e]0;[DEV] %m: %~\a" }
    ;;
esac
