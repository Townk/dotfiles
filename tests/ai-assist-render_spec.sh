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
    # Point the pager at a non-existent path so the absolute-path resolution is
    # bypassed, and strip glow from PATH, forcing the fold reflow.
    BeforeRun 'export PATH=/usr/bin:/bin' 'export AI_ASSIST_PAGER_BIN=/nonexistent/ai-assist-pager'
    When run script "$SCRIPT" --harness X -- printf 'plain output line\n'
    The status should be success
    The output should include "plain output line"
  End

  It 'errors with no command after --'
    When run script "$SCRIPT" --harness X --
    The status should eq 2
    The stderr should include "no command"
  End

  # A stub broker: records its args, then sleeps so the render can kill it.
  broker_stub() {
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "BROKER $*" >> "$TEST_TMP/broker.log"'
      echo 'sleep 30'
    } > "$TEST_TMP/broker"
    chmod +x "$TEST_TMP/broker"
  }

  It 'spawns the broker and passes --actions-fifo to the pager when --origin-pane is set'
    fifo_pager() {
      { echo '#!/usr/bin/env zsh'
        echo 'print -r -- "PAGER actions=$4"   # --harness X --actions-fifo <path> are $1-$4'
      } > "$TEST_TMP/pager"; chmod +x "$TEST_TMP/pager"
    }
    BeforeRun 'broker_stub' 'fifo_pager' \
      'export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"' \
      'export AI_ASSIST_BROKER_BIN="$TEST_TMP/broker"' \
      'export TEST_TMP="$TEST_TMP"'
    When run script "$SCRIPT" --harness X --origin-pane terminal_4 --over-ssh -- printf 'hi\n'
    The status should be success
    The output should include "PAGER actions=/"
    The contents of file "$TEST_TMP/broker.log" should include "BROKER"
    The contents of file "$TEST_TMP/broker.log" should include "--origin-pane terminal_4"
    The contents of file "$TEST_TMP/broker.log" should include "--over-ssh"
  End

  It 'runs the pager with no --actions-fifo when --origin-pane is absent'
    plain_pager() {
      { echo '#!/usr/bin/env zsh'
        echo 'print -r -- "PAGER args=[$*]"'
      } > "$TEST_TMP/pager"; chmod +x "$TEST_TMP/pager"
    }
    BeforeRun 'plain_pager' 'export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"'
    When run script "$SCRIPT" --harness X -- printf 'hi\n'
    The status should be success
    The output should not include "actions-fifo"
  End
End
