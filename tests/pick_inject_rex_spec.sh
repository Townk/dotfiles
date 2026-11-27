# Tests for the Rex branch of the pickers' insert-WITHOUT-closing path: a
# picker running in a Rex floating layer (rex-modal --inject) types a value
# into the block it was opened over while it stays open. rex-modal exports
# PICK_INJECT_PANE (the origin block) and PICK_INJECT_REX (the rex binary).
Describe 'pick::background_sink — Rex'
  Include home/dot_local/lib/pick-common.zsh

  setup() {
    PI_TMP=$(mktemp -d)
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
  cleanup() { rm -rf "$PI_TMP"; unset PICK_INJECT_PANE PICK_INJECT_REX; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

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
