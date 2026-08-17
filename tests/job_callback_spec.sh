# job-callback — the pueue daemon's completion hook. Branches on the result
# (Success / Killed / anything else), writes the job's result file, and
# prunes old finished jobs. The hs CLI is a recording stub: which Lua call
# crossed is the observable. Hermetic: no SSH routing, sandboxed state.
Describe 'job-callback'
  CALLBACK="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_job-callback"
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY NOTIFY_VIA_BRIDGE
    CB_SANDBOX=$(mktemp -d)
    export JOB_STATE_ROOT="$CB_SANDBOX/state"
    export XDG_CACHE_HOME="$CB_SANDBOX/cache"
    mkdir -p "$CB_SANDBOX/bin"
    cat > "$CB_SANDBOX/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CB_SANDBOX/hs.log"
EOF
    chmod +x "$CB_SANDBOX/bin/hs"
    export HS="$CB_SANDBOX/bin/hs"
    export JOB_FAKE_LOG="$CB_SANDBOX/pueue.log"
    cat > "$CB_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in add) echo "7" ;; esac
EOF
    chmod +x "$CB_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$CB_SANDBOX/pueue"
    # Fake tmux (JOB_TMUX_BIN): the callback's @jobs statusbar sync must
    # never reach the live server from the suite.
    cat > "$CB_SANDBOX/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CB_SANDBOX_TMUX_LOG"
exit 0
EOF
    chmod +x "$CB_SANDBOX/tmux"
    export CB_SANDBOX_TMUX_LOG="$CB_SANDBOX/tmux.log"
    export JOB_TMUX_BIN="$CB_SANDBOX/tmux"
    # History lands in the sandbox too (notify's phase-3 append).
    export NOTIFY_HISTORY_FILE="$CB_SANDBOX/history.jsonl"
  }
  cleanup() { rm -rf "$CB_SANDBOX"; unset JOB_TMUX_BIN NOTIFY_HISTORY_FILE CB_SANDBOX_TMUX_LOG; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Seed one job dir the way job::start would (pueue_id 7).
  seed() {
    zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift
               job::start --title "Build X" --icon "glyph:nf-md-wrench" -- true' \
      -- "$JOBLIB"
  }

  It 'toasts success with a sound and writes the result file'
    success() {
      id=$(seed) || return 1
      zsh -f "$CALLBACK" 7 "Success" 0 || return 2
      printf '%s|%s' \
        "$(grep -c 'completed' "$CB_SANDBOX/hs.log")" \
        "$(sed 's/^[0-9]* //' "$JOB_STATE_ROOT/$id/result")"
    }
    When call success
    The output should equal '1|Success 0'
    # Success carries a sound; the exact Lua call includes "Glass".
    The contents of file "$CB_SANDBOX/hs.log" should include 'Glass'
  End

  It 'treats Killed as a quiet cancel — no sound, no failure wording'
    killed() {
      id=$(seed) || return 1
      zsh -f "$CALLBACK" 7 "Killed" "" || return 2
      cat "$CB_SANDBOX/hs.log"
    }
    When call killed
    The output should include 'cancelled'
    The output should not include 'Glass'
    The output should not include 'failed'
    The output should not include 'hs.notify'
  End

  It 'pairs a failure toast with a persistent notification'
    failed() {
      id=$(seed) || return 1
      zsh -f "$CALLBACK" 7 "Failed(2)" 2 || return 2
      cat "$CB_SANDBOX/hs.log"
    }
    When call failed
    The output should include 'failed'
    The output should include 'hs.notify.new'
    The output should include 'withdrawAfter=0'
  End

  It 'falls back to a generic title for tasks pueue ran outside job::start'
    unlabeled() { zsh -f "$CALLBACK" 99 "Success" 0; cat "$CB_SANDBOX/hs.log"; }
    When call unlabeled
    The status should equal 0
    The output should include 'Task 99'
  End

  It 'prunes finished job dirs beyond JOB_KEEP, never active ones'
    prune() {
      a=$(seed) || return 1
      sleep 1
      b=$(seed) || return 1
      printf '1 Success 0\n' > "$JOB_STATE_ROOT/$a/result"
      active=$(seed) || return 1
      JOB_KEEP=1 zsh -f "$CALLBACK" 7 "Success" 0 || return 2
      # b just finished (kept, newest); a's older result pruned; active kept.
      printf '%s|%s|%s' \
        "$([ -d "$JOB_STATE_ROOT/$a" ] && echo kept || echo pruned)" \
        "$([ -d "$JOB_STATE_ROOT/$b" ] && echo kept || echo pruned)" \
        "$([ -d "$JOB_STATE_ROOT/$active" ] && echo kept || echo pruned)"
    }
    When call prune
    The output should equal 'pruned|kept|kept'
  End

  # Regression (Mode B 2026-08-15): a job whose task died with the daemon
  # never gets a result file, so the result-keyed prune above never touched
  # it — the dir leaked forever and the HUD resurrected it as a frozen
  # ghost capsule on every re-arm. The callback now sweeps result-less dirs
  # whose meta.json is a day stale; fresh active dirs stay.
  It 'sweeps day-stale result-less dirs, keeps fresh active ones'
    sweep() {
      ghost=$(seed) || return 1
      sleep 1
      fresh=$(seed) || return 1
      touch -t 202001010000 "$JOB_STATE_ROOT/$ghost/meta.json" || return 2
      zsh -f "$CALLBACK" 99 "Success" 0 || return 3
      printf '%s|%s' \
        "$([ -d "$JOB_STATE_ROOT/$ghost" ] && echo kept || echo swept)" \
        "$([ -d "$JOB_STATE_ROOT/$fresh" ] && echo kept || echo swept)"
    }
    When call sweep
    The output should equal 'swept|kept'
  End

  # phase 3 (spec §8): the unseen-failures ledger + the statusbar resync.
  Describe 'the @jobs statusbar side'
    It 'a Failed result appends one ledger line and resyncs the badge'
      failed_ledger() {
        seed >/dev/null || return 1
        zsh -f "$CALLBACK" 7 "Failed" 2 || return 2
        printf '%s|%s' \
          "$(wc -l < "$JOB_STATE_ROOT/.failed-unseen" | tr -d ' ')" \
          "$(grep -cF 'set -g @jobs' "$CB_SANDBOX/tmux.log")"
      }
      When call failed_ledger
      # 2 syncs: one from the seed's job::start, one from the callback.
      The output should equal '1|2'
    End

    It 'Success and Killed leave the ledger untouched but still resync'
      clean_results() {
        seed >/dev/null || return 1
        zsh -f "$CALLBACK" 7 "Success" 0 || return 2
        seed >/dev/null || return 3
        zsh -f "$CALLBACK" 7 "Killed" "" || return 4
        printf '%s|%s' \
          "$([ -e "$JOB_STATE_ROOT/.failed-unseen" ] && echo present || echo absent)" \
          "$(grep -cF 'set -g @jobs' "$CB_SANDBOX/tmux.log")"
      }
      When call clean_results
      # 4 syncs: two seeds' job::start + two callbacks.
      The output should equal 'absent|4'
    End

    It 'the failure toast carries the job meta into the history'
      failed_history() {
        seed >/dev/null || return 1
        zsh -f "$CALLBACK" 7 "Failed" 2 || return 2
        tail -n 1 "$NOTIFY_HISTORY_FILE" | jq -r '[.kind, .meta.pueue_id, .meta.result] | join("|")'
      }
      When call failed_history
      The output should equal 'job|7|Failed'
    End
  End
End
