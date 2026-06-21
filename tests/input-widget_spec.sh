# Tests for input-widget — the --type dispatcher (pane process).
Describe 'input-widget'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_input-widget"

  setup() {
    TEST_TMP="$(mktemp -d)"
    aii="$TEST_TMP/ai-assist-input"
    { echo '#!/usr/bin/env zsh'; echo 'printf "%s" "${AII_OUT:-}"'; echo 'exit ${AII_RC:-0}'; } > "$aii"
    chmod +x "$aii"; export AI_ASSIST_INPUT_BIN="$aii"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset AI_ASSIST_INPUT_BIN AII_OUT AII_RC; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'dispatches --type line to input::line'
    export AII_OUT="typed"
    When run "$SCRIPT" --type line -- "Name?"
    The output should equal "typed"
    The status should be success
  End

  It 'dispatches --type confirm and maps no to exit 1'
    export AII_RC=1
    When run "$SCRIPT" --type confirm -- "OK?"
    The output should equal "no"
    The status should eq 1
  End

  It 'rejects an unknown type'
    When run "$SCRIPT" --type bogus -- "x"
    The status should eq 2
    The stderr should include "unknown"
  End
End
