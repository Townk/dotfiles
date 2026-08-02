# Tests for home/dot_config/zellij/scripts/lib/pick-adapter.zsh — zj_adapter::exec,
# the shared shell behind the four zellij floating-pane picker adapters
# (pick-glyph / pick-gitmoji / pick-clipboard / quick-launch). It resolves the
# picker binary, guards it, exports the floating-pane fzf geometry, requests the
# borderless look (either the --no-border CLI flag or the <PREFIX>_NO_BORDER env),
# and exec's the picker. HEIGHT=-4 is a hard contract with zellij-modal's 3-row
# title block — a wrong value misaligns the modal header.
Describe 'pick-adapter.zsh — zj_adapter::exec'
  Include home/dot_config/zellij/scripts/lib/pick-adapter.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    export REC="$TEST_TMP/rec.txt"
    STUB="$TEST_TMP/picker"
    # Stub picker: record its argv and the geometry / no-border env it inherits.
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "ARGV: $*" > "$REC"'
      echo 'for v in TP_HEIGHT TP_MARGIN TP_PADDING TP_NO_BORDER; do'
      echo '  val="${(P)v-<unset>}"'
      echo '  print -r -- "$v=$val" >> "$REC"'
      echo 'done'
    } > "$STUB"
    chmod +x "$STUB"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'exports the -4 title-block height plus the margin/padding geometry'
    When run zj_adapter::exec TP "$STUB" --flag-no-border -- foo
    The status should be success
    The contents of file "$REC" should include "TP_HEIGHT=-4"
    The contents of file "$REC" should include "TP_MARGIN=0,0,0,0"
    The contents of file "$REC" should include "TP_PADDING=0,2,0,2"
  End

  It 'puts --no-border on the command line in --flag-no-border mode (no env var)'
    When run zj_adapter::exec TP "$STUB" --flag-no-border -- foo bar
    The status should be success
    The contents of file "$REC" should include "ARGV: --no-border foo bar"
    The contents of file "$REC" should include "TP_NO_BORDER=<unset>"
  End

  It 'exports <PREFIX>_NO_BORDER=1 and keeps argv clean in env mode'
    When run zj_adapter::exec TP "$STUB" -- foo
    The status should be success
    The contents of file "$REC" should include "ARGV: foo"
    The contents of file "$REC" should include "TP_NO_BORDER=1"
  End

  It 'honors a caller-supplied geometry override instead of clobbering it'
    export TP_HEIGHT=12
    When run zj_adapter::exec TP "$STUB" --flag-no-border -- foo
    The status should be success
    The contents of file "$REC" should include "TP_HEIGHT=12"
  End

  It 'resolves <PREFIX>_BIN in preference to the default binary'
    export TP_BIN="$STUB"
    When run zj_adapter::exec TP /nonexistent/default --flag-no-border -- x
    The status should be success
    The contents of file "$REC" should include "ARGV: --no-border x"
  End

  It 'fails cleanly (exit 1 + stderr) when the binary is missing or non-executable'
    When run zj_adapter::exec TP "$TEST_TMP/nope" -- x
    The status should equal 1
    The stderr should include "missing or non-executable"
    The stderr should include "$TEST_TMP/nope"
  End
End
