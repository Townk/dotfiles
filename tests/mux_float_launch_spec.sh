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
# Each example runs the float under a watchdog (run_and_report) so a regression
# cannot hang the suite: the float's stdout is relayed on stdout, its exit status
# is preserved, and any leftover float temp file in TMPDIR is reported on stderr
# as "LEAK:<name>". Guarding this way lets one `When call` assert the selection,
# the prompt return, and the absence of leaks together.

# run_and_report <secs> <fn> [args...]   (picker rows, if any, on stdin)
#   Run <fn args> in a subshell with a hard <secs> watchdog. Relay its stdout,
#   preserve its status, and print LEAK:<name> on stderr for every float temp
#   still present in TEST_TMP afterwards.
run_and_report() {
  local secs="$1"; shift
  local tmpin outf
  tmpin=$(mktemp "$TEST_TMP/guardin.XXXXXX")
  # Stage stdin (async jobs default to /dev/null) — but never from a TERMINAL:
  # an example with no piped rows then waited on the tty forever, hanging the
  # whole suite whenever it ran with one attached (e.g. under `script`).
  if [ -t 0 ]; then : >"$tmpin"; else cat >"$tmpin"; fi
  outf=$(mktemp "$TEST_TMP/guardout.XXXXXX")

  # stderr -> /dev/null so that if a regression hangs the float, the reader it
  # orphans cannot hold shellspec's error pipe open and drag the run out.
  ( "$@" <"$tmpin" >"$outf" 2>/dev/null ) &
  local p=$!
  # kill -$p can't reach the float's descendants (monitor/process-groups are
  # unavailable in shellspec's non-interactive context), so after killing the
  # subshell also reap anything still referencing this example's unique sandbox
  # (an orphaned `cat "$fifo"` reader) — otherwise it stalls shellspec forever.
  ( sleep "$secs"; kill -TERM "$p" 2>/dev/null; sleep 0.3
    kill -KILL "$p" 2>/dev/null
    pkill -KILL -f "$TEST_TMP" 2>/dev/null ) &
  local w=$!
  wait "$p"; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null

  cat "$outf"
  rm -f -- "$tmpin" "$outf"

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

  setup() {
    TEST_TMP=$(mktemp -d)
    export TMPDIR="$TEST_TMP"
    unset TMUX MUX_BACKEND
    export REX_SESSION=session:s1 REX_BLOCK=block:origin
    stub="$TEST_TMP/rex"
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "$*" >> "$STUB_ARGV_LOG"'
      echo 'case " $* " in'
      echo '  *" session.new_layer "*)'
      echo '    req=$(cat); print -r -- "$req" > "$STUB_REQ"'
      echo '    [[ "${STUB_MODE:-ok}" == fail ]] && exit 1'
      echo '    : > "$STUB_ALIVE"'
      echo '    fifo=$(print -r -- "$req" | jq -r ".layout.block.options.command as \$c | \$c[(\$c | index(\"--capture\")) + 1]")'
      echo '    if [[ "${STUB_MODE:-ok}" == closed ]]; then'
      echo '      # The layer is closed by hand: it goes away and nobody writes.'
      echo '      { sleep 0.4; rm -f "$STUB_ALIVE" } &!'
      echo '    elif [[ "${STUB_MODE:-ok}" == slow ]]; then'
      echo '      # Alive and silent: the example writes the answer itself, later.'
      echo '      :'
      echo '    else'
      echo '      { exec 3>"$fifo"; printf "%s" "${STUB_ANSWER-picked}" >&3; exec 3>&-; rm -f "$STUB_ALIVE" } &!'
      echo '    fi'
      echo '    print -r -- "{\"block_ids\":[\"block:layer\"]}"'
      echo '    exit 0 ;;'
      echo '  *" block close "*) rm -f "$STUB_ALIVE"; exit 0 ;;'
      echo '  *" block inspect "*) [[ -n "${STUB_INSPECT_RC:-}" ]] && exit "$STUB_INSPECT_RC"; [[ -e "$STUB_ALIVE" ]] && exit 0; exit 3 ;;'
      echo 'esac'
      echo 'exit 1'
    } > "$stub"
    chmod +x "$stub"
    export MUX_REX_BIN="$stub" STUB_ARGV_LOG="$TEST_TMP/argv.log" STUB_REQ="$TEST_TMP/req.json" \
      STUB_ALIVE="$TEST_TMP/alive" STUB_MODE=ok STUB_ANSWER=picked
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset MUX_REX_BIN STUB_ARGV_LOG STUB_REQ STUB_ALIVE STUB_MODE STUB_ANSWER TMPDIR REX_SESSION REX_BLOCK STUB_INSPECT_RC _MUX_RX_AWAIT_MISSES
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  layer_cmd() { jq -r '.layout.block.options.command | join(" ")' "$STUB_REQ"; }

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
    export STUB_MODE=slow
    interrupted() {
      ( print -r -- 'a  A' | _mux_rx_pick_float 70% 60% Pick --output field:1 ) &
      local pid=$!
      local i; for i in {1..40}; do [[ -e "$STUB_ALIVE" ]] && break; sleep 0.1; done
      sleep 0.3
      kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
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

  It '_mux_rx_float closes its float when the caller is interrupted'
    export STUB_MODE=slow
    interrupted() {
      ( _mux_rx_float --type confirm --title Quit -- "Really?" ) &
      local pid=$!
      local i; for i in {1..40}; do [[ -e "$STUB_ALIVE" ]] && break; sleep 0.1; done
      sleep 0.3
      kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      print -r -- "rc=$?"
      grep -c 'block close .*block:layer' "$STUB_ARGV_LOG"
    }
    When call run_and_report 12 interrupted
    The line 1 of output should equal "rc=130"
    The line 2 of output should equal "1"
  End

  It '_mux_rx_float promises the widget its measured rows, a percent picker none'
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
  It 'returns 130 at once when the server is gone mid-wait'
    export STUB_MODE=closed STUB_INSPECT_RC=4
    When call run_and_report 4 _mux_rx_float --type confirm --title Quit -- "Really?"
    The output should equal ""
    The error should equal ""
    The status should equal 130
  End

  It 'gives up after a run of failed checks instead of waiting forever'
    export STUB_MODE=closed STUB_INSPECT_RC=1 _MUX_RX_AWAIT_MISSES=3
    When call run_and_report 6 _mux_rx_float --type confirm --title Quit -- "Really?"
    The output should equal ""
    The error should equal ""
    The status should equal 130
  End

  It 'does not give up on a float that is simply taking its time'
    slow() {
      # The layer stays alive (inspect exits 0) and answers after many more
      # polls than the miss limit: successful checks must not count as misses.
      export _MUX_RX_AWAIT_MISSES=2 STUB_MODE=slow
      ( sleep 1.5
        fifo=$(jq -r '.layout.block.options.command as $c | $c[($c | index("--capture")) + 1]' "$STUB_REQ")
        print -rn -- late >"$fifo" ) &
      _mux_rx_float --type confirm --title Quit -- "Really?"
    }
    When call run_and_report 8 slow
    The output should equal "late"
    The status should be success
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
