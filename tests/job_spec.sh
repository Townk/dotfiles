# job.zsh — submission, the sidecar progress protocol, and cancel, against a
# recording fake pueue (JOB_PUEUE_BIN seam). Hermetic: JOB_STATE_ROOT lives
# in a sandbox and no real daemon is consulted.
Describe 'job.zsh'
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY NOTIFY_VIA_BRIDGE
    JOB_SANDBOX=$(mktemp -d)
    export JOB_STATE_ROOT="$JOB_SANDBOX/state"
    export JOB_FAKE_LOG="$JOB_SANDBOX/pueue.log"
    cat > "$JOB_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
[ -n "${JOB_FAKE_RC:-}" ] && exit "$JOB_FAKE_RC"
case "$1" in
  add) echo "7" ;;
  status) cat "${JOB_FAKE_STATUS:-/dev/null}" 2>/dev/null || :; [ -n "${JOB_FAKE_STATUS:-}" ] || echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$JOB_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$JOB_SANDBOX/pueue"
  }
  cleanup() { rm -rf "$JOB_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # -f: this repo's ~/.zshenv would re-export XDG vars over the sandbox.
  run_job() {
    zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift; "$@"' \
      -- "$JOBLIB" "$@"
  }

  Describe 'job::start'
    It 'prints an id, writes meta.json, and enqueues a labeled quoted command'
      started() {
        id=$(run_job job::start --group heavy --title "Build X" \
          --icon "glyph:nf-md-wrench" -- echo "a b") || return 1
        dir="$JOB_STATE_ROOT/$id"
        [ -f "$dir/meta.json" ] || return 2
        # The enqueued command line must carry JOB_ID=<the id THIS run
        # produced> — checked and folded into a stable yes/no here rather
        # than re-deriving the id from $(ls "$JOB_STATE_ROOT") at assertion
        # time, which is fragile (ordering/timing) once more than one job
        # dir could ever exist.
        local job_id_match="no"
        grep -q "JOB_ID=$id" "$JOB_FAKE_LOG" && job_id_match="yes"
        printf '%s|%s|%s|%s|%s' \
          "$(jq -r .title "$dir/meta.json")" \
          "$(jq -r .pueue_id "$dir/meta.json")" \
          "$(jq -r .progress "$dir/meta.json")" \
          "$(grep -c "add --group heavy --label job:$id" "$JOB_FAKE_LOG" | tr -d '\n')" \
          "$job_id_match"
      }
      When call started
      The output should equal 'Build X|7|expected|1|yes'
    End

    It 'defaults the title to the command and the group to default'
      titled() {
        id=$(run_job job::start -- sleep 5) || return 1
        printf '%s|%s' \
          "$(jq -r .title "$JOB_STATE_ROOT/$id/meta.json")" \
          "$(jq -r .group "$JOB_STATE_ROOT/$id/meta.json")"
      }
      When call titled
      The output should equal 'sleep|default'
    End

    It 'creates the heavy group before enqueueing into it'
      grouped() {
        run_job job::start --group heavy -- true >/dev/null || return 1
        # group add first, then the parallelism pin, then the add.
        awk '{print $1, $2}' "$JOB_FAKE_LOG" | paste -sd'|' -
      }
      When call grouped
      The output should equal 'group add|parallel 1|add --group'
    End

    It 'dies loudly naming the service when pueued is unreachable'
      down() { JOB_FAKE_RC=1 run_job job::start -- true; }
      leftover() { ls "$JOB_STATE_ROOT" 2>/dev/null; }
      When call down
      The status should equal 1
      The stderr should include "system-service start pueued"
      # The half-created job dir must not survive a failed submit.
      The result of function leftover should equal ""
    End
  End

  Describe 'job::progress'
    It 'atomically rewrites the single-line sidecar'
      prog() {
        id=$(run_job job::start -- true) || return 1
        JOB_ID="$id" run_job job::progress 40 "step two" || return 2
        line="$(cat "$JOB_STATE_ROOT/$id/progress")"
        # <epoch> <pct> <message>
        printf '%s' "$line" | sed 's/^[0-9][0-9]* //'
      }
      When call prog
      The output should equal '40 step two'
    End

    It 'accepts -1 as indeterminate'
      indet() {
        id=$(run_job job::start -- true) || return 1
        JOB_ID="$id" run_job job::progress -1 "preparing" || return 2
        sed 's/^[0-9][0-9]* //' "$JOB_STATE_ROOT/$id/progress"
      }
      When call indet
      The output should equal '-1 preparing'
    End

    It 'returns 1 with no JOB_ID in the environment'
      When call run_job job::progress 10 "orphan"
      The status should equal 1
    End
  End

  Describe 'job::cancel'
    It 'kills the recorded pueue task id'
      cancel() {
        id=$(run_job job::start -- sleep 99) || return 1
        run_job job::cancel "$id" || return 2
        grep -c '^kill 7$' "$JOB_FAKE_LOG"
      }
      When call cancel
      The output should equal '1'
    End
  End

  Describe 'job::list'
    It 'merges meta, sidecar line, done flag, and pueue status'
      listed() {
        id=$(run_job job::start --title "T" -- true) || return 1
        JOB_ID="$id" run_job job::progress 30 "warming" || return 2
        printf '%s\n' '{"tasks":{}}' > "$JOB_SANDBOX/status.json"
        export JOB_FAKE_STATUS="$JOB_SANDBOX/status.json"
        out=$(run_job job::list) || return 3
        printf '%s|%s|%s' \
          "$(printf '%s' "$out" | jq -r '.jobs[0].title')" \
          "$(printf '%s' "$out" | jq -r '.jobs[0].progress_line' | sed 's/^[0-9]* //')" \
          "$(printf '%s' "$out" | jq -r '.jobs[0].done')"
      }
      When call listed
      The output should equal 'T|30 warming|false'
    End

    It 'flags a job with a result file as done'
      done_flag() {
        id=$(run_job job::start -- true) || return 1
        printf '1 Success 0\n' > "$JOB_STATE_ROOT/$id/result"
        run_job job::list | jq -r '.jobs[0].done'
      }
      When call done_flag
      The output should equal 'true'
    End
  End

  Describe 'job::hud'
    It 'sends one require("jobs") call through hs'
      hud() {
        mkdir -p "$JOB_SANDBOX/bin"
        cat > "$JOB_SANDBOX/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$JOB_SANDBOX/hs.log"
EOF
        chmod +x "$JOB_SANDBOX/bin/hs"
        HS="$JOB_SANDBOX/bin/hs" run_job job::hud show || return 1
        cat "$JOB_SANDBOX/hs.log"
      }
      When call hud
      The output should equal '-q -c require("jobs").show()'
    End
  End

  Describe 'libexec/job front-end'
    JOBBIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_job"
    It 'dispatches verbs to the library'
      When call zsh -f "$JOBBIN" start --title "Via CLI" -- true
      The status should equal 0
      The output should match pattern '*-*'
    End
    It 'rejects unknown verbs with usage'
      When call zsh -f "$JOBBIN" frobnicate
      The status should equal 1
      The stderr should include 'usage: job'
    End
  End
End
