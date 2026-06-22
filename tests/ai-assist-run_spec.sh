Describe 'ai-assist-run'
  RUN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-run"
  SHELL_SRV="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-shell"

  setup() {
    TEST_TMP="$(mktemp -d)"
    FIFO="$TEST_TMP/cmd.fifo"; mkfifo "$FIFO"
    "$SHELL_SRV" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" & SHELL_PID=$!
    export AI_ASSIST_SHELL_FIFO="$FIFO"
    export TMPDIR="$TEST_TMP"
  }
  cleanup() { kill "$SHELL_PID" 2>/dev/null; rm -rf "$TEST_TMP"; unset AI_ASSIST_SHELL_FIFO; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'returns stdout and the exit code'
    When run "$RUN" 'echo hello; exit 0'
    The output should equal "hello"
    The status should be success
  End

  It 'propagates a non-zero exit code'
    When run "$RUN" 'exit 5'
    The status should eq 5
  End

  It 'emits structured JSON with --json'
    When run "$RUN" --json 'echo hi'
    The output should include '"stdout"'
    The output should include 'hi'
    The output should include '"exit"'
  End

  It 'errors clearly when no agent shell is present'
    unset AI_ASSIST_SHELL_FIFO
    When run "$RUN" 'echo nope'
    The status should eq 3
    The stderr should include "no agent shell"
  End

  It 'passes --id through so a later run sees AAS_OUT_<id>'
    "$RUN" --id step1 -- 'echo wired' >/dev/null
    When run "$RUN" -- 'printf %s "$AAS_OUT_step1"'
    The output should equal "wired"
    The status should equal 0
  End
End
