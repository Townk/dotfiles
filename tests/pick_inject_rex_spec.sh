# Tests for the Rex branch of the pickers' insert-WITHOUT-closing path: a
# picker running in a Rex floating layer (rex-modal --inject) types a value
# into the block it was opened over while it stays open. rex-modal exports
# PICK_INJECT_PANE (the origin block) and PICK_INJECT_REX (the rex binary).
Describe 'pick::background_sink — Rex'
  Include home/dot_local/lib/pick-common.zsh

  setup() {
    spec_sandbox pi; PI_TMP=$SANDBOX
    # The real binary lives under "Application Support": the path has a space.
    mkdir -p "$PI_TMP/Application Support"
    PI_REX="$PI_TMP/Application Support/rex"
    cat >"$PI_REX" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$PI_TMP/rex.log"
EOS
    chmod +x "$PI_REX"
    unset PICK_INJECT_TMUX
  }
  # The stub runs from a pooled inode: exec'd once before the first example.
  Include tests/exec_warm_helper.sh
  BeforeAll 'spec_exec_pool_warm 1'
  BeforeEach 'setup'

  sent() { cat "$PI_TMP/rex.log" 2>/dev/null || true; }

  It 'types the text into the origin block'
    run() { PICK_INJECT_PANE=block:o PICK_INJECT_REX="$PI_REX" pick::background_sink "✨ sparkle"; sent; }
    When call run
    The output should equal "--autostart=false send -s block:o -b block:o -- ✨ sparkle"
  End

  It 'does not use the Rex path without an origin block'
    pick::detect_clip() { print -r -- ""; }
    run() { PICK_INJECT_REX="$PI_REX" pick::background_sink "x"; sent; }
    When call run
    The output should equal ""
  End
End

# One implementation types a picker's result into the pane it was opened
# over: pick::inject, driven by the PICK_INJECT_* environment the modal
# exports. The background sink and the clipboard picker's "insert and stay"
# both go through it.
Describe 'pick::inject'
  Include home/dot_local/lib/pick-common.zsh

  setup() {
    spec_sandbox pj; PJ_TMP=$SANDBOX
    mkdir -p "$PJ_TMP/Application Support"
    printf '%s\n' '#!/bin/sh' "printf 'rex|%s\\n' \"\$*\" >>'$PJ_TMP/log'" >"$PJ_TMP/Application Support/rex"
    printf '%s\n' '#!/bin/sh' "printf 'tmux|%s\\n' \"\$*\" >>'$PJ_TMP/log'" >"$PJ_TMP/tmux"
    printf '%s\n' '#!/bin/sh' "printf 'clip|' >>'$PJ_TMP/log'; cat >>'$PJ_TMP/log'" >"$PJ_TMP/pbcopy"
    chmod +x "$PJ_TMP/Application Support/rex" "$PJ_TMP/tmux" "$PJ_TMP/pbcopy"
    unset PICK_INJECT_PANE PICK_INJECT_REX PICK_INJECT_TMUX
  }
  # Three stubs per example, on pooled inodes: exec'd once before the first.
  Include tests/exec_warm_helper.sh
  BeforeAll 'spec_exec_pool_warm 3'
  BeforeEach 'setup'

  logged() { cat "$PJ_TMP/log" 2>/dev/null || true; }

  It 'types into the origin Rex block, the binary path never word-split'
    run() { PICK_INJECT_PANE=block:o PICK_INJECT_REX="$PJ_TMP/Application Support/rex" pick::inject "two words"; logged; }
    When call run
    The output should equal "rex|--autostart=false send -s block:o -b block:o -- two words"
  End

  It 'keeps U+FE0F on Rex (its grid agrees with zsh about the width)'
    run() { PICK_INJECT_PANE=block:o PICK_INJECT_REX="$PJ_TMP/Application Support/rex" pick::inject $'\u2764\uFE0F'; logged | od -An -tx1 | tr -d ' \n'; }
    When call run
    The output should include "e29da4efb88f"
  End

  It 'types literally into the origin tmux pane, without U+FE0F'
    run() { PICK_INJECT_PANE=%7 PICK_INJECT_TMUX="$PJ_TMP/tmux -L sock" pick::inject $'a\u2764\uFE0Fb'; logged; }
    When call run
    The output should equal "tmux|-L sock send-keys -t %7 -l -- a"$'\u2764'"b"
  End

  It 'copies to the clipboard when there is no origin pane'
    run() { PATH="$PJ_TMP:$PATH" pick::inject "plain"; logged; }
    When call run
    The output should equal "clip|plain"
  End

  It 'is what the background sink does'
    run() { PICK_INJECT_PANE=%7 PICK_INJECT_TMUX="$PJ_TMP/tmux" pick::background_sink "x"; logged; }
    When call run
    The output should equal "tmux|send-keys -t %7 -l -- x"
  End

  # The clipboard picker's Ctrl+O had only the Rex branch: opened over a tmux
  # pane it silently copied instead of typing.
  It 'gives the clipboard picker'"'"'s insert-and-stay a tmux branch'
    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
    run() {
      # Only the function under test is taken from the picker: sourcing the
      # whole script needs a store, and this is about where the text goes.
      eval "$(awk '/^clip::inject_by_id\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$SCRIPT")"
      clip::text_by_id() { print -r -- "clip $1"; }
      PICK_INJECT_PANE=%7 PICK_INJECT_TMUX="$PJ_TMP/tmux" clip::inject_by_id 42
      logged
    }
    When call run
    The output should equal "tmux|send-keys -t %7 -l -- clip 42"
  End
End
