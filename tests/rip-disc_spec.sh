# rip-disc — makemkvcon auto-rip chained into the pipeline, one capsule.
Describe 'rip.zsh disc'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    RIP_SANDBOX=$(mktemp -d)
    export RIP_STAGING_ROOT="$RIP_SANDBOX/Rips"
    export RIP_REMOTE_BASE="$RIP_SANDBOX/server"
    export JOB_STATE_ROOT="$RIP_SANDBOX/state"
    export JOB_FAKE_LOG="$RIP_SANDBOX/pueue.log"
    export RIP_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export RIP_PUSH_MIN_AGE_S=0
    # No real pty in the fake harness — it isn't buffered, so it needs no
    # help staying line-buffered, and shellspec's own sandboxing has no
    # reason to fight a real `script` invocation on every run.
    export RIP_PTY_WRAP=""
    mkdir -p "$RIP_STAGING_ROOT/movies" "$RIP_SANDBOX/server/movies"
    cat > "$RIP_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in add) echo "7" ;; esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/pueue"; export JOB_PUEUE_BIN="$RIP_SANDBOX/pueue"
    # fake makemkvcon: `-r info` prints two titles (idx 0 short, idx 1 long);
    # `mkv` emits PRGV progress and drops a file in the target dir
    cat > "$RIP_SANDBOX/makemkvcon" <<'EOF'
#!/bin/sh
case "$*" in
  *info*)
    echo 'TINFO:0,9,0,"0:00:38"'
    echo 'TINFO:1,9,0,"2:08:59"'
    ;;
  *mkv*)
    dir=""
    for a in "$@"; do dir="$a"; done
    # CR-terminated, mimicking a real pty's ONLCR translation (\n -> \r\n)
    # — the fix under test has to tolerate that, not just a bare \n. Always
    # emitted first (even ahead of a forced failure below) so the
    # CR-tolerance example can see a genuine mid-rip percentage rather than
    # nothing at all.
    printf 'PRGV:16384,0,65536\r\n'
    [ -n "${RIP_FAKE_MKV_RC:-}" ] && exit "$RIP_FAKE_MKV_RC"
    printf 'PRGV:32768,0,65536\r\n'
    printf 'PRGV:65536,0,65536\r\n'
    printf 'ripped' > "$dir/title_t01.mkv"
    ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/makemkvcon"; export RIP_MAKEMKVCON_BIN="$RIP_SANDBOX/makemkvcon"
    cat > "$RIP_SANDBOX/HandBrakeCLI" <<'EOF'
#!/bin/sh
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
echo 'Encoding: task 1 of 1, 100.00 %'
printf 'encoded' > "$out"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/HandBrakeCLI"; export RIP_HANDBRAKE_BIN="$RIP_SANDBOX/HandBrakeCLI"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_SANDBOX/rsync"; export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
  }
  cleanup() { rm -rf "$RIP_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'happy path: rips longest title, encodes, pushes, cleans autorip'
    export JOB_ID="job-disc-1"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::disc_worker 'A Movie (2001)'"
    The status should equal 0
    The output should include "verified"
    The path "$RIP_STAGING_ROOT/.work/autorip" should not be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)" should not be exist
  End

  It 'rip failure keeps nothing and propagates rc'
    export RIP_FAKE_MKV_RC=5
    When run zsh -c "source $RIPLIB && rip::disc_worker 'A Movie (2001)'"
    The status should equal 5
    The stderr should include "disc rip failed"
    The path "$RIP_STAGING_ROOT/.work/autorip" should not be exist
  End

  It 'progress: the rip stage lands in the 0-40 band'
    export JOB_ID="job-disc-2"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    # freeze after the rip: encode fails so the sidecar's last write is rip-stage
    printf '#!/bin/sh\nexit 1\n' > "$RIP_SANDBOX/HandBrakeCLI"
    chmod +x "$RIP_SANDBOX/HandBrakeCLI"
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::disc_worker 'A Movie (2001)'"
    The status should equal 1
    The stderr should include "encode failed"
    # last rip-stage write was PRGV 65536/65536 → 100% of a 0-40 band → 40
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include " 40 "
  End

  It 'progress: CR-terminated PRGV lines (pty ONLCR) still parse mid-rip'
    export JOB_ID="job-disc-3"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    export RIP_FAKE_MKV_RC=9
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::disc_worker 'A Movie (2001)'"
    The status should equal 9
    The stderr should include "disc rip failed"
    # PRGV:16384,0,65536 -> 25% of the 0-40 band -> 10. If the trailing \r
    # (real pty ONLCR: \n -> \r\n) broke the numeric-glob check, no write
    # would follow the worker's initial "0", and this would read " 0 "
    # instead.
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include " 10 "
  End

  It 'enqueue: heavy group, rip: title, absolute worker path'
    titles() { cat "$JOB_STATE_ROOT"/*/meta.json 2>/dev/null; }
    When run zsh -c "source $RIPLIB && rip::disc_enqueue 'A Movie (2001)'"
    The status should equal 0
    The output should not equal ""
    The contents of file "$JOB_FAKE_LOG" should include "--group heavy"
    The contents of file "$JOB_FAKE_LOG" should include "/rip-disc --worker"
    The result of function titles should include "rip: A Movie (2001)"
  End
End
