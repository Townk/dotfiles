# Tests for rex-modal — the Rex twin of tmux-modal: the script
# that runs INSIDE a Rex floating layer and hands a picker's or a widget's
# result back, either through a capture file or by typing it into the block
# the layer was opened over. Hermetic: `rex` is a stub that logs its argv.
Describe 'rex-modal'
  MODAL="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_rex-modal"
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    RM_TMP=$(mktemp -d)
    cat >"$RM_TMP/rex" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$RM_TMP/rex.log"
exit 0
EOS
    chmod +x "$RM_TMP/rex"
    # A target that reports what the modal exported to it, then prints $1.
    cat >"$RM_TMP/target" <<EOS
#!/bin/sh
{ echo "title=\${MUX_MODAL_TITLE-unset} zj=\${ZJ_MODAL_TITLE-unset}"
  echo "tmux=\${TMUX-unset} zellij=\${ZELLIJ-unset}" >"$RM_TMP/mux.log"
  echo "pane=\${PICK_INJECT_PANE-unset} rex=\${PICK_INJECT_REX-unset} target=\${MUX_MODAL_TARGET_PANE-unset}"; } >"$RM_TMP/env.log"
printf '%s\n' "\$1"
exit "\${2:-0}"
EOS
    chmod +x "$RM_TMP/target"
  }
  cleanup() { rm -rf "$RM_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  raw_modal() {
    env -u REX_SESSION REX_BLOCK=block:layer MUX_REX_BIN="$RM_TMP/rex" MUX_LIB="$LIB" TMPDIR="$RM_TMP" \
      TMUX=/tmp/tmux-sock,1,0 ZELLIJ=0 zsh "$MODAL" "$@" 2>"$RM_TMP/err"
  }
  # The modal answers only into a FIFO, as its callers give it. `--capture
  # FILE` here stands a FIFO in for FILE and drains it into FILE, so the
  # examples can read the answer back as a plain file.
  modal() {
    local -a args=("$@")
    local i=${args[(i)--capture]} rc=0
    if (( i > ${#args} )); then raw_modal "$@"; return; fi
    local file="${args[i+1]}" fifo="$RM_TMP/cap.fifo"
    mkfifo "$fifo"
    cat "$fifo" >"$file" &
    local reader=$!
    args[i+1]="$fifo"
    raw_modal "${args[@]}" || rc=$?
    wait "$reader"
    rm -f "$fifo"
    return $rc
  }
  sent() { cat "$RM_TMP/rex.log" 2>/dev/null || true; }
  seen() { cat "$RM_TMP/env.log"; }

  Describe 'capture mode'
    It 'writes the result to the capture file, without its trailing newline'
      run() { modal --no-chrome --capture "$RM_TMP/out" -- "$RM_TMP/target" "picked value"; print -r -- "rc=$?"; print -r -- "[$(cat "$RM_TMP/out"; print -n x)]"; }
      When call run
      The output should equal "rc=0
[picked valuex]"
    End

    It 'writes an EMPTY capture when the target is cancelled, so the reader unblocks'
      run() { modal --no-chrome --capture "$RM_TMP/out" -- "$RM_TMP/target" "" 130; print -r -- "rc=$? size=$(wc -c <"$RM_TMP/out" | tr -d ' ')"; }
      When call run
      The output should equal "rc=0 size=0"
    End

    It 'never leaves the answer behind as a regular file'
      # The caller gave up and removed its FIFO: nothing is listening.
      run() { raw_modal --no-chrome --capture "$RM_TMP/gone" -- "$RM_TMP/target" x; print -r -- "rc=$?"; [[ -e "$RM_TMP/gone" ]] && print stray || print clean; }
      When call run
      The output should equal "rc=0
clean"
    End

    It 'hides an inherited tmux or zellij from the target'
      run() { modal --no-chrome --capture "$RM_TMP/out" -- "$RM_TMP/target" x; cat "$RM_TMP/mux.log"; }
      When call run
      The output should equal "tmux=unset zellij=unset"
    End

    It 'types nothing into any block'
      run() { modal --no-chrome --origin block:o --capture "$RM_TMP/out" -- "$RM_TMP/target" x >/dev/null; sent; }
      When call run
      The output should equal ""
    End

    It 'leaves no temp file behind'
      run() { modal --no-chrome --capture "$RM_TMP/out" -- "$RM_TMP/target" x; ls "$RM_TMP" | grep -c '^rexmodal\.' || true; }
      When call run
      The output should equal "0"
    End
  End

  Describe 'inject mode'
    It 'types the result into the origin block, never starting a server'
      run() { modal --no-chrome --origin block:o --inject -- "$RM_TMP/target" "✨ feat"; sent; }
      When call run
      The output should equal "--autostart=false send -s block:o -b block:o -- ✨ feat"
    End

    It 'exports the origin and the rex binary for insert-without-closing'
      run() { modal --no-chrome --origin block:o --inject -- "$RM_TMP/target" x; seen | sed -n 2p; }
      When call run
      The output should equal "pane=block:o rex=$RM_TMP/rex target=unset"
    End

    It 'types nothing when the picker was cancelled'
      run() { modal --no-chrome --origin block:o --inject -- "$RM_TMP/target" "" 130; print -r -- "rc=$?"; sent; }
      When call run
      The output should equal "rc=0"
    End

    It 'types nothing without an origin'
      run() { modal --no-chrome --inject -- "$RM_TMP/target" x; sent; }
      When call run
      The output should equal ""
    End

    It 'keeps embedded newlines and drops only the last one'
      run() { modal --no-chrome --origin block:o --inject -- /bin/sh -c 'printf "a\nb\n"'; sent | tr '\n' '|'; }
      When call run
      The output should equal "--autostart=false send -s block:o -b block:o -- a|b|"
    End
  End

  Describe 'chrome'
    It 'hands the title to the target with --no-chrome and draws nothing'
      run() { modal --no-chrome --title "Glyph Picker" --capture "$RM_TMP/out" -- "$RM_TMP/target" x | od -c | head -1; seen | sed -n 1p; }
      When call run
      The output should equal "title=Glyph Picker zj=Glyph Picker"
    End

    It 'paints the title block itself without --no-chrome'
      run() { modal --title "Confirm" --capture "$RM_TMP/out" -- "$RM_TMP/target" x | grep -c '▓▓▓ Confirm'; seen | sed -n 1p; }
      When call run
      The output should equal "1
title=unset zj=unset"
    End
  End

  Describe 'action mode'
    It 'runs the target with the origin exported and its own exit status'
      run() { modal --no-chrome --origin block:o -- "$RM_TMP/target" done 7 >/dev/null; print -r -- "rc=$?"; seen | sed -n 2p; }
      When call run
      The output should equal "rc=7
pane=unset rex=unset target=block:o"
    End
  End

  Describe 'usage'
    It 'refuses to run without a target command'
      run() { modal --title x; print -r -- "rc=$?"; cat "$RM_TMP/err"; }
      When call run
      The output should include "rc=2"
      The output should include "no target command"
    End

    It 'rejects an unknown option'
      run() { modal --bogus -- true; print -r -- "rc=$?"; }
      When call run
      The output should equal "rc=2"
    End
  End
End
