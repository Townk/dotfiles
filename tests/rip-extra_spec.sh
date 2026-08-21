# rip-extra — encode one DVD extra DIRECT from the disc into Jellyfin's
# extras/ convention (movies/<Movie>/extras/<Name>.mkv), pushed and
# verified like any other rip. Hermetic: fake HandBrakeCLI (both --scan and
# encode modes), fake rsync, fake pueue; a sandbox volume dir with a
# VIDEO_TS subdir stands in for the mounted disc via the RIP_DVD_VOLUME
# seam — no real disc, no real network.
Describe 'rip.zsh extra'
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
    mkdir -p "$RIP_STAGING_ROOT/movies" "$RIP_SANDBOX/server/movies"

    # stand-in mounted DVD: a plain sandbox dir with a VIDEO_TS subdir,
    # reached through the RIP_DVD_VOLUME seam instead of scanning /Volumes.
    mkdir -p "$RIP_SANDBOX/dvd/VIDEO_TS"
    export RIP_DVD_VOLUME="$RIP_SANDBOX/dvd"

    cat > "$RIP_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in add) echo "7" ;; esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/pueue"; export JOB_PUEUE_BIN="$RIP_SANDBOX/pueue"

    # fake HandBrakeCLI, dual-mode: `--scan` prints a scan listing (two
    # titles); otherwise it's an encode call (`-t N -o <file>`). Every
    # invocation is logged so a test can assert NOTHING was called at all
    # (the server-already-has-it idempotency path).
    export RIP_FAKE_HB_LOG="$RIP_SANDBOX/hb.log"
    : > "$RIP_FAKE_HB_LOG"
    cat > "$RIP_SANDBOX/HandBrakeCLI" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_HB_LOG"
case "$*" in
  *--scan*)
    printf '+ title 1:\n  + duration: 00:00:38\n'
    printf '+ title 2:\n  + duration: 02:08:59\n'
    exit 0
    ;;
  *)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "${RIP_FAKE_HB_RC:-}" ] && exit "$RIP_FAKE_HB_RC"
    printf 'Encoding: task 1 of 1, 42.50 %%\r'
    printf 'Encoding: task 1 of 1, 100.00 %%\n'
    printf 'encoded' > "$out"
    exit 0
    ;;
esac
EOF
    chmod +x "$RIP_SANDBOX/HandBrakeCLI"; export RIP_HANDBRAKE_BIN="$RIP_SANDBOX/HandBrakeCLI"

    # copying fake (mirrors rip-push_spec.sh's fake_copy_rsync): actually
    # `cp`s the listed files from src to the local sandbox "remote" so a
    # test can assert on the bytes that landed server-side, not just infer
    # "shipped" from local absence.
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
case "$*" in *-rcn*) exit 0 ;; esac
lf="" a1="" a2=""
for a in "$@"; do
  case "$a" in
    --files-from=*) lf="${a#--files-from=}"; continue ;;
    -*) continue ;;
  esac
  a1="$a2"; a2="$a"
done
src="$a1" dest="$a2"
[ -n "$lf" ] || exit 0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  mkdir -p "$dest$(dirname "$rel")"
  cp "$src$rel" "$dest$rel" 2>/dev/null
done < "$lf"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/rsync"; export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
  }
  cleanup() { rm -rf "$RIP_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  titles() { cat "$JOB_STATE_ROOT"/*/meta.json 2>/dev/null; }

  # --- --list: scan the mounted DVD ------------------------------------

  It '--list parses the fake scan into title N: duration lines'
    When run zsh -c "source $RIPLIB && rip::extra_list"
    The status should equal 0
    The output should include "title 1: 00:00:38"
    The output should include "title 2: 02:08:59"
  End

  It '--list errors when no DVD volume is mounted'
    # A directory WITHOUT a VIDEO_TS subdir under the seam — not an unset
    # RIP_DVD_VOLUME, which would fall through to a real /Volumes scan and
    # could pick up a disc actually in this machine's drive right now.
    export RIP_DVD_VOLUME="$RIP_SANDBOX/no-disc"
    When run zsh -c "source $RIPLIB && rip::extra_list"
    The status should equal 1
    The stderr should include "no DVD volume"
  End

  # --- validation --------------------------------------------------------

  It 'rejects a non-numeric title number'
    When run zsh -c "source $RIPLIB && rip::extra_enqueue abc 'A Movie (2001)' 'Trailer'"
    The status should equal 2
    The stderr should include "title number"
  End

  It 'rejects an extra name containing a slash'
    When run zsh -c "source $RIPLIB && rip::extra_enqueue 2 'A Movie (2001)' 'Foo/Bar'"
    The status should equal 2
    The stderr should include "slash"
  End

  It 'rejects a movie title containing a slash (reuses rip::_check_title)'
    When run zsh -c "source $RIPLIB && rip::extra_enqueue 2 'A/B (2001)' 'Trailer'"
    The status should equal 2
    The stderr should include "title"
  End

  It 'rejects a movie title of ".." (bare path-segment escape)'
    When run zsh -c "source $RIPLIB && rip::extra_enqueue 2 '..' 'Trailer'"
    The status should equal 2
    The stderr should include ".."
  End

  It 'rejects an extra name of ".." (defense-in-depth, hygiene)'
    When run zsh -c "source $RIPLIB && rip::extra_enqueue 2 'A Movie (2001)' '..'"
    The status should equal 2
    The stderr should include ".."
  End

  # --- worker happy path ---------------------------------------------------

  It 'worker happy path: encodes direct from disc, publishes, pushes, and cleans'
    export JOB_ID="job-extra-1"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::extra_worker 2 'A Movie (2001)' 'Behind the Scenes'"
    The status should equal 0
    The output should include "verified"
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/extras/Behind the Scenes.mkv" should not be exist
    The path "$RIP_SANDBOX/server/movies/A Movie (2001)/extras/Behind the Scenes.mkv" should be exist
    The contents of file "$RIP_SANDBOX/server/movies/A Movie (2001)/extras/Behind the Scenes.mkv" should equal "encoded"
    # HandBrakeCLI was invoked with -t <title-no> against the disc volume,
    # not an intermediate rip
    The contents of file "$RIP_FAKE_HB_LOG" should include "-t 2"
    The contents of file "$RIP_FAKE_HB_LOG" should include "$RIP_SANDBOX/dvd"
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include "100"
  End

  # Live failure 2026-08-20 (U2 360°, "no progress in the capsule"): every
  # worker example here pre-sources job.zsh — but the real bins source ONLY
  # rip.zsh, and no worker loaded the job lib itself, so job::progress was
  # undefined and rip::_progress silently no-op'd in every production run.
  # The sidecar never existed live. This example runs the worker under the
  # PRODUCTION composition (rip.zsh alone) and demands the sidecar.
  It 'worker writes the progress sidecar without the caller pre-loading job.zsh'
    export JOB_ID="job-extra-prodcomp"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    When run zsh -c "source $RIPLIB && rip::extra_worker 2 'A Movie (2001)' 'Behind the Scenes'"
    The status should equal 0
    The output should include "verified"
    The path "$JOB_STATE_ROOT/$JOB_ID/progress" should be exist
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include "100"
  End

  # Live failure 2026-08-20 (Elvis TTWII title 5, exit 141): HandBrake's
  # stream carried a byte that is invalid UTF-8; under a UTF-8 locale macOS
  # `tr` aborts on it ("tr: Illegal byte sequence"), the pipe collapses, and
  # the still-writing encoder dies of SIGPIPE — a good encode killed by the
  # progress PARSER. The fake reproduces it deterministically: one bad byte,
  # then >64KB more output, so if tr exits early the writer must overrun the
  # pipe buffer and take the SIGPIPE (141) rather than sneaking out on a
  # buffered exit. The parse pipes must run tr under LC_ALL=C (byte-safe).
  It 'encode survives invalid UTF-8 bytes in the HandBrake stream (the tr/SIGPIPE 141)'
    export JOB_ID="job-extra-badbyte"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    cat > "$RIP_SANDBOX/HandBrakeCLI" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_HB_LOG"
case "$*" in
  *--scan*) exit 0 ;;
  *)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    printf 'libdvdread: raw \251 metadata\r\n'
    i=0
    while [ "$i" -lt 3000 ]; do
      printf 'Encoding: task 1 of 1, 42.50 %%\r'
      i=$((i+1))
    done
    printf 'Encoding: task 1 of 1, 100.00 %%\n'
    printf 'encoded' > "$out"
    exit 0
    ;;
esac
EOF
    chmod +x "$RIP_SANDBOX/HandBrakeCLI"
    When run zsh -c "export LC_ALL=en_US.UTF-8; source $JOBLIB; source $RIPLIB && rip::extra_worker 2 'A Movie (2001)' 'Behind the Scenes'"
    The status should equal 0
    The output should include "verified"
    The path "$RIP_SANDBOX/server/movies/A Movie (2001)/extras/Behind the Scenes.mkv" should be exist
  End

  # Progress composition: encode owns 0-85, push owns 85-100 — proven by
  # forcing the encode to fail right after a known percentage so the
  # sidecar's last write (job::progress overwrites, it doesn't append) can
  # only have come from the encode-band rescale, never the push band.
  It 'progress: the encode stage lands in the 0-85 band'
    export JOB_ID="job-extra-2"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    export RIP_FAKE_HB_RC=1
    cat > "$RIP_SANDBOX/HandBrakeCLI" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_HB_LOG"
case "$*" in
  *--scan*) exit 0 ;;
  *)
    printf 'Encoding: task 1 of 1, 42.50 %%\r'
    exit "${RIP_FAKE_HB_RC:-0}"
    ;;
esac
EOF
    chmod +x "$RIP_SANDBOX/HandBrakeCLI"
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::extra_worker 2 'A Movie (2001)' 'Behind the Scenes'"
    The status should equal 1
    The stderr should include "extra encode failed"
    # 42% of a 0-85 band -> 35 (42*85/100 truncated)
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include " 35 "
  End

  # --- server idempotency --------------------------------------------------

  It 'server already has the extra: nothing encoded, exit 0'
    mkdir -p "$RIP_SANDBOX/server/movies/A Movie (2001)/extras"
    printf 'already-there' > "$RIP_SANDBOX/server/movies/A Movie (2001)/extras/Behind the Scenes.mkv"
    When run zsh -c "source $RIPLIB && rip::extra_worker 2 'A Movie (2001)' 'Behind the Scenes'"
    The status should equal 0
    The output should include "server already has"
    The contents of file "$RIP_FAKE_HB_LOG" should equal ""
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)" should not be exist
  End

  # --- encode failure --------------------------------------------------------

  It 'encode failure: temp gone, nothing published, rc propagated'
    export RIP_FAKE_HB_RC=5
    When run zsh -c "source $RIPLIB && rip::extra_worker 2 'A Movie (2001)' 'Behind the Scenes'"
    The status should equal 5
    The stderr should include "extra encode failed"
    The path "$RIP_STAGING_ROOT/.work/.extra-encode.mkv" should not be exist
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)" should not be exist
  End

  # --- push failure ------------------------------------------------------

  # Mirrors the encode-failure test above, but the encode SUCCEEDS and the
  # subsequent push fails: the already-published extra must stay exactly
  # where it is (movies/<Movie>/extras/<Name>.mkv), kept for a plain
  # `rip-push movies` retry with no re-encode — the same cleanup contract
  # rip::pipeline_worker documents for its own push/verify failure. Nothing
  # may land server-side. The fake rsync forced to fail unconditionally
  # (rc 23) is the same idiom rip-push_spec.sh's "worker propagates rsync
  # failure" example uses.
  It 'push failure: encode published, rsync fails, extra kept locally, nothing server-side'
    printf '#!/bin/sh\nexit 23\n' > "$RIP_SANDBOX/rsync"; chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && rip::extra_worker 2 'A Movie (2001)' 'Behind the Scenes'"
    The status should equal 23
    The stderr should include "rsync failed"
    The path "$RIP_STAGING_ROOT/movies/A Movie (2001)/extras/Behind the Scenes.mkv" should be exist
    The path "$RIP_SANDBOX/server/movies/A Movie (2001)/extras/Behind the Scenes.mkv" should not be exist
  End

  # --- enqueue shape ---------------------------------------------------------

  It 'enqueue: heavy group, "extra: <Movie> — <Name>" title, absolute worker path'
    When run zsh -c "source $RIPLIB && rip::extra_enqueue 2 'A Movie (2001)' 'Behind the Scenes'"
    The status should equal 0
    The output should not equal ""
    The contents of file "$JOB_FAKE_LOG" should include "--group heavy"
    The contents of file "$JOB_FAKE_LOG" should include "/rip-extra --worker"
    The result of function titles should include "extra: A Movie (2001) — Behind the Scenes"
  End
End
