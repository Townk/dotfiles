# Tests for home/dot_config/zsh/environment.sh — the very-early XDG/env bootstrap
# sourced by BOTH ~/.zshenv (every zsh) and the launchd agent (under /bin/sh),
# before ~/.local/lib is loadable. Its over-SSH block steers PINENTRY_USER_DATA
# (and the 1Password op mode) and MUST use the full canonical remote triple —
# SSH_TTY / SSH_CONNECTION / SSH_CLIENT — the inlined mirror of mux::is_remote
# (a bare early-boot script cannot source that zsh layer). The regression this
# guards: a no-pty `ssh -T` login can leave only SSH_TTY set, and dropping it
# misclassified the session as local, choosing the wrong pinentry / op mode.
#
# The script is sourced under a fully isolated env (env -i + a temp $HOME) so
# nothing but the SSH triple can influence the observable output, and so the
# real ~/.config secrets/token are never touched.
Describe 'environment.sh over-SSH detection'
  ENV_SH="home/dot_config/zsh/environment.sh"

  setup() {
    ISO_HOME="$(mktemp -d)"
  }
  cleanup() { rm -rf "$ISO_HOME"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # probe SSH_TTY SSH_CONNECTION SSH_CLIENT [inherited] -> prints the resulting
  # PINENTRY_USER_DATA (empty when the over-SSH block did not fire). The
  # optional fourth argument presets it, as a tmux server born over SSH does.
  probe() {
    # shellcheck disable=SC2086  # the ${4:+...} word must vanish when unset
    env -i \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="$ISO_HOME" \
      TMPDIR="$ISO_HOME/tmp" \
      SSH_TTY="$1" SSH_CONNECTION="$2" SSH_CLIENT="$3" \
      ${4:+PINENTRY_USER_DATA=$4} \
      sh -c 'mkdir -p "$TMPDIR" 2>/dev/null; . '"$ENV_SH"' >/dev/null 2>&1; printf "%s" "${PINENTRY_USER_DATA:-}"'
  }

  It 'treats an SSH_TTY-only (ssh -T) session as remote'
    When call probe "/dev/pts/3" "" ""
    The output should equal "USE_CURSES=1"
  End

  It 'treats an SSH_CONNECTION-only session as remote'
    When call probe "" "10.0.0.1 5 10.0.0.2 22" ""
    The output should equal "USE_CURSES=1"
  End

  It 'treats an SSH_CLIENT-only session as remote'
    When call probe "" "" "10.0.0.1 5 22"
    The output should equal "USE_CURSES=1"
  End

  It 'leaves a local session (no SSH vars) alone'
    When call probe "" "" ""
    The output should equal ""
  End

  # A keyless host consumes the LAPTOP's forwarded gpg-agent, so USE_CURSES
  # would travel there and demote a machine that has Touch ID into drawing
  # curses in a remote pane. `no-autostart` is gpg.conf's existing marker for
  # "never runs a local agent", so the remote block must skip the export when
  # it is present — and must still fire when it is not, or the mux float on
  # the key-holding host (which is gated on USE_CURSES) never opens.
  gpgconf_with() {
    mkdir -p "$ISO_HOME/.config/gnupg"
    printf '%s\n' "$1" > "$ISO_HOME/.config/gnupg/gpg.conf"
  }

  It 'skips USE_CURSES on a host whose gpg.conf says no-autostart'
    gpgconf_with "no-autostart"
    When call probe "/dev/pts/3" "" ""
    The output should equal ""
  End

  It 'still exports USE_CURSES when gpg.conf exists without no-autostart'
    gpgconf_with "default-key A9C4A3D8CA995D91"
    When call probe "/dev/pts/3" "" ""
    The output should equal "USE_CURSES=1"
  End

  It 'ignores a commented-out no-autostart'
    gpgconf_with "# no-autostart"
    When call probe "/dev/pts/3" "" ""
    The output should equal "USE_CURSES=1"
  End

  # A Mac with the `presence` helper picks the pinentry per request and ignores
  # USE_CURSES, so there the variable can only hurt: gpg-agent forwards it as
  # `OPTION pinentry-user-data`, and pinentry-touchid 0.0.3 answers that unknown
  # option with ERR *and* OK. Every later reply is then off by one, GETPIN reads
  # SETPROMPT's stale OK, and signing fails with "No passphrase given" while
  # Touch ID is still on screen. A tmux server born over SSH hands both the SSH
  # markers and the variable to every later pane, so an inherited copy has to
  # be removed, not merely left unexported.
  install_presence() {
    mkdir -p "$ISO_HOME/.local/libexec"
    printf '#!/bin/sh\necho touchid\n' > "$ISO_HOME/.local/libexec/presence"
    chmod +x "$ISO_HOME/.local/libexec/presence"
  }
  not_darwin() { [ "$(uname -s)" != Darwin ]; }

  It 'skips USE_CURSES on a Mac with the presence helper'
    Skip if "the presence lane only exists on Darwin" not_darwin
    install_presence
    When call probe "/dev/pts/3" "" ""
    The output should equal ""
  End

  It 'removes a USE_CURSES inherited from an SSH-born tmux server'
    Skip if "the presence lane only exists on Darwin" not_darwin
    install_presence
    When call probe "/dev/pts/3" "" "" "USE_CURSES=1"
    The output should equal ""
  End

  It 'keeps USE_CURSES when the presence helper is not executable'
    install_presence
    chmod -x "$ISO_HOME/.local/libexec/presence"
    When call probe "/dev/pts/3" "" ""
    The output should equal "USE_CURSES=1"
  End
End

# The askpass exports in the same over-SSH block: sudo, ssh and git all take a
# helper that gets the prompt in argv and writes the secret to stdout, and they
# are pointed at askpass-auto — pinentry-auto's second personality
# (docs/askpass-design.md).
#
# Two rules carry the weight. The helper has to EXIST, because there is no stock
# prompt underneath `sudo -A`; and an existing value must never be overwritten,
# because editors and agent runtimes set their own, theirs prompts on the
# machine the human is actually at, and deferring is the better answer.
Describe 'environment.sh askpass wiring'
  ENV_SH="home/dot_config/zsh/environment.sh"

  setup() {
    ISO_HOME="$(mktemp -d)"
    mkdir -p "$ISO_HOME/.local/libexec"
  }
  cleanup() { rm -rf "$ISO_HOME"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A host after `chezmoi apply`: the dispatcher and its symlink are managed, so
  # they are always here. Nothing is compiled yet.
  install_dispatcher() {
    printf '#!/bin/sh\nexit 1\n' > "$ISO_HOME/.local/libexec/askpass-auto"
    chmod +x "$ISO_HOME/.local/libexec/askpass-auto"
  }

  # ...and after somebody ran `make -C custom-builds/pinentry-ui install`.
  install_helper() {
    install_dispatcher
    printf '#!/bin/sh\nexit 0\n' > "$ISO_HOME/.local/libexec/pinentry-ui"
    chmod +x "$ISO_HOME/.local/libexec/pinentry-ui"
  }

  # probe <remote?> [preset var=value ...] -> prints the four resulting values.
  probe_askpass() {
    remote="$1"; shift
    env -i \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="$ISO_HOME" \
      TMPDIR="$ISO_HOME/tmp" \
      SSH_CONNECTION="$remote" \
      "$@" \
      sh -c 'mkdir -p "$TMPDIR" 2>/dev/null; . '"$ENV_SH"' >/dev/null 2>&1;
             printf "%s|%s|%s|%s" "${SUDO_ASKPASS:-}" "${SSH_ASKPASS:-}" \
                                  "${SSH_ASKPASS_REQUIRE:-}" "${GIT_ASKPASS:-}"'
  }

  It 'points sudo, ssh and git at the helper over SSH'
    install_helper
    When call probe_askpass "10.0.0.1 5 10.0.0.2 22"
    The output should equal "$ISO_HOME/.local/libexec/askpass-auto|$ISO_HOME/.local/libexec/askpass-auto|force|$ISO_HOME/.local/libexec/askpass-auto"
  End

  # `prefer` still defers to the TTY when DISPLAY is unset, which over SSH it
  # always is. `force` is the only setting that reaches us at all.
  It 'forces ssh to use it even with no DISPLAY'
    install_helper
    When call probe_askpass "10.0.0.1 5 10.0.0.2 22"
    The output should include "|force|"
  End

  It 'leaves a local session alone'
    install_helper
    When call probe_askpass ""
    The output should equal "|||"
  End

  It 'exports nothing when nothing at all is installed'
    When call probe_askpass "10.0.0.1 5 10.0.0.2 22"
    The output should equal "|||"
  End

  # The regression, and the reason the guard names the binary. `chezmoi apply`
  # installs askpass-auto on EVERY host, while pinentry-ui is compiled and
  # nothing builds it automatically — `system-update` does not touch
  # custom-builds. A guard on the symlink is therefore always true, so a host
  # that has only pulled the dotfiles exports a helper that can only exit 1 —
  # and with `sudo -A` there is no prompt underneath it. Measured on a dev shell
  # within the hour: sudo stopped working there, with `\sudo` the only way in.
  It 'exports nothing when the dispatcher is there but nothing is built'
    install_dispatcher
    When call probe_askpass "10.0.0.1 5 10.0.0.2 22"
    The output should equal "|||"
  End

  It 'never overwrites a helper somebody else chose'
    install_helper
    When call probe_askpass "10.0.0.1 5 10.0.0.2 22" SUDO_ASKPASS="/opt/theirs/askpass"
    The output should start with "/opt/theirs/askpass|"
  End

  # SSH_ASKPASS and its REQUIRE move together: forcing ssh to use somebody
  # else's helper is a decision we have no business making for them.
  It 'leaves REQUIRE alone when ssh already has a helper'
    install_helper
    When call probe_askpass "10.0.0.1 5 10.0.0.2 22" SSH_ASKPASS="/opt/theirs/askpass"
    The output should include "|/opt/theirs/askpass||"
  End
End

# XDG_RUNTIME_DIR must honour a runtime dir the OS already provides
# (systemd-logind exports /run/user/<uid>; `systemctl --user` finds its bus
# there, so clobbering it breaks every user-unit call) and fall back under
# TMPDIR only when nothing is set or the provided dir is gone. The Go env
# lives HERE, not in the interactive rc: a chezmoi apply over ssh, the package
# workers it runs, and their on-change hooks are all non-interactive, and
# `go install` without GOBIN lands binaries in the default ~/go/bin where
# nothing looks (the first server onboarding did exactly that).
Describe 'environment.sh runtime dir and Go env'
  ENV_SH="home/dot_config/zsh/environment.sh"

  setup() {
    ISO_HOME="$(mktemp -d)"
    mkdir -p "$ISO_HOME/tmp" "$ISO_HOME/run"
  }
  cleanup() { rm -rf "$ISO_HOME"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # probe_env <inherited XDG_RUNTIME_DIR or ""> <VAR> — sources the file under
  # an isolated env and prints $VAR.
  probe_env() {
    env -i \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="$ISO_HOME" \
      TMPDIR="$ISO_HOME/tmp" \
      ${1:+XDG_RUNTIME_DIR="$1"} \
      sh -c '. '"$ENV_SH"' >/dev/null 2>&1; eval "printf \"%s\" \"\$$1\""' _ "$2"
  }

  It 'keeps a runtime dir the OS already provides'
    When call probe_env "$ISO_HOME/run" XDG_RUNTIME_DIR
    The output should equal "$ISO_HOME/run"
  End

  It 'falls back under TMPDIR when nothing is set'
    When call probe_env "" XDG_RUNTIME_DIR
    The output should equal "$ISO_HOME/tmp/runtime-$(id -u)"
  End

  It 'falls back when the provided dir does not exist'
    When call probe_env "$ISO_HOME/missing" XDG_RUNTIME_DIR
    The output should equal "$ISO_HOME/tmp/runtime-$(id -u)"
  End

  It 'exports GOPATH under XDG_DATA_HOME'
    When call probe_env "" GOPATH
    The output should equal "$ISO_HOME/.local/share/go"
  End

  It 'exports GOBIN under GOPATH'
    When call probe_env "" GOBIN
    The output should equal "$ISO_HOME/.local/share/go/bin"
  End

  It 'puts GOBIN on PATH for non-interactive shells'
    When call probe_env "" PATH
    The output should include "$ISO_HOME/.local/share/go/bin:"
  End
End
