# job/follow.zsh — the OSC 7501 status report for a job's state. Hermetic:
# JOB_STATE_ROOT lives in a sandbox; job state dirs are written directly.
Describe 'job/follow.zsh'
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    JOB_SANDBOX=$(mktemp -d)
    export JOB_STATE_ROOT="$JOB_SANDBOX/state"
    cat > "$JOB_SANDBOX/pueue" <<'EOS'
#!/bin/sh
exit 0
EOS
    chmod +x "$JOB_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$JOB_SANDBOX/pueue"
    mkdir -p "$JOB_STATE_ROOT/j1"
  }
  cleanup() { rm -rf "$JOB_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # -f: this repo's ~/.zshenv would re-export XDG vars over the sandbox.
  run_job() {
    zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift; "$@"' \
      -- "$JOBLIB" "$@"
  }
  b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  meta() { printf '{"title":"%s","notify":"%s"}\n' "$1" "${2:-all}" > "$JOB_STATE_ROOT/j1/meta.json"; }
  report() { run_job job::_follow_report j1 "$1"; }

  Describe 'job::_follow_report'
    It 'reports a queued job'
      meta "Remux"
      When call report queued
      The output should equal "state=working:app=job:msg=$(b64 queued)"
    End

    It 'reports progress with a percentage'
      meta "Remux"
      echo "1700000000 40 remuxing" > "$JOB_STATE_ROOT/j1/progress"
      When call report running
      The output should equal "state=working:app=job:progress=40:msg=$(b64 remuxing)"
    End

    It 'omits progress when indeterminate'
      meta "Remux"
      echo "1700000000 -1 scanning files" > "$JOB_STATE_ROOT/j1/progress"
      When call report running
      The output should equal "state=working:app=job:msg=$(b64 'scanning files')"
    End

    It 'prefixes the message while waiting'
      meta "Remux"
      echo "1700000000 -1 for disk" > "$JOB_STATE_ROOT/j1/progress"
      echo waiting > "$JOB_STATE_ROOT/j1/phase"
      When call report running
      The output should equal "state=working:app=job:msg=$(b64 'waiting: for disk')"
    End

    It 'reports success as done'
      meta "Remux"
      echo "1700000000 Success 0" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal "state=done:app=job:msg=$(b64 'Remux completed')"
    End

    It 'stays silent on success when notify is failures'
      meta "Remux" failures
      echo "1700000000 Success 0" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal ""
    End

    It 'stays silent when the job was killed'
      meta "Remux"
      echo "1700000000 Killed 137" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal ""
    End

    It 'reports a failure with its exit code'
      meta "Remux"
      echo "1700000000 Failed 2" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal "state=error:app=job:msg=$(b64 'Remux failed (exit 2)')"
    End

    It 'reports a failure without an exit code'
      meta "Remux"
      echo "1700000000 Failed" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal "state=error:app=job:msg=$(b64 'Remux failed')"
    End

    It 'falls back to the title before any progress exists'
      meta "Remux"
      When call report running
      The output should equal "state=working:app=job:msg=$(b64 Remux)"
    End

    It 'sanitizes a message Rex would reject'
      long() { printf 'a%.0s' $(seq 3000); }
      meta "Remux"
      printf '1700000000 -1 line1\nline2\tx%s\n' "$(long)" > "$JOB_STATE_ROOT/j1/progress"
      check() {
        local body decoded
        body=$(report running) || return 1
        decoded=$(printf '%s' "${body##*msg=}" | base64 -D | LC_ALL=C tr -d '\040-\176')
        # decoded now holds only bytes outside printable ASCII: must be empty
        [ -z "$decoded" ] || { echo "bad bytes"; return 0; }
        local n
        n=$(printf '%s' "${body##*msg=}" | base64 -D | wc -c | tr -d ' ')
        [ "$n" -le 2048 ] && echo ok || echo "too long $n"
      }
      When call check
      The output should equal ok
    End

    It 'cuts on a character boundary'
      meta "Remux"
      printf '1700000000 -1 %s\n' "$(printf 'é%.0s' $(seq 1500))" > "$JOB_STATE_ROOT/j1/progress"
      check() {
        local body
        body=$(report running) || return 1
        printf '%s' "${body##*msg=}" | base64 -D | iconv -f UTF-8 -t UTF-8 >/dev/null && echo valid
      }
      When call check
      The output should equal valid
    End
  End

  Describe 'job::_follow_emit'
    It 'wraps the body in one OSC 7501 sequence'
      emit() { run_job job::_follow_emit "state=working:app=job" | od -An -c | tr -d ' \n'; }
      When call emit
      The output should equal '033]7501;state=working:app=job033\'
    End
  End
End
