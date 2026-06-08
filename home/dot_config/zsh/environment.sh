# Single source of truth for XDG base-directory env vars.
#
# Both ~/.zshenv (sourced for every shell) and the
# ~/Library/LaunchAgents/my.environment.variables.plist (run at login,
# propagates to GUI apps via `launchctl setenv`) read this file. Edit
# the values here; reload the LaunchAgent to push to launchd.
#
# sh-compatible: avoid bash/zsh-only syntax so the launchd agent can
# source it under /bin/sh.

export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_BIN_HOME="$HOME/.local/bin"
export GNUPGHOME="$XDG_CONFIG_HOME/gnupg"

# $UID is a zsh builtin (no fork); falls back to `id -u` under sh.
# $TMPDIR is set by launchd for user processes; defaults to /tmp elsewhere.
export XDG_RUNTIME_DIR="${TMPDIR:-/tmp}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR%/}/runtime-${UID:-$(id -u)}"

# PATH for non-interactive shells. `.zshrc`'s `path=(~/.local/bin …)` only
# runs in interactive zsh, which means `#!/bin/zsh` scripts (system-update,
# system-package, …) can't find local/mise binaries. Prepend the two
# directories here so they're available wherever `.zshenv` is sourced.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$HOME/.local/share/mise/shims:"*) ;;
  *) PATH="$HOME/.local/share/mise/shims:$PATH" ;;
esac
case ":$PATH:" in
  *":$HOME/.cargo/bin:"*) ;;
  *) PATH="$PATH:$HOME/.cargo/bin" ;;
esac
export PATH

# Secret env vars (API keys, tokens). Resolved from 1Password by chezmoi
# at apply time and written to ~/.config/zsh/secrets.sh (mode 0600,
# never committed). The template lives at
# dot_config/zsh/private_secrets.sh.tmpl. Sourced here so every shell
# AND every launchd-spawned subprocess gets the same env.
[ -r "$HOME/.config/zsh/secrets.sh" ] && . "$HOME/.config/zsh/secrets.sh"

# Over SSH/mosh, steer gpg-agent's pinentry to the terminal. gpg forwards this
# to the agent, which hands it to our pinentry-auto dispatcher; USE_CURSES is
# the value pinentry-mac honors too. Unset locally so Touch ID stays the
# default. Empty in launchd/GUI shells (no SSH_CONNECTION), so GUI apps are
# unaffected.
if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ]; then
  export PINENTRY_USER_DATA="USE_CURSES=1"
fi
