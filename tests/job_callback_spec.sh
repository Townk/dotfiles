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
  }
  cleanup() { rm -rf "$CB_SANDBOX"; }
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
End
