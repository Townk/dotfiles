# Tests for mux-modal's Rex arm: the backend-neutral modal entry point opens a
# floating layer running rex-modal and, like tmux's `display-popup -E`, does
# not return until that layer is gone. Hermetic: `rex` is a stub.
Describe 'mux-modal on Rex'
  MODAL="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-modal"
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  # No example waits. The fake's layer lives for a number of polls
  # ($STUB_LAYER_LIFE: none by default, `open` until closed), and the poll
  # loop's `sleep 0.2` goes to the virtual clock, which says afterwards how
  # long the script believes it waited.
  # The clock (three stubs) is made once for the file, and run once, with a
  # warm slot for the fake rex every example writes (tests/exec_warm_helper.sh);
  # an example only starts the clock again from an empty journal.
  Include tests/exec_warm_helper.sh
  clock_once() { spec_clock_set && spec_clock_warm && spec_exec_pool_warm 2; }
  BeforeAll 'clock_once'
  setup() {
    spec_sandbox; MM_TMP=$SANDBOX
    spec_fake_rex "$MM_TMP"
    : >"$SPEC_CLOCK_FILE"
    spec_clock_set 1000
  }
  BeforeEach 'setup'
  polls() { spec_stub_calls "$MM_TMP" rex | grep -c ' block inspect ' || true; }
  waited() { print -r -- "polls=$(polls) slept=$(( $(spec_clock_now ms) - 1000000 ))ms"; }

  # A HOME that does not exist, and NOT under /home: that is an automount
  # point on macOS, where every lookup of a dotfile below it (jq's ~/.jq,
  # zsh's ~/.zshenv) waits ~100 ms for autofs to say no.
  modal() {
    env -u TMUX HOME=/nohome/u REX_SESSION=session:s REX_BLOCK=block:origin \
      MUX_REX_BIN="$MM_TMP/rex" MUX_LIB="$LIB" MUX_MODAL_REX_MISSES="${MISSES:-25}" zsh -f "$MODAL" "$@" 2>"$MM_TMP/err"
  }
  cmdline() { jq -r '.layout.block.options.command | join(" ")' "$MM_TMP/req.json"; }

  It 'opens a layer running rex-modal over the calling block, in its directory'
    run() {
      cd "$MM_TMP" || return 1
      modal --borderless --no-chrome --no-discover --width 50% --height 40% --title Jobs --capture /tmp/f -- troupe jobs --width 57
      print -r -- "rc=$?"; cmdline; jq -c '.bounds | map(. * 100 | round)' "$MM_TMP/req.json"
      [[ "$(jq -r '.layout.block.options.cwd' "$MM_TMP/req.json")" == "$PWD" ]] && print cwd-ok
      jq -r '.layout.block.label' "$MM_TMP/req.json"
    }
    When call run
    The output should equal "rc=0
/nohome/u/.config/mux/scripts/rex-modal --origin block:origin --no-chrome --title Jobs --capture /tmp/f -- troupe jobs --width 57
[25,30,50,40]
cwd-ok
Jobs"
  End

  It 'tells rex-modal the exact row count of a height given in cells'
    run() { modal --width 57 --height 15 -- true; cmdline | cut -d' ' -f1-3; }
    When call run
    The output should equal "env MUX_REX_MODAL_ROWS=15 /nohome/u/.config/mux/scripts/rex-modal"
  End

  It 'does not return while the layer is open'
    Skip if 'complete-only: four polls of the layer, each a fake rex and a fake sleep (~120 ms)' spec_complete_only
    # Alive for three polls: it must come back on the fourth, not before.
    export STUB_LAYER_LIFE=3
    run() { modal -- true; waited; }
    When call run
    The output should equal "polls=4 slept=600ms"
  End

  It 'fails when no layer can be opened'
    export STUB_LAYER=fail
    run() { modal -- true; print -r -- "rc=$?"; cat "$MM_TMP/err"; }
    When call run
    The output should equal "rc=1
mux-modal: could not open a floating layer"
  End

  It 'returns at once when the server is gone'
    export STUB_LAYER_LIFE=open STUB_INSPECT_RC=4
    run() { modal -- true; waited; }
    When call run
    The output should equal "polls=1 slept=0ms"
  End

  It 'gives up after a run of failed checks instead of waiting forever'
    Skip if 'complete-only: a run of failed checks, each a fake rex and a fake sleep (~90 ms)' spec_complete_only
    export STUB_LAYER_LIFE=open STUB_INSPECT_RC=1
    MISSES=3
    run() { modal -- true; waited; }
    When call run
    The output should equal "polls=3 slept=400ms"
  End

  It 'releases a caller still reading the capture FIFO when the layer closes unanswered'
    run() {
      mkfifo "$MM_TMP/fifo"
      cat "$MM_TMP/fifo" >"$MM_TMP/out" &
      local reader=$!
      modal --capture "$MM_TMP/fifo" -- true
      # The reader is our own child: join it. It ends when the script lets
      # go of the FIFO; a script that leaves it blocked hangs the example here.
      wait $reader && print "reader released"
      print -r -- "size=$(wc -c <"$MM_TMP/out" | tr -d ' ')"
    }
    When call run
    The output should equal "reader released
size=0"
  End

  It 'does not hang when the answer was already read'
    run() {
      mkfifo "$MM_TMP/fifo"   # nobody is reading any more
      modal --capture "$MM_TMP/fifo" -- true
      print "no hang"
    }
    When call run
    The output should equal "no hang"
  End

  It 'closes its layer when interrupted'
    Skip if 'complete-only: the modal interrupted and joined while its layer is open (~100 ms)' spec_complete_only
    # A layer that would outlive five polls; the first nap between polls
    # delivers the signal, so it lands while the script waits on its layer.
    # Nothing runs in the background and nothing is timed: a script that does
    # not close its layer dies of the signal, or polls on and closes nothing.
    export STUB_LAYER_LIFE=5
    run() {
      spec_stub "$MM_TMP/term" sleep '[ -e "$STUB_DIR/sent" ] || { : >"$STUB_DIR/sent"; kill -TERM "$(cat "$STUB_DIR/pid")"; }'
      # exec: the signal must reach the script itself, not a wrapper shell.
      sh -c 'echo $$ >"$1/pid"; shift; exec "$@"' sh "$MM_TMP/term" \
        env -u TMUX HOME=/nohome/u REX_SESSION=session:s REX_BLOCK=block:origin PATH="$MM_TMP/term:$PATH" \
          MUX_REX_BIN="$MM_TMP/rex" MUX_LIB="$LIB" zsh -f "$MODAL" -- true 2>/dev/null
      grep -c 'block close .*block:layer' "$MM_TMP/rex.log"
      print -r -- "polls=$(polls)"
    }
    When call run
    The output should equal "1
polls=2"
  End

  It 'still prefers tmux when both are present'
    run() {
      printf '%s\n' '#!/bin/sh' "echo \"tmux \$1\" >\"$MM_TMP/tmux.log\"" >"$MM_TMP/tmux"; chmod +x "$MM_TMP/tmux"
      env TMUX=/tmp/s,1,0 TMUX_PANE=%1 REX_BLOCK=block:origin MUX_TMUX_BIN="$MM_TMP/tmux" MUX_REX_BIN="$MM_TMP/rex" MUX_LIB="$LIB" zsh -f "$MODAL" -- true
      cat "$MM_TMP/tmux.log"; [[ -e "$MM_TMP/req.json" ]] && print "rex layer" || print "no rex layer"
    }
    When call run
    The output should equal "tmux display-popup
no rex layer"
  End
End
