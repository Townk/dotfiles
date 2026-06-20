Describe 'ai-assist-remember'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-remember"

  setup() {
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/home"; mkdir -p "$HOME"
    export XDG_DATA_HOME="$TEST_TMP/data"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset HOME XDG_DATA_HOME; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  kb_for() { # mirror assist::kb_path for assertions
    local key; key="$(printf '%s' "$1" | shasum -a 1 | awk '{print $1}')"
    printf '%s' "$XDG_DATA_HOME/ai-assist/projects/$key/knowledge.md"
  }

  It 'appends a fact to the project knowledge base'
    When run "$SCRIPT" --project /tmp/proj "make needs gmake on macOS"
    The status should be success
    kb="$(kb_for /tmp/proj)"
    The contents of file "$kb" should include "make needs gmake on macOS"
  End

  It 'appends rather than overwrites'
    "$SCRIPT" --project /tmp/proj "first fact" >/dev/null
    "$SCRIPT" --project /tmp/proj "second fact" >/dev/null
    kb="$(kb_for /tmp/proj)"
    The contents of file "$kb" should include "first fact"
    The contents of file "$kb" should include "second fact"
  End

  It 'errors on an empty fact'
    When run "$SCRIPT" --project /tmp/proj ""
    The status should eq 2
    The stderr should include "empty fact"
  End
End
