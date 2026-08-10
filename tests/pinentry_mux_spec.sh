# Tests for home/dot_local/libexec/executable_pinentry-mux.tmpl — the Assuan
# filter that moves an AI agent's passphrase prompt out of its invisible pty
# and into a mux float (docs/gpg-signing-ux.md).
#
# The filter rewrites exactly one line of the protocol, `OPTION ttyname=`, and
# relays everything else untouched. So every example here drives it with a real
# Assuan conversation over a pipe and asserts on what the pinentry BEHIND it
# received — that is the whole contract, and it is observable without a tmux
# server, a dialog, or a key.
#
# Pass-through is the property most worth pinning. Every gate that fails must
# end at the unchanged in-pane prompt: a non-agent tty, no tmux, a float that
# will not open. Those are not edge cases, they are the normal path for a human
# ssh session, and a regression there breaks signing for everyone rather than
# just failing to help an agent.
#
# Stubs: `ps` decides agent-ness, the popup helper stands in for the float, and
# the pinentry stub echoes back what it was fed. PINENTRY_CURSES_BIN and
# PINENTRY_MUX_POPUP_BIN are the filter's declared test seams.
Describe 'pinentry-mux — Assuan ttyname filter'
  # The filter is a chezmoi template (it bakes the agent-name list from
  # .chezmoidata/mux.yaml), so the spec renders it exactly as chezmoi would —
  # once for the whole file, because `chezmoi execute-template` costs about a
  # second and the rendered filter is read-only.
  PM_BIN="$SHELLSPEC_TMPBASE/pinentry-mux"
  render() {
    chezmoi execute-template <home/dot_local/libexec/executable_pinentry-mux.tmpl \
      >"$PM_BIN" 2>/dev/null
    chmod +x "$PM_BIN"
  }
  BeforeAll 'render'

  setup() {
    PM_TMP=$(mktemp -d)
    mkdir -p "$PM_TMP/bin"

    # Stand-in pinentry: echoes every line it is handed, so an example can
    # assert on the exact stream that came through the filter.
    cat >"$PM_TMP/bin/pinentry" <<'EOS'
#!/bin/sh
echo "OK greeting"
while IFS= read -r l; do
  echo "GOT:$l"
  [ "$l" = BYE ] && break
done
EOS

    # The holder the stub float leaves behind: a real process that logs the
    # close signal, so teardown is asserted against something live rather than
    # assumed. It ignores INT/TERM exactly as the real one does.
    # Arming the traps BEFORE announcing readiness is the invariant, not an
    # implementation detail: the filter may signal the moment it learns the
    # pid, and USR1's default disposition is to kill. The real helper publishes
    # its tty on the fifo only after its traps are set for exactly this reason,
    # so the stub has to be faithful about the ordering or it tests a race that
    # production does not have.
    cat >"$PM_TMP/bin/holder" <<EOS
#!/bin/sh
trap '' INT TERM HUP QUIT
trap 'echo closed >>"$PM_TMP/popup.log"; exit 0' USR1
: >"$PM_TMP/holder.ready"
while :; do sleep 0.1; done
EOS

    # Stand-in float. STUB_POPUP=fail is a float that will not open.
    #
    # The holder's output goes to /dev/null, and that is not tidiness: it
    # inherits the caller's stdout, which here is the command substitution the
    # filter reads the float's tty from, and a pipe stays open until its last
    # writer closes. A holder that kept it open would hang the filter — the
    # same trap the real spawner documents around its own background jobs.
    cat >"$PM_TMP/bin/popup" <<EOS
#!/bin/sh
echo "open \$2" >>"$PM_TMP/popup.log"
[ "\${STUB_POPUP:-ok}" = fail ] && exit 1
rm -f "$PM_TMP/holder.ready"
"$PM_TMP/bin/holder" </dev/null >/dev/null 2>&1 &
pid=\$!
i=0
while [ ! -e "$PM_TMP/holder.ready" ] && [ \$i -lt 50 ]; do sleep 0.1; i=\$((i+1)); done
echo "/dev/ttyFLOAT \$pid"
EOS

    # `ps` is how the filter decides agent-ness; STUB_PS is the comm it reports.
    cat >"$PM_TMP/bin/ps" <<EOS
#!/bin/sh
printf 'Ss+  %s\n' "\${STUB_PS:-/bin/zsh}"
EOS

    # A tmux that is reachable (or not, with STUB_TMUX=fail) but does nothing.
    cat >"$PM_TMP/bin/tmux" <<'EOS'
#!/bin/sh
[ "${STUB_TMUX:-ok}" = fail ] && exit 1
exit 0
EOS

    chmod +x "$PM_TMP/bin"/*
    PATH="$PM_TMP/bin:$PATH"
    export PATH PINENTRY_USER_DATA="USE_CURSES=1"
    export PINENTRY_CURSES_BIN="$PM_TMP/bin/pinentry"
    export PINENTRY_MUX_POPUP_BIN="$PM_TMP/bin/popup"
    export MUX_TMUX_BIN="$PM_TMP/bin/tmux"
    # Exported here, not per-example: the stubs are child processes, so an
    # example that only assigns an unexported variable would silently get the
    # default behavior and pass for the wrong reason.
    STUB_PS=/bin/zsh STUB_POPUP=ok STUB_TMUX=ok
    export STUB_PS STUB_POPUP STUB_TMUX
  }
  cleanup() {
    pkill -f "$PM_TMP" 2>/dev/null
    rm -rf "$PM_TMP"
    unset PM_TMP PINENTRY_USER_DATA PINENTRY_CURSES_BIN PINENTRY_MUX_POPUP_BIN \
          MUX_TMUX_BIN STUB_PS STUB_POPUP STUB_TMUX
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A minimal signing conversation, fed on stdin under a watchdog so a
  # regression that wedges the filter fails the example instead of the suite.
  converse() {
    printf 'OPTION ttyname=%s\nOPTION ttytype=screen\nSETPROMPT PIN\nGETPIN\nBYE\n' \
      "${1:-/dev/ttysAGENT}" |
      { "$PM_BIN" & p=$!
        ( sleep 8; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
        wait "$p"; kill "$w" 2>/dev/null; }
    # The close signal is asynchronous: the filter sends USR1 and exits, while
    # the holder is mid-`sleep` and runs its handler on the next tick. Wait for
    # it to actually go, so the teardown assertion is not a race. No holder (a
    # pass-through example) falls straight through.
    local i=0
    while [ "$i" -lt 30 ] && pgrep -f "$PM_TMP/bin/holder" >/dev/null 2>&1; do
      sleep 0.1
      i=$((i + 1))
    done
  }

  # Assuan is strictly synchronous — one response per command — and because
  # pinentry answers the agent directly, this filter can never swallow a reply
  # it did not ask for. So it must hand pinentry exactly as many commands as the
  # agent handed it, no more. Counting them is the point: every content
  # assertion in this file passed while an injected `OPTION ttyname=` quietly
  # added a surplus OK, which the agent then read as the answer to GETPIN — a
  # result with no data, which IS "No passphrase given". Signing failed every
  # time while the dialog on screen looked perfect, and nothing here noticed.
  budget() {
    printf 'OPTION ttyname=/dev/ttysAGENT\nOPTION ttytype=screen\nSETPROMPT PIN\nGETPIN\nBYE\n' |
      { "$PM_BIN" & p=$!
        ( sleep 8; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
        wait "$p"; kill "$w" 2>/dev/null; } >"$PM_TMP/budget.out"
    printf 'sent=5 forwarded=%s\n' "$(grep -c '^GOT:' "$PM_TMP/budget.out")"
  }

  # The same conversation with the agent's end left open behind the hang-up,
  # which is not a contrivance: reject a passphrase and gpg-agent keeps the
  # connection while pinentry exits on BYE, so the filter's read never returns
  # on its own. One writer emits the conversation and then simply stays open —
  # writing and holding from the same process is what makes it deterministic,
  # since a separate keeper could still be blocked in open() when the writer
  # closed, handing the filter the EOF this example exists to withhold.
  converse_abandoned() {
    mkfifo "$PM_TMP/agent.fifo"
    { printf 'OPTION ttyname=/dev/ttysAGENT\nSETPROMPT PIN\nGETPIN\nBYE\n'
      sleep 20; } >"$PM_TMP/agent.fifo" &
    keeper=$!
    { "$PM_BIN" <"$PM_TMP/agent.fifo" & p=$!
      ( sleep 8; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
      wait "$p"; kill "$w" 2>/dev/null; }
    kill "$keeper" 2>/dev/null
    local i=0
    while [ "$i" -lt 30 ] && pgrep -f "$PM_TMP/bin/holder" >/dev/null 2>&1; do
      sleep 0.1
      i=$((i + 1))
    done
  }

  Describe 'an agent pane'
    It 'rewrites ttyname to the float and leaves the rest of the protocol alone'
      STUB_PS=/Users/x/.local/bin/claude
      When call converse /dev/ttysAGENT
      The line 2 of output should equal "GOT:OPTION ttyname=/dev/ttyFLOAT"
      The output should include "GOT:OPTION ttytype=screen"
      The output should include "GOT:SETPROMPT PIN"
      The output should include "GOT:GETPIN"
      The output should include "GOT:BYE"
      The status should be success
    End

    It 'opens the float against the tty gpg-agent named'
      STUB_PS=/Users/x/.local/bin/claude
      When call converse /dev/ttysAGENT
      The contents of file "$PM_TMP/popup.log" should include "open /dev/ttysAGENT"
      The output should include "GOT:OPTION ttyname=/dev/ttyFLOAT"
    End

    It 'closes the float when the conversation ends'
      STUB_PS=/Users/x/.local/bin/claude
      When call converse /dev/ttysAGENT
      The output should include "GOT:BYE"
      # The holder ignores INT/TERM so a stray key cannot dismiss it; USR1 is
      # the filter's private close channel, and this proves it was used.
      The contents of file "$PM_TMP/popup.log" should include "closed"
    End

    It 'hands pinentry exactly one command for each one the agent sent'
      STUB_PS=/Users/x/.local/bin/claude
      When call budget
      The output should equal "sent=5 forwarded=5"
      The status should be success
    End

    It 'closes the float when pinentry goes, even if the agent holds the line'
      # The float used to live and die with the agent's pipe rather than with
      # the dialog, so a rejected passphrase — pinentry gone, connection still
      # open — left it on screen forever. It ignores INT/TERM by design, so the
      # human could neither dismiss it nor take the keyboard back: the one
      # outcome worse than prompting on a tty nobody is watching.
      STUB_PS=/Users/x/.local/bin/claude
      When call converse_abandoned
      The output should include "GOT:BYE"
      The contents of file "$PM_TMP/popup.log" should include "closed"
      The status should be success
    End
  End

  Describe 'pass-through (the safety net)'
    It 'leaves a human pane prompting in place'
      STUB_PS=/bin/zsh
      When call converse /dev/ttysHUMAN
      The line 2 of output should equal "GOT:OPTION ttyname=/dev/ttysHUMAN"
      The path "$PM_TMP/popup.log" should not be exist
      The status should be success
    End

    It 'leaves the stream alone when no tmux server is reachable'
      STUB_PS=/Users/x/.local/bin/claude
      STUB_TMUX=fail
      When call converse /dev/ttysAGENT
      The line 2 of output should equal "GOT:OPTION ttyname=/dev/ttysAGENT"
      The path "$PM_TMP/popup.log" should not be exist
      The status should be success
    End

    It 'leaves the stream alone when the float will not open'
      STUB_PS=/Users/x/.local/bin/claude
      STUB_POPUP=fail
      When call converse /dev/ttysAGENT
      The line 2 of output should equal "GOT:OPTION ttyname=/dev/ttysAGENT"
      The contents of file "$PM_TMP/popup.log" should include "open /dev/ttysAGENT"
      The status should be success
    End

    It 'never proxies a prompt that is not on the curses lane'
      STUB_PS=/Users/x/.local/bin/claude
      unset PINENTRY_USER_DATA
      When call converse /dev/ttysAGENT
      The line 2 of output should equal "GOT:OPTION ttyname=/dev/ttysAGENT"
      The path "$PM_TMP/popup.log" should not be exist
      The status should be success
    End
  End

  # The list these come from lives in .chezmoidata/mux.yaml and is rendered
  # into both this filter and the tmux keymap probe. The old hand-written
  # `(cursor-)?agent` matched the first two and silently missed the rest, which
  # is exactly the bug that left prompts parked on agent panes.
  Describe 'the shared agent-name list'
    Parameters
      /Users/x/.local/bin/agent
      /Users/x/.local/bin/cursor-agent
      /Users/x/.local/bin/claude
      /Users/x/.local/bin/pi
      /Users/x/.local/bin/pi-coding-agent
      claude.exe
    End

    It "treats $1 as an agent"
      STUB_PS="$1"
      When call converse /dev/ttysAGENT
      The line 2 of output should equal "GOT:OPTION ttyname=/dev/ttyFLOAT"
    End
  End

  Describe 'processes that are not agents'
    Parameters
      /bin/zsh
      /usr/local/bin/node
      /usr/bin/vim
      claude-helper
    End

    It "leaves $1 prompting in place"
      STUB_PS="$1"
      When call converse /dev/ttysHUMAN
      The line 2 of output should equal "GOT:OPTION ttyname=/dev/ttysHUMAN"
    End
  End
End

# Tests for home/dot_local/lib/mux/pinentry.zsh — the half that decides WHERE
# the float goes. Pure lookups against a stub tmux; opening a real float is
# covered end to end by the filter examples above.
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

  # pinentry answers `ERR … Screen or window too small` rather than drawing
  # when the tty cannot hold its 55x7 chrome (measured, pinentry 1.3.3). That
  # is a clean error, but it FAILS the signature — so a client this small has
  # to fall back to prompting in place, which at least works.
  Describe 'sizing the float'
    It 'leaves a margin on a roomy client, up to a readable maximum'
      When call mux::pinentry_geometry /dev/ttys009
      The output should equal "78 16"
      The status should be success
    End

    It 'shrinks to fit a smaller client'
      export STUB_W=70 STUB_H=20
      When call mux::pinentry_geometry /dev/ttys009
      The output should equal "64 14"
    End

    It 'refuses a client too narrow for the dialog'
      export STUB_W=60 STUB_H=42
      When call mux::pinentry_geometry /dev/ttys009
      The status should be failure
    End

    It 'refuses a client too short for the dialog'
      export STUB_W=131 STUB_H=14
      When call mux::pinentry_geometry /dev/ttys009
      The status should be failure
    End

    It 'refuses a client whose size tmux will not report'
      export STUB_W=x STUB_H=y
      When call mux::pinentry_geometry /dev/ttys009
      The status should be failure
    End
  End
End
