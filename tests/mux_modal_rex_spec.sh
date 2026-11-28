# Tests for mux-modal's Rex arm: the backend-neutral modal entry point opens a
# floating layer running rex-modal and, like tmux's `display-popup -E`, does
# not return until that layer is gone. Hermetic: `rex` is a stub.
Describe 'mux-modal on Rex'
  MODAL="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-modal"
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    zmodload zsh/datetime
    MM_TMP=$(mktemp -d)
    cat >"$MM_TMP/rex" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$MM_TMP/rex.log"
case " \$* " in
  *" session.new_layer "*)
    cat >"$MM_TMP/req.json"
    [ "\${STUB_LAYER:-ok}" = ok ] || exit 1
    : >"$MM_TMP/alive"
    # The layer lives for a moment, then closes.
    ( sleep "\${STUB_LIFE:-0.6}"; rm -f "$MM_TMP/alive" ) >/dev/null 2>&1 &
    echo '{"block_ids":["block:layer"]}' ;;
  *" block close "*) rm -f "$MM_TMP/alive" ;;
  *" block inspect "*) [ -n "\${STUB_INSPECT_RC:-}" ] && exit "\$STUB_INSPECT_RC"; [ -e "$MM_TMP/alive" ] && exit 0; exit 3 ;;
esac
exit 0
EOS
    chmod +x "$MM_TMP/rex"
  }
  cleanup() { rm -rf "$MM_TMP"; unset STUB_LAYER STUB_LIFE STUB_INSPECT_RC; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  modal() {
    env -u TMUX HOME=/home/u REX_SESSION=session:s REX_BLOCK=block:origin \
      MUX_REX_BIN="$MM_TMP/rex" MUX_LIB="$LIB" MUX_MODAL_REX_MISSES="${MISSES:-25}" zsh "$MODAL" "$@" 2>"$MM_TMP/err"
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
/home/u/.config/mux/scripts/rex-modal --origin block:origin --no-chrome --title Jobs --capture /tmp/f -- troupe jobs --width 57
[25,30,50,40]
cwd-ok
Jobs"
  End

  It 'tells rex-modal the exact row count of a height given in cells'
    run() { modal --width 57 --height 15 -- true; cmdline | cut -d' ' -f1-3; }
    When call run
    The output should equal "env MUX_REX_MODAL_ROWS=15 /home/u/.config/mux/scripts/rex-modal"
  End

  It 'does not return while the layer is open'
    export STUB_LIFE=1.2
    run() {
      local t0=$EPOCHREALTIME
      modal -- true
      (( EPOCHREALTIME - t0 >= 1.0 )) && print waited || print "returned early"
    }
    When call run
    The output should equal "waited"
  End

  It 'fails when no layer can be opened'
    export STUB_LAYER=fail
    run() { modal -- true; print -r -- "rc=$?"; cat "$MM_TMP/err"; }
    When call run
    The output should equal "rc=1
mux-modal: could not open a floating layer"
  End

  It 'returns at once when the server is gone'
    export STUB_LIFE=6 STUB_INSPECT_RC=4
    run() { local t0=$EPOCHREALTIME; modal -- true; (( EPOCHREALTIME - t0 < 3 )) && print prompt; }
    When call run
    The output should equal "prompt"
  End

  It 'gives up after a run of failed checks instead of waiting forever'
    export STUB_LIFE=6 STUB_INSPECT_RC=1
    MISSES=3
    run() { local t0=$EPOCHREALTIME; modal -- true; (( EPOCHREALTIME - t0 < 5 )) && print bounded; }
    When call run
    The output should equal "bounded"
  End

  It 'releases a caller still reading the capture FIFO when the layer closes unanswered'
    run() {
      mkfifo "$MM_TMP/fifo"
      cat "$MM_TMP/fifo" >"$MM_TMP/out" &
      local reader=$!
      modal --capture "$MM_TMP/fifo" -- true
      local i; for i in {1..20}; do kill -0 $reader 2>/dev/null || break; sleep 0.1; done
      kill -0 $reader 2>/dev/null && { kill $reader; print "reader stuck"; } || print "reader released"
      print -r -- "size=$(wc -c <"$MM_TMP/out" | tr -d ' ')"
    }
    When call run
    The output should equal "reader released
size=0"
  End

  It 'does not hang when the answer was already read'
    run() {
      mkfifo "$MM_TMP/fifo"   # nobody is reading any more
      local t0=$EPOCHREALTIME
      modal --capture "$MM_TMP/fifo" -- true
      (( EPOCHREALTIME - t0 < 4 )) && print "no hang"
    }
    When call run
    The output should equal "no hang"
  End

  It 'closes its layer when interrupted'
    export STUB_LIFE=6
    run() {
      # exec: the signal must reach the script itself, not a wrapper shell.
      ( exec env -u TMUX HOME=/home/u REX_SESSION=session:s REX_BLOCK=block:origin \
          MUX_REX_BIN="$MM_TMP/rex" MUX_LIB="$LIB" zsh "$MODAL" -- true 2>/dev/null ) &
      local pid=$!
      local i; for i in {1..40}; do [[ -e "$MM_TMP/alive" ]] && break; sleep 0.1; done
      sleep 0.3; kill -TERM $pid; wait $pid 2>/dev/null
      grep -c 'block close .*block:layer' "$MM_TMP/rex.log"
    }
    When call run
    The output should equal "1"
  End

  It 'still prefers tmux when both are present'
    run() {
      printf '%s\n' '#!/bin/sh' "echo \"tmux \$1\" >\"$MM_TMP/tmux.log\"" >"$MM_TMP/tmux"; chmod +x "$MM_TMP/tmux"
      env TMUX=/tmp/s,1,0 TMUX_PANE=%1 REX_BLOCK=block:origin MUX_TMUX_BIN="$MM_TMP/tmux" MUX_REX_BIN="$MM_TMP/rex" MUX_LIB="$LIB" zsh "$MODAL" -- true
      cat "$MM_TMP/tmux.log"; [[ -e "$MM_TMP/req.json" ]] && print "rex layer" || print "no rex layer"
    }
    When call run
    The output should equal "tmux display-popup
no rex layer"
  End
End
