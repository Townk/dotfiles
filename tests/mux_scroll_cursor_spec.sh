# mux-scroll-cursor — the copy-mode cursor is the REAL terminal cursor.
#
# Scroll mode hides it by painting `cursor-colour` the canvas background, which
# tmux emits as OSC 12. Leaving the mode unsets that pane option, and tmux
# emits Cr (`OSC 112`, reset cursor colour) — measured on a scratch server, so
# the tmux half of the restore is not in doubt.
#
# What IS in doubt is the far end. `OSC 112` is a request the outer terminal
# may simply not implement, and a terminal that ignores it keeps the colour
# hide() painted — for good. The cursor never comes back, in any pane, until
# the terminal is restarted (found in Blink/hterm, 2026-07-29).
#
# That is the same shape as the DECSCUSR gotcha shape_reset already carries:
# tmux's own reset is correct and the outer terminal still has to be told
# explicitly. So the restore repaints the theme's cursor colour through the
# client ttys instead of trusting the reset to land.
#
# The wire is rendered with `cat -v`: ESC reads as `^[`, BEL as `^G`.
Describe 'mux-scroll-cursor'
  BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-scroll-cursor"

  setup() {
    SC_TMP=$(mktemp -d)
    CLIENT="$SC_TMP/client-tty"      # a regular file: `[[ -w ]]` passes and the
    : > "$CLIENT"                    # bytes are readable back
    THEME="$SC_TMP/theme.json"
    printf '%s' '{"roles":{"ui":{"bg":"#1e1e2e","cursor":"#f5e0dc"}}}' > "$THEME"
    { print '#!/bin/sh'
      print 'echo "$*" >> "'"$SC_TMP"'/calls"'
      print 'case "$1" in'
      print '  display)'
      print '    for a in "$@"; do f="$a"; done'
      print '    case "$f" in'
      print '      *pane_in_mode*)     echo "$STUB_STATE" ;;'
      print '      "#{cursor_colour}") echo "$STUB_CURSOR_COLOUR" ;;'
      print '      "#{cursor_shape}")  echo "$STUB_CURSOR_SHAPE" ;;'
      print '      "#{session_name}")  echo "sess" ;;'
      print '    esac ;;'
      print '  list-clients) echo "'"$CLIENT"'" ;;'
      print 'esac'
      print 'exit 0'
    } > "$SC_TMP/tmux"
    chmod +x "$SC_TMP/tmux"
  }
  cleanup() { rm -rf "$SC_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # $1 the four-field state probe, $2 the pane's own cursor colour
  # ("none" = nothing in the pane is driving OSC 12), $3 the cursor shape.
  # Prints the tmux calls, then the bytes that reached the client tty.
  sync_with() {
    STUB_STATE="$1" \
    STUB_CURSOR_COLOUR="${2:-none}" \
    STUB_CURSOR_SHAPE="${3:-default}" \
    MUX_TMUX_BIN="$SC_TMP/tmux" \
    MUX_LIB="$PWD/home/dot_local/lib" \
    THEME_PALETTE_JSON="${SC_THEME_OVERRIDE:-$THEME}" \
      zsh "$BIN" '%1' >/dev/null 2>&1
    cat "$SC_TMP/calls" 2>/dev/null
    print -n 'WIRE:'; cat -v "$CLIENT" 2>/dev/null; print
  }

  Describe 'leaving copy-mode'
    # The regression. `set -p -u cursor-colour` is necessary but not
    # sufficient: it makes TMUX right, and says nothing to a terminal that
    # ignored the reset.
    It 'repaints the theme cursor colour on the wire, not just in tmux'
      When call sync_with '0 0 0 0'
      The output should include 'set -p -t %1 -u cursor-colour'
      The output should include '^[]12;#f5e0dc^G'
    End

    It 'still resets the cursor shape'
      When call sync_with '0 0 0 0'
      The output should include '^[[0 q'
    End

    # An app driving its own OSC 12 (nvim's per-mode cursors) owns the colour:
    # tmux re-emits the app's value on redraw, and painting the theme colour
    # over it would break the app instead of fixing the terminal.
    It 'leaves an app-owned cursor colour alone'
      When call sync_with '0 0 0 0' '#00ff00'
      The output should include 'set -p -t %1 -u cursor-colour'
      The output should not include '^[]12;'
    End
  End

  Describe 'entering scroll mode'
    It 'hides the cursor by painting it the canvas background'
      When call sync_with '1 0 0 0'
      The output should include 'set -p -t %1 cursor-colour #1e1e2e'
    End

    It 'does not repaint the theme colour while hidden'
      When call sync_with '1 0 0 0'
      The output should not include '^[]12;#f5e0dc'
    End
  End

  Describe 'copy/visual state'
    # Cursor ON and BLOCK: the restore has to fire here too, or the visual
    # cursor is a block painted the background colour — invisible, which is
    # precisely the state the mode exists to show.
    It 'repaints the cursor and asks for a block'
      When call sync_with '1 0 0 1'
      The output should include 'set -p -t %1 cursor-style block'
      The output should include '^[]12;#f5e0dc^G'
    End
  End

  Describe 'search with the input dialog up'
    It 'shows the cursor for typing'
      When call sync_with '1 1 0 0'
      The output should include 'set -p -t %1 -u cursor-colour'
      The output should include '^[]12;#f5e0dc^G'
    End
  End

  Describe 'a theme it cannot read'
    # Better a cursor that stays hidden than a stray OSC 12 with the literal
    # string "null" painted onto every attached client.
    It 'writes nothing when the theme json is missing'
      When call sync_with '0 0 0 0' none default
      The output should include '^[]12;'
    End

    It 'really writes nothing when the theme json is missing'
      SC_THEME_OVERRIDE="/nonexistent/theme.json"
      When call sync_with '0 0 0 0'
      The output should not include '^[]12;'
    End
  End
End
