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

# The Rex half: the float is a floating layer, the pane list comes from the
# Rex server, and the process names from `ps` on each pane's tty. Hermetic:
# `rex` and `ps` are stubs.
Describe 'mux/pinentry.zsh — on Rex'
  Include home/dot_local/lib/mux/pinentry.zsh

  setup() {
    PR_TMP=$(mktemp -d)
    cat >"$PR_TMP/rex" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$PR_TMP/rex.log"
case " \$* " in
  *" client ls "*) echo '{"clients":[{"info":{"kind":"app"},"connection_state":"connected","session_ids":["session:a"]},{"info":{"kind":"cli"},"connection_state":"connected","session_ids":["session:b"]},{"info":{"kind":"app"},"connection_state":"'"\${STUB_B_STATE:-lost}"'","session_ids":["session:b"]}]}' ;;
  *" ls --json "*) echo '{"sessions":[{"session_id":"session:a","label":"Main"},{"session_id":"session:b","label":"Jobs | x"}]}' ;;
  *" session.new_layer "*)
    cat >"$PR_TMP/req.json"
    [ "\${STUB_LAYER:-ok}" = fail ] && exit 1
    : >"$PR_TMP/alive"
    if [ "\${STUB_LAYER:-ok}" = ok ]; then
      fifo=\$(jq -r '.layout.block.options.command[-1]' "$PR_TMP/req.json")
      ( printf '/dev/ttys099 4242\n' >"\$fifo" ) >/dev/null 2>&1 &
    fi
    echo '{"block_ids":["block:layer"]}' ;;
  *" session.view "*)
    case " \$* " in
      *" -s session:b "*) echo '{"active_window_id":"window:j","windows":[{"window_id":"window:j","focused_block_id":"block:job","layers":[{"kind":"tiled","blocks":[{"block_id":"block:job","creator_name":"com.superlogical.terminal","rect":[0,0,1,1]}]}]}]}' ;;
      *) echo '{"active_window_id":"window:2","windows":[{"window_id":"window:1","focused_block_id":"block:sh","layers":[{"kind":"tiled","blocks":[{"block_id":"block:sh","creator_name":"com.superlogical.terminal","rect":[0,0,1,1]}]}]},{"window_id":"window:2","focused_block_id":"block:ag","layers":[{"kind":"tiled","blocks":[{"block_id":"block:ag","creator_name":"com.superlogical.terminal","rect":[0,0,0.5,1]},{"block_id":"block:wrapped","creator_name":"com.superlogical.terminal","rect":[0.5,0,0.5,1]},{"block_id":"block:web","creator_name":"com.example.browser"}]}]}]}' ;;
    esac ;;
  *" block call "*" process "*)
    case " \$* " in
      *" -b block:sh "*) echo '{"child":{"pid":101},"foreground":{"name":"zsh"}}' ;;
      *" -b block:ag "*) echo '{"child":{"pid":102},"foreground":{"name":"claude.exe"}}' ;;
      *" -b block:wrapped "*) echo '{"child":{"pid":103},"foreground":{"name":"node"}}' ;;
      *" -b block:job "*) echo '{"child":{"pid":104},"foreground":{"name":"zsh"}}' ;;
    esac ;;
  *" block call "*" size "*) echo "{\"columns\":\${STUB_COLS:-60},\"rows\":\${STUB_ROWS:-40}}" ;;
  *" block inspect "*)
    # A layer closed by hand, with no time passing: when the example wrote
    # polls-left, the layer answers that many more probes and is gone.
    [ -e "$PR_TMP/alive" ] || exit 3
    if [ -f "$PR_TMP/polls-left" ]; then
      left=\$(cat "$PR_TMP/polls-left")
      [ "\$left" -gt 0 ] || { rm -f "$PR_TMP/alive"; exit 3; }
      echo \$((left - 1)) >"$PR_TMP/polls-left"
    fi
    exit 0 ;;
  *" block close "*) rm -f "$PR_TMP/alive" ;;
esac
exit 0
EOS
    cat >"$PR_TMP/ps" <<'EOS'
#!/bin/sh
case "$*" in
  "-o tty= -p 101") echo 'ttys001' ;;
  "-o tty= -p 102") echo 'ttys002  ' ;;
  "-o tty= -p 103") echo 'ttys003' ;;
  "-o tty= -p 104") echo '??' ;;
  "-o state= -o comm= -t ttys003") printf 'Ss   -zsh\nT    /opt/bin/claude\nS+   node\nS+   /usr/local/bin/cursor-agent\n' ;;
  "-o state= -o comm= -t ttys001") printf 'Ss   -zsh\n' ;;
esac
EOS
    chmod +x "$PR_TMP/rex" "$PR_TMP/ps"
    printf '%s\n' '# agents' agent cursor-agent claude >"$PR_TMP/agents"
    export MUX_REX_BIN="$PR_TMP/rex" MUX_PE_PS_BIN="$PR_TMP/ps" MUX_PE_AGENT_PROCS="$PR_TMP/agents" TMPDIR="$PR_TMP"
    unset TMUX MUX_TMUX_BIN MUX_BACKEND REX_BLOCK REX_SESSION STUB_LAYER STUB_COLS STUB_ROWS STUB_B_STATE
    mux::pinentry_alert() { print -r -- "$*" >"$PR_TMP/alert"; }
  }
  cleanup() { rm -rf "$PR_TMP"; unset PR_TMP MUX_REX_BIN MUX_PE_PS_BIN MUX_PE_AGENT_PROCS TMPDIR MUX_BACKEND STUB_LAYER STUB_COLS STUB_ROWS STUB_B_STATE; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'listing the panes'
    It 'prints every terminal pane that has a tty, in the tmux line layout'
      When call mux::pinentry_rex_panes
      The output should equal "/dev/ttys001|block:sh|zsh|zsh|1|1|0|Main
/dev/ttys002|block:ag|claude|claude|2|1|1|Main
/dev/ttys003|block:wrapped|cursor-agent|cursor-agent|2|0|1|Main"
    End

    It 'names an agent running under a wrapper, but not a stopped one'
      # ttys003: claude is stopped (T), cursor-agent is running.
      When call mux::pinentry_rex_panes
      The line 3 of output should include "|cursor-agent|"
    End

    It 'never starts a server'
      check() { mux::pinentry_rex_panes >/dev/null; grep -c -v -- '--autostart=false' "$PR_TMP/rex.log" || true; }
      When call check
      The output should equal "0"
    End

    It 'fails when no server answers'
      export MUX_REX_BIN=/usr/bin/false
      When call mux::pinentry_rex_panes
      The status should be failure
    End
  End

  Describe 'listing who is watching'
    It 'prints the sessions a connected app shows, by label, separator-safe'
      When call mux::pinentry_rex_attached
      The output should equal "Main"
    End

    It 'flattens the separators of a label it prints'
      export STUB_B_STATE=connected
      When call mux::pinentry_rex_attached
      The output should equal "Main
Jobs   x"
    End

    # One implementation (mux/rex.zsh) answers the shim's question too.
    It 'gives the shim the same sessions: an app that lost its connection shows nothing'
      export MUX_BACKEND=rex
      When call mux::attached_sessions
      The output should equal "Main"
    End

    It 'gives the shim the label as it is'
      export MUX_BACKEND=rex STUB_B_STATE=connected
      When call mux::attached_sessions
      The output should equal "Main
Jobs | x"
    End

    It 'bounds every call the shim'"'"'s query makes, and starts no server'
      bounded() { MUX_BACKEND=rex mux::attached_sessions >/dev/null; grep -c -v -- '^--autostart=false --timeout 3s ' "$PR_TMP/rex.log" || true; }
      When call bounded
      The output should equal "0"
    End
  End

  Describe 'opening the float'
    layer_cmd() { jq -r '.layout.block.options.command | join(" ")' "$PR_TMP/req.json" | sed -e "s|$PR_TMP/[^ ]*|FIFO|"; }

    It 'opens a layer over the asking pane and prints its tty and holder'
      When call mux::pinentry_spawn /dev/ttys002 44 12 claude
      The output should equal "/dev/ttys099 4242"
      The status should be success
    End

    It 'runs the holder in that layer, in the asking pane'"'"'s session, sized in cells'
      shape() {
        mux::pinentry_spawn /dev/ttys002 60 20 claude >/dev/null
        layer_cmd | grep -c 'libexec/pinentry-mux-popup --hold FIFO$'
        grep -c -- '-s block:ag session.new_layer' "$PR_TMP/rex.log"
        # block:ag is half of a window: 60 cols x 40 rows -> a 120 x 40 window.
        jq -c '.bounds | map(. * 100 | round)' "$PR_TMP/req.json"
        cat "$PR_TMP/alert"
      }
      When call shape
      The line 1 of output should equal "1"
      The line 2 of output should equal "1"
      The line 3 of output should equal "[25,25,50,50]"
      The line 4 of output should equal " claude Rex"
    End

    It 'fails for a tty no pane has, opening nothing'
      nothing() { mux::pinentry_spawn /dev/ttys777 44 12; print -r -- "rc=$?"; [[ -e "$PR_TMP/req.json" ]] && print opened || print "not opened"; }
      When call nothing
      The output should equal "rc=1
not opened"
    End

    It 'refuses a float the window cannot spare the margin for'
      nothing() { mux::pinentry_spawn /dev/ttys002 118 12; print -r -- "rc=$?"; [[ -e "$PR_TMP/req.json" ]] && print opened || print "not opened"; }
      When call nothing
      The output should equal "rc=1
not opened"
    End

    It 'fails when the layer cannot be created, leaving nothing behind'
      export STUB_LAYER=fail
      failed() { mux::pinentry_spawn /dev/ttys002 44 12; print -r -- "rc=$?"; ls "$PR_TMP" | grep -c 'fifo' || true; }
      When call failed
      The output should equal "rc=1
0"
    End

    It 'closes a layer whose holder never reports, and fails'
      export STUB_LAYER=silent
      silent() {
        # The holder never writes; the layer is closed by hand a moment later:
        # it answers the first once-a-second probe and is gone at the second.
        # The naps between probes go to the virtual clock.
        spec_clock_set 1000
        echo 1 >"$PR_TMP/polls-left"
        mux::pinentry_spawn /dev/ttys002 44 12; print -r -- "rc=$?"
        ls "$PR_TMP" | grep -c 'fifo' || true
      }
      When call silent
      The output should equal "rc=1
0"
    End

    It 'refuses a size that is not a pair of numbers'
      When call mux::pinentry_spawn /dev/ttys002 wide 12
      The status should be failure
    End
  End

  Describe 'what the OSD says'
    It 'names Rex when nobody could be named'
      When call mux::pinentry_alert_text "" Rex
      The output should equal "Passphrase needed — a signing prompt is waiting in Rex"
    End
  End
End
