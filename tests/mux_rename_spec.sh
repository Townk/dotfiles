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

    # Every other mode's pill arrives free: tmux redraws the status line when
    # the key table moves. Rename moves an OPTION instead, and an option
    # change earns no redraw — without an explicit refresh the pill waits for
    # the next status-interval tick (10s) while the dialog is already up.
    It 'asks for a repaint when it lights the mode, not only when it leaves'
      refreshes() {
        grep -c "refresh-client -S" "$BIN"
      }
      When call refreshes
      The output should equal "2"
    End

    It 'styles that dialog with the rename accent and glyph'
      src() { cat "$BIN"; }
      When call src
      The output should include "dialog.warning"
      The output should include "I_RENAME"
      The output should not include "e5bf7b"
    End
  End

  # Renaming a SESSION is the third payload for the same dialog, plus one
  # affordance the other two do not want: Alt+r drops an unused
  # adjective-noun name into the field (mux-random-session-name), so naming a
  # session is a keypress rather than an invention.
  Describe 'session'
    setup() {
      RS_TMP=$(mktemp -d)
      STUB="$RS_TMP/tmux"
      { print '#!/bin/sh'
        print 'echo "$*" >> '"$RS_TMP/calls"
        print 'case "$*" in'
        print '  *session_name*) echo "old-session" ;;'
        print '  *pane_id*)      echo "%1" ;;'
        print 'esac'
      } > "$STUB"; chmod +x "$STUB"
      RAND="$RS_TMP/rand"
      { print '#!/bin/sh'; print 'echo lucky-otter' } > "$RAND"; chmod +x "$RAND"
      THEME="$RS_TMP/theme.json"
      print '{"extended":{"tab":{"bg":"#282c41"},"dialog":{"warning":"#e5bf7b","search_accent":"#61afef"}},"roles":{"ui":{"bg":"#1e1e2e","dialog_bg":"#181825","border_inactive":"#45475a"},"action":{"attention":"#f9e2af"}},"palette":{"white":"#ffffff"}}' > "$THEME"
    }
    cleanup() { rm -rf "$RS_TMP"; }
    BeforeEach 'setup'
    AfterEach 'cleanup'

    # Feed the dialog raw bytes on stdin, exactly as a terminal would.
    drive() {
      printf '%b' "$1" | MUX_TMUX_BIN="$STUB" TMUX=/tmp/s,1,0 \
        THEME_PALETTE_JSON="$THEME" MUX_RANDOM_NAME_BIN="$RAND" \
        MUX_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" \
        zsh "$BIN" session >/dev/null 2>&1
      cat "$RS_TMP/calls"
    }

    It 'prefills with the current session name and renames on Enter'
      When call drive '\r'
      The output should include "rename-session"
      The output should include "old-session"
    End

    It 'replaces the field with a random name on Alt+r'
      When call drive '\033r\r'
      The output should include "lucky-otter"
    End

    # The roll FILLS THE FIELD and nothing else: the script is called with no
    # arguments (it has --apply/--apply-current modes that must never be used
    # from here), and the rename still only happens on Enter. Alt+r followed
    # by a cancel must leave the session exactly as it was.
    It 'does not rename when a rolled name is then cancelled'
      When call drive '\033r\033'
      The output should not include "rename-session"
    End

    It 'asks the generator for a name, never for a rename'
      calls() {
        RAND_LOG="$RS_TMP/randargs"
        { print '#!/bin/sh'; print 'echo "[$*]" >> '"$RS_TMP/randargs"; print 'echo lucky-otter' } > "$RAND"
        printf '%b' '\033r\r' | MUX_TMUX_BIN="$STUB" TMUX=/tmp/s,1,0 \
          THEME_PALETTE_JSON="$THEME" MUX_RANDOM_NAME_BIN="$RAND" \
          MUX_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" \
          zsh "$BIN" session >/dev/null 2>&1
        cat "$RS_TMP/randargs"
      }
      When call calls
      # invoked with NO arguments — never --apply or --apply-current
      The output should equal "[]"
    End

    It 'still cancels on a bare ESC'
      When call drive '\033'
      The output should not include "rename-session"
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