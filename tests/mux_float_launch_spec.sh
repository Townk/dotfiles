# Regression test for the float-capture helpers in home/dot_local/lib/mux/*.zsh.
#
# HI-7: each float (_mux_tx_pick_float / _mux_tx_float and the Rex twins)
# spawns the popup/pane, discards its stderr, never checks whether
# it actually launched, and then does `result=$(cat "$fifo")`. If the spawn
# FAILS (no client, a client that already owns a popup, a missing pane, …) no
# writer ever opens the FIFO, so the `cat` blocks on open(2) forever: the caller
# (mux::pick / mux::choose used by ai-commit, pick-playbook, system-backup-tm)
# hangs and leaks the txpick-fifo.* / txpick.* staged temp files.
#
# The fix must return non-zero PROMPTLY and leave no temp files behind when the
# spawn fails, while the happy path (a real selection over the capture FIFO) is
# unchanged.
#
# Each example runs the float through run_and_report: the float's stdout is
# relayed on stdout, its exit status is preserved, and any leftover float temp
# file in TMPDIR is reported on stderr as "LEAK:<name>". That lets one `When
# call` assert the selection, the return, and the absence of leaks together.
#
# No example waits (tests/README-scaffolding.md, policy 2), so there is no
# watchdog either: a float that blocks on its FIFO again hangs its example
# instead of failing it after N seconds. "Promptly" is asserted as a count
# where the code polls (the Rex half: so many `block inspect` calls, so much
# time on the virtual clock), and is the example returning at all where it
# does not (the tmux half, whose float blocks on nothing once the popup fails).

# run_and_report <secs> <fn> [args...]   (picker rows, if any, on stdin)
#   Run <fn args> in a subshell. Relay its stdout, preserve its status, and
#   print LEAK:<name> on stderr for every float temp still present in TEST_TMP
#   afterwards. <secs> was the watchdog's bound and is ignored: it is kept so
#   that every `When call run_and_report N …` line reads as it always did.
run_and_report() {
  shift
  local tmpin rc=0
  tmpin=$(mktemp "$TEST_TMP/guardin.XXXXXX")
  # Stage stdin — but never from a TERMINAL: an example with no piped rows
  # then waited on the tty forever, hanging the whole suite whenever it ran
  # with one attached (e.g. under `script`).
  if [ -t 0 ]; then : >"$tmpin"; else cat >"$tmpin"; fi

  # The float's own stderr is not part of what an example asserts: only the
  # LEAK lines below are.
  ( "$@" <"$tmpin" 2>/dev/null ) || rc=$?
  rm -f -- "$tmpin"

  local f
  for f in "$TEST_TMP"/*fifo*(N) "$TEST_TMP"/txpick.*(N) \
           "$TEST_TMP"/*-out.*(N) "$TEST_TMP"/txinput*(N) \
           "$TEST_TMP"/rxpick.*(N) "$TEST_TMP"/rxinput*(N); do
    [[ "${f:t}" == guard* ]] && continue
    print -r -- "LEAK:${f:t}" >&2
  done
  return $rc
}

Describe 'mux/tmux.zsh — float launch guard (HI-7)'
  Include home/dot_local/lib/mux.zsh
  # One warm slot for the tmux stub every example of the two tmux groups
  # writes: see tests/exec_warm_helper.sh.
  Include tests/exec_warm_helper.sh
  BeforeAll 'spec_exec_pool_warm 1'

  setup() {
    TEST_TMP=$(mktemp -d)
    export TMPDIR="$TEST_TMP"          # steer every float temp into the sandbox
    export TMUX=/tmp/sock,1,0
    stub="$TEST_TMP/tmux"
    {
      echo '#!/usr/bin/env zsh'
      echo 'printf "%s\n" "$@" >> "${STUB_ARGV_LOG:-/dev/null}"'
      echo 'if [[ "$1" == display-popup ]]; then'
      echo '  if [[ "${STUB_MODE:-ok}" == fail ]]; then exit 1; fi'
      echo '  fifo=""; prev=""'
      echo '  for a in "$@"; do [[ "$prev" == "--capture" ]] && fifo="$a"; prev="$a"; done'
      echo '  # Write-only open BLOCKS until the float opens the fifo for read — a'
      echo '  # race-free rendezvous. (The old `3<>` + `sleep 0.5` hoped the reader'
      echo '  # opened within 0.5s; on a slow box it did not, the buffer was freed on'
      echo '  # close, and the reader hung — stalling the whole suite. HI-7 harness.)'
      echo '  [[ -n "$fifo" ]] && { { exec 3>"$fifo"; printf "%s" "${STUB_ANSWER:-picked}" >&3; exec 3>&- } &! }'
      echo '  exit 0'
      echo 'fi'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export MUX_TMUX_BIN="$stub"
    export STUB_MODE=ok STUB_ANSWER=picked
  }
  cleanup() { rm -rf "$TEST_TMP"; unset MUX_TMUX_BIN STUB_MODE STUB_ANSWER TMPDIR; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It '_mux_tx_pick_float returns the selection and leaves no temp files (happy path)'
    export STUB_ANSWER=claude
    Data
      #|claude  Claude Code
    End
    When call run_and_report 8 _mux_tx_pick_float 70% 60% Pick --output field:1
    The output should equal "claude"
    The error should equal ""
    The status should be success
  End

  It '_mux_tx_pick_float returns non-zero promptly and leaks nothing when the popup fails'
    export STUB_MODE=fail
    Data
      #|claude  Claude Code
    End
    When call run_and_report 8 _mux_tx_pick_float 70% 60% Pick --output field:1
    The output should equal ""
    The error should equal ""
    The status should equal 1
  End

  It '_mux_tx_float returns the answer and leaves no temp files (happy path)'
    export STUB_ANSWER=yes
    When call run_and_report 8 _mux_tx_float --type confirm --title Quit -- "Really?"
    The output should equal "yes"
    The error should equal ""
    The status should be success
  End

  # Regression (Mode B 2026-08-15): --borderless true was silently discarded
  # on tmux, stacking the themed popup border AROUND the widget's own box —
  # a double border on every floated dialog. It must translate to -B (the
  # widget's box is then the single frame, zellij parity).
  It '_mux_tx_float honors --borderless true as display-popup -B'
    borderless_argv() {
      export STUB_ARGV_LOG="$TEST_TMP/argv.log"
      run_and_report 8 _mux_tx_float --type confirm --borderless true \
        --title Quit -- "Really?" >/dev/null || return 1
      grep -c -- '^-B$' "$STUB_ARGV_LOG"
    }
    When call borderless_argv
    The output should equal "1"
  End

  It '_mux_tx_float returns non-zero promptly and leaks nothing when the popup fails'
    export STUB_MODE=fail
    When call run_and_report 8 _mux_tx_float --type confirm --title Quit -- "Really?"
    The output should equal ""
    The error should equal ""
    The status should equal 1
  End

  # Regression (live-session, surfaced under the Ctrl+C cancel-confirm popup):
  # the +2 border-compensation padding applied UNCONDITIONALLY, even under
  # --borderless true where -B means display-popup draws no frame at all —
  # handing the widget's own self-drawn box (e.g. troupe jobs' ▓▓▓ frame) a
  # pty 2 rows/cols larger than its content, a visible empty gap band. A
  # borderless popup's geometry must be the measured height EXACTLY.
  It '_mux_tx_float pins borderless geometry to the measured height exactly (no +2)'
    borderless_height_argv() {
      export STUB_ARGV_LOG="$TEST_TMP/argv.log"
      run_and_report 8 _mux_tx_float --type confirm --borderless true \
        --pane-height 15 --title Quit -- "Really?" >/dev/null || return 1
      grep -c -- '^-h$' "$STUB_ARGV_LOG"
    }
    When call borderless_height_argv
    The output should equal "1"
  End

  It '_mux_tx_float borderless -h argument is the measured height, not measured+2'
    borderless_height_value() {
      export STUB_ARGV_LOG="$TEST_TMP/argv.log"
      run_and_report 8 _mux_tx_float --type confirm --borderless true \
        --pane-height 15 --title Quit -- "Really?" >/dev/null || return 1
      awk '/^-h$/{getline; print; exit}' "$STUB_ARGV_LOG"
    }
    When call borderless_height_value
    The output should equal "15"
  End
End

Describe 'mux/tmux.zsh — floating pane (job-runner design §6 rev 4)'
  Include home/dot_local/lib/mux.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    export TMUX=/tmp/sock,1,0
    stub="$TEST_TMP/tmux"
    ARGVLOG="$TEST_TMP/argv.log"
    export ARGVLOG
    {
      echo '#!/usr/bin/env zsh'
      echo 'printf "%s\n" "$@" >> "$ARGVLOG"'
      echo 'case "$1" in'
      echo '  list-commands)'
      echo '    [[ "${STUB_HAS_NEWPANE:-1}" == 1 ]] && print -r -- "new-pane (newp) [flags]"'
      echo '    print -r -- "split-window (splitw) [flags]"'
      echo '    exit 0 ;;'
      echo '  display)'
      echo '    [[ "$*" == *client_width* ]] && print -r -- "${STUB_CLIENT_WIDTH:-200}"'
      echo '    [[ "$*" == *client_height* ]] && print -r -- "${STUB_CLIENT_HEIGHT:-50}"'
      echo '    exit 0 ;;'
      echo '  new-pane)'
      echo '    if [[ "${STUB_NEWPANE_RC:-0}" != 0 ]]; then exit "${STUB_NEWPANE_RC}"; fi'
      echo '    print -r -- "${STUB_PANE_ID:-%3}"'
      echo '    exit 0 ;;'
      echo 'esac'
      echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
    export MUX_TMUX_BIN="$stub"
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset MUX_TMUX_BIN STUB_HAS_NEWPANE STUB_CLIENT_WIDTH STUB_CLIENT_HEIGHT STUB_NEWPANE_RC STUB_PANE_ID ARGVLOG
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It '_mux_tx_has_float_pane is true when list-commands carries new-pane'
    When call _mux_tx_has_float_pane
    The status should be success
  End

  It '_mux_tx_has_float_pane is false on an older tmux without new-pane'
    export STUB_HAS_NEWPANE=0
    When call _mux_tx_has_float_pane
    The status should be failure
  End

  It '_mux_tx_float_pane prints the new pane id from -P -F'
    export STUB_PANE_ID='%7'
    When call _mux_tx_float_pane 57 15 -- sh -c 'sleep 1'
    The output should equal '%7'
    The status should be success
  End

  It '_mux_tx_float_pane propagates a failed launch'
    export STUB_NEWPANE_RC=1
    When call _mux_tx_float_pane 57 15 -- sh -c 'sleep 1'
    The output should equal ''
    The status should equal 1
  End

  It '_mux_tx_float_pane centers the pane (-X = (client_width-width)/2, -Y = (client_height-height)/2) and never focuses -d/-k'
    export STUB_CLIENT_WIDTH=200 STUB_CLIENT_HEIGHT=50
    geom() {
      _mux_tx_float_pane 57 15 -- sh -c 'sleep 1' >/dev/null || return 1
      local xv yv
      xv=$(awk '/^-X$/{getline; print; exit}' "$ARGVLOG")
      yv=$(awk '/^-Y$/{getline; print; exit}' "$ARGVLOG")
      local no_d="yes" no_k="yes"
      grep -qx -- '-d' "$ARGVLOG" && no_d="no"
      grep -qx -- '-k' "$ARGVLOG" && no_k="no"
      printf 'X=%s|Y=%s|no_d=%s|no_k=%s' "$xv" "$yv" "$no_d" "$no_k"
    }
    When call geom
    # (200-57)/2 = 71 (71.5 truncated), (50-15)/2 = 17 (17.5 truncated) —
    # matches the live scratch-socket verification in mux/tmux.zsh's header.
    The output should equal 'X=71|Y=17|no_d=yes|no_k=yes'
  End

  It '_mux_tx_float_pane floors X/Y at 0 when the pane is larger than the client viewport'
    export STUB_CLIENT_WIDTH=40 STUB_CLIENT_HEIGHT=10
    geom() {
      _mux_tx_float_pane 57 15 -- sh -c 'sleep 1' >/dev/null || return 1
      local xv yv
      xv=$(awk '/^-X$/{getline; print; exit}' "$ARGVLOG")
      yv=$(awk '/^-Y$/{getline; print; exit}' "$ARGVLOG")
      printf 'X=%s|Y=%s' "$xv" "$yv"
    }
    When call geom
    The output should equal 'X=0|Y=0'
  End

  It '_mux_tx_float_pane sizes -x/-y from the caller and joins the trailing command into one string'
    cmdline() {
      _mux_tx_float_pane 57 15 -- sh -c 'echo hi' >/dev/null || return 1
      local xv yv
      xv=$(awk '/^-x$/{getline; print; exit}' "$ARGVLOG")
      yv=$(awk '/^-y$/{getline; print; exit}' "$ARGVLOG")
      printf 'x=%s|y=%s' "$xv" "$yv"
    }
    When call cmdline
    The output should equal 'x=57|y=15'
  End
End

# The Rex twins. A Rex float is a floating LAYER (session.new_layer) whose
# command is rex-modal; the answer comes back through the same capture FIFO.
# Two failure shapes are Rex's own: the layer cannot be created, and — a layer
# being a real pane — it is closed by hand before the modal ever answers. In
# both the float must return promptly and leave nothing behind.
Describe 'mux/rex.zsh — float launch guard'
  Include home/dot_local/lib/mux.zsh

  # The fake rex takes everything that varies from the environment (STUB_*),
  # so it is written ONCE per file and run once here, and the virtual clock is
  # made once too (tests/exec_warm_helper.sh): an example only gets a new
  # directory and starts the clock again. The fake runs under `zsh -f`: it
  # needs nothing of the user's ~/.zshenv, and must not depend on it.
  build_stub() {
    stub="$SHELLSPEC_TMPBASE/float-rex"
    # The layer lives for a COUNT of `block inspect` polls, not for a time
    # ($STUB_LIFE: a number, or `open` until it is closed), and what happens
    # to it mid-wait happens during an exact poll (at_poll). STUB_MODE:
    #   ok      the modal answers $STUB_ANSWER on the capture FIFO before the
    #           call returns (the open blocks until the float's reader is
    #           there: a rendezvous), and its layer goes with it, as a real
    #           one does when its command exits;
    #   inflight  the modal has written half of $STUB_ANSWER and still holds
    #           the FIFO open when its layer goes (during the first poll); it
    #           writes the rest only after that;
    #   fail    the layer cannot be created;
    #   closed  nobody answers, and the layer is closed by hand: it is alive
    #           for ${STUB_LAYER_LIFE:-2} polls and gone at the next;
    #   slow    alive and silent, until an at_poll snippet says otherwise.
    # The float holds a write end of the capture FIFO itself until its layer
    # is gone, so its reader sees end of file exactly then: after an answer
    # (complete, however late its last byte), or with none.
    cat >"$stub" <<'STUB'
#!/usr/bin/env -S zsh -f
print -r -- "$*" >> "$STUB_ARGV_LOG"
case " $* " in
  *" session.new_layer "*)
    req=$(cat); print -r -- "$req" > "$STUB_REQ"
    [[ "${STUB_MODE:-ok}" == fail ]] && exit 1
    fifo=$(print -r -- "$req" | jq -r '.layout.block.options.command as $c | $c[($c | index("--capture")) + 1]')
    print -r -- "$fifo" > "$STUB_EV/fifo"
    case "${STUB_MODE:-ok}" in
      closed) print -r -- "${STUB_LAYER_LIFE:-2}" > "$STUB_LIFE" ;;
      slow) print open > "$STUB_LIFE" ;;
      inflight)
        print open > "$STUB_LIFE"; mkfifo "$STUB_EV/go"
        a="${STUB_ANSWER-picked}"; h=$(( ${#a} / 2 ))
        { exec 3>"$fifo"; printf "%s" "${a[1,h]}" >&3; read -r _ < "$STUB_EV/go"
          printf "%s" "${a[h+1,-1]}" >&3; exec 3>&-; } >/dev/null 2>&1 </dev/null &! ;;
      *)
        { exec 3>"$fifo"; printf "%s" "${STUB_ANSWER-picked}" >&3; exec 3>&-; }
        print 0 > "$STUB_LIFE" ;;
    esac
    print -r -- '{"block_ids":["block:layer"]}'
    exit 0 ;;
  *" block close "*) print 0 > "$STUB_LIFE"; exit 0 ;;
  *" block inspect "*)
    n=$(( $(cat "$STUB_EV/polls" 2>/dev/null) + 1 )); print $n > "$STUB_EV/polls"
    [[ -f "$STUB_EV/at-poll-$n" ]] && source "$STUB_EV/at-poll-$n"
    [[ -n "${STUB_INSPECT_RC:-}" ]] && exit "$STUB_INSPECT_RC"
    life=$(cat "$STUB_LIFE" 2>/dev/null)
    case "${life:-0}" in
      0) exit 3 ;;
      open) exit 0 ;;
      *) print $(( life - 1 )) > "$STUB_LIFE"; exit 0 ;;
    esac ;;
esac
exit 1
STUB
    chmod +x "$stub"
    STUB_ARGV_LOG=/dev/null STUB_LIFE=/dev/null "$stub" block close
    spec_clock_set && spec_clock_warm
  }
  Include tests/exec_warm_helper.sh
  BeforeAll 'build_stub'

  setup() {
    # :a squeezes the `//` of the tmpbase path, so the names the floats
    # derive from $TMPDIR read as they would under mktemp.
    spec_sandbox float; TEST_TMP=${SANDBOX:a}
    export TMPDIR="$TEST_TMP"
    unset TMUX MUX_BACKEND
    export REX_SESSION=session:s1 REX_BLOCK=block:origin
    mkdir -p "$TEST_TMP/ev"
    export MUX_REX_BIN="$stub" STUB_ARGV_LOG="$TEST_TMP/argv.log" STUB_REQ="$TEST_TMP/req.json" \
      STUB_LIFE="$TEST_TMP/layer.life" STUB_EV="$TEST_TMP/ev" STUB_MODE=ok STUB_ANSWER=picked
    # The floats nap between polls (`sleep 0.2`), and nowhere else: on the
    # virtual clock, which says afterwards how long they believe they waited.
    : >"$SPEC_CLOCK_FILE"
    spec_clock_set 1000
  }
  cleanup() {
    unset MUX_REX_BIN STUB_ARGV_LOG STUB_REQ STUB_LIFE STUB_EV STUB_MODE STUB_ANSWER STUB_LAYER_LIFE TMPDIR REX_SESSION REX_BLOCK STUB_INSPECT_RC _MUX_RX_AWAIT_MISSES
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  layer_cmd() { jq -r '.layout.block.options.command | join(" ")' "$STUB_REQ"; }
  # at_poll <n> <zsh snippet> — what happens during the float's nth poll of
  # its layer. The stub runs it, so it lands at that exact point of the wait.
  at_poll() { print -r -- "$2" > "$STUB_EV/at-poll-$1"; }
  # waited — how the float waited: polls made, time it believes went by.
  waited() { print -r -- "polls=$(cat "$STUB_EV/polls" 2>/dev/null || print 0) slept=$(( $(spec_clock_now ms) - 1000000 ))ms"; }
  # A float running beside the example writes its pid here first, and the
  # stub signals it during the first poll: while the float waits on its
  # layer, which is where a Ctrl+C finds it. (Signalled from outside it would
  # be caught anywhere, and on the virtual clock mostly inside a nap.)
  own_pid() { sh -c 'echo $PPID' > "$STUB_EV/pid"; }
  term_at_first_poll() { at_poll 1 'kill -TERM "$(cat "$STUB_EV/pid")"'; }

  It '_mux_rx_pick_float returns the selection and leaves no temp files (happy path)'
    export STUB_ANSWER=claude
    Data
      #|claude  Claude Code
    End
    When call run_and_report 8 _mux_rx_pick_float 70% 60% Pick --output field:1
    The output should equal "claude"
    The error should equal ""
    The status should be success
  End

  It '_mux_rx_pick_float runs pick-list under rex-modal, capturing, over our block'
    shape() {
      print -r -- 'a  A' | _mux_rx_pick_float 70% 60% Pick --output field:1 >/dev/null
      layer_cmd | grep -c -E 'rex-modal --origin block:origin --title Pick --no-chrome --capture [^ ]+ -- [^ ]*/pick-list --output field:1 .*-- [^ ]*rxpick\.'
      jq -c '.bounds | map(. * 100 | round)' "$STUB_REQ"
      grep -c -v -- '--autostart=false' "$STUB_ARGV_LOG" || true
    }
    When call shape
    The line 1 of output should equal "1"
    The line 2 of output should equal "[15,20,70,60]"
    The line 3 of output should equal "0"
  End

  It '_mux_rx_pick_float picks inline, leaking nothing, when the layer cannot be created'
    export STUB_MODE=fail
    pick::start() { print -r -- "inline[$*][$(cat)]"; }
    Data
      #|claude  Claude Code
    End
    When call run_and_report 8 _mux_rx_pick_float 70% 60% Pick --output field:1
    The output should equal "inline[--output field:1][claude  Claude Code]"
    The error should equal ""
    The status should be success
  End

  It '_mux_rx_pick_float passes the inline picker'"'"'s own status on'
    export STUB_MODE=fail
    pick::start() { cat >/dev/null; return 130; }
    Data
      #|claude  Claude Code
    End
    When call run_and_report 8 _mux_rx_pick_float 70% 60% Pick --output field:1
    The output should equal ""
    The status should equal 130
  End

  It 'opens the float in the caller'"'"'s directory'
    where() {
      cd "$TEST_TMP" || return 1
      print -r -- 'a  A' | _mux_rx_pick_float 70% 60% Pick --output field:1 >/dev/null
      [[ "$(jq -r '.layout.block.options.cwd' "$STUB_REQ")" == "$PWD" ]] && print same
    }
    When call where
    The output should equal "same"
  End

  It 'closes its float when the caller is interrupted'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    export STUB_MODE=slow
    interrupted() {
      term_at_first_poll
      ( own_pid; print -r -- 'a  A' | _mux_rx_pick_float 70% 60% Pick --output field:1 ) &
      wait $! 2>/dev/null
      print -r -- "rc=$?"
      grep -c 'block close .*block:layer' "$STUB_ARGV_LOG"
      ls "$TEST_TMP" | grep -c -E 'rxpick|rxinput' || true
    }
    When call run_and_report 12 interrupted
    The line 1 of output should equal "rc=130"
    The line 2 of output should equal "1"
    The line 3 of output should equal "0"
  End

  It '_mux_rx_pick_float reports a cancel as 130'
    export STUB_ANSWER=""
    Data
      #|claude  Claude Code
    End
    When call run_and_report 8 _mux_rx_pick_float 70% 60% Pick --output field:1
    The output should equal ""
    The error should equal ""
    The status should equal 130
  End

  It '_mux_rx_pick_float returns 130 and leaks nothing when the layer is closed by hand'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    export STUB_MODE=closed
    Data
      #|claude  Claude Code
    End
    When call run_and_report 8 _mux_rx_pick_float 70% 60% Pick --output field:1
    The output should equal ""
    The error should equal ""
    The status should equal 130
  End

  It '_mux_rx_float returns the answer and leaves no temp files (happy path)'
    export STUB_ANSWER=yes
    When call run_and_report 8 _mux_rx_float --type confirm --title Quit -- "Really?"
    The output should equal "yes"
    The error should equal ""
    The status should be success
  End

  # The input widgets draw their own box and title. A tmux popup is exactly as
  # tall as the widget, so a header painted by the modal scrolls away; a Rex
  # layer is sized as a fraction of the window and is rarely that exact, and
  # the header stayed on screen above the widget's own (seen live with
  # mux::choose). So the modal never paints one here.
  It '_mux_rx_float runs input-widget under rex-modal, which draws no header of its own'
    shape() {
      _mux_rx_float --type choose --title Quit -- --title Quit "Really?" a b >/dev/null
      layer_cmd | grep -c -E 'rex-modal --origin block:origin --no-chrome --capture [^ ]+ -- [^ ]*/input-widget --type choose -- --title Quit Really\? a b$'
      jq -r '.layout.block.label' "$STUB_REQ"
    }
    When call shape
    The output should equal "1
Quit"
  End

  It '_mux_rx_float asks inline, leaking nothing, when the layer cannot be created'
    export STUB_MODE=fail
    input::confirm() { print -rn -- "inline[$*]"; }
    When call run_and_report 8 _mux_rx_float --type confirm --title Quit -- --title Quit "Really?"
    The output should equal "inline[--title Quit Really?]"
    The error should equal ""
    The status should be success
  End

  # The reader must be born with the FIFO open. When it opened the FIFO by
  # name, a capture that ended at once (no layer) could release the caller's
  # end before the reader had got to its open: the reader then waited for a
  # writer for ever, and the caller for the reader. Seen as a hung suite run.
  It 'starts its reader on an open descriptor, never on the FIFO by name'
    export STUB_MODE=fail
    input::confirm() { print -rn -- "inline"; }
    cat_args() {
      mkdir -p "$TEST_TMP/catbin"
      printf '%s\n' '#!/bin/sh' 'echo "cat args=[$*]" >>"$CAT_LOG"' 'exec /bin/cat "$@"' >"$TEST_TMP/catbin/cat"
      command chmod +x "$TEST_TMP/catbin/cat"
      export CAT_LOG="$TEST_TMP/cat.log"
      PATH="$TEST_TMP/catbin:$PATH" _mux_rx_float --type confirm --title Quit -- "Really?"
      print
      grep -c 'fifo' "$CAT_LOG" || true
      head -1 "$CAT_LOG"
    }
    When call cat_args
    The line 1 of output should equal "inline"
    The line 2 of output should equal "0"
    The line 3 of output should equal "cat args=[]"
  End

  It '_mux_rx_float closes its float when the caller is interrupted'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    export STUB_MODE=slow
    interrupted() {
      term_at_first_poll
      ( own_pid; _mux_rx_float --type confirm --title Quit -- "Really?" ) &
      wait $! 2>/dev/null
      print -r -- "rc=$?"
      grep -c 'block close .*block:layer' "$STUB_ARGV_LOG"
    }
    When call run_and_report 12 interrupted
    The line 1 of output should equal "rc=130"
    The line 2 of output should equal "1"
  End

  # The pane that asked for the float is closed: its shell gets a hangup. The
  # float must not outlive it (nor its temp files), and the caller must still
  # die of the hangup, as it would have without a float: nothing after the
  # float runs in a shell whose terminal is gone. (rc=1 is how zsh ends on a
  # hangup with no trap at all: it exits by itself instead of being killed.
  # "survived" is what would show a caller that carried on.)
  hup_at_first_poll() { at_poll 1 'kill -HUP "$(cat "$STUB_EV/pid")"'; }

  It '_mux_rx_float closes its float and still dies when the caller is hung up'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    export STUB_MODE=slow
    hung_up() {
      hup_at_first_poll
      ( own_pid; _mux_rx_float --type confirm --title Quit -- "Really?"; print survived ) &
      wait $! 2>/dev/null
      print -r -- "rc=$?"
      grep -c 'block close .*block:layer' "$STUB_ARGV_LOG"
    }
    When call run_and_report 12 hung_up
    The line 1 of output should equal "rc=1"
    The line 2 of output should equal "1"
    The lines of output should equal 2
    The error should equal ""
  End

  It '_mux_rx_pick_float closes its float and still dies when the caller is hung up'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    export STUB_MODE=slow
    hung_up() {
      hup_at_first_poll
      ( own_pid; print -r -- 'a  A' | _mux_rx_pick_float 70% 60% Pick --output field:1; print survived ) &
      wait $! 2>/dev/null
      print -r -- "rc=$?"
      grep -c 'block close .*block:layer' "$STUB_ARGV_LOG"
    }
    When call run_and_report 12 hung_up
    The line 1 of output should equal "rc=1"
    The line 2 of output should equal "1"
    The lines of output should equal 2
    The error should equal ""
  End

  It '_mux_rx_float promises the widget its measured rows, a percent picker none'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    rows() {
      _mux_rx_float --type confirm --title Quit --pane-height 11 -- "Really?" >/dev/null
      layer_cmd | grep -c 'MUX_REX_MODAL_ROWS=[0-9][0-9]* [^ ]*rex-modal'
      print -r -- 'a  A' | _mux_rx_pick_float 70% 60% Pick --output field:1 >/dev/null
      layer_cmd | grep -c 'MUX_REX_MODAL_ROWS' || true
    }
    When call rows
    The output should equal "1
0"
  End

  It '_mux_rx_float returns 130 when the layer is closed by hand'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    export STUB_MODE=closed
    When call run_and_report 8 _mux_rx_float --type confirm --title Quit -- "Really?"
    The output should equal ""
    The error should equal ""
    The status should equal 130
  End

  # The wait must be bounded whatever the server says. Only "block not found"
  # (3) PROVES the layer is gone, but a server that has stopped (4), or one
  # that keeps failing for any other reason, will never say it — and nobody
  # will ever write the answer either.
  # Both on a layer that never goes away by itself and never answers, so only
  # the bound under test can end the wait. `slept` is the naps between polls
  # (0.2 s each) and nothing more: once the layer counts as gone the reader
  # is given its end of file, not a grace period.
  It 'returns 130 at once when the server is gone mid-wait'
    export STUB_MODE=slow STUB_INSPECT_RC=4
    gone() { run_and_report 4 _mux_rx_float --type confirm --title Quit -- "Really?"; print -r -- "rc=$? $(waited)"; }
    When call gone
    The output should equal "rc=130 polls=1 slept=0ms"
    The error should equal ""
  End

  It 'gives up after a run of failed checks instead of waiting forever'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    export STUB_MODE=slow STUB_INSPECT_RC=1 _MUX_RX_AWAIT_MISSES=3
    failing() { run_and_report 6 _mux_rx_float --type confirm --title Quit -- "Really?"; print -r -- "rc=$? $(waited)"; }
    When call failing
    The output should equal "rc=130 polls=3 slept=400ms"
    The error should equal ""
  End

  It 'does not give up on a float that is simply taking its time'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    slow() {
      # The layer stays alive (inspect exits 0) and answers during the 7th
      # poll, many more than the miss limit: successful checks must not count
      # as misses. A float that gave up at the limit never gets to that poll.
      export _MUX_RX_AWAIT_MISSES=2 STUB_MODE=slow
      at_poll 7 'print -rn -- late > "$(cat "$STUB_EV/fifo")"; print 0 > "$STUB_LIFE"'
      _mux_rx_float --type confirm --title Quit -- "Really?"
    }
    When call run_and_report 8 slow
    The output should equal "late"
    The status should be success
  End

  # A modal writes its answer as it exits, and its layer can be seen gone
  # while the last bytes are still on their way. The float used to allow such
  # a reader 0.3 s and then kill it, answer and all.
  It 'delivers an answer still being written when its layer goes'
    export STUB_MODE=inflight STUB_ANSWER=wezterm
    inflight() {
      # During the first poll: the layer is gone, and only then is the modal
      # told to write the second half.
      at_poll 1 'print 0 > "$STUB_LIFE"; print go > "$STUB_EV/go"'
      _mux_rx_float --type line --title Term -- "Which?"
      print -r -- " rc=$? $(waited) left=$(ls "$TEST_TMP" | grep -c "^rxinput-")"
    }
    When call inflight
    The output should equal "wezterm rc=0 polls=1 slept=0ms left=0"
    The error should equal ""
  End

  It 'never kills its reader: a layer closed by hand ends it with an end of file'
    Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
    export STUB_MODE=closed STUB_LAYER_LIFE=0
    closed() {
      _mux_rx_float --type confirm --title Quit -- "Really?"
      print -r -- "rc=$? $(waited) left=$(ls "$TEST_TMP" | grep -c "^rxinput-") readers=$(pgrep -f "cat $TEST_TMP/rxinput-fifo" | wc -l | tr -d " ")"
    }
    When call closed
    The output should equal "rc=130 polls=1 slept=0ms left=0 readers=0"
    The error should equal ""
  End

  Describe 'dispatch'
    It 'floats widgets in a Rex pane without the consumer knob'
      When call _mux::widgets_float
      The status should be success
    End

    It 'routes mux::confirm through the Rex float'
      export STUB_ANSWER=yes
      When call run_and_report 8 mux::confirm --title Quit "Really?"
      The output should equal "yes"
      The status should be success
    End

    It 'fails mux::confirm closed when the layer is closed by hand'
      Skip if 'complete-only: a float that polls its layer through the zsh fake rex and the fake clock, poll after poll (100-200 ms)' spec_complete_only
      export STUB_MODE=closed
      When call run_and_report 8 mux::confirm --title Quit "Really?"
      The output should equal "no"
      The status should equal 130
    End

    It 'routes mux::pick through the Rex float'
      export STUB_ANSWER=claude
      Data
        #|claude  Claude Code
      End
      When call run_and_report 8 mux::pick --output field:1
      The output should equal "claude"
      The status should be success
    End
  End
End
