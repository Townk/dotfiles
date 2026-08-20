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

  # stray_listfiles() — count of push-<type>.<pid>.list scratch files left
  # under .work/. Used to assert the private per-invocation listfile is
  # actually removed once a run finishes (success or failure), not just
  # renamed off the old shared path.
  stray_listfiles() {
    local -a f=("$RIP_STAGING_ROOT"/.work/push-*.list(N))
    print -r -- "${#f}"
  }

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
    export RIP_FAKE_CURL_LOG="$RIP_SANDBOX/curl.log"
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_CURL_LOG"
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  # the artist-image chain's MB/Deezer/Wikidata lookups: graceful empty
  # results so no jq parse-error noise leaks into tests that don't care
  # about artist images at all. Ordered most-specific first: url-rels
  # relation lookup and the artist search endpoint both contain
  # "musicbrainz" too, so the generic release-search case must come last.
  *inc=url-rels*) echo '{"relations":[]}' ;;
  *musicbrainz*artist/) echo '{"artists":[]}' ;;
  *musicbrainz*) echo '{"releases":[{"id":"mbid-1"}]}' ;;
  *deezer*) echo '{"data":[]}' ;;
  *wikidata*) echo '{"claims":{}}' ;;
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

  # fake_copy_rsync — an rsync stand-in that actually copies the listed
  # files from src to the local sandbox "remote" (plain `cp`, no network),
  # so artist-image tests can assert on the bytes that landed server-side
  # instead of only inferring "shipped" from local absence.
  fake_copy_rsync() {
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
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
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

  # Regression guard (final-review finding 1): rip::_enrich_music used to
  # glob the WHOLE album directory instead of grouping the age-gated LIST
  # itself. A sibling track mid-write (e.g. XLD still writing a neighboring
  # track in the same album dir while this one already settled) would get
  # probed and metaflac'd right along with the settled one — metaflac's
  # rewrite-and-rename on a file XLD is still appending to sends XLD's
  # remaining writes into an unlinked inode; the truncated file then settles
  # on its own next run, ships, self-verifies clean, and is deleted locally.
  # Only files the age gate actually admitted into <listfile> may be probed
  # or embedded.
  It 'enrichment touches only the listed flac, never an unlisted fresh sibling in the same album dir'
    export RIP_PUSH_MIN_AGE_S=90   # re-export the real default; need age gating active
    enrich_setup
    # unlisted: written just now, well inside the 90s gate — simulates a
    # sibling track XLD is still mid-write on
    touch "$RIP_STAGING_ROOT/music/Art/Alb/02 Other.flac"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_FAKE_MF_LOG" should include "01 Song.flac"
    The contents of file "$RIP_FAKE_MF_LOG" should not include "02 Other.flac"
    # the settled/listed track shipped and was cleaned…
    The path "$RIP_STAGING_ROOT/music/Art/Alb/01 Song.flac" should not be exist
    # …the fresh unlisted sibling was never touched, in any way
    The path "$RIP_STAGING_ROOT/music/Art/Alb/02 Other.flac" should be exist
  End

  # Regression guard (final-review finding 2): the listfile used to be a
  # FIXED path shared by every invocation of the same type, so the pipeline's
  # heavy-group inner push and a transfer-group/hand-run `rip-push <type>`
  # (which DO run concurrently) could rebuild each other's list mid-flight.
  # Fix: the listfile is private per invocation ($$ in its name — asserted
  # below via the rsync log), and verify_and_clean snapshots it into memory
  # ONCE and drives both the verify's --files-from and the delete loop off
  # that snapshot rather than a second read of the file. The fake rsync
  # here simulates the worst case directly: it OVERWRITES the private
  # listfile with a different (unrelated, never-pushed) filename during the
  # verify call itself — if the delete loop re-read the file instead of
  # using its snapshot, it would delete the wrong file entirely.
  It 'verify+delete are driven by an in-memory snapshot, immune to the listfile changing between them; listfile is private per-$$ and removed on success'
    export RIP_PUSH_MIN_AGE_S=90   # re-export the real default; need age gating active
    mkdir -p "$RIP_STAGING_ROOT/music/B/Alb" "$RIP_STAGING_ROOT/music/C/Untouched"
    touch "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"
    touch -t 202601010000 "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac"   # settled: admitted to the list
    touch "$RIP_STAGING_ROOT/music/C/Untouched/evil.flac"   # fresh: NEVER in the real list
    export RIP_FAKE_RSYNC_LOG="$RIP_SANDBOX/rsync.log"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_RSYNC_LOG"
lf=""
for a in "$@"; do case "$a" in --files-from=*) lf="${a#--files-from=}";; esac; done
case "$*" in
  *-rcn*)
    printf '%s\n' "C/Untouched/evil.flac" > "$lf"
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    # the listfile is private per invocation: --files-from carries a $$
    # segment, never the old fixed shared name
    The contents of file "$RIP_FAKE_RSYNC_LOG" should include ".work/push-music."
    The contents of file "$RIP_FAKE_RSYNC_LOG" should include ".list"
    The contents of file "$RIP_FAKE_RSYNC_LOG" should not include "push-music.list"
    # delete followed the SNAPSHOT taken before verify — the real pushed
    # file is gone, its now-empty album dir pruned…
    The path "$RIP_STAGING_ROOT/music/B/Alb/01 T.flac" should not be exist
    The path "$RIP_STAGING_ROOT/music/B" should not be exist
    # …and the name the tampered listfile pointed at instead was never
    # touched, since the delete loop never re-read it
    The path "$RIP_STAGING_ROOT/music/C/Untouched/evil.flac" should be exist
    # the private listfile itself is gone — nothing stray left in .work/
    The result of function stray_listfiles should equal "0"
  End

  # --- enrichment: per-artist artist.jpg -----------------------------------
  # Dedupe artists across the albums touched THIS run, derived from the SAME
  # listfile-based album map _enrich_music already builds (not a directory
  # glob — same discipline as the cover/lyrics step, see the regression
  # guard above). Idempotent both locally and on the server; keyless fetch
  # chain Deezer → MusicBrainz/Wikidata/Commons; best-effort, never blocks
  # the push.

  deezer_search_count() { grep -c "search/artist" "$RIP_SANDBOX/curl.log" 2>/dev/null; }

  It 'artist image: server already has it — no fetch attempted, no local file created'
    enrich_setup
    mkdir -p "$RIP_SANDBOX/server/music/Art"
    printf 'REMOTE-ALREADY-THERE' > "$RIP_SANDBOX/server/music/Art/artist.jpg"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "deezer"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "wikidata"
    The path "$RIP_STAGING_ROOT/music/Art/artist.jpg" should not be exist
  End

  It 'artist image: fetched from Deezer, appended to the list, and shipped'
    enrich_setup
    fake_copy_rsync
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_CURL_LOG"
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  *inc=url-rels*) echo '{"relations":[]}' ;;
  *musicbrainz*artist/) echo '{"artists":[]}' ;;
  *musicbrainz*) echo '{"releases":[{"id":"mbid-1"}]}' ;;
  *deezer*search/artist*) echo '{"data":[{"picture_xl":"https://fake-deezer-cdn.test/pic_xl.jpg"}]}' ;;
  *fake-deezer-cdn.test*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'DEEZERJPEG' > "$out" ;;
  *wikidata*) echo '{"claims":{}}' ;;
  *coverartarchive*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'JPEGDATA' > "$out" ;;
  *lrclib*) echo '{"syncedLyrics":"[00:01.00] la la","plainLyrics":"la la"}' ;;
  *itunes*) echo '{"results":[]}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/curl"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_SANDBOX/curl.log" should include "search/artist"
    # gone locally after verify-clean, present in the local remote
    The path "$RIP_STAGING_ROOT/music/Art/artist.jpg" should not be exist
    The path "$RIP_STAGING_ROOT/music/Art" should not be exist
    The path "$RIP_SANDBOX/server/music/Art/artist.jpg" should be exist
    The contents of file "$RIP_SANDBOX/server/music/Art/artist.jpg" should equal "DEEZERJPEG"
  End

  It "artist image: rejects Deezer's placeholder picture and falls back to Wikimedia via MusicBrainz/Wikidata"
    enrich_setup
    fake_copy_rsync
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_CURL_LOG"
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  *inc=url-rels*) echo '{"relations":[{"url":{"resource":"https://www.wikidata.org/wiki/Q42"}}]}' ;;
  *musicbrainz*artist/) echo '{"artists":[{"id":"mbid-artist-1"}]}' ;;
  *musicbrainz*) echo '{"releases":[{"id":"mbid-1"}]}' ;;
  *deezer*search/artist*) echo '{"data":[{"picture_xl":"https://fake-deezer-cdn.test/d41d8cd98f00b204e9800998ecf8427e.jpg"}]}' ;;
  *fake-deezer-cdn.test*) printf 'this branch must never be downloaded' ;;
  *wikidata*api.php*) echo '{"claims":{"P18":[{"mainsnak":{"datavalue":{"value":"Some Artist.jpg"}}}]}}' ;;
  *commons*Special:FilePath*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'COMMONSJPEG' > "$out" ;;
  *coverartarchive*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'JPEGDATA' > "$out" ;;
  *lrclib*) echo '{"syncedLyrics":"[00:01.00] la la","plainLyrics":"la la"}' ;;
  *itunes*) echo '{"results":[]}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/curl"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    # the placeholder-carrying deezer URL was never downloaded…
    The contents of file "$RIP_SANDBOX/curl.log" should not include "d41d8cd98f00b204e9800998ecf8427e.jpg"
    # …the fallback landed instead
    The path "$RIP_SANDBOX/server/music/Art/artist.jpg" should be exist
    The contents of file "$RIP_SANDBOX/server/music/Art/artist.jpg" should equal "COMMONSJPEG"
  End

  It 'artist image: total miss across every source — logs and never blocks the push'
    enrich_setup
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The output should include "no artist image found"
    The path "$RIP_STAGING_ROOT/music/Art/artist.jpg" should not be exist
    The path "$RIP_SANDBOX/server/music/Art/artist.jpg" should not be exist
  End

  It 'artist image: dedupes the fetch across multiple albums by the same artist in one run'
    mkdir -p "$RIP_STAGING_ROOT/music/Art/Alb1" "$RIP_STAGING_ROOT/music/Art/Alb2"
    touch "$RIP_STAGING_ROOT/music/Art/Alb1/01 Song.flac" "$RIP_STAGING_ROOT/music/Art/Alb2/01 Other.flac"
    printf '#!/bin/sh\nexit 0\n' > "$RIP_SANDBOX/rsync"; chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    export RIP_FAKE_MF_LOG="$RIP_SANDBOX/metaflac.log"
    cat > "$RIP_SANDBOX/metaflac" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_MF_LOG"
case "$*" in
  *--list*PICTURE*) exit 0 ;;
  *--show-tag=LYRICS*) exit 0 ;;
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
    export RIP_FAKE_CURL_LOG="$RIP_SANDBOX/curl.log"
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_CURL_LOG"
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  *inc=url-rels*) echo '{"relations":[]}' ;;
  *musicbrainz*artist/) echo '{"artists":[]}' ;;
  *musicbrainz*) echo '{"releases":[{"id":"mbid-1"}]}' ;;
  *deezer*search/artist*) echo '{"data":[{"picture_xl":"https://fake-deezer-cdn.test/pic_xl.jpg"}]}' ;;
  *fake-deezer-cdn.test*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'DEEZERJPEG' > "$out" ;;
  *wikidata*) echo '{"claims":{}}' ;;
  *lrclib*) echo '{"syncedLyrics":"[00:01.00] la la","plainLyrics":"la la"}' ;;
  *itunes*) echo '{"results":[]}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/curl"
    export RIP_CURL_BIN="$RIP_SANDBOX/curl"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The result of function deezer_search_count should equal "1"
  End

  It 'artist image: pre-existing local file is idempotent (no fetch) and still ships'
    enrich_setup
    mkdir -p "$RIP_STAGING_ROOT/music/Art"
    printf 'LOCAL-ALREADY-HERE' > "$RIP_STAGING_ROOT/music/Art/artist.jpg"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "search/artist"
    The path "$RIP_STAGING_ROOT/music/Art/artist.jpg" should not be exist
  End

  It 'artist image: ssh remote check reports it already exists — skip fetch (host:path remote base)'
    enrich_setup
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    export RIP_FAKE_SSH_LOG="$RIP_SANDBOX/ssh.log"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_SSH_LOG"
case "$*" in
  *"/srv/media/music/Art/artist.jpg"*) exit 0 ;;
esac
exit 1
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_SANDBOX/ssh.log" should include "fakehost"
    The contents of file "$RIP_SANDBOX/ssh.log" should include "artist.jpg"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "search/artist"
    The path "$RIP_STAGING_ROOT/music/Art/artist.jpg" should not be exist
  End

  It 'artist image: ssh remote check confirms absent — fetch proceeds normally (host:path remote base)'
    enrich_setup
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    printf '#!/bin/sh\nexit 1\n' > "$RIP_SANDBOX/ssh"; chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_CURL_LOG"
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  *inc=url-rels*) echo '{"relations":[]}' ;;
  *musicbrainz*artist/) echo '{"artists":[]}' ;;
  *musicbrainz*) echo '{"releases":[{"id":"mbid-1"}]}' ;;
  *deezer*search/artist*) echo '{"data":[{"picture_xl":"https://fake-deezer-cdn.test/pic_xl.jpg"}]}' ;;
  *fake-deezer-cdn.test*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'DEEZERJPEG' > "$out" ;;
  *wikidata*) echo '{"claims":{}}' ;;
  *coverartarchive*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'JPEGDATA' > "$out" ;;
  *lrclib*) echo '{"syncedLyrics":"[00:01.00] la la","plainLyrics":"la la"}' ;;
  *itunes*) echo '{"results":[]}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/curl"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_SANDBOX/curl.log" should include "search/artist"
    The path "$RIP_STAGING_ROOT/music/Art/artist.jpg" should not be exist
  End

  It 'artist image: ssh remote check failure counts as unknown — skip fetch this run, never block'
    enrich_setup
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    printf '#!/bin/sh\nexit 255\n' > "$RIP_SANDBOX/ssh"; chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The output should include "rip: artist image"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "search/artist"
    The path "$RIP_STAGING_ROOT/music/Art/artist.jpg" should not be exist
  End

  # Security regression guard (review finding 1): the remote command used to
  # be hand-built with a raw single-quoted interpolation —
  # "test -f '$rpath/music/$artist_rel/artist.jpg'" — so an apostrophe in
  # the artist DIRECTORY name (itself derived from untrusted CDDB/
  # MusicBrainz tag data upstream in the pipeline) breaks the quoting, and a
  # crafted name can break OUT of it and run arbitrary commands on cantina
  # over the media@ ssh credentials. Fix: ${(q)...}, zsh's own quoter, which
  # safely shell-quotes ANY content. This fake ssh round-trips the generated
  # remote command through a REAL `sh -c` (simulating the remote shell) and
  # logs the resulting rc — proving the command is syntactically valid
  # (rc 1: file legitimately absent) rather than broken (a syntax error
  # would not yield a clean rc 1, and get miscategorized as "unknown").
  fake_roundtrip_ssh() {
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/ssh.log"
shift 4   # -o BatchMode=yes -o ConnectTimeout=5
shift     # <host>
cmd="\$1"
sh -c "\$cmd"
rc=\$?
printf 'RC=%s\n' "\$rc" >> "$RIP_SANDBOX/ssh.log"
exit "\$rc"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
  }

  It 'artist image: ssh remote check safely quotes an artist directory name containing an apostrophe'
    enrich_setup
    mkdir -p "$RIP_STAGING_ROOT/music/N' Roses/Alb"
    touch "$RIP_STAGING_ROOT/music/N' Roses/Alb/01 Song.flac"
    export RIP_REMOTE_BASE="fakehost:$RIP_SANDBOX/server"
    fake_roundtrip_ssh
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    # rc 1 — the remote `test -f` ran cleanly and legitimately found the
    # file absent; a broken quote would either error out or, at best, not
    # reliably report 1 here
    The contents of file "$RIP_SANDBOX/ssh.log" should include "RC=1"
    The contents of file "$RIP_SANDBOX/ssh.log" should include "BatchMode=yes"
    The contents of file "$RIP_SANDBOX/ssh.log" should include "ConnectTimeout=5"
    # confirmed absent → the fetch chain proceeded (never misread as
    # "unknown" from a syntax error, which would have skipped it)
    The contents of file "$RIP_SANDBOX/curl.log" should include "search/artist"
  End

  It 'artist image: ssh remote check is immune to shell metacharacter injection via a crafted artist directory name'
    enrich_setup
    evil="x'; touch '$RIP_SANDBOX/PWNED' #"
    mkdir -p "$RIP_STAGING_ROOT/music/$evil/Alb"
    touch "$RIP_STAGING_ROOT/music/$evil/Alb/01 Song.flac"
    export RIP_REMOTE_BASE="fakehost:$RIP_SANDBOX/server"
    fake_roundtrip_ssh
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    # the payload never executed…
    The path "$RIP_SANDBOX/PWNED" should not be exist
    # …the quoted command still parsed and ran cleanly (rc 1: absent, not a
    # syntax error), so the fetch chain proceeded normally
    The contents of file "$RIP_SANDBOX/ssh.log" should include "RC=1"
    The contents of file "$RIP_SANDBOX/curl.log" should include "search/artist"
  End
End
