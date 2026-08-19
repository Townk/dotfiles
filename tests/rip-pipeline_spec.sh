# rip-pipeline — encode → push → verify → cleanup as one job body.
# Fake HandBrakeCLI (RIP_HANDBRAKE_BIN) + fake rsync (RIP_RSYNC_BIN);
# hermetic sandbox, no real encoder/daemon/ssh.
Describe 'rip.zsh pipeline'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    RIP_SANDBOX=$(mktemp -d)
    export RIP_STAGING_ROOT="$RIP_SANDBOX/Rips"
    export RIP_REMOTE_BASE="$RIP_SANDBOX/server"
    export JOB_STATE_ROOT="$RIP_SANDBOX/state"
    export JOB_FAKE_LOG="$RIP_SANDBOX/pueue.log"
    mkdir -p "$RIP_STAGING_ROOT/intermediate" "$RIP_STAGING_ROOT/movies" \
             "$RIP_SANDBOX/server/movies"
    printf 'raw' > "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv"
    cat > "$RIP_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in add) echo "7" ;; esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$RIP_SANDBOX/pueue"
    # fake HandBrakeCLI: emits CR-separated progress, writes the -o target
    cat > "$RIP_SANDBOX/HandBrakeCLI" <<'EOF'
#!/bin/sh
out=""
prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "${RIP_FAKE_HB_RC:-}" ] && exit "$RIP_FAKE_HB_RC"
printf 'Encoding: task 1 of 1, 42.50 %%\r'
printf 'Encoding: task 1 of 1, 100.00 %%\n'
printf 'encoded' > "$out"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/HandBrakeCLI"
    export RIP_HANDBRAKE_BIN="$RIP_SANDBOX/HandBrakeCLI"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
case "$*" in *-rcn*) exit "${RIP_FAKE_VERIFY_RC:-0}" ;; *) exit "${RIP_FAKE_RSYNC_RC:-0}" ;; esac
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
  }
  cleanup() { rm -rf "$RIP_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # titles() — read every enqueued job's title straight from its meta.json
  # (job::start writes the title THERE, never onto pueue's argv — pueue only
  # ever sees `--group <G> --label job:<id>` and the sh-quoted command line).
  titles() { cat "$JOB_STATE_ROOT"/*/meta.json 2>/dev/null; }

  It 'happy path: encodes, pushes, cleans intermediate and encode'
    export JOB_ID="job-pl-1"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::pipeline_worker '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A Movie (2001)'"
    The status should equal 0
    The output should include "verified"
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should not be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)" should not be exist
  End

  It 'names the encode movies/<Title>/<Title>.mkv (visible on push failure)'
    export RIP_FAKE_RSYNC_RC=23
    When run zsh -c "source $RIPLIB && rip::pipeline_worker '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A Movie (2001)'"
    The status should equal 23
    The stderr should include "rip"
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/A Movie (2001).mkv" should be exist
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should be exist
  End

  It 'encode failure keeps the intermediate and skips the push'
    export RIP_FAKE_HB_RC=1
    When run zsh -c "source $RIPLIB && rip::pipeline_worker '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A Movie (2001)'"
    The status should equal 1
    The stderr should include "encode failed"
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/A Movie (2001).mkv" should not be exist
  End

  It 'verify failure keeps intermediate and encode'
    export RIP_FAKE_VERIFY_RC=1
    When run zsh -c "source $RIPLIB && rip::pipeline_worker '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A Movie (2001)'"
    The status should equal 1
    The stderr should include "verify"
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/A Movie (2001).mkv" should be exist
  End

  It 'rejects a title containing a slash'
    When run zsh -c "source $RIPLIB && rip::pipeline_worker '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A/B (2001)'"
    The status should equal 2
    The stderr should include "title"
  End

  It 'enqueue lands in the heavy group with the movie title'
    When run zsh -c "source $RIPLIB && rip::pipeline_enqueue '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A Movie (2001)'"
    The status should equal 0
    The output should not equal ""
    The contents of file "$JOB_FAKE_LOG" should include "--group heavy"
    The result of function titles should include "rip: A Movie (2001)"
    The contents of file "$JOB_FAKE_LOG" should include "--worker"
  End
End
