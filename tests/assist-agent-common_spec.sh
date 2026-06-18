# Tests for home/dot_local/lib/assist-agent-common.zsh — the assist:: engine
# behind the ai-assist dispatcher and its workers.
Describe 'assist-agent-common.zsh'
  Include home/dot_local/lib/assist-agent-common.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$TEST_TMP/state"
    export XDG_DATA_HOME="$TEST_TMP/data"
    export AI_ASSIST_SESSION="testsess"
    mkdir -p "$HOME"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'session pin'
    It 'reads empty when no pin exists'
      When call assist::pin_read
      The output should equal ""
      The status should be success
    End

    It 'round-trips a written pin'
      assist::pin_write claude
      When call assist::pin_read
      The output should equal "claude"
    End

    It 'clears a pin idempotently'
      assist::pin_write pi
      assist::pin_clear
      assist::pin_clear
      When call assist::pin_read
      The output should equal ""
    End

    It 'keys the pin on the session name'
      AI_ASSIST_SESSION="other"
      When call assist::session_dir
      The output should include "/sessions/other"
    End
  End

  Describe 'assist::request_read'
    request_fixture() {
      cat > "$TEST_TMP/req.json" <<'JSON'
{
  "version": 1,
  "kind": "error",
  "origin": {"zellij_session":"main","pane_id":"terminal_3","cwd":"/tmp/proj","project_root":"/tmp/proj"},
  "command": {"text":"make","exit":2,"duration_ms":1840},
  "scrollback":"make: *** No rule to make target 'all'.",
  "user_request":"Diagnose why make failed",
  "project":{"name":"proj","branch":"main"}
}
JSON
    }

    It 'parses fields into REQ_* globals'
      request_fixture
      When call assist::request_read "$TEST_TMP/req.json"
      The variable REQ_KIND should equal "error"
      The variable REQ_COMMAND_TEXT should equal "make"
      The variable REQ_COMMAND_EXIT should equal "2"
      The variable REQ_PROJECT_ROOT should equal "/tmp/proj"
      The variable REQ_USER_REQUEST should equal "Diagnose why make failed"
      The variable REQ_PROJECT_NAME should equal "proj"
    End

    It 'dies on a missing file'
      When run assist::request_read "$TEST_TMP/nope.json"
      The status should be failure
      The stderr should include "request file not found"
    End
  End

  Describe 'knowledge base'
    It 'derives a stable sha1 key from the root path'
      key1=$(assist::project_key /tmp/proj)
      key2=$(assist::project_key /tmp/proj)
      When call test "$key1" = "$key2"
      The status should be success
    End

    It 'ensure creates the dir and an empty knowledge.md'
      kb_path=$(assist::kb_ensure /tmp/proj)
      The file "$kb_path" should be exist
    End
  End
End
