# Route sudo's password prompt to the right surface, decided PER INVOCATION.
#
# sudo consults SUDO_ASKPASS only when there is no terminal or when -A is given
# (sudo(1), ENVIRONMENT), and inside a tmux pane there IS a terminal — just one
# nobody may be watching, which is the whole problem. So -A has to come from
# somewhere, and this used to be `alias sudo="sudo -A"` set once per shell from
# its SSH_* markers. That once-per-shell decision is the bug the presence
# helper replaced (docs/superpowers/specs/2026-08-31-presence-aware-pinentry-
# design.md): a pane born over SSH keeps its markers after the user sits back
# down at the console, and vice versa. A function asks presence fresh each
# time instead — and like the alias it replaces, `\sudo` and `command sudo`
# bypass it. That escape matters more than usual here, because with -A there
# is no prompt underneath us — a broken helper means sudo cannot authenticate
# at all (docs/askpass-design.md, "Blast radius").
#
# The two lanes:
#
#   present (touchid/gui/vnc) — plain sudo with the SSH triple SCRUBBED from
#     its environment. The scrub is the fix, not a flourish: pam_reattach's
#     ignore_ssh keys off exactly SSH_TTY/SSH_CONNECTION/SSH_CLIENT (measured
#     with `strings` on the dylib), so a stale marker made it skip the
#     namespace reattach, pam_tid failed inside tmux, and the password fell
#     to the float while the sensor sat inches from the user's hand. Scrubbed,
#     the reattach happens and pam_tid answers with Touch ID — no password.
#     Over VNC the sensor is unreachable so pam_tid fails fast, and the
#     password lands inline on the very terminal the viewer is watching.
#
#   remote — -A into askpass-auto, exactly the old behavior. SUDO_ASKPASS is
#     set here rather than trusted from the environment (it is exported only
#     by SSH-born shells — same staleness), first setter still wins.
#
# The fallback lane keeps the old alias's exact birth-time test, because a
# host mid-provision (helper not yet applied) must behave as it always did.
#
# Gated on the compiled binary rather than on the askpass-auto symlink, which
# chezmoi installs everywhere — see the same guard in environment.sh for what
# that mistake costs.
if [ -x "$HOME/.local/libexec/pinentry-ui" ]; then
  sudo() {
    local lane=""
    [[ -x "$HOME/.local/libexec/presence" ]] &&
      lane="$("$HOME/.local/libexec/presence" 2>/dev/null)"
    case "$lane" in
      touchid | gui | vnc)
        command env -u SSH_TTY -u SSH_CONNECTION -u SSH_CLIENT sudo "$@"
        ;;
      remote)
        SUDO_ASKPASS="${SUDO_ASKPASS:-$HOME/.local/libexec/askpass-auto}" \
          command sudo -A "$@"
        ;;
      *)
        if [ -n "${SSH_TTY:-}${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]; then
          command sudo -A "$@"
        else
          command sudo "$@"
        fi
        ;;
    esac
  }
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
