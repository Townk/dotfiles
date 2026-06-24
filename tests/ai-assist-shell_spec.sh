Describe 'ai-assist-shell'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-shell"

  # Stage 4: the zpty controller is now the DEFAULT. These tests exercise the
  # eval-loop FALLBACK, so every spawn opts out via AI_ASSIST_SHELL_NO_INTERACTIVE=1.
  setup() {
    TEST_TMP="$(mktemp -d)"
    FIFO="$TEST_TMP/cmd.fifo"; mkfifo "$FIFO"
    AI_ASSIST_SHELL_NO_INTERACTIVE=1 "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" &
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

  # A later success in a multi-command block must not mask an earlier failure.
  It 'fails a multi-command block at the first failing command (set -e)'
    reply="$(run_job 'false
echo second')"
    The contents of file "$reply/exit" should equal "1"
  End

  # A block can opt out of a deliberate non-zero with `… || true`.
  It 'lets a block guard a deliberate non-zero (|| true)'
    reply="$(run_job 'false || true
echo ok')"
    The contents of file "$reply/exit" should equal "0"
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
    AI_ASSIST_SHELL_NO_INTERACTIVE=1 AI_ASSIST_RUN_TIMEOUT=1 "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" & SHELL_PID=$!
    reply="$(run_job 'sleep 5')"
    The contents of file "$reply/exit" should equal "124"
  End

  # The per-id pidfile (used by a stop action) is published during the run and
  # cleaned up after it completes.
  It 'cleans up the per-id pidfile after a run'
    rund="$TEST_TMP/run"; mkdir "$rund"
    kill "$SHELL_PID" 2>/dev/null
    AI_ASSIST_SHELL_NO_INTERACTIVE=1 "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" --run-dir "$rund" & SHELL_PID=$!
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
    AI_ASSIST_SHELL_NO_INTERACTIVE=1 "$SCRIPT" --cmd-fifo "$FIFO" --env-file "$envf" --cwd "$TEST_TMP" & SHELL_PID=$!
    reply="$(run_job 'echo $SEEDED')"
    The contents of file "$reply/out" should equal "yes"
  End

  It 'exposes AAS_OUT_<id> to a later job'
    run_job_id diag 'echo hello' >/dev/null
    reply="$(run_job 'printf %s "$AAS_OUT_diag"')"
    When call cat "$reply/out"
    The output should equal "hello"
  End

  # Stage 3: the captured live aliases/functions dump (--shell-init) is sourced
  # into the eval-loop's seed so a job resolves a function (and alias) defined
  # ONLY in that dump — proving the dump delivery path for the eval-loop backend.
  It 'seeds aliases/functions from --shell-init (eval-loop)'
    initf="$TEST_TMP/init"
    printf 'aas_initfn() { print -r -- INITFN_OK }\nalias aas_initalias='\''print -r -- INITALIAS_OK'\''\n' > "$initf"
    kill "$SHELL_PID" 2>/dev/null
    AI_ASSIST_SHELL_NO_INTERACTIVE=1 "$SCRIPT" --cmd-fifo "$FIFO" --shell-init "$initf" --cwd "$TEST_TMP" & SHELL_PID=$!
    reply="$(run_job 'aas_initfn')"
    The contents of file "$reply/out" should equal "INITFN_OK"
    reply2="$(run_job 'aas_initalias')"
    The contents of file "$reply2/out" should equal "INITALIAS_OK"
  End

  # Directory-scoped env managers (mise/direnv) are re-synced after each job, so a
  # config change in one block is visible to the next. Stub mise's hook-env to
  # emit an export and verify a later job sees it.
  It 're-syncs dir-env managers (mise hook-env) into later jobs'
    printf '#!/usr/bin/env zsh\n[[ "$1" == "hook-env" ]] && print -r -- "export MISE_SYNCED=yes"\n' > "$TEST_TMP/mise"
    chmod +x "$TEST_TMP/mise"
    kill "$SHELL_PID" 2>/dev/null
    AI_ASSIST_SHELL_NO_INTERACTIVE=1 PATH="$TEST_TMP:$PATH" "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" & SHELL_PID=$!
    run_job 'true' >/dev/null
    reply="$(run_job 'echo $MISE_SYNCED')"
    The contents of file "$reply/out" should equal "yes"
  End

  # The re-sync hook list is configurable via AI_ASSIST_ENV_HOOKS (option c).
  It 'honors AI_ASSIST_ENV_HOOKS as the env re-sync hook list'
    kill "$SHELL_PID" 2>/dev/null
    AI_ASSIST_SHELL_NO_INTERACTIVE=1 AI_ASSIST_ENV_HOOKS='export CUSTOM_HOOK=ran' "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" & SHELL_PID=$!
    run_job 'true' >/dev/null
    reply="$(run_job 'echo $CUSTOM_HOOK')"
    The contents of file "$reply/out" should equal "ran"
  End
End

# The zpty interactive backend (Stage 4: now the DEFAULT). The legacy
# AI_ASSIST_SHELL_INTERACTIVE=1 on the spawns below is an inert no-op kept for
# clarity — with no AI_ASSIST_SHELL_NO_INTERACTIVE=1 the controller picks zpty.
# Hosts a real login-interactive zsh inside zsh/zpty so the agent's shell mirrors
# the user's environment. It must satisfy every contract the eval-loop does, so the
# same core contracts run against it here. Determinism comes from a CONTROLLED
# ZDOTDIR: a temp .zshrc that defines a test function + alias (so `zsh -il` loads
# them fast — NOT the runner's real rc). The new interactive-env test confirms the
# hosted shell resolves that function and alias (not `command not found`).
Describe 'ai-assist-shell (zpty interactive backend)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-shell"

  setup() {
    TEST_TMP="$(mktemp -d)"
    # Controlled rc: a minimal .zshrc with a test function + alias, loaded by the
    # hosted `zsh -il` instead of the runner's heavy real rc.
    ZDOT="$TEST_TMP/zdot"; mkdir -p "$ZDOT"
    printf 'aas_testfn() { print -r -- FN_OK }\nalias aas_testalias='\''print -r -- ALIAS_OK'\''\n' > "$ZDOT/.zshrc"
    FIFO="$TEST_TMP/cmd.fifo"; mkfifo "$FIFO"
    ZDOTDIR="$ZDOT" AI_ASSIST_SHELL_INTERACTIVE=1 "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" &
    SHELL_PID=$!
  }
  cleanup() { kill "$SHELL_PID" 2>/dev/null; rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # The hosted shell is a real login zsh (slower seed than the eval-loop); allow a
  # generous bound so seeding + the job round-trip never races the assertion.
  run_job() {
    local reply; reply="$(mktemp -d "$TEST_TMP/reply.XXXXXX")"
    printf '%s\x1f%s\x1e' "$reply" "$1" > "$FIFO"
    local i=0; while [ ! -e "$reply/done" ] && [ $i -lt 600 ]; do sleep 0.02; i=$((i+1)); done
    printf '%s' "$reply"
  }
  run_job_id() {
    local reply id cmd; reply="$(mktemp -d "$TEST_TMP/reply.XXXXXX")"; id="$1"; cmd="$2"
    printf '%s\x1f%s\x1f%s\x1e' "$reply" "$id" "$cmd" > "$FIFO"
    local i=0; while [ ! -e "$reply/done" ] && [ $i -lt 600 ]; do sleep 0.02; i=$((i+1)); done
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

  # A command that fails WITHOUT calling `exit` must still report its non-zero code.
  It 'reports a non-zero exit for a failing command (not just exit N)'
    reply="$(run_job 'false')"
    The contents of file "$reply/exit" should equal "1"
  End

  # A later success in a multi-command block must not mask an earlier failure.
  It 'fails a multi-command block at the first failing command (set -e)'
    reply="$(run_job 'false
echo second')"
    The contents of file "$reply/exit" should equal "1"
  End

  # A block can opt out of a deliberate non-zero with `… || true`.
  It 'lets a block guard a deliberate non-zero (|| true)'
    reply="$(run_job 'false || true
echo ok')"
    The contents of file "$reply/exit" should equal "0"
  End

  # Benign SIGPIPE (producer killed by an early-closing `| head`) is success.
  It 'treats SIGPIPE as success (downstream closed early)'
    reply="$(run_job 'yes | head -5')"
    The contents of file "$reply/exit" should equal "0"
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

  It 'exposes AAS_OUT_<id> to a later job'
    run_job_id diag 'echo hello' >/dev/null
    reply="$(run_job 'printf %s "$AAS_OUT_diag"')"
    The contents of file "$reply/out" should equal "hello"
  End

  It 'seeds the environment from --env-file'
    envf="$TEST_TMP/env"; printf "export SEEDED=yes\n" > "$envf"
    kill "$SHELL_PID" 2>/dev/null
    ZDOTDIR="$ZDOT" AI_ASSIST_SHELL_INTERACTIVE=1 "$SCRIPT" --cmd-fifo "$FIFO" --env-file "$envf" --cwd "$TEST_TMP" & SHELL_PID=$!
    reply="$(run_job 'echo $SEEDED')"
    The contents of file "$reply/out" should equal "yes"
  End

  # Stage 3: a --shell-init dump (the captured live aliases/functions) is sourced
  # into the hosted login shell. Both a function AND an alias defined ONLY in the
  # dump must resolve in a job — proving the dump path end-to-end into the zpty
  # backend's real interactive shell.
  It 'seeds ad-hoc aliases/functions from --shell-init'
    initf="$TEST_TMP/init"
    printf 'aas_initfn() { print -r -- INITFN_OK }\nalias aas_initalias='\''print -r -- INITALIAS_OK'\''\n' > "$initf"
    kill "$SHELL_PID" 2>/dev/null
    ZDOTDIR="$ZDOT" AI_ASSIST_SHELL_INTERACTIVE=1 "$SCRIPT" --cmd-fifo "$FIFO" --shell-init "$initf" --cwd "$TEST_TMP" & SHELL_PID=$!
    reply="$(run_job 'aas_initfn')"
    The contents of file "$reply/out" should equal "INITFN_OK"
    reply2="$(run_job 'aas_initalias')"
    The contents of file "$reply2/out" should equal "INITALIAS_OK"
  End

  # The real execution timeout: a runaway command is interrupted and reported 124.
  It 'kills a job that overruns AI_ASSIST_RUN_TIMEOUT (exit 124)'
    kill "$SHELL_PID" 2>/dev/null
    ZDOTDIR="$ZDOT" AI_ASSIST_RUN_TIMEOUT=1 AI_ASSIST_SHELL_INTERACTIVE=1 "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" & SHELL_PID=$!
    reply="$(run_job 'sleep 5')"
    The contents of file "$reply/exit" should equal "124"
  End

  # The point of the interactive backend: the hosted login shell loads the user's
  # rc, so a function and an alias defined there RESOLVE (no 127/command not found).
  It 'resolves the interactive rc function and alias (not command not found)'
    reply="$(run_job 'aas_testfn; aas_testalias')"
    The contents of file "$reply/out" should equal "FN_OK
ALIAS_OK"
    The contents of file "$reply/exit" should equal "0"
  End

  # `exit 0` mid-block must STOP the block (not fall through). A plain
  # `return ${1:-0}` shadow would continue, since err_return only catches non-zero.
  It 'stops the block on exit 0 (does not run the rest)'
    reply="$(run_job 'echo a; exit 0; echo b')"
    The contents of file "$reply/out" should equal "a"
    The contents of file "$reply/exit" should equal "0"
  End

  # `exit N` mid-block stops the block AND records N as the exit code.
  It 'stops the block on exit N and records the code'
    reply="$(run_job 'echo a; exit 5; echo b')"
    The contents of file "$reply/out" should equal "a"
    The contents of file "$reply/exit" should equal "5"
  End

  # cd made BEFORE an exit still persists (anon function, no fork): a later job
  # sees the new cwd even though the earlier block exited early.
  It 'persists cd made before an exit'
    run_job 'cd /tmp; exit 3' >/dev/null
    reply="$(run_job 'pwd')"
    The contents of file "$reply/out" should equal "/tmp"
  End

  # Stop via the flag file: a long job whose $run_dir/<id>.stop appears mid-run is
  # interrupted with ^C and recorded as exit 143 (SIGTERM-class). The hosted shell
  # must SURVIVE and serve a following job (proving ^C only aborted the foreground
  # job, not the controller).
  It 'stops a running job via the stop flag (exit 143) and survives'
    rund="$TEST_TMP/run"; mkdir "$rund"
    kill "$SHELL_PID" 2>/dev/null
    ZDOTDIR="$ZDOT" AI_ASSIST_SHELL_INTERACTIVE=1 "$SCRIPT" --cmd-fifo "$FIFO" --cwd "$TEST_TMP" --run-dir "$rund" & SHELL_PID=$!
    # Submit a long job with an id, then touch the stop flag shortly after dispatch.
    stopdrive() {
      local reply; reply="$(mktemp -d "$TEST_TMP/reply.XXXXXX")"
      printf '%s\x1f%s\x1f%s\x1e' "$reply" "blkstop" "sleep 30" > "$FIFO"
      sleep 0.5
      : > "$rund/blkstop.stop"
      local i=0; while [ ! -e "$reply/done" ] && [ $i -lt 600 ]; do sleep 0.02; i=$((i+1)); done
      printf '%s' "$reply"
    }
    reply="$(stopdrive)"
    The contents of file "$reply/exit" should equal "143"
    # The hosted shell survived: a following job runs normally.
    reply2="$(run_job 'echo alive')"
    The contents of file "$reply2/out" should equal "alive"
    The contents of file "$reply2/exit" should equal "0"
  End
End
