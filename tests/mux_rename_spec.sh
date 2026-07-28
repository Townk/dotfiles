# mux-rename — the themed rename dialog (zj-hud `role "rename"` parity).
#
# zj-hud renders rename as a THREE-ROW dialog anchored bottom-right: a yellow
# left rule, the md_rename glyph, and a half-block input box holding the
# current name (src/rename/mod.rs render_field, PANE_WIDTH/PANE_HEIGHT and the
# BOX_* constants). The tmux port used to open a 66x13 generic input popup —
# same function, nothing of the look. These pin the shape and the wiring; the
# pixels are a Mode B judgement.
Describe 'mux-rename'
  BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-rename"

  Describe 'launch geometry'
    setup() {
      RN_TMP=$(mktemp -d)
      STUB="$RN_TMP/tmux"
      { print '#!/bin/sh'
        print 'echo "$*" >> '"$RN_TMP/calls"
        print 'case "$*" in'
        print '  *client_width*)  echo 120 ;;'
        print '  *client_height*) echo 40 ;;'
        print '  *pane_id*)       echo "%3" ;;'
        print 'esac'
      } > "$STUB"
      chmod +x "$STUB"
    }
    cleanup() { rm -rf "$RN_TMP"; }
    BeforeEach 'setup'
    AfterEach 'cleanup'

    launch() {
      MUX_TMUX_BIN="$STUB" TMUX=/tmp/s,1,0 zsh "$BIN" --launch "$1" >/dev/null 2>&1
      cat "$RN_TMP/calls"
    }

    It 'opens a three-row dialog anchored to the bottom right'
      When call launch window
      # zj-hud: PANE_HEIGHT 3, PANE_WIDTH 40, RIGHT_INSET keeps it off the edge
      The output should include "-w 40"
      The output should include "-h 3"
      The output should include "-x 79"
      The output should include "-y 38"
    End

    It 'carries the kind through to the dialog body'
      When call launch pane
      The output should include "pane"
    End
  End

  Describe 'the dialog body'
    It 'refuses to run outside tmux rather than drawing nothing'
      When run zsh "$BIN" window
      The status should be failure
      The stderr should include "tmux only"
    End

    It 'draws nothing itself — the shared dialog owns the chrome'
      src() { cat "$BIN"; }
      When call src
      # the frame, the field and the anchor come from one place
      The output should include "mux/dialog.zsh"
      The output should include "mux_dialog::frame"
      The output should include "mux_dialog::field"
      The output should include "mux_dialog::launch"
      # …so no second copy of the box glyphs or the CSI plumbing lives here
      The output should not include "𜺠"
      The output should not include "38;2;"
    End

    It 'styles that dialog with the rename accent and glyph'
      src() { cat "$BIN"; }
      When call src
      The output should include "dialog.warning"
      The output should include "I_RENAME"
      The output should not include "e5bf7b"
    End
  End

  # One compact dialog, two callers. If a third ever appears, it goes through
  # here too — the plugin draws search and rename with the same render_field.
  Describe 'the shared dialog'
    LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/mux/dialog.zsh"

    It 'carries the plugin geometry constants exactly once'
      src() { cat "$LIB"; }
      When call src
      The output should include "MD_W=40"
      The output should include "MD_H=3"
      The output should include "MD_GLYPH_COL=2"
      The output should include "MD_INPUT_COL=5"
      The output should include "MD_RIGHT_INSET=5"
    End

    It 'is the only place the box glyphs are drawn'
      count() {
        grep -l "𜺠" "$SHELLSPEC_PROJECT_ROOT"/home/dot_local/lib/mux/*.zsh \
             "$SHELLSPEC_PROJECT_ROOT"/home/dot_config/mux/scripts/* 2>/dev/null | wc -l | tr -d ' '
      }
      When call count
      The output should equal "1"
    End

    It 'takes the accent from the caller, not from a literal'
      src() { cat "$LIB"; }
      When call src
      The output should include "accent_path"
      The output should not include "61afef"
      The output should not include "e5bf7b"
    End
  End
End