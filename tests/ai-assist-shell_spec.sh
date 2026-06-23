Describe 'ai-assist-shell'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-shell"

  setup() {
    TEST_TMP="$(mktemp -d)"
    FIFO="$TEST_TMP/cmd.fifo"; mkfifo "$FIFO"
    "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" &
    SHELL_PID=$!
  }
  cleanup() { kill "$SHELL_PID" 2>/dev/null; rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Submit a job and block until the server signals done; echoes the reply dir.
  run_job() {
    local reply; reply="$(mktemp -d "$TEST_TMP/reply.XXXXXX")"
    printf '%s\x1f%s\x1e' "$reply" "$1" > "$FIFO"
    local i=0; while [ ! -e "$reply/done" ] && [ $i -lt 200 ]; do sleep 0.02; i=$((i+1)); done
    printf '%s' "$reply"
  }

  # Submit a job carrying a block id; blocks until done.
  run_job_id() {
    local reply id cmd; reply="$(mktemp -d "$TEST_TMP/reply.XXXXXX")"; id="$1"; cmd="$2"
    printf '%s\x1f%s\x1f%s\x1e' "$reply" "$id" "$cmd" > "$FIFO"
    local i=0; while [ ! -e "$reply/done" ] && [ $i -lt 200 ]; do sleep 0.02; i=$((i+1)); done
    printf '%s' "$reply"
  }

  It 'captures stdout, stderr and exit code separately'
    reply="$(run_job 'echo out; echo err >&2; exit 3')"
    The contents of file "$reply/out" should equal "out"
    The contents of file "$reply/err" should equal "err"
    The contents of file "$reply/exit" should equal "3"
  End

  It 'reports exit 0 for a successful command'
    reply="$(run_job 'true')"
    The contents of file "$reply/exit" should equal "0"
  End

  # Regression: a command that fails WITHOUT calling `exit` must still report
  # its non-zero code. The trailing state-write used to mask it (always 0).
  It 'reports a non-zero exit for a failing command (not just exit N)'
    reply="$(run_job 'false')"
    The contents of file "$reply/exit" should equal "1"
  End

  # Regression: a failure in any pipe stage must propagate (pipefail), so a
  # masked failure like `ls /nonexistent | head` is not reported as success.
  It 'propagates a pipe-stage failure (pipefail)'
    reply="$(run_job 'false | head -5')"
    The contents of file "$reply/exit" should equal "1"
  End

  # The runner's own nounset must not leak into user code (false failures).
  It 'does not impose nounset on user commands'
    reply="$(run_job 'echo "${THIS_VAR_IS_UNSET}"')"
    The contents of file "$reply/exit" should equal "0"
  End

  # Benign SIGPIPE (producer killed by an early-closing `| head`) is success.
  It 'treats SIGPIPE as success (downstream closed early)'
    reply="$(run_job 'yes | head -5')"
    The contents of file "$reply/exit" should equal "0"
  End

  # The real execution timeout: a runaway command is killed and reported 124.
  It 'kills a job that overruns AI_ASSIST_RUN_TIMEOUT (exit 124)'
    kill "$SHELL_PID" 2>/dev/null
    AI_ASSIST_RUN_TIMEOUT=1 "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" & SHELL_PID=$!
    reply="$(run_job 'sleep 5')"
    The contents of file "$reply/exit" should equal "124"
  End

  # The per-id pidfile (used by a stop action) is published during the run and
  # cleaned up after it completes.
  It 'cleans up the per-id pidfile after a run'
    rund="$TEST_TMP/run"; mkdir "$rund"
    kill "$SHELL_PID" 2>/dev/null
    "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" --run-dir "$rund" & SHELL_PID=$!
    run_job_id blk1 'true' >/dev/null
    The path "$rund/blk1.pid" should not be exist
  End

  It 'persists cwd across jobs (cd is stateful)'
    sub="$TEST_TMP/sub"; mkdir "$sub"
    run_job "cd '$sub'" >/dev/null
    reply="$(run_job 'pwd')"
    The contents of file "$reply/out" should equal "$sub"
  End

  It 'persists exported vars across jobs'
    run_job 'export FOO=bar' >/dev/null
    reply="$(run_job 'echo $FOO')"
    The contents of file "$reply/out" should equal "bar"
  End

  It 'exposes the previous result as LAST_EXCODE'
    run_job 'exit 7' >/dev/null
    reply="$(run_job 'echo $LAST_EXCODE')"
    The contents of file "$reply/out" should equal "7"
  End

  It 'seeds the environment from --env-file'
    envf="$TEST_TMP/env"; printf "export SEEDED=yes\n" > "$envf"
    kill "$SHELL_PID" 2>/dev/null
    "$SCRIPT" --cmd-fifo "$FIFO" --env-file "$envf" --cwd "$TEST_TMP" & SHELL_PID=$!
    reply="$(run_job 'echo $SEEDED')"
    The contents of file "$reply/out" should equal "yes"
  End

  It 'exposes AAS_OUT_<id> to a later job'
    run_job_id diag 'echo hello' >/dev/null
    reply="$(run_job 'printf %s "$AAS_OUT_diag"')"
    When call cat "$reply/out"
    The output should equal "hello"
  End
End
