# Tests for home/dot_local/lib/mux/pinentry.zsh — the half that decides WHERE
# the passphrase float goes, and how loudly it announces itself.
#
# The Assuan half moved into pinentry-ui, a Rust binary with its own suite
# (custom-builds/pinentry-ui), when the shell filter this file used to test was
# retired: a filter cannot own the response direction, and everything that
# mattered followed from that (docs/pinentry-ui-design.md). What is left here
# is the part that is still shell, and it is all lookups against a stub tmux.
#
# Pass-through is still the property most worth pinning. Every gate that fails
# must end at a prompt drawn in the calling pane: no client, a screen too small,
# a size tmux will not report. Those are not edge cases — they are the normal
# path for a human ssh session, and a regression there breaks signing for
# everyone rather than merely failing to help an agent.
Describe 'mux/pinentry.zsh — float targeting'
  Include home/dot_local/lib/mux/pinentry.zsh

  setup() {
    PL_TMP=$(mktemp -d)
    cat >"$PL_TMP/tmux" <<'EOS'
#!/bin/sh
case "$1" in
  list-panes)   printf '/dev/ttys001 Main\n/dev/ttys002 Work\n' ;;
  list-clients)
    [ "${STUB_NOCLIENT:-}" = 1 ] && exit 0
    # activity name session — ttys009 is the live one, ttys000 was abandoned
    # hours earlier, and tmux lists the stale one FIRST.
    printf '1786258932 /dev/ttys000 Main\n1786303428 /dev/ttys009 Main\n'
    ;;
  display)      printf '%s %s\n' "${STUB_W:-131}" "${STUB_H:-42}" ;;
esac
exit 0
EOS
    chmod +x "$PL_TMP/tmux"
    export MUX_TMUX_BIN="$PL_TMP/tmux"
    unset STUB_NOCLIENT STUB_W STUB_H
  }
  cleanup() { rm -rf "$PL_TMP"; unset PL_TMP MUX_TMUX_BIN STUB_NOCLIENT STUB_W STUB_H; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'mapping the caller tty back to a session'
    It 'finds the session owning the pane'
      When call mux::pinentry_session_for_tty /dev/ttys002
      The output should equal "Work"
      The status should be success
    End

    It 'fails when no pane has that tty'
      When call mux::pinentry_session_for_tty /dev/ttysGONE
      The output should equal ""
      The status should be failure
    End
  End

  # The finding that this whole function exists for: on tmux 3.7b a popup aimed
  # with `-t '=B:'` painted on the client attached to session A, because tmux
  # resolves a popup's client from the CURRENT client. Aiming by session alone
  # puts the passphrase prompt on the wrong screen; `-c <client>` is exact.
  Describe 'resolving the client to paint on'
    # A popup is per-client, so when one session holds several the choice IS
    # the feature: picking the stale client paints the prompt on a screen
    # nobody is watching, which is the bug this whole thing exists to fix.
    It 'picks the most recently active client, not the first one listed'
      When call mux::pinentry_client_for_session Main
      The output should equal "/dev/ttys009"
      The status should be success
    End

    It 'fails for a session nobody is attached to'
      When call mux::pinentry_client_for_session Work
      The status should be failure
    End

    It 'fails when the server has no clients at all'
      export STUB_NOCLIENT=1
      When call mux::pinentry_client_for_session Main
      The status should be failure
    End
  End

  # The caller brings the size now. A tmux popup's dimensions are fixed at
  # creation and the dialog's follow from text that arrives 23 commands after
  # the float has to exist, so the only program that can size it is the one
  # laying the dialog out. This end only checks the screen can take it.
  Describe 'checking the float fits'
    It 'accepts a size with room to spare around it'
      When call mux::pinentry_fits /dev/ttys009 57 21
      The status should be success
    End

    It 'refuses a float wider than the client'
      export STUB_W=50 STUB_H=42
      When call mux::pinentry_fits /dev/ttys009 57 21
      The status should be failure
    End

    It 'refuses a float taller than the client'
      export STUB_W=131 STUB_H=20
      When call mux::pinentry_fits /dev/ttys009 57 21
      The status should be failure
    End

    # A float flush against the edges reads as a takeover rather than a float,
    # and leaves nothing of the session visible behind it.
    It 'refuses a size that would fill the client edge to edge'
      export STUB_W=57 STUB_H=21
      When call mux::pinentry_fits /dev/ttys009 57 21
      The status should be failure
    End

    It 'refuses a client whose size tmux will not report'
      export STUB_W=x STUB_H=y
      When call mux::pinentry_fits /dev/ttys009 57 21
      The status should be failure
    End

    # Whatever went wrong upstream, a float is not opened on a guess.
    It 'refuses a size that is not a pair of numbers'
      When call mux::pinentry_fits /dev/ttys009 wide tall
      The status should be failure
    End
  End

  # When this fires the human is by definition not looking at a terminal, so
  # the sentence is the only context they get. Naming the requester is the
  # difference between going to find out which of three agents wants something
  # and knowing before you stand up.
  Describe 'what the OSD says'
    It 'names the requester, capitalised'
      When call mux::pinentry_alert_text claude
      The output should equal "Claude is requesting your passphrase"
    End

    It 'falls back to a generic sentence when nobody could be named'
      When call mux::pinentry_alert_text ""
      The output should equal "Passphrase needed — a signing prompt is waiting in tmux"
    End
  End
End

# The float's own entry point. Only the argument contract is checked here —
# opening a real popup needs a tmux server, a client and a human, and is
# covered by the by-hand pass in docs/pinentry-ui-design.md.
Describe 'pinentry-mux-popup — argument contract'
  POPUP=home/dot_local/libexec/executable_pinentry-mux-popup

  # The size is required now, and silently defaulting it would put a float of
  # the wrong size on screen with no way to resize it.
  It 'refuses --open without a size'
    When run zsh "$POPUP" --open /dev/ttys001
    The status should equal 2
    The stderr should include "--open <caller_tty> <w> <h>"
  End

  It 'refuses an unknown mode'
    When run zsh "$POPUP" --frobnicate
    The status should equal 2
    The stderr should include "usage:"
  End
End
