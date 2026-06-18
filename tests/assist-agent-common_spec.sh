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

  Describe 'assist::system_prompt'
    It 'includes the bounded-context discipline and the request context'
      REQ_KIND="error"; REQ_COMMAND_TEXT="make"; REQ_COMMAND_EXIT="2"
      REQ_PROJECT_ROOT="/tmp/proj"; REQ_PROJECT_NAME="proj"; REQ_BRANCH="main"
      REQ_SCROLLBACK="No rule to make target 'all'."
      REQ_USER_REQUEST="Diagnose why make failed"
      kb=$(mktemp); : > "$kb"
      When call assist::system_prompt "$kb"
      The output should include "make"
      The output should include "Diagnose why make failed"
      The output should include "bounded"
      The output should include "No rule to make target"
    End

    It 'includes knowledge-base contents when present'
      REQ_KIND="question"; REQ_PROJECT_ROOT="/tmp/proj"
      REQ_USER_REQUEST="how do I build?"
      kb=$(mktemp); printf 'KB-FACT: build with gmake\n' > "$kb"
      When call assist::system_prompt "$kb"
      The output should include "KB-FACT: build with gmake"
    End
  End

  Describe 'assist::spawn_pane'
    It 'invokes zellij new-pane to the right with the cwd and the command'
      export ZELLIJ=1
      stub="$TEST_TMP/zjstub"
      {
        echo '#!/usr/bin/env zsh'
        echo "printf '%s\\n' \"\$*\" > \"$TEST_TMP/zj-args\""
      } > "$stub"; chmod +x "$stub"
      export ZELLIJ_BIN="$stub"
      REQ_PROJECT_ROOT="/tmp/proj"
      When call assist::spawn_pane echo hello world
      The status should be success
      The contents of file "$TEST_TMP/zj-args" should include "action new-pane"
      The contents of file "$TEST_TMP/zj-args" should include "--direction right"
      The contents of file "$TEST_TMP/zj-args" should include "--cwd /tmp/proj"
      The contents of file "$TEST_TMP/zj-args" should include "-- echo hello world"
    End

    It 'dies when not inside a Zellij session'
      unset ZELLIJ
      export ZELLIJ_BIN="/bin/echo"
      REQ_PROJECT_ROOT="/tmp/proj"
      When run assist::spawn_pane echo hi
      The status should be failure
      The stderr should include "not inside a Zellij session"
    End
  End
End
