# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

ZDOTDIR="${HOME}/.zsh"

export LANG=en_US.UTF-8
export LC_COLLATE=ja_JP.UTF-8
export LC_CTYPE=ja_JP.UTF-8

export VISUAL=vim
export EDITOR=vim
export GIT_EDITOR=vim

# History
export HISTFILE=${HOME}/.zsh_history
export HISTSIZE=1000
export SAVEHIST=100000
function history-all { history -E 1 }

# Container-local additions (sourced first so brew/path tweaks take effect early)
if [ -f ${ZDOTDIR}/add.zshrc ]; then
  source ${ZDOTDIR}/add.zshrc
fi

# Completion
autoload -Uz compinit && compinit

# Case-insensitive matching
zstyle ':completion:*' matcher-list 'm:{[:lower:][:upper:]}={[:upper:][:lower:]}'
# Arrow-key candidate selection
zstyle ':completion:*:default' menu select=1

# ls colors (Linux/GNU coreutils only; this container is Linux)
if (( $+commands[dircolors] )); then
  eval `dircolors ${ZDOTDIR}/dircolors -b`
  if [ -n "$LS_COLORS" ]; then
    zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
  fi
fi
alias ls="ls -F --color=auto"
alias la="ls -a"
alias ll="ls -l"
alias lla="ls -la"

# cd without typing cd
setopt AUTO_CD

# ls on cd
function chpwd() { ls }

# Python
export PYTHONDONTWRITEBYTECODE=1

# Allow inline `#` comments in interactive shells
setopt interactive_comments

# zinit
source ${ZDOTDIR}/zinitrc

# bindkey (must come after zinitrc to avoid fast-syntax-highlighting conflicts)
source ${ZDOTDIR}/bindkeyrc

# Powerlevel10k user config (placed at $HOME/.p10k.zsh by init-zsh.sh)
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
