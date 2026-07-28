# mux-fullscreen-probe — Ghostty's fullscreen mirror, refreshed OFF the hot path.
#
# WezTerm pushes its fullscreen state from wezterm.lua on every window event.
# Ghostty has no such hook, so the state must be asked for — and asking costs
# 4-11 seconds through the accessibility API. Asking from the ribbon renderer
# (a tmux `#()` job, which tmux will not re-run while one is in flight) meant
# the bar was not re-expanded between runs at all: a mode began and ended
# inside a single render, so no mode pill ever appeared. The question now
# lives here, driven by the client-resized hook.
Describe 'mux-fullscreen-probe'
  BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-fullscreen-probe"

  setup() {
    FP_TMP=$(mktemp -d)
    STATE="$FP_TMP/ghostty_fullscreen"
    { print '#!/bin/sh'
      print 'while IFS= read -r _l; do :; done'
      print 'echo "${STUB_STATE:-WINDOWED}"'
    } > "$FP_TMP/osascript"
    { print '#!/bin/sh'; print 'echo "$*" >> '"$FP_TMP/tmuxcalls" } > "$FP_TMP/tmux"
    chmod +x "$FP_TMP/osascript" "$FP_TMP/tmux"
  }
  cleanup() { rm -rf "$FP_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  probe() {
    STUB_STATE="$1" \
    TMPDIR="$FP_TMP" \
    WIDGETS_OSASCRIPT_BIN="$FP_TMP/osascript" \
    MUX_TMUX_BIN="$FP_TMP/tmux" \
    WIDGETS_GHOSTTY_FULLSCREEN_STATE="$STATE" \
      zsh "$BIN" >/dev/null 2>&1
    cat "$STATE" 2>/dev/null || echo "<absent>"
  }

  It 'records native fullscreen'
    When call probe NATIVE_FULLSCREEN
    The output should equal "true"
  End

  It 'records the non-native (maximised) case as fullscreen too'
    When call probe NON_NATIVE_FULLSCREEN
    The output should equal "true"
  End

  It 'records a windowed terminal'
    When call probe WINDOWED
    The output should equal "false"
  End

  # NOT_RUNNING from a Ghostty that is plainly running means the ASKER was not
  # granted Accessibility — not that the window vanished. Writing `false` on
  # that answer would quietly switch the fullscreen segments off and read as a
  # rendering bug, so an untrustworthy answer must leave the mirror alone.
  Describe 'an answer it cannot trust'
    It 'leaves an existing mirror untouched rather than clobbering it'
      keeps() {
        printf 'true' > "$STATE"
        probe NOT_RUNNING
      }
      When call keeps
      The output should equal "true"
    End

    It 'writes nothing at all when there is no mirror yet'
      When call probe NO_WINDOWS
      The output should equal "<absent>"
    End
  End

  It 'asks the bar to repaint once the mirror moves'
    calls() {
      probe NATIVE_FULLSCREEN >/dev/null
      cat "$FP_TMP/tmuxcalls" 2>/dev/null
    }
    When call calls
    The output should include "refresh-client -S"
  End

  # A resize arrives as a BURST — every intermediate size while dragging an
  # edge fires the hook, and each probe is seconds long. Without coalescing,
  # one drag spawns dozens of overlapping accessibility calls.
  It 'coalesces a burst behind an atomic lock'
    src() { cat "$BIN"; }
    When call src
    The output should include 'mkdir "$LOCK"'
    The output should include "rmdir"
  End
End
