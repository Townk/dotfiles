Describe 'ai-assist-run'
  RUN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-run"
  SHELL_SRV="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-shell"

  setup() {
    TEST_TMP="$(mktemp -d)"
    FIFO="$TEST_TMP/cmd.fifo"; mkfifo "$FIFO"
    # These exercise ai-assist-run, not the shell backend. Pin the fast,
    # deterministic eval-loop (Stage 4 made zpty the default, whose ~0.5s login
    # seed per spawn races shellspec's per-example timeout here).
    AI_ASSIST_SHELL_NO_INTERACTIVE=1 "$SHELL_SRV" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" & SHELL_PID=$!
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

  Describe 'timeout'
    timeout_setup() {
      # Kill the real shell started by outer BeforeEach — not needed here.
      kill "$SHELL_PID" 2>/dev/null; unset SHELL_PID
      # Fresh fifo with no shell servicing it.  A background zsh holds the
      # read end open (so the write in ai-assist-run doesn't block on open),
      # but never writes 'done', so the poll times out.
      TIMEOUT_TMP="$(mktemp -d)"
      TIMEOUT_FIFO="$TIMEOUT_TMP/timeout.fifo"
      mkfifo "$TIMEOUT_FIFO"
      # Open read end in a background job so write-open in ai-assist-run
      # doesn't block; the job will be killed in timeout_cleanup.
      zsh -c "cat '$TIMEOUT_FIFO' >/dev/null" &
      DRAIN_PID=$!
      export AI_ASSIST_SHELL_FIFO="$TIMEOUT_FIFO"
      export TMPDIR="$TIMEOUT_TMP"
      export AI_ASSIST_RUN_TIMEOUT=1
    }
    timeout_cleanup() {
      kill "$DRAIN_PID" 2>/dev/null
      rm -rf "$TIMEOUT_TMP"
      unset AI_ASSIST_RUN_TIMEOUT DRAIN_PID TIMEOUT_TMP TIMEOUT_FIFO
    }
    BeforeEach 'timeout_setup'
    AfterEach 'timeout_cleanup'

    It 'exits 124 and prints message when agent shell never responds'
      When run "$RUN" 'echo unreachable'
      The status should eq 124
      The stderr should include "timed out after 1s"
    End
  End
End
