# Conditional alias
if command -v nix >/dev/null; then
  alias nixrepl="nix repl '<nixpkgs>'"
  alias sha-to-base32="nix to-base32 --type sha256"
fi
command -v emacsclient >/dev/null && alias em="emacsclient -n"
command -v bandwhich >/dev/null && alias bandwhich="sudo bandwhich"
command -v trip >/dev/null && alias trip="sudo trip"
command -v tidy-viewer >/dev/null && alias tv="tidy-viewer"
command -v bat >/dev/null && alias cat="bat -p"
if command -v eza >/dev/null; then
  alias ls="eza -F --group-directories-first --icons --hyperlink"
else
  alias ls="ls -F -h --color=always"
fi
command -v terminal-notifier >/dev/null && alias notify="terminal-notifier"

## basic commands
alias cmds="terminal_commands"
alias commands="terminal_commands"
alias cd="super-cd"
alias cp="cp -i"
alias diff='diff --color=auto'
alias fzf='-z4h-fzf'
alias grep='grep --color=auto --exclude-dir={.bzr,CVS,.git,.hg,.svn}'
alias h="history -1" # full histor
alias history="fc -il 1"
alias lg="lazygit"
alias lsg="ls --git --git-ignore"
alias l="ls -1"
alias la="ls -a"
alias ll="ls -l"
alias lla="ls -la"
alias lt="ls --tree"
alias mkdir="mkdir -pv"
alias mv="mv -i"
alias pgrep="pgrep -lf" # long output, match against full args lis
alias rm="rm -i"
alias wget="wget -c"
alias y="yazi"
alias zcp="zmv -C"
alias zln="zmv -L"
alias zprofile-next="touch $XDG_RUNTIME_DIR/_zsh_profile.lock"
alias vim="nvim"
alias vi="nvim"
alias claude="/Users/thiagoa/.claude/local/claude"

## git aliases
alias git="noglob git"
alias cdg='cd `git rev-parse --show-toplevel`'
alias gst="git status --short"
alias gu="git pull"
alias gp="git push"
alias gd="git vimdiff"
alias gdf="git diff --name-only"
alias gc="git commit -v"
alias gca="git commit -v -a"
alias gb="git branch -v"
alias gba="git branch -av"
alias grv="git remote -v"
alias gl="git log --graph --pretty='format:%C(auto)%h %C(red)%G?%Creset %<(50,trunc)%s %C(magenta)(%cr)%Creset by %C(bold blue)%an <@%al> %C(auto)%d %C(8)%(trailers:valueonly,key=cr,separator=%x2C)'"

# ssh helper
alias ssh-x="ssh -o CompressionLevel=9 -c arcfour,blowfish-cbc -YC"

# Other helpers
alias isotime="date -u +'%Y-%m-%dT%H:%M:%S+0000'"


# Global aliases
alias -g -- /h='-h 2>&1 | bat --language=help --style=plain'
alias -g -- --help='--help 2>&1 | bat --language=help --style=plain'
