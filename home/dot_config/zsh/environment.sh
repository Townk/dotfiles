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

# Force XDG compliance for tools that default to ~/.<dir>. Read here (not just
# .zshrc) so launchd/GUI-spawned processes see the same paths. npm's cache stays
# in the userconfig itself (cache=${XDG_CACHE_HOME}/npm).
export NPM_CONFIG_USERCONFIG="$XDG_CONFIG_HOME/npm/npmrc"
export MPLCONFIGDIR="$XDG_CACHE_HOME/matplotlib"

# Rust is managed by mise's rustup backend. mise reads MISE_*_HOME and then
# re-exports CARGO_HOME/RUSTUP_HOME from them — setting CARGO_HOME directly here
# wouldn't survive `mise activate`. The toolchain stays rustup-managed under
# RUSTUP_HOME; $MISE_CARGO_HOME/bin is added to PATH below (cargo-installed bins).
export MISE_CARGO_HOME="$XDG_DATA_HOME/cargo"
export MISE_RUSTUP_HOME="$XDG_DATA_HOME/rustup"

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

# Homebrew. The macOS GUI/launchd session PATH is the bare system one (no
# /opt/homebrew), and we skip /etc/zprofile's path_helper (no_global_rcs in
# ~/.zshenv), so nothing else puts Homebrew on PATH. A login shell that starts
# a fresh process tree — e.g. a new Zellij *server* for a new window — would
# otherwise see no brew-installed tools at all. Set it statically rather than
# `eval "$(brew shellenv)"` to avoid forking brew on every shell startup.
for _brew_prefix in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew; do
  if [ -x "$_brew_prefix/bin/brew" ]; then
    export HOMEBREW_PREFIX="$_brew_prefix"
    case ":$PATH:" in
      *":$_brew_prefix/bin:"*) ;;
      *) PATH="$_brew_prefix/bin:$_brew_prefix/sbin:$PATH" ;;
    esac
    break
  fi
done
unset _brew_prefix

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
  *":$MISE_CARGO_HOME/bin:"*) ;;
  *) PATH="$PATH:$MISE_CARGO_HOME/bin" ;;
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

# Over-SSH adjustments. Empty in launchd/GUI shells (no SSH_* vars), so GUI
# apps and local sessions are unaffected. The remote test uses the full
# canonical triple (SSH_TTY / SSH_CONNECTION / SSH_CLIENT non-empty) — a no-pty
# `ssh -T` login can leave only a subset (e.g. just SSH_TTY) set, and dropping
# SSH_TTY misclassified those as local, steering the wrong pinentry / op mode.
# This mirrors mux::is_remote (mux-bootstrap.zsh) and its resolution-time analog
# sec::op_use_service (system-secrets-common.zsh), but MUST stay inlined here:
# environment.sh is sourced very early (by ~/.zshenv and the launchd agent,
# under /bin/sh) before ~/.local/lib is loadable, so it cannot source that zsh
# layer. Hence POSIX `[` + string concatenation, not the zsh-only `[[ ]]`. Keep
# the triple in sync.
if [ -n "${SSH_TTY:-}${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]; then
  # Steer gpg-agent's pinentry to the terminal. gpg forwards this to the agent,
  # which hands it to our pinentry-auto dispatcher; USE_CURSES is the value
  # pinentry-mac honors too. Unset locally so Touch ID stays the default.
  #
  # ...but only on a host that runs its OWN agent. A keyless host consumes the
  # laptop's forwarded agent, so this variable travels to the LAPTOP's pinentry
  # and demotes a machine that has Touch ID into drawing curses in a remote
  # pane. `no-autostart` in gpg.conf is already the marker for "never runs a
  # local agent" (see gpg.conf.tmpl's headless block), so it is exactly the
  # right discriminator and needs no new flag. The grep costs a fork, in the
  # branch that already forks for the op token below.
  if ! grep -qs '^[[:space:]]*no-autostart' "$GNUPGHOME/gpg.conf"; then
    export PINENTRY_USER_DATA="USE_CURSES=1"
  fi

  # Point every OTHER password prompt at the same dialog. sudo, ssh and git all
  # take a helper that gets the prompt in argv and writes the secret to stdout;
  # askpass-auto is pinentry-auto wearing its second face (docs/askpass-design.md).
  #
  # Never clobber a helper somebody else already chose. Editors and agent
  # runtimes set SUDO_ASKPASS to their own, and theirs is usually the better
  # answer: it prompts on the machine the human is sitting at, not in a float on
  # this one. First setter wins, expressed as a rule rather than as a list of
  # vendors to keep in step.
  #
  # ssh additionally needs REQUIRE=force. `prefer` still defers to the TTY when
  # DISPLAY is unset, which over SSH it always is; `force` is documented as "used
  # for all passphrase input regardless of whether DISPLAY is set", and that is
  # the only setting that reaches us.
  #
  # The guard is on the BINARY, not on askpass-auto. That distinction is the
  # whole safety net and it is easy to get backwards: askpass-auto is a chezmoi
  # symlink, so it exists on every host the moment the dotfiles are applied,
  # while pinentry-ui is compiled and nothing builds it automatically —
  # `system-update` does not touch custom-builds. Gating on the symlink
  # therefore exports a helper that can only ever exit 1, and with `sudo -A`
  # there is no prompt underneath it: sudo simply stops working in that pane.
  # Measured on a dev shell an hour after this shipped.
  if [ -x "$HOME/.local/libexec/pinentry-ui" ] &&
    [ -x "$HOME/.local/libexec/askpass-auto" ]; then
    [ -n "${SUDO_ASKPASS:-}" ] || export SUDO_ASKPASS="$HOME/.local/libexec/askpass-auto"
    [ -n "${GIT_ASKPASS:-}" ] || export GIT_ASKPASS="$HOME/.local/libexec/askpass-auto"
    if [ -z "${SSH_ASKPASS:-}" ]; then
      export SSH_ASKPASS="$HOME/.local/libexec/askpass-auto"
      export SSH_ASKPASS_REQUIRE=force
    fi
  fi

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
