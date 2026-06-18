# Tests for home/dot_local/libexec/executable_ai-assist-render: the docked-pane
# wrapper that shows a title block + spinner while the harness runs (buffered),
# then renders the captured markdown through glow (or a fold fallback).
Describe 'ai-assist-render'
  setup() {
    TEST_TMP=$(mktemp -d)
    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-render"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'prints the title block and renders the harness markdown'
    When run script "$SCRIPT" --harness "Claude Code" -- printf '# Diagnosis\n\nthe **fix** is simple\n'
    The status should be success
    The output should include "ai-assist — Claude Code"
    The output should include "Diagnosis"
    The output should include "fix"
    The output should include "simple"
  End

  It 'propagates the harness exit code'
    When run script "$SCRIPT" --harness X -- sh -c 'echo working; exit 3'
    The status should eq 3
    The output should include "working"
  End

  It 'falls back to a reflow when glow is absent'
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
