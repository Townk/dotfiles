# Route sudo's password prompt to our dialog, over SSH only.
#
# sudo consults SUDO_ASKPASS only when there is no terminal or when -A is given
# (sudo(1), ENVIRONMENT), and inside a tmux pane there IS a terminal — just one
# nobody may be watching, which is the whole problem. So -A has to come from
# somewhere, and an alias is the deliberate choice over a wrapper on PATH:
# `\sudo` and `command sudo` bypass it. That matters more than usual here,
# because with -A there is no prompt underneath us — a broken helper means sudo
# cannot authenticate at all (docs/askpass-design.md, "Blast radius").
#
# Local sessions are left alone: at the physical keyboard PAM answers with Touch
# ID before any password is asked for.
if [ -n "${SSH_TTY:-}${SSH_CONNECTION:-}${SSH_CLIENT:-}" ] &&
  [ -x "$HOME/.local/libexec/askpass-auto" ]; then
  alias sudo="sudo -A"
fi

# Conditional alias
command -v bandwhich >/dev/null && alias bandwhich="sudo bandwhich"
command -v trip >/dev/null && alias trip="sudo trip"
command -v tidy-viewer >/dev/null && alias tv="tidy-viewer"
command -v bat >/dev/null && alias cat="bat -p"
if command -v eza >/dev/null; then
  alias ls="eza -F --group-directories-first --icons --hyperlink=auto"
else
  alias ls="ls -F -h --color=always"
fi

## basic commands
alias commands="cmds" # `cmds` itself is a function (functions.d/commands.sh)
alias cd="super-cd"
alias cp="cp -i"
alias diff='diff --color=auto'
alias grep='grep --color=auto --exclude-dir={.bzr,CVS,.git,.hg,.svn}'
alias h="history -1" # full histor
alias history="fc -il 1"
alias mkdir="mkdir -pv"
alias mv="mv -i"
alias pgrep="pgrep -lf" # long output, match against full args lis
alias rm="rm -i"
alias wget="wget2 -c"
alias zmv="noglob zmv -M"
alias zcp="noglob zmv -C"
alias zln="noglob zmv -L"
alias vim="nvim"
alias vi="nvim"
alias zj="zellij"
alias t="tmux"

## git aliases
alias git="noglob git"
alias cdg='cd `git rev-parse --show-toplevel`'
alias gl="git log --graph --pretty='format:%C(auto)%h %<(50,trunc)%s %C(magenta)(%cr)%Creset by %C(bold blue)%an <@%al> %C(auto)%d %C(8)%(trailers:valueonly,key=cr,separator=%x2C)'"

# Other helpers
alias isotime="date -u +'%Y-%m-%dT%H:%M:%S+0000'"
alias gpg-check="echo test | gpg --clearsign >/dev/null 2>&1 && echo SIGNING_OK || echo SIGNING_FAILED"

# Global aliases
alias -g -- /h='-h 2>&1 | bat --language=help --style=plain'
alias -g -- --help='--help 2>&1 | bat --language=help --style=plain'
