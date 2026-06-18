# Tests for home/dot_local/bin/executable_ai-assist: the harness dispatcher.
# Runs the script as a subprocess with stub `ai-assist-*` workers on a private
# bin dir, and the library pointed at the repo via AI_ASSIST_LIB_DIR.
Describe 'ai-assist dispatcher'
  setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$TEST_TMP/state"
    export AI_ASSIST_SESSION="testsess"
    export AI_ASSIST_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    mkdir -p "$HOME" "$TEST_TMP/bin"

    # The dispatcher discovers workers next to itself: copy it into our bin dir
    # and drop stub workers beside it.
    cp "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_ai-assist" "$TEST_TMP/bin/ai-assist"
    chmod +x "$TEST_TMP/bin/ai-assist"
    make_worker() {  # $1 = harness, $2 = probe-exit (0 available / 1 not)
      {
        echo '#!/usr/bin/env zsh'
        echo "[[ \"\${1:-}\" == --probe ]] && { exit $2; }"
        echo "echo \"WORKER $1 ARGS: \$*\""
      } > "$TEST_TMP/bin/ai-assist-$1"
      chmod +x "$TEST_TMP/bin/ai-assist-$1"
    }
    SCRIPT="$TEST_TMP/bin/ai-assist"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'help exits 0 and prints usage'
    make_worker claude 0
    When run script "$SCRIPT" --help
    The status should be success
    The output should include "Usage:"
  End

  It 'explicit harness forwards args verbatim and does not pin'
    make_worker claude 0
    make_worker pi 0
    When run script "$SCRIPT" claude --request /tmp/r.json
    The status should be success
    The output should include "WORKER claude ARGS: --request /tmp/r.json"
    The path "$TEST_TMP/state/ai-assist/sessions/testsess/harness" should not be exist
  End

  It 'sole available harness auto-selects and pins'
    make_worker claude 0
    make_worker pi 1   # pi probe fails → unavailable
    When run script "$SCRIPT" --request /tmp/r.json
    The status should be success
    The output should include "WORKER claude ARGS: --request /tmp/r.json"
    The contents of file "$TEST_TMP/state/ai-assist/sessions/testsess/harness" should equal "claude"
    The stderr should include "only available harness"
  End

  It 'reuses a session pin without re-probing'
    make_worker claude 0
    make_worker pi 0
    { printf 'pi\n' > "$TEST_TMP/state/ai-assist/sessions/testsess/harness"; } 2>/dev/null || {
      mkdir -p "$TEST_TMP/state/ai-assist/sessions/testsess"
      printf 'pi\n' > "$TEST_TMP/state/ai-assist/sessions/testsess/harness"
    }
    When run script "$SCRIPT" --request /tmp/r.json
    The status should be success
    The output should include "WORKER pi ARGS:"
    The stderr should include "session-pinned"
  End

  It '--forget clears the pin'
    make_worker claude 0
    mkdir -p "$TEST_TMP/state/ai-assist/sessions/testsess"
    printf 'claude\n' > "$TEST_TMP/state/ai-assist/sessions/testsess/harness"
    When run script "$SCRIPT" --forget
    The status should be success
    The path "$TEST_TMP/state/ai-assist/sessions/testsess/harness" should not be exist
    The stdout should include "cleared"
  End

  It 'errors when no worker is available'
    make_worker claude 1
    When run script "$SCRIPT" --request /tmp/r.json
    The status should be failure
    The stderr should include "no harness available"
  End
End
