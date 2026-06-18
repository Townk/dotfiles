# Tests for home/dot_local/libexec/executable_ai-assist-render: the docked-pane
# wrapper that runs the harness with a braille spinner (buffered), then hands the
# captured markdown to ai-assist-pager (the interactive viewer) — falling back to
# glow, then a width-aware fold, when the pager isn't installed.
Describe 'ai-assist-render'
  setup() {
    TEST_TMP=$(mktemp -d)
    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-render"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A stub pager: prints a marker with its --harness value, then dumps the file it
  # was handed (the last arg). Lets us assert the render delegated to the pager.
  pager_stub() {
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "PAGER_RAN harness=$2"'
      echo 'cat -- "${@: -1}"'
    } > "$TEST_TMP/pager"
    chmod +x "$TEST_TMP/pager"
  }

  It 'hands the captured markdown to ai-assist-pager'
    BeforeRun 'pager_stub' 'export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"'
    When run script "$SCRIPT" --harness "Claude Code" -- printf '# Hi\n'
    The status should be success
    The output should include "PAGER_RAN harness=Claude Code"
    The output should include "# Hi"
  End

  It 'propagates the harness exit code'
    BeforeRun 'pager_stub' 'export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"'
    When run script "$SCRIPT" --harness X -- sh -c 'echo working; exit 3'
    The status should eq 3
    The output should include "working"
  End

  It 'falls back to a reflow when neither pager nor glow is available'
    BeforeRun 'export PATH=/usr/bin:/bin'
    When run script "$SCRIPT" --harness X -- printf 'plain output line\n'
    The status should be success
    The output should include "plain output line"
  End

  It 'errors with no command after --'
    When run script "$SCRIPT" --harness X --
    The status should eq 2
    The stderr should include "no command"
  End
End
