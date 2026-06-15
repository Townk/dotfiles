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
# Create it (0700): apps that use it — notably 1Password's `op` session daemon,
# which writes op-daemon.pid/socket here — fail to start when it's missing (op
# logs "couldn't start daemon" and falls back to a slower, uncached path that
# re-prompts). mkdir -p is idempotent; never let it break sourcing.
[ -d "$XDG_RUNTIME_DIR" ] || mkdir -m 700 -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Refuse bare `pip install`. A loose `pip install [--user]` against the mise
# Python writes console-script shims straight into ~/.local/bin and dependency
# trees into ~/.local/lib, polluting both (e.g. an accidental `matplotlib`/
# `yfinance` install dragged in ~35 packages and 13 stray shims). This makes
# pip error out unless a virtualenv is active. It does NOT affect `uv pip`
# (uv ignores it) nor `pip` run from inside an explicit venv, so isolated tool
# installs (uv tool, project venvs, the nerd-font build) keep working.
export PIP_REQUIRE_VIRTUALENV=true

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
if [ -d /snap/bin ]; then
  case ":$PATH:" in
    *":/snap/bin:"*) ;;
    *) PATH="$PATH:/snap/bin" ;;
  esac
fi
export PATH

# Secret env vars (API keys, tokens). ~/.config/zsh/secrets.sh is a non-secret
# loader that sources this machine's per-slot fragment(s) under
# ~/.config/zsh/secrets.d/ (mode 0600). Fragments are materialized by chezmoi
# at apply: SOPS+age decryption on headless hosts, 1Password resolution on
# human hosts. Sourced here so every shell AND every launchd-spawned
# subprocess gets the same env. See `system-onboard`/`system-secrets`.
[ -r "$HOME/.config/zsh/secrets.sh" ] && . "$HOME/.config/zsh/secrets.sh"

# Over-SSH adjustments. Empty in launchd/GUI shells (no SSH_CONNECTION), so GUI
# apps and local sessions are unaffected.
if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ]; then
  # Steer gpg-agent's pinentry to the terminal. gpg forwards this to the agent,
  # which hands it to our pinentry-auto dispatcher; USE_CURSES is the value
  # pinentry-mac honors too. Unset locally so Touch ID stays the default.
  export PINENTRY_USER_DATA="USE_CURSES=1"

  # The 1Password desktop app can't authorize `op` over SSH (no GUI / Touch ID),
  # so use the loose service-account token: `op` — and chezmoi's `output "op"
  # read` secret resolution at apply — runs in service mode. Local sessions skip
  # this and stay in account mode (Touch ID, full Private-vault access). The
  # token is loose, 0600, never committed; see system-onboard.
  if [ -r "$XDG_DATA_HOME/op/service-account" ]; then
    OP_SERVICE_ACCOUNT_TOKEN="$(cat "$XDG_DATA_HOME/op/service-account")"
    export OP_SERVICE_ACCOUNT_TOKEN
  fi
fi
