# Tests for home/dot_local/libexec/executable_presence — the one helper that
# decides which surface a passphrase prompt should use.
#
# Scope is the LAST branch only: the console decision between `touchid` and
# `gui`. That is the branch that changed when device enumeration was replaced
# by a real capability probe, and it is the only one with a seam — the probe is
# a separate executable, resolved next to the script, so a stub can answer a
# chosen way.
#
# The earlier lanes (`vnc`, `remote`) are deliberately NOT exercised, for the
# reason pinentry_auto_spec.sh gives about its own untested branches: they read
# /usr/sbin/netstat, /usr/sbin/ioreg, /usr/bin/who and tmux by absolute path
# with no seam, and adding one that exists only for this file would be a wider
# change than the change under test. They are reached first, so on a machine
# that answers `remote` or `vnc` these cases cannot run at all and are skipped
# rather than faked.
#
# WHY THE SCRIPT IS COPIED RATHER THAN RUN IN PLACE
#
# The probe is found via `dirname "$0"`, so a copy in a temp directory puts the
# stub exactly where the real binary would sit — and keeps the repo's own
# libexec free of test artefacts. That resolution is itself load-bearing and
# has a case below: the script's header promises it reads no environment, so
# the probe must be found with $HOME pointing somewhere else entirely.
Describe 'presence console lane'
  PRESENCE_SRC="home/dot_local/libexec/executable_presence"

  Skip if "presence must be reachable to know whether this machine is at a console" \
    [ ! -x "$HOME/.local/libexec/presence" ]

  # The real helper decides whether these cases are meaningful at all. Anything
  # other than a console answer means an earlier lane won on this machine.
  not_at_console() {
    case "$("$HOME/.local/libexec/presence" 2>/dev/null)" in
      touchid | gui) return 1 ;;
      *) return 0 ;;
    esac
  }
  Skip if "an earlier lane wins on this machine, so the console branch is unreachable" \
    not_at_console

  setup() {
    PR_DIR=$(mktemp -d)
    cp "$PRESENCE_SRC" "$PR_DIR/presence"
    chmod +x "$PR_DIR/presence"
  }
  cleanup() { rm -rf "$PR_DIR"; unset PR_DIR; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # The probe reports by exit status and nothing else, which is all presence
  # reads from it.
  probe_exits() {
    printf '#!/bin/sh\nexit %s\n' "$1" >"$PR_DIR/touchid-available"
    chmod +x "$PR_DIR/touchid-available"
  }

  ask() { sh "$PR_DIR/presence"; }

  It 'takes the touchid lane when the probe reports a usable sensor'
    probe_exits 0
    When call ask
    The output should equal "touchid"
    The status should be success
  End

  # The regression this file exists for. Enumeration said `touchid` here too,
  # and the user got a pinentry-mac password box via pinentry-touchid's silent
  # fallback — a lane that could not deliver what it named.
  It 'falls to the gui lane when the sensor cannot authenticate'
    probe_exits 1
    When call ask
    The output should equal "gui"
    The status should be success
  End

  # Normal on a host that has the dotfiles but no Swift toolchain: the build
  # hook is soft, so "applied, nothing built" must still answer usefully.
  It 'falls to the gui lane when the probe was never built'
    When call ask
    The output should equal "gui"
    The status should be success
  End

  # A present-but-unrunnable file must not be trusted on its name alone.
  It 'falls to the gui lane when the probe is not executable'
    printf '#!/bin/sh\nexit 0\n' >"$PR_DIR/touchid-available"
    chmod 0644 "$PR_DIR/touchid-available"
    When call ask
    The output should equal "gui"
    The status should be success
  End

  # The header's promise, asserted: the probe is found next to the script, so a
  # $HOME pointing anywhere else changes nothing. Resolving it under $HOME
  # instead would pass every case above and fail only in gpg-agent's
  # environment, which is where this helper actually runs.
  It 'finds the probe next to itself rather than under $HOME'
    probe_exits 0
    empty=$(mktemp -d)
    When call env HOME="$empty" sh "$PR_DIR/presence"
    The output should equal "touchid"
    rm -rf "$empty"
  End
End
