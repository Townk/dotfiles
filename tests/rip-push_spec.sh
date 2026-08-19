# rip-push — enqueue validation, skip-if-empty, worker transfer/verify/delete.
# Hermetic: sandboxed staging + JOB_STATE_ROOT, recording fake pueue
# (JOB_PUEUE_BIN) and fake rsync (RIP_RSYNC_BIN). No ssh, no daemon.
Describe 'rip.zsh push'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    RIP_SANDBOX=$(mktemp -d)
    export RIP_STAGING_ROOT="$RIP_SANDBOX/Rips"
    export RIP_REMOTE_BASE="$RIP_SANDBOX/server"
    export JOB_STATE_ROOT="$RIP_SANDBOX/state"
    export JOB_FAKE_LOG="$RIP_SANDBOX/pueue.log"
    mkdir -p "$RIP_STAGING_ROOT/movies" "$RIP_STAGING_ROOT/music" \
             "$RIP_SANDBOX/server/movies" "$RIP_SANDBOX/server/music"
    cat > "$RIP_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in add) echo "7" ;; esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$RIP_SANDBOX/pueue"
    # the bins under test must source the SOURCE-TREE lib, not ~/.local/lib
    export RIP_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
  }
  cleanup() { rm -rf "$RIP_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # titles() — read every enqueued job's title straight from its meta.json
  # (job::start writes the title THERE, never onto pueue's argv — pueue only
  # ever sees `--group <G> --label job:<id>` and the sh-quoted command line).
  titles() { cat "$JOB_STATE_ROOT"/*/meta.json 2>/dev/null; }

  It 'rejects an unknown type'
    When run zsh -c "source $RIPLIB && rip::push_enqueue books"
    The status should equal 2
    The stderr should include "unknown type"
  End

  It 'skips an empty type without enqueuing'
    When run zsh -c "source $RIPLIB && rip::push_enqueue movies"
    The status should equal 0
    The output should include "nothing to push"
    The path "$JOB_FAKE_LOG" should not be exist
  End

  It 'enqueues a transfer-group job for staged files'
    mkdir -p "$RIP_STAGING_ROOT/movies/A (2001)"
    touch "$RIP_STAGING_ROOT/movies/A (2001)/A (2001).mkv"
    When run zsh -c "source $RIPLIB && rip::push_enqueue movies"
    The status should equal 0
    The output should not equal ""
    The contents of file "$JOB_FAKE_LOG" should include "--group transfer"
    The result of function titles should include "rip push: movies"
    The contents of file "$JOB_FAKE_LOG" should include "--worker movies"
  End

  It 'no-arg CLI enqueues both populated types'
    mkdir -p "$RIP_STAGING_ROOT/movies/A (2001)" "$RIP_STAGING_ROOT/music/B/Alb"
    touch "$RIP_STAGING_ROOT/movies/A (2001)/A (2001).mkv" \
          "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-push"
    The status should equal 0
    The output should not equal ""
    The result of function titles should include "rip push: movies"
    The result of function titles should include "rip push: music"
  End
End
