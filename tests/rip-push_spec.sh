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

  It 'worker streams progress into the job sidecar'
    mkdir -p "$RIP_STAGING_ROOT/music/B/Alb"; touch "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
case "$*" in
  *-rcn*) exit 0 ;;   # verify pass: no differences
  *)
    printf 'B/Alb/01 T.flac\n'
    printf '      1,000  50%%   1.2MB/s  0:00:01\r'
    printf '      2,000 100%%   1.2MB/s  0:00:00 (xfr#1, to-chk=0/1)\n'
    exit 0 ;;
esac
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    export JOB_ID="job-test-1"
    mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include "100"
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include "01 T.flac"
  End

  It 'worker propagates rsync failure'
    mkdir -p "$RIP_STAGING_ROOT/music/B/Alb"; touch "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    printf '#!/bin/sh\nexit 23\n' > "$RIP_SANDBOX/rsync"; chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 23
    The stderr should include "rip"
    The path "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac" should be exist
  End
End
