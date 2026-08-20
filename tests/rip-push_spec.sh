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
    # Every pre-existing example here stages files moments before running
    # the worker, so they'd all sit inside the default 90s age gate. Disable
    # it suite-wide; the three age-gate examples below re-export the real
    # default themselves since gating behavior is exactly what they test.
    export RIP_PUSH_MIN_AGE_S=0
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
    The contents of file "$JOB_FAKE_LOG" should include "/rip-push --worker movies"
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
    The output should include "verified"
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include "100"
  End

  # Regression guard: without this, deleting the tr/while parsing loop in
  # rip::push_worker would go unnoticed — the "streams progress" example
  # above only checks the sidecar's FINAL state, and _verify_and_clean's own
  # unconditional 100%-"verified" write on a clean pass would satisfy that
  # assertion even with a broken (or removed) parsing loop. Forcing the -rcn
  # verify call to exit 1 means _verify_and_clean returns before writing the
  # sidecar again, so whatever is left in it can ONLY have come from the
  # transfer-phase parsing loop itself — and this also exercises the "dry-run
  # failed to run" keep-everything branch (distinct from "dry-run ran but
  # reported differences", covered separately above).
  It 'worker keeps transfer-phase progress when the verify dry-run fails to run'
    mkdir -p "$RIP_STAGING_ROOT/music/B/Alb"; touch "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
case "$*" in
  *-rcn*) exit 1 ;;   # verify dry-run itself fails to run
  *)
    printf 'B/Alb/01 T.flac\n'
    printf '      1,000  50%%   1.2MB/s  0:00:01\r'
    exit 0 ;;
esac
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    export JOB_ID="job-test-2"
    mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::push_worker music"
    The status should equal 1
    The stderr should include "verify"
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include "50"
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include "01 T.flac"
    The path "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac" should be exist
  End

  # Goes through the REAL bin (not a bare function call): executable_rip-
  # push sources rip.zsh under `set -eu -o pipefail`, and rip::push_worker's
  # own rsync-into-a-loop pipeline has the identical shape as
  # rip::pipeline_worker's (see that suite's regression-guard comment) — a
  # bare function call never exercises the outer errexit that used to skip
  # this function's rc-capture/cleanup.
  It 'worker propagates rsync failure'
    mkdir -p "$RIP_STAGING_ROOT/music/B/Alb"; touch "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    printf '#!/bin/sh\nexit 23\n' > "$RIP_SANDBOX/rsync"; chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-push" --worker music
    The status should equal 23
    The stderr should include "rip"
    The path "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac" should be exist
  End

  It 'worker deletes staging after a clean verify'
    mkdir -p "$RIP_STAGING_ROOT/music/B/Alb"; touch "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
case "$*" in *-rcn*) exit 0 ;; *) exit 0 ;; esac
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The path "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac" should not be exist
    The path "$RIP_STAGING_ROOT/music/B" should not be exist
    The path "$RIP_STAGING_ROOT/music" should be exist
  End

  # TOCTOU guard. The verify pass blesses the tree as the push found it, but
  # the delete runs moments later. Anything that lands in that window — a
  # track XLD finishes, or an encode the pipeline publishes while a hand-run
  # `rip-push movies` is in flight, since heavy and transfer are separate
  # groups that DO run concurrently — was never pushed, so deleting it would
  # destroy the only digital copy. The fake drops exactly such a file in
  # from its verify branch, i.e. after the transfer has already finished.
  It 'keeps a file that lands after the push started'
    mkdir -p "$RIP_STAGING_ROOT/music/B/Alb"; touch "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    export RIP_FAKE_LATE_FILE="$RIP_STAGING_ROOT/music/C/Late/02 Late.flac"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
case "$*" in
  *-rcn*)
    mkdir -p "$(dirname "$RIP_FAKE_LATE_FILE")"
    printf 'late' > "$RIP_FAKE_LATE_FILE"
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    # what the push actually covered is gone…
    The path "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac" should not be exist
    The path "$RIP_STAGING_ROOT/music/B" should not be exist
    # …and the late arrival, with the directory holding it, survives
    The path "$RIP_FAKE_LATE_FILE" should be exist
    The path "$RIP_STAGING_ROOT/music/C/Late" should be exist
  End

  It 'worker keeps everything when the verify pass finds differences'
    mkdir -p "$RIP_STAGING_ROOT/music/B/Alb"; touch "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
case "$*" in *-rcn*) printf 'B/Alb/01 T.flac\n'; exit 0 ;; *) exit 0 ;; esac
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 1
    The stderr should include "verify"
    The path "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac" should be exist
  End

  It 'age gate: a settling file is not pushed and survives the clean'
    export RIP_PUSH_MIN_AGE_S=90   # re-export the real default over setup()'s 0
    mkdir -p "$RIP_STAGING_ROOT/music/B/Alb" "$RIP_STAGING_ROOT/music/C/New"
    touch "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    # make the settled file old enough for the 90s default gate
    touch -t 202601010000 "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    touch "$RIP_STAGING_ROOT/music/C/New/01 Fresh.flac"   # just written
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${RIP_FAKE_RSYNC_LOG:?}"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    export RIP_FAKE_RSYNC_LOG="$RIP_SANDBOX/rsync.log"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    # the settled file was pushed (files-from list) and deleted
    The path "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac" should not be exist
    # the fresh file was NEVER in the list and survives, dir intact
    The path "$RIP_STAGING_ROOT/music/C/New/01 Fresh.flac" should be exist
    The contents of file "$RIP_FAKE_RSYNC_LOG" should include "--files-from"
  End

  It 'age gate: nothing settled → quiet success, no rsync at all'
    export RIP_PUSH_MIN_AGE_S=90   # re-export the real default over setup()'s 0
    mkdir -p "$RIP_STAGING_ROOT/music/C/New"
    touch "$RIP_STAGING_ROOT/music/C/New/01 Fresh.flac"
    printf '#!/bin/sh\nexit 99\n' > "$RIP_SANDBOX/rsync"; chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "nothing settled"
    The path "$RIP_STAGING_ROOT/music/C/New/01 Fresh.flac" should be exist
  End

  It 'age gate disabled (RIP_PUSH_MIN_AGE_S=0) pushes fresh files — the pipeline composition'
    mkdir -p "$RIP_STAGING_ROOT/movies/A (2001)"
    touch "$RIP_STAGING_ROOT/movies/A (2001)/A (2001).mkv"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && RIP_PUSH_MIN_AGE_S=0 rip::push_worker movies"
    The status should equal 0
    The output should include "verified"
    The path "$RIP_STAGING_ROOT/movies/A (2001)/A (2001).mkv" should not be exist
  End

  # --- enrichment: embedded cover art + lyrics ------------------------------

  enrich_setup() {
    mkdir -p "$RIP_STAGING_ROOT/music/Art/Alb"
    touch "$RIP_STAGING_ROOT/music/Art/Alb/01 Song.flac"
    touch -t 202601010000 "$RIP_STAGING_ROOT/music/Art/Alb/01 Song.flac"
    printf '#!/bin/sh\nexit 0\n' > "$RIP_SANDBOX/rsync"; chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    export RIP_FAKE_MF_LOG="$RIP_SANDBOX/metaflac.log"
    cat > "$RIP_SANDBOX/metaflac" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_MF_LOG"
case "$*" in
  *--list*PICTURE*) exit 0 ;;                       # no picture yet (empty out)
  *--show-tag=LYRICS*) exit 0 ;;                    # no lyrics yet
  *--show-tag=ARTIST*) echo "ARTIST=Art" ;;
  *--show-tag=ALBUM*) echo "ALBUM=Alb" ;;
  *--show-tag=TITLE*) echo "TITLE=Song" ;;
  *--show-total-samples*) echo 8820000 ;;
  *--show-sample-rate*) echo 44100 ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/metaflac"
    export RIP_METAFLAC_BIN="$RIP_SANDBOX/metaflac"
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  *musicbrainz*) echo '{"releases":[{"id":"mbid-1"}]}' ;;
  *coverartarchive*) # last arg pattern: -o <file> present in argv
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'JPEGDATA' > "$out" ;;
  *lrclib*) echo '{"syncedLyrics":"[00:01.00] la la","plainLyrics":"la la"}' ;;
  *itunes*) echo '{"results":[]}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/curl"
    export RIP_CURL_BIN="$RIP_SANDBOX/curl"
  }

  It 'enrichment embeds picture + lyrics and ships cover.jpg'
    enrich_setup
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_FAKE_MF_LOG" should include "--import-picture-from"
    The contents of file "$RIP_FAKE_MF_LOG" should include "--set-tag-from-file=LYRICS"
    # cover.jpg was created post-list, appended, shipped, and cleaned
    The path "$RIP_STAGING_ROOT/music/Art/Alb/cover.jpg" should not be exist
    The path "$RIP_STAGING_ROOT/music/Art" should not be exist
  End

  It 'enrichment failures never fail the push'
    enrich_setup
    printf '#!/bin/sh\nexit 7\n' > "$RIP_SANDBOX/curl"; chmod +x "$RIP_SANDBOX/curl"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    # cover fetch failed (curl rc 7) so lyrics fetch is tried and also fails
    # via the same broken curl, printing the "not found" line to stdout
    The output should include "no lyrics found"
    The stderr should include "enrich"
  End

  It 'enrichment is idempotent — existing picture and lyrics are skipped'
    enrich_setup
    cat > "$RIP_SANDBOX/metaflac" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_MF_LOG"
case "$*" in
  *--list*PICTURE*) echo "METADATA block #2"; echo "  type: 6 (PICTURE)" ;;
  *--show-tag=LYRICS*) echo "LYRICS=already here" ;;
  *--show-tag=ARTIST*) echo "ARTIST=Art" ;;
  *--show-tag=ALBUM*) echo "ALBUM=Alb" ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/metaflac"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_FAKE_MF_LOG" should not include "--import-picture-from"
    The contents of file "$RIP_FAKE_MF_LOG" should not include "--set-tag-from-file"
  End
End
