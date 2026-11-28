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
    export NOTIFY_TMUX_BIN="$CB_SANDBOX/tmux"
    # History + the unacked ledger land in the sandbox too.
    export NOTIFY_HISTORY_FILE="$CB_SANDBOX/history.jsonl"
    export NOTIFY_UNACKED_FILE="$CB_SANDBOX/unacked"
  }
  cleanup() { rm -rf "$CB_SANDBOX"; unset JOB_TMUX_BIN NOTIFY_TMUX_BIN NOTIFY_HISTORY_FILE NOTIFY_UNACKED_FILE CB_SANDBOX_TMUX_LOG; }
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

  # A job with a live follower in a Rex tab is announced by Rex itself (the
  # follower's status report raises the notification, and clicking it opens
  # the tab), so the callback only records it. Measured 2026-11-27: Rex shows
  # a banner unless Rex is the app in front, where it plays its sound and
  # badges the tab instead.
  followed() {  # followed <id> <block> — a live follower for the job
    # A process that stays until it is killed, with no clock in it.
    tail -f /dev/null &
    FOLLOWER_PID=$!
    print -r -- "$2 $FOLLOWER_PID" > "$JOB_STATE_ROOT/$1/follower"
  }

  It 'leaves a success to Rex when the job has a tab there, but records it'
    rex_success() {
      id=$(seed) || return 1
      followed "$id" block:tab
      zsh -f "$CALLBACK" 7 "Success" 0 || return 2
      kill $FOLLOWER_PID 2>/dev/null
      printf '%s|%s|%s' \
        "$(cat "$CB_SANDBOX/hs.log" 2>/dev/null | grep -c 'completed' || true)" \
        "$(jq -r '.text' "$NOTIFY_HISTORY_FILE")" \
        "$(sed 's/^[0-9]* //' "$JOB_STATE_ROOT/$id/result")"
    }
    When call rex_success
    The output should equal '0|Build X completed|Success 0'
  End

  It 'leaves a failure to Rex too: no toast, no persistent notification, still acknowledgable'
    rex_failure() {
      id=$(seed) || return 1
      followed "$id" block:tab
      zsh -f "$CALLBACK" 7 "Failed(2)" 2 || return 2
      kill $FOLLOWER_PID 2>/dev/null
      printf '%s|%s|%s' \
        "$(cat "$CB_SANDBOX/hs.log" 2>/dev/null | grep -c . || true)" \
        "$(jq -r '[.text, (.ack|tostring)] | join(" ack=")' "$NOTIFY_HISTORY_FILE")" \
        "$([[ -s "$NOTIFY_UNACKED_FILE" ]] && print ledger)"
    }
    When call rex_failure
    The output should equal '0|Build X failed (exit 2) ack=true|ledger'
  End

  It 'still notifies itself when the follower is dead'
    dead_follower() {
      id=$(seed) || return 1
      print -r -- "block:tab 999999" > "$JOB_STATE_ROOT/$id/follower"
      zsh -f "$CALLBACK" 7 "Success" 0 || return 2
      grep -c 'completed' "$CB_SANDBOX/hs.log"
    }
    When call dead_follower
    The output should equal '1'
  End

  It 'still notifies itself for a follower that is not in a Rex tab'
    inline_follower() {
      id=$(seed) || return 1
      followed "$id" -
      zsh -f "$CALLBACK" 7 "Failed(2)" 2 || return 2
      kill $FOLLOWER_PID 2>/dev/null
      grep -c 'hs.notify.new' "$CB_SANDBOX/hs.log"
    }
    When call inline_follower
    The output should equal '1'
  End

  It 'falls back to a generic title for tasks pueue ran outside job::start'
    unlabeled() { zsh -f "$CALLBACK" 99 "Success" 0; cat "$CB_SANDBOX/hs.log"; }
    When call unlabeled
    The status should equal 0
    The output should include 'Task 99'
  End

  It 'prunes finished job dirs beyond JOB_KEEP, never active ones'
    prune() {
      # No pause between the seeds: a job id is the start time in
      # microseconds, so three seeds in a row are already in order by name.
      a=$(seed) || return 1
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

  # The callback repairs the Jobs session after a Rex restart: a restored
  # bare shell no follower names is closed. A fake rex (JOB_REX_BIN) with a
  # Jobs session holding one such block; JOB_FAKE_REX_RC makes every call
  # fail instead.
  Describe 'the Rex reconcile'
    fake_rex() {
      export JOB_FAKE_REX_LOG="$CB_SANDBOX/rex.log"
      cat > "$CB_SANDBOX/rex" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_REX_LOG"
[ -n "${JOB_FAKE_REX_RC:-}" ] && exit "$JOB_FAKE_REX_RC"
case "$*" in
  *' block ls '*) echo '{"blocks":[{"block_id":"block:b9","label":"shell"}]}' ;;
  *' ls --json'*) echo '{"sessions":[{"session_id":"session:jobs","label":"Jobs"}]}' ;;
esac
exit 0
EOF
      chmod +x "$CB_SANDBOX/rex"
      export JOB_REX_BIN="$CB_SANDBOX/rex"
    }

    It 'closes a Jobs tab no follower names'
      reconciled() {
        id=$(seed) || return 1
        fake_rex
        zsh -f "$CALLBACK" 7 "Success" 0 || return 2
        grep -c ' block close -s Jobs block:b9$' "$JOB_FAKE_REX_LOG"
      }
      When call reconciled
      The output should equal 1
    End

    It 'still exits 0 and records the result when rex fails'
      failing() {
        id=$(seed) || return 1
        fake_rex
        JOB_FAKE_REX_RC=4 zsh -f "$CALLBACK" 7 "Success" 0
        echo "rc=$? asked=$(grep -c ' ls --json' "$JOB_FAKE_REX_LOG")"
        sed 's/^[0-9]* //' "$JOB_STATE_ROOT/$id/result"
      }
      When call failing
      The output should equal "rc=0 asked=1
Success 0"
    End
  End

  # phase 4: the --notify meta gates the callback's toasts.
  Describe 'the --notify gate'
    seed_notify() {  # <mode>
      zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift
                 job::start --notify "$1" --title "Quiet X" -- true' \
        -- "$JOBLIB" "$1"
    }

    It 'failures: Success and Killed stay silent, the failure toast fires'
      quiet_flow() {
        seed_notify failures >/dev/null || return 1
        zsh -f "$CALLBACK" 7 "Success" 0 || return 2
        seed_notify failures >/dev/null || return 3
        zsh -f "$CALLBACK" 7 "Killed" "" || return 4
        seed_notify failures >/dev/null || return 5
        zsh -f "$CALLBACK" 7 "Failed" 2 || return 6
        printf '%s|%s|%s' \
          "$(grep -c 'completed' "$CB_SANDBOX/hs.log" || :)" \
          "$(grep -c 'cancelled' "$CB_SANDBOX/hs.log" || :)" \
          "$(grep -c 'failed' "$CB_SANDBOX/hs.log" || :)"
      }
      When call quiet_flow
      The output should equal '0|0|2'
    End

    It 'none: even the failure stays silent; result + resync still happen'
      silent_fail() {
        seed_notify none >/dev/null || return 1
        id=$(ls -t "$JOB_STATE_ROOT" | head -1)
        zsh -f "$CALLBACK" 7 "Failed" 2 || return 2
        printf '%s|%s|%s' \
          "$([ -e "$CB_SANDBOX/hs.log" ] && wc -l < "$CB_SANDBOX/hs.log" | tr -d ' ' || echo 0)" \
          "$([ -e "$JOB_STATE_ROOT/$id/result" ] && echo result || echo none)" \
          "$(grep -cF 'refresh-client -S' "$CB_SANDBOX/tmux.log")"
      }
      When call silent_fail
      The output should equal '0|result|2'
    End
  End

  # phase 3 UI rev: a failure is an ACK-ABLE toast — notify --ack feeds
  # the unacked ledger (the bar's bell element); the callback itself only
  # forces repaints at transitions.
  Describe 'the acknowledgable-failure side'
    It 'a Failed result appends to the unacked ledger with ack:true history'
      failed_ack() {
        seed >/dev/null || return 1
        zsh -f "$CALLBACK" 7 "Failed" 2 || return 2
        printf '%s|%s' \
          "$(wc -l < "$NOTIFY_UNACKED_FILE" | tr -d ' ')" \
          "$(tail -n 1 "$NOTIFY_HISTORY_FILE" | jq -r '.ack')"
      }
      When call failed_ack
      The output should equal '1|true'
    End

    It 'Success and Killed stay non-acknowledgable'
      clean_results() {
        seed >/dev/null || return 1
        zsh -f "$CALLBACK" 7 "Success" 0 || return 2
        seed >/dev/null || return 3
        zsh -f "$CALLBACK" 7 "Killed" "" || return 4
        printf '%s|%s' \
          "$([ -e "$NOTIFY_UNACKED_FILE" ] && echo present || echo absent)" \
          "$(jq -rs 'map(.ack) | unique | join(",")' "$NOTIFY_HISTORY_FILE")"
      }
      When call clean_results
      The output should equal 'absent|false'
    End

    It 'the failure toast carries the job meta into the history'
      failed_history() {
        seed >/dev/null || return 1
        zsh -f "$CALLBACK" 7 "Failed" 2 || return 2
        tail -n 1 "$NOTIFY_HISTORY_FILE" | jq -r '[.kind, (.meta.pueue_id|tostring), .meta.result] | join("|")'
      }
      When call failed_history
      The output should equal 'job|7|Failed'
    End
  End
End
