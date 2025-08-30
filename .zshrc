# Personal Zsh configuration file. It is strongly recommended to keep all
# shell customization and configuration (including exported environment
# variables such as PATH) in this file or in files sourced from it.
#
# Documentation: https://github.com/romkatv/zsh4humans/blob/v5/README.md.

# Periodic auto-update on Zsh startup: 'ask' or 'no'.
# You can manually run `z4h update` to update everything.
zstyle ':z4h:' auto-update 'no'
# Ask whether to auto-update this often; has no effect if auto-update is 'no'.
zstyle ':z4h:' auto-update-days '28'

# Keyboard type: 'mac' or 'pc'.
zstyle ':z4h:bindkey' keyboard 'mac'

# Don't start tmux.
zstyle ':z4h:' start-tmux no

# Mark up shell's output with semantic information.
zstyle ':z4h:' term-shell-integration 'yes'

# Right-arrow key accepts one character ('partial-accept') from
# command autosuggestions or the whole thing ('accept')?
zstyle ':z4h:autosuggestions' forward-char 'accept'

# Recursively traverse directories when TAB-completing files.
zstyle ':z4h:fzf-complete' recurse-dirs 'no'
zstyle ':z4h:fzf-complete' fzf-bindings 'tab:repeat'
zstyle ':z4h:fzf-complete' fzf-bindings 'ctrl-space:toggle-preview'
zstyle ':z4h:fzf-complete' fzf-bindings 'ctrl-j:down'
zstyle ':z4h:fzf-complete' fzf-bindings 'ctrl-h:up'

# Enable direnv to automatically source .envrc files.
zstyle ':z4h:direnv' enable 'yes'
# Show "loading" and "unloading" notifications from direnv.
zstyle ':z4h:direnv:success' notify 'yes'

# Enable ('yes') or disable ('no') automatic teleportation of z4h over
# SSH when connecting to these hosts.
zstyle ':z4h:ssh:thiagoa-cloud-desktop.aka.corp.amazon.com' enable 'yes'
zstyle ':z4h:ssh:cloud-desktop' enable 'yes'
# zstyle ':z4h:ssh:*.example-hostname2' enable 'no'
# The default value if none of the overrides above match the hostname.
zstyle ':z4h:ssh:*' enable 'no'

# Send these files over to the remote host when connecting over SSH to the
# enabled hosts.
zstyle ':z4h:ssh:*' send-extra-files '~/.config/zsh/functions'
zstyle ':z4h:ssh:*' send-extra-files "~/.atuin/bin/env"
zstyle ':z4h:ssh:*' send-extra-files "~/.config/nvim"

export FZF_DEFAULT_COMMAND="fd --type f"
zstyle ':z4h:*' fzf-flags \
  --color=bg+:"#31353F" \
  --color=fg+:"#abb2bf" \
  --color=hl+:"#ddaeeb" \
  --color=bg:"#1f2329" \
  --color=fg:"#abb2bf" \
  --color=hl:"#a0cff5" \
  --color=prompt:"#ffffff" \
  --color=pointer:"#efd9b0" \
  --color=marker:"#c1dbaf" \
  --color=info:"#a0cff5" \
  --color=gutter:"#1f2329" \
  --color=header:"#a0cff5" \
  --color=spinner:"#9ad3da" \
  --color=border:"#e5bf7b" \
  --filepath-word \
  --border \
  --height=45% \
  --layout=reverse \
  --info=default \
  --exit-0 \
  --select-1 \
  --padding='0,2,1,0' \
  --prompt='    ' \
  --pointer='➔' \
  --marker='✔' \
  --preview 'fzf-preview {}' \
  --preview-window=right:60%:hidden

export GOPATH=~/.local/share/go
export GOPROXY=direct

export HOMEBREW_NO_ENV_HINTS=1

export GNUPGHOME=~/.config/gnupg

# Install plugins by clonning additional Git repositories from GitHub.
# We still need to load these plugins later, after `z4h init`
# z4h install jeffreytse/zsh-vi-mode

# Install or update core components (fzf, zsh-autosuggestions, etc.) and
# initialize Zsh. After this point console I/O is unavailable until Zsh
# is fully initialized. Everything that requires user interaction or can
# perform network I/O must be done above. Everything else is best done below.
z4h init || return

[[ -x "$HOMEBREW_PREFIX/bin/atuin" ]] && eval "$($HOMEBREW_PREFIX/bin/atuin init zsh)"
[[ -x "$HOMEBREW_PREFIX/bin/thefuck" ]] && eval "$($HOMEBREW_PREFIX/bin/thefuck --alias)"
[[ -x "$HOMEBREW_PREFIX/bin/mise" ]] && eval "$($HOMEBREW_PREFIX/bin/mise activate zsh)"
[[ -x "$HOMEBREW_PREFIX/bin/wezterm" ]] && eval "$($HOMEBREW_PREFIX/bin/wezterm shell-completion --shell zsh)"
[[ -x "$HOMEBREW_PREFIX/bin/zoxide" ]] && eval "$($HOMEBREW_PREFIX/bin/zoxide init zsh)"

# Extend PATH.
# path=(~/.local/bin /opt/homebrew/opt/binutils/bin $path)
path=(~/.local/bin $path)

# Extend FPATH.
[[ -n $HOMEBREW_PREFIX ]] && fpath=("$HOMEBREW_PREFIX/share/zsh-abbr" $fpath)

# Export environment variables.
export GPG_TTY=$TTY
export EDITOR=nvim
export USERNAME='Thiago Alves'

# Source additional local files if they exist.
z4h source ~/.config/zsh/functions
[[ -f "$HOMEBREW_PREFIX/Library/Taps/homebrew/homebrew-command-not-found/handler.sh" ]] \
  && z4h source "$HOMEBREW_PREFIX/Library/Taps/homebrew/homebrew-command-not-found/handler.sh"

# Use additional Git repositories pulled in with `z4h install`.
# z4h load jeffreytse/zsh-vi-mode
[[ -n $HOMEBREW_PREFIX ]] && z4h source "$HOMEBREW_PREFIX/share/zsh-abbr/zsh-abbr.zsh"

z4h bindkey magic-space Space                # Expand abbreviation
z4h bindkey abbr-expand-and-insert Alt+Space # undo the last command line change

# Define key bindings.
z4h bindkey undo Ctrl+/    # undo the last command line change
z4h bindkey undo Shift+Tab # undo the last command line change
z4h bindkey redo Option+/  # redo the last undone command line change

z4h bindkey z4h-cd-back Shift+Left     # cd into the previous directory
z4h bindkey z4h-cd-forward Shift+Right # cd into the next directory
z4h bindkey z4h-cd-up Shift+Up         # cd into the parent directory
z4h bindkey z4h-cd-down Shift+Down     # cd into a child directory

z4h bindkey autosuggest-accept Ctrl+Space # accept autosuggestion
z4h bindkey autosuggest-accept Ctrl+Y     # accept autosuggestion
z4h bindkey autosuggest-clear Ctrl+E      # cancel current autosuggestion

z4h bindkey fzf-file-widget Ctrl+T # find files with fzf

z4h bindkey history-substring-search-up Up       # history search previous cmd line
z4h bindkey history-substring-search-down Down   # history search next cmd line
z4h bindkey history-substring-search-up Ctrl+P   # history search previous cmd line
z4h bindkey history-substring-search-down Ctrl+N # history search next cmd line

[[ -x "$HOMEBREW_PREFIX/bin/atuin" ]] && z4h bindkey _atuin_search_widget Ctrl+R # shell history with atuin

# Autoload functions.
autoload -Uz zmv

typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

# Define aliases.
z4h source ~/.config/zsh/aliases

# Set shell options: http://zsh.sourceforge.net/Doc/Release/Options.html.
setopt glob_dots # no special treatment for file names with a leading dot
setopt auto_menu # require an extra TAB press to open the completion menu

HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_FOUND="bg=none,fg=yellow,bold"
HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_NOT_FOUND="bg=none,fg=red,bold"
HISTORY_SUBSTRING_SEARCH_GLOBBING_FLAGS="l"

# The next snippet should only be executed if I'm opening a terminal.
# Currently, the 3 possible terminal emulators I use are:
#
# - Kitty
# - Alacritty
# - iTerm2
#
# If I can't identify one of these running this ZSH session, I'll skip the
# "welcome screen".
if [[ -n "$WEZTERM_UNIX_SOCKET" ]] || [[ -n "$ALACRITTY_SOCKET" ]] || [[ -n "$KITTY_PID" ]] || [[ -n "$ITERM_PROFILE" ]]; then
  # I like to show a "welcome screen" when I open a terminal, and ONLY when I
  # open a terminal, but I don't like to waste time on it if I already open a
  # terminal once.
  # This next line will count how many different `tty???` we have open, so we
  # can be selective about when to display the welcome screen.
  if ! ps | rg 'ttys[\d]*[1-9]' >/dev/null 2>&1; then
    # Only display the welcome message if this is the first terminal open
    type motd >/dev/null 2>&1 && motd
    print -P -- "                                        %F{#5c6370}━━━━━━━━ ❖ ━━━━━━━━%f\n"
    type terminal_commands >/dev/null 2>&1 && terminal_commands
  fi
fi
