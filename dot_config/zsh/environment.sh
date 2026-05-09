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

# $UID is a zsh builtin (no fork); falls back to `id -u` under sh.
# $TMPDIR is set by launchd for user processes; defaults to /tmp elsewhere.
export XDG_RUNTIME_DIR="${TMPDIR:-/tmp}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR%/}/runtime-${UID:-$(id -u)}"
