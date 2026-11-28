# rip-pipeline — encode → push → verify → cleanup as one job body.
# Fake HandBrakeCLI (RIP_HANDBRAKE_BIN) + fake rsync (RIP_RSYNC_BIN);
# hermetic sandbox, no real encoder/daemon/ssh.
Describe 'rip.zsh pipeline'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"
  # rip.zsh is loaded once, here; `When run rip_zsh "…"` runs the string a
  # `zsh -f -c` used to get, in a subshell (tests/rip_helper.sh).
  Include tests/rip_helper.sh
  rip_lib_load

  # The fakes of setup() are the same scripts for every example (what differs
  # between examples reaches them through the environment), so each is written
  # once per file, here, and setup() only points its seam at the shared copy
  # under $RIP_STATIC. An example that needs a different one writes it under
  # $RIP_SANDBOX and exports the seam to it (THE RULE, tests/rip_helper.sh).
  static_stubs() {
    rip_static_build || return 1
    rip_static_put HandBrakeCLI <<'EOF'
#!/bin/sh
out=""
prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "${RIP_FAKE_HB_RC:-}" ] && exit "$RIP_FAKE_HB_RC"
# hang mode: lay down a PARTIAL output, say `started` on the FIFO the
# cancel driver blocks on, then stay put (a FIFO nobody ever writes) — the
# shape a cancel interrupts (a real x265 encode writes the container as it
# goes). Only the driver's signal ends it.
if [ -n "${RIP_FAKE_HB_HANG:-}" ]; then
  printf 'partial' > "$out"
  echo started > "$RIP_FAKE_EV/started"
  read -r hold < "$RIP_FAKE_EV/never"
  exit 0
fi
printf 'Encoding: task 1 of 1, 42.50 %%\r'
printf 'Encoding: task 1 of 1, 100.00 %%\n'
printf 'encoded' > "$out"
exit 0
EOF
    rip_static_put rsync <<'EOF'
#!/bin/sh
case "$*" in
  *-rcn*) exit "${RIP_FAKE_VERIFY_RC:-0}" ;;
  *) if [ -n "${RIP_FAKE_RSYNC_HANG:-}" ]; then
       echo started > "$RIP_FAKE_EV/started"
       read -r hold < "$RIP_FAKE_EV/never"
     fi
     exit "${RIP_FAKE_RSYNC_RC:-0}" ;;
esac
EOF
    rip_static_warm HandBrakeCLI rsync
  }
  BeforeAll 'static_stubs'

  setup() {
    rip_sandbox; typeset +x RIP_SANDBOX   # as before: not in the environment
    export RIP_STAGING_ROOT="$RIP_SANDBOX/Rips"
    export RIP_REMOTE_BASE="$RIP_SANDBOX/server"
    export JOB_STATE_ROOT="$RIP_SANDBOX/state"
    export JOB_FAKE_LOG="$RIP_SANDBOX/pueue.log"
    rip_mkdir "$RIP_STAGING_ROOT/intermediate" "$RIP_STAGING_ROOT/movies" \
             "$RIP_SANDBOX/server/movies"
    printf 'raw' > "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv"
    export JOB_PUEUE_BIN="$RIP_STATIC/pueue"
    # fake HandBrakeCLI: emits CR-separated progress, writes the -o target
    export RIP_HANDBRAKE_BIN="$RIP_STATIC/HandBrakeCLI"
    export RIP_PTY_WRAP="" # hermetic: no real pty in tests (the disc suite's rule)
    export RIP_RSYNC_BIN="$RIP_STATIC/rsync"
    # the bins under test must source the SOURCE-TREE lib, not ~/.local/lib
    export RIP_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    # cancel-drive — reproduce `pueue kill` faithfully: pueue signals the
    # task's whole PROCESS GROUP, so the encoder dies alongside the worker.
    # macOS ships no setsid(1), and `setopt monitor` is refused in a
    # non-interactive shell without a tty, so perl's POSIX::setsid makes the
    # child a group leader we can `kill --`. CANCEL_SIGNAL picks the signal:
    # TERM is the graceful path (the worker's trap runs); KILL is what plain
    # `pueue kill` actually sends on pueue 4.x — untrappable, and therefore
    # the case the .work staging design has to survive on its own.
    #
    # The signal is aimed by an event, not by a delay: the fake encoder (or
    # the fake rsync) in hang mode says `started` on a FIFO once it is where
    # the cancel must find it, and the driver blocks on that line.
    export RIP_FAKE_EV="$RIP_SANDBOX"
    mkfifo "$RIP_SANDBOX/started" "$RIP_SANDBOX/never"
    cat > "$RIP_SANDBOX/cancel-drive.zsh" <<'EOF'
#!/usr/bin/env zsh
perl -e 'use POSIX; POSIX::setsid(); exec @ARGV or die' "$@" &
pid=$!
read -r at < "$RIP_FAKE_EV/started"
kill -${CANCEL_SIGNAL:-TERM} -$pid 2>/dev/null
wait $pid
exit $?
EOF
    chmod +x "$RIP_SANDBOX/cancel-drive.zsh"
  }
  cleanup() {
    rip_static_check RIP_HANDBRAKE_BIN="$RIP_SANDBOX/HandBrakeCLI" RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    rip_rmtree "$RIP_SANDBOX"
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # titles() — read every enqueued job's title straight from its meta.json
  # (job::start writes the title THERE, never onto pueue's argv — pueue only
  # ever sees `--group <G> --label job:<id>` and the sh-quoted command line).
  titles() { cat "$JOB_STATE_ROOT"/*/meta.json 2>/dev/null; }

  It 'happy path: encodes, pushes, cleans intermediate and encode'
    export JOB_ID="job-pl-1"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    When run rip_zsh "source $JOBLIB; source $RIPLIB && rip::pipeline_worker '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A Movie (2001)'"
    The status should equal 0
    The output should include "verified"
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should not be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)" should not be exist
  End

  It 'names the encode movies/<Title>/<Title>.mkv (visible on push failure)'
    export RIP_FAKE_RSYNC_RC=23
    When run rip_zsh "source $RIPLIB && rip::pipeline_worker '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A Movie (2001)'"
    The status should equal 23
    The stderr should include "rip"
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/A Movie (2001).mkv" should be exist
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should be exist
  End

  # Goes through the REAL bin (not a bare function call): executable_rip-
  # pipeline sources rip.zsh under `set -eu -o pipefail`, and a bare
  # HandBrakeCLI-into-a-loop pipeline's non-zero status under pipefail used
  # to trigger errexit BEFORE rip::pipeline_worker's own rc-capture/cleanup
  # ever ran — skipping the rm/rmdir/log_error entirely and leaving an
  # orphaned movies/<Title>/ dir behind. A bare function call (no outer
  # set -e) never exercised that failure mode, so it slipped past the unit
  # suite once already; this is the regression guard for it.
  It 'encode failure keeps the intermediate, skips the push, and leaves no orphan dir'
    export RIP_FAKE_HB_RC=1
    When run zsh -f "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-pipeline" \
      --worker "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" 'A Movie (2001)'
    The status should equal 1
    The stderr should include "encode failed"
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/A Movie (2001).mkv" should not be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)" should not be exist
  End

  # Cancelling `rip: <title>` from the HUD kills the worker where it stands,
  # mid-encode. The encode therefore never writes into movies/ at all: it
  # writes .work/encode.mkv and is RENAMED into place only once the encoder
  # has exited 0. Nothing reads .work — rip-push only ships movies/ and
  # music/ — so however hard the worker dies, no partial can ever reach the
  # server. This example covers the graceful (TERM) half: the trap also
  # cleans the temp and reports itself.
  It 'cancel mid-encode leaves nothing under movies/ and keeps the intermediate'
    export RIP_FAKE_HB_HANG=1
    When run zsh -f "$RIP_SANDBOX/cancel-drive.zsh" \
      zsh -f "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-pipeline" \
      --worker "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" 'A Movie (2001)'
    The status should equal 130
    The stderr should include "cancelled"
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/A Movie (2001).mkv" should not be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)" should not be exist
    The path "$RIP_STAGING_ROOT/.work/encode.mkv" should not be exist
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should be exist
  End

  # The case no trap can ever cover: plain `pueue kill` sends SIGKILL on
  # pueue 4.x (live-verified — a TERM/INT trap simply never runs), so the
  # worker gets no chance to clean up after itself. Safety here comes from
  # the layout alone: the half-written encode is in .work, which nothing
  # pushes and which the next worker run clears. No exit status is asserted
  # beyond SIGKILL's own 137 — the point of this example is the filesystem.
  It 'SIGKILL mid-encode still leaves nothing pushable under movies/'
    export RIP_FAKE_HB_HANG=1
    export CANCEL_SIGNAL=KILL
    When run zsh -f "$RIP_SANDBOX/cancel-drive.zsh" \
      zsh -f "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-pipeline" \
      --worker "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" 'A Movie (2001)'
    The status should equal 137
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/A Movie (2001).mkv" should not be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)" should not be exist
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should be exist
  End

  # The other half of the contract: the trap is disarmed the moment the
  # encode is known good, so a cancel during the PUSH keeps the finished
  # encode (and the intermediate) for a plain `rip-push movies` retry — no
  # re-encode. Guards against a future edit widening the trap's scope and
  # silently throwing away an hour of x265.
  It 'cancel mid-push keeps the finished encode and the intermediate'
    export RIP_FAKE_RSYNC_HANG=1
    When run zsh -f "$RIP_SANDBOX/cancel-drive.zsh" \
      zsh -f "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-pipeline" \
      --worker "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" 'A Movie (2001)'
    The status should equal 143
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/A Movie (2001).mkv" should be exist
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should be exist
  End

  It 'verify failure keeps intermediate and encode'
    export RIP_FAKE_VERIFY_RC=1
    When run rip_zsh "source $RIPLIB && rip::pipeline_worker '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A Movie (2001)'"
    The status should equal 1
    The stderr should include "verify"
    The path "$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv" should be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/A Movie (2001).mkv" should be exist
  End

  It 'rejects a title containing a slash'
    When run rip_zsh "source $RIPLIB && rip::pipeline_worker '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A/B (2001)'"
    The status should equal 2
    The stderr should include "title"
  End

  It 'enqueue lands in the heavy group with the movie title'
    When run rip_zsh "source $RIPLIB && rip::pipeline_enqueue '$RIP_STAGING_ROOT/intermediate/DISC_t00.mkv' 'A Movie (2001)'"
    The status should equal 0
    The output should not equal ""
    The contents of file "$JOB_FAKE_LOG" should include "--group heavy"
    The result of function titles should include "rip: A Movie (2001)"
    The contents of file "$JOB_FAKE_LOG" should include "/rip-pipeline --worker"
  End
End
