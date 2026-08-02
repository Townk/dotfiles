# Characterization tests for the four zellij floating-pane picker adapters:
#   home/dot_config/zellij/scripts/executable_pick-glyph-zellij
#   home/dot_config/zellij/scripts/executable_pick-gitmoji-zellij
#   home/dot_config/zellij/scripts/executable_pick-clipboard-zellij
#   home/dot_config/zellij/scripts/executable_quick-launch-zellij
#
# Each adapter resolves its picker binary, exports the -4 title-block geometry
# (the zellij-modal contract), forwards its args, and requests the borderless
# look via the --no-border CLI flag. All four now use the flag form (Wave 2,
# group C5, Decision 1): pick-glyph / pick-gitmoji always parsed it; pick-clipboard
# gained a --no-border flag and the quick-launch dispatcher gained --no-border
# forwarding into `menu`, so the *_NO_BORDER env form is no longer used here.
# These are the safety net for the shared-lib (C5) refactor: the borderless
# render + -4 geometry must be identical before and after the migration.
Describe 'zellij picker adapters'
  setup() {
    TEST_TMP=$(mktemp -d)
    export REC="$TEST_TMP/rec.txt"
    STUB="$TEST_TMP/stub"
    # Stub picker: record argv plus every exported adapter env var.
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "ARGV: $*" > "$REC"'
      echo "env | grep -E '^(PICK_GLYPH|PICK_GITMOJI|PICK_CLIPBOARD|QUICK_LAUNCH)_' | sort >> \"\$REC\""
    } > "$STUB"
    chmod +x "$STUB"
    SDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zellij/scripts"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'pick-glyph-zellij'
    It 'execs pick-glyph with the --no-border flag, -4 geometry, and forwarded args'
      export PICK_GLYPH_BIN="$STUB"
      When run zsh "$SDIR/executable_pick-glyph-zellij" -q EMOJI
      The status should be success
      The contents of file "$REC" should include "ARGV: --no-border -q EMOJI"
      The contents of file "$REC" should include "PICK_GLYPH_HEIGHT=-4"
      The contents of file "$REC" should include "PICK_GLYPH_MARGIN=0,0,0,0"
      The contents of file "$REC" should include "PICK_GLYPH_PADDING=0,2,0,2"
      The contents of file "$REC" should not include "PICK_GLYPH_NO_BORDER"
    End

    It 'fails cleanly (exit 1) when the picker binary is missing'
      export PICK_GLYPH_BIN="$TEST_TMP/absent"
      When run zsh "$SDIR/executable_pick-glyph-zellij"
      The status should equal 1
      The stderr should include "pick-glyph-zellij: missing or non-executable"
    End
  End

  Describe 'pick-gitmoji-zellij'
    It 'execs pick-gitmoji with the --no-border flag and -4 geometry'
      export PICK_GITMOJI_BIN="$STUB"
      When run zsh "$SDIR/executable_pick-gitmoji-zellij"
      The status should be success
      The contents of file "$REC" should include "ARGV: --no-border"
      The contents of file "$REC" should include "PICK_GITMOJI_HEIGHT=-4"
      The contents of file "$REC" should include "PICK_GITMOJI_MARGIN=0,0,0,0"
      The contents of file "$REC" should include "PICK_GITMOJI_PADDING=0,2,0,2"
      The contents of file "$REC" should not include "PICK_GITMOJI_NO_BORDER"
    End
  End

  Describe 'pick-clipboard-zellij'
    It 'execs pick-clipboard with the --no-border flag and -4 geometry (no env var)'
      export PICK_CLIPBOARD_BIN="$STUB"
      When run zsh "$SDIR/executable_pick-clipboard-zellij"
      The status should be success
      The contents of file "$REC" should include "ARGV: --no-border"
      The contents of file "$REC" should include "PICK_CLIPBOARD_HEIGHT=-4"
      The contents of file "$REC" should include "PICK_CLIPBOARD_MARGIN=0,0,0,0"
      The contents of file "$REC" should include "PICK_CLIPBOARD_PADDING=0,2,0,2"
      The contents of file "$REC" should not include "PICK_CLIPBOARD_NO_BORDER"
    End
  End

  Describe 'quick-launch-zellij'
    It 'execs quick-launch menu <kind> with the --no-border flag and -4 geometry (no env var)'
      export QUICK_LAUNCH_BIN="$STUB"
      When run zsh "$SDIR/executable_quick-launch-zellij" pane
      The status should be success
      The contents of file "$REC" should include "ARGV: --no-border menu pane"
      The contents of file "$REC" should include "QUICK_LAUNCH_HEIGHT=-4"
      The contents of file "$REC" should include "QUICK_LAUNCH_MARGIN=0,0,0,0"
      The contents of file "$REC" should include "QUICK_LAUNCH_PADDING=0,2,0,2"
      The contents of file "$REC" should not include "QUICK_LAUNCH_NO_BORDER"
    End
  End
End
