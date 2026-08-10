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

  # probe SSH_TTY SSH_CONNECTION SSH_CLIENT -> prints the resulting
  # PINENTRY_USER_DATA (empty when the over-SSH block did not fire).
  probe() {
    env -i \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="$ISO_HOME" \
      TMPDIR="$ISO_HOME/tmp" \
      SSH_TTY="$1" SSH_CONNECTION="$2" SSH_CLIENT="$3" \
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

  install_helper() {
    printf '#!/bin/sh\nexit 0\n' > "$ISO_HOME/.local/libexec/askpass-auto"
    chmod +x "$ISO_HOME/.local/libexec/askpass-auto"
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

  # The dotfiles land before anything is compiled, and pinentry-auto is only
  # reachable through this symlink once `make -C custom-builds/pinentry-ui
  # install` has run. Exporting a path to a helper that is not there would make
  # `sudo -A` fail with no prompt underneath it.
  It 'exports nothing when the helper has not been installed'
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
