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
