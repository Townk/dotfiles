# rip-push — enqueue validation, skip-if-empty, worker transfer/verify/delete.
# Hermetic: sandboxed staging + JOB_STATE_ROOT, recording fake pueue
# (JOB_PUEUE_BIN) and fake rsync (RIP_RSYNC_BIN). No ssh, no daemon.
Describe 'rip.zsh push'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    export RIP_SANDBOX=$(mktemp -d)
    export RIP_STAGING_ROOT="$RIP_SANDBOX/Rips"
    export RIP_REMOTE_BASE="$RIP_SANDBOX/server"
    export JOB_STATE_ROOT="$RIP_SANDBOX/state"
    export JOB_FAKE_LOG="$RIP_SANDBOX/pueue.log"
    mkdir -p "$RIP_STAGING_ROOT/movies" "$RIP_STAGING_ROOT/music" \
             "$RIP_STAGING_ROOT/audiobooks/Books" \
             "$RIP_SANDBOX/server/movies" "$RIP_SANDBOX/server/music" "$RIP_SANDBOX/server/audiobooks"
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
    # MusicBrainz rate-limit pacing (rip::_mb_call): zero both pauses so
    # the suite stays fast — the retry-behavior examples below assert the
    # RETRY happens (fake curl fails once, succeeds the second call), not
    # that any particular delay elapses.
    export RIP_MB_PAUSE_S=0
    export RIP_MB_RETRY_PAUSE_S=0
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

  # mb_*_call_count() — read back the counter files the MB-retry regression
  # tests' fake curl scripts bump on each call to the given endpoint, so an
  # example can assert the retry actually fired (count 2) rather than just
  # that the end result happened to land.
  mb_release_call_count() { cat "$RIP_SANDBOX/mb_release_count" 2>/dev/null; }
  mb_artist_call_count() { cat "$RIP_SANDBOX/mb_artist_count" 2>/dev/null; }

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

  It 'maps staging dirs per type, absorbing Libation Books level'
    When run zsh -c "source $RIPLIB && rip::staging_for movies && rip::staging_for music && rip::staging_for audiobooks"
    The status should equal 0
    The line 1 should equal "$RIP_STAGING_ROOT/movies"
    The line 2 should equal "$RIP_STAGING_ROOT/music"
    The line 3 should equal "$RIP_STAGING_ROOT/audiobooks/Books"
  End

  It 'accepts audiobooks as a type and enqueues from the Books level'
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Books/Brandon Sanderson/Steelheart"
    touch "$RIP_STAGING_ROOT/audiobooks/Books/Brandon Sanderson/Steelheart/Steelheart.m4b"
    When run zsh -c "source $RIPLIB && rip::push_enqueue audiobooks"
    The status should equal 0
    The output should not equal ""
    The contents of file "$JOB_FAKE_LOG" should include "--group transfer"
    The result of function titles should include "rip push: audiobooks"
    The contents of file "$JOB_FAKE_LOG" should include "/rip-push --worker audiobooks"
  End

  It 'pushes audiobooks to the server WITHOUT the Books level'
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Books/Brandon Sanderson/Steelheart"
    touch "$RIP_STAGING_ROOT/audiobooks/Books/Brandon Sanderson/Steelheart/Steelheart.m4b"
    When run zsh -c "source $RIPLIB && rip::push_worker audiobooks"
    The status should equal 0
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
    The path "$RIP_STAGING_ROOT/audiobooks/Books/Brandon Sanderson/Steelheart/Steelheart.m4b" should not be exist
    The stdout should include "verified"
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
  *--export-picture-to=*)
    out=""
    for a in "$@"; do case "$a" in --export-picture-to=*) out="${a#--export-picture-to=}";; esac; done
    [ -n "$out" ] && printf 'EMBEDDEDJPEG' > "$out" ;;
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
    # embedded art won — no external cover search was needed
    The contents of file "$RIP_SANDBOX/curl.log" should not include "coverartarchive"
  End

  # Live defect (root-caused by the controller, 2026-08-20): an album where
  # XLD had already embedded correct cover art still got a WRONG cover.jpg
  # fetched externally — an ambiguous title ("MTV ao Vivo") matched another
  # release. Navidrome's default CoverArtPriority puts cover.* ABOVE
  # embedded, so the wrong external fetch won the display even though
  # per-track idempotency correctly left the good embedded art alone. Fix:
  # when cover.jpg is absent, an embedded PICTURE block on the album's
  # FIRST listed track — the most trustworthy source, since XLD matched it
  # against the actual disc — is exported to cover.jpg and used, and the
  # external MB/CAA→iTunes chain is only tried when no listed track
  # carries embedded art at all. (The live album itself was already
  # corrected server-side by the controller; this is the systemic fix.)
  It 'cover: an embedded PICTURE block on the album — first track wins over any external fetch'
    enrich_setup
    cat > "$RIP_SANDBOX/metaflac" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_MF_LOG"
case "$*" in
  *--list*PICTURE*) echo "METADATA block #2"; echo "  type: 6 (PICTURE)" ;;
  *--export-picture-to=*)
    out=""
    for a in "$@"; do case "$a" in --export-picture-to=*) out="${a#--export-picture-to=}";; esac; done
    [ -n "$out" ] && printf 'EMBEDDEDJPEG' > "$out" ;;
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
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_FAKE_MF_LOG" should include "--export-picture-to"
    # no external cover source was ever consulted
    The contents of file "$RIP_SANDBOX/curl.log" should not include "coverartarchive"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "itunes"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "/release/"
  End

  # Live defect, round 3 (root-caused by the controller, 2026-08-20):
  # closing the remaining wrong-release class. Round 2's embedded-first fix
  # can't help when NOTHING is embedded — an art-less rip of "MTV ao Vivo"
  # matched the wrong edition because the MB release search matched by
  # title+artist alone. The rip's own DATE tag is a disambiguator already
  # in hand (rip::_track_meta): when present, the MB query adds
  # `AND date:<year>` first, retrying once without it only if that yields
  # nothing (a right-titled wrong-edition cover beats none).

  It 'cover: the MusicBrainz query includes date:<year> when the rip carries a DATE tag'
    enrich_setup
    cat > "$RIP_SANDBOX/metaflac" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_MF_LOG"
case "$*" in
  *--list*PICTURE*) exit 0 ;;
  *--show-tag=LYRICS*) exit 0 ;;
  *--show-tag=ARTIST*) echo "ARTIST=Art" ;;
  *--show-tag=ALBUM*) echo "ALBUM=Alb" ;;
  *--show-tag=TITLE*) echo "TITLE=Song" ;;
  *--show-tag=DATE*) echo "DATE=2004-03-15" ;;
  *--show-total-samples*) echo 8820000 ;;
  *--show-sample-rate*) echo 44100 ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/metaflac"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_SANDBOX/curl.log" should include "date:2004"
    The contents of file "$RIP_FAKE_MF_LOG" should include "--import-picture-from"
  End

  It 'cover: a date-filtered MusicBrainz miss falls back to the unfiltered query and still lands a cover'
    enrich_setup
    cat > "$RIP_SANDBOX/metaflac" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_MF_LOG"
case "$*" in
  *--list*PICTURE*) exit 0 ;;
  *--show-tag=LYRICS*) exit 0 ;;
  *--show-tag=ARTIST*) echo "ARTIST=Art" ;;
  *--show-tag=ALBUM*) echo "ALBUM=Alb" ;;
  *--show-tag=TITLE*) echo "TITLE=Song" ;;
  *--show-tag=DATE*) echo "DATE=2004-03-15" ;;
  *--show-total-samples*) echo 8820000 ;;
  *--show-sample-rate*) echo 44100 ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/metaflac"
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_CURL_LOG"
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  *musicbrainz*/release/)
    case "$*" in
      *"AND date:"*) echo '{"releases":[]}' ;;   # date-filtered: no match
      *) echo '{"releases":[{"id":"mbid-1"}]}' ;; # unfiltered fallback: hit
    esac ;;
  *coverartarchive*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'JPEGDATA' > "$out" ;;
  *lrclib*) echo '{"syncedLyrics":"[00:01.00] la la","plainLyrics":"la la"}' ;;
  *itunes*) echo '{"results":[]}' ;;
  *deezer*) echo '{"data":[]}' ;;
  *inc=url-rels*) echo '{"relations":[]}' ;;
  *musicbrainz*artist/) echo '{"artists":[]}' ;;
  *wikidata*) echo '{"claims":{}}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/curl"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    # the date-filtered query was tried and missed…
    The contents of file "$RIP_SANDBOX/curl.log" should include "date:2004"
    # …the fallback landed the cover anyway
    The contents of file "$RIP_FAKE_MF_LOG" should include "--import-picture-from"
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

  # Live 2026-08-21 (The Black Piper): Deezer also serves placeholder ART
  # (grey silhouette) under a normal per-artist URL hash — the URL check
  # above never fires, and a 16KB placeholder shipped as artist.jpg. The
  # downloaded BYTES must be digest-checked against the known-placeholder
  # denylist (RIP_DEEZER_PLACEHOLDER_FILE_MD5S seam) and rejected the same
  # way: fall through to the Wikidata chain.
  It "artist image: rejects Deezer placeholder BYTES under a clean URL (digest denylist)"
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
  *deezer*search/artist*) echo '{"data":[{"picture_xl":"https://fake-deezer-cdn.test/e4f18b52ef370cf500bac7597eaf7b89.jpg"}]}' ;;
  *fake-deezer-cdn.test*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'DZPLACEHOLDER' > "$out" ;;
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
    export RIP_DEEZER_PLACEHOLDER_FILE_MD5S="$(printf 'DZPLACEHOLDER' | md5 | awk '{print $NF}')"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    # the clean-URL image WAS downloaded (unlike the URL-reject case)…
    The contents of file "$RIP_SANDBOX/curl.log" should include "e4f18b52ef370cf500bac7597eaf7b89.jpg"
    # …but its bytes matched the placeholder denylist, so the fallback won
    The path "$RIP_SANDBOX/server/music/Art/artist.jpg" should be exist
    The contents of file "$RIP_SANDBOX/server/music/Art/artist.jpg" should equal "COMMONSJPEG"
  End

  # Live 2026-08-21 ("Discotecagem pop variada", XLD-converted from old
  # files): macOS/XLD write accented tags DECOMPOSED (NFD — "í" as i +
  # combining acute), while CD rips carried composed (NFC) text. External
  # lookups (LRCLIB especially) match bytes, so NFD queries missed lyrics
  # that NFC finds. _track_meta must hand out NFC; paths never come from
  # tags (fs-derived reldirs), so normalizing here is query-only.
  # Companion to the --iconv rule: the server is NFC-canonical, but the
  # remote-existence checks compose their relpaths from LOCAL folder names
  # — which can be NFD. Unnormalized, the cover check would read a
  # present NFC cover.jpg as "confirmed absent" and refetch over curated
  # art. _remote_has_file must NFC-normalize the relpath it asks about.
  It 'remote-existence check NFC-normalizes its relpath (NFD local vs NFC server)'
    enrich_setup
    # ssh mode ON PURPOSE: local-dir mode cannot catch this — macOS APFS
    # path lookup is normalization-insensitive, so an NFD path finds an
    # NFC file and the example passes with or without the fix. The real
    # server (ext4 over ssh) is byte-strict; the fake ssh below stands in
    # for it, answering "exists" ONLY to the composed (NFC) bytes.
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<FAKESSH
#!/bin/sh
case "\$*" in
  *"music/$(printf 'P\xc3\xa9')/artist.jpg"*) exit 0 ;;
esac
exit 1
FAKESSH
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::_remote_has_file \"music/$(printf 'Pe\xcc\x81')/artist.jpg\""
    The status should equal 0
  End

  # Live 2026-08-21 (Picard over the SMB share): a staged file named in
  # macOS-decomposed Unicode (NFD) ships byte-identically, and the server
  # then holds a name the macOS SMB client cannot OPEN — it lists NFD but
  # opens NFC, so Samba byte-compares and 404s. The library is
  # NFC-canonical from here on: both rsync invocations (push AND verify)
  # must translate names on the wire via --iconv=utf-8-mac,utf-8.
  It 'push and verify rsync both normalize names on the wire (--iconv)'
    export RIP_PUSH_MIN_AGE_S=0
    mkdir -p "$RIP_STAGING_ROOT/music/N/Alb"
    printf 'x' > "$RIP_STAGING_ROOT/music/N/Alb/01 T.flac"
    export RIP_FAKE_RSYNC_ARGS="$RIP_SANDBOX/rsync-args.log"
    : > "$RIP_FAKE_RSYNC_ARGS"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_RSYNC_ARGS"
case "$*" in *-rcn*) exit 0 ;; *) exit 0 ;; esac
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The line 1 of contents of file "$RIP_FAKE_RSYNC_ARGS" should include "--iconv=utf-8-mac,utf-8"
    The line 2 of contents of file "$RIP_FAKE_RSYNC_ARGS" should include "--iconv=utf-8-mac,utf-8"
  End

  # Live 2026-08-21 (Spirit of Africa): the transfer group runs 4 wide, and
  # a second music push enqueued mid-transfer of the first read the same
  # staged files — then had them verify-DELETED from under its rsync
  # (rc 24 "file has vanished"; every file was already safe via the first
  # push, but the loser failed a job and alarmed the operator). Same-type
  # pushes must SERIALIZE: a blocking flock, taken BEFORE the file list is
  # built, so the waiter globs post-clean staging and ships only the new.
  It 'concurrent same-type pushes serialize instead of racing (rc-24 vanish)'
    export RIP_PUSH_MIN_AGE_S=0
    export RIP_FAKE_RSYNC_ORDER="$RIP_SANDBOX/order.log"
    : > "$RIP_FAKE_RSYNC_ORDER"
    cat > "$RIP_SANDBOX/rsync" <<'EOF'
#!/bin/sh
case "$*" in *-rcn*) exit 0 ;; esac
printf 'start\n' >> "$RIP_FAKE_RSYNC_ORDER"
sleep 1
lf=""
for a in "$@"; do case "$a" in --files-from=*) lf="${a#--files-from=}";; esac; done
src=""; dst=""
for a in "$@"; do case "$a" in -*|--*) continue;; *) [ -z "$src" ] && src="$a" || dst="$a";; esac; done
if [ -n "$lf" ] && [ -n "$src" ] && [ -n "$dst" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$dst/$(dirname "$rel")"
    cp "$src/$rel" "$dst/$rel"
  done < "$lf"
fi
printf 'end\n' >> "$RIP_FAKE_RSYNC_ORDER"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    serialize_run() {
      mkdir -p "$RIP_STAGING_ROOT/music/Art/Alpha"
      printf 'a' > "$RIP_STAGING_ROOT/music/Art/Alpha/01 One.flac"
      zsh -c "source $RIPLIB && rip::push_worker music" >/dev/null 2>&1 &
      local first=$!
      sleep 0.3
      mkdir -p "$RIP_STAGING_ROOT/music/Art/Beta"
      printf 'b' > "$RIP_STAGING_ROOT/music/Art/Beta/01 Two.flac"
      zsh -c "source $RIPLIB && rip::push_worker music" >/dev/null 2>&1
      local rc2=$?
      wait $first
      local rc1=$?
      printf '%s %s\n' "$rc1" "$rc2"
    }
    When call serialize_run
    The output should equal "0 0"
    # strict serialization: start end start end — never start start
    The line 1 of contents of file "$RIP_FAKE_RSYNC_ORDER" should equal "start"
    The line 2 of contents of file "$RIP_FAKE_RSYNC_ORDER" should equal "end"
    The line 3 of contents of file "$RIP_FAKE_RSYNC_ORDER" should equal "start"
    The line 4 of contents of file "$RIP_FAKE_RSYNC_ORDER" should equal "end"
    The path "$RIP_SANDBOX/server/music/Art/Alpha/01 One.flac" should be exist
    The path "$RIP_SANDBOX/server/music/Art/Beta/01 Two.flac" should be exist
  End

  # Live 2026-08-21 (the real root of the lyrics corruption): pueue spawns
  # workers with NO locale — under C, metaflac transliterates non-ASCII on
  # BOTH read (queries became "A'i c^e falou" → LRCLIB misses) and write
  # (every accented char in every push-embedded lyric shipped as "##").
  # Sourcing rip.zsh must guarantee a UTF-8 LC_CTYPE; the scoped
  # LC_ALL=C tr pipes are unaffected (LC_ALL outranks LC_CTYPE per-command).
  It 'lib: sourcing under a bare C locale exports a UTF-8 LC_CTYPE'
    When run env -u LANG -u LC_ALL -u LC_CTYPE zsh -c "source $RIPLIB && print -r -- \$LC_CTYPE"
    The status should equal 0
    The output should include "UTF-8"
  End

  It 'track meta: decomposed (NFD) tags are normalized to NFC'
    enrich_setup
    cat > "$RIP_SANDBOX/metaflac" <<EOF
#!/bin/sh
case "\$*" in
  *--show-tag=ARTIST*) printf 'ARTIST=Jota Quest\n' ;;
  *--show-tag=ALBUM*)  printf 'ALBUM=Discotecagem\n' ;;
  *--show-tag=TITLE*)  printf 'TITLE=A$(printf 'i\xcc\x81') c$(printf 'e\xcc\x82') falou\n' ;;
  *--show-tag=DATE*)   printf 'DATE=2003\n' ;;
  *--show-total-samples*) printf '441000\n' ;;
  *--show-sample-rate*) printf '44100\n' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/metaflac"
    When run zsh -c "source $RIPLIB && rip::_track_meta whatever.flac"
    The status should equal 0
    # composed forms present (í = C3 AD, ê = C3 AA)…
    The output should include "$(printf 'A\xc3\xad c\xc3\xaa falou')"
    # …decomposed combining sequences gone
    The output should not include "$(printf 'i\xcc\x81')"
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

  # Live defect (root-caused by the controller, 2026-08-20): the
  # artist-image chain missed on a real push while the SAME chain
  # succeeded standalone. MusicBrainz rate-limits to ~1 req/s; the
  # enrichment pass had just made its own MB cover-lookup call, so the
  # artist-image step's MB search landed right behind it and got 503'd —
  # `curl -sf` fails silently and the chain honestly reported a miss on
  # data that was really there. rip::_mb_call now paces every MB call and
  # retries once (both suite-wide zeroed via RIP_MB_PAUSE_S /
  # RIP_MB_RETRY_PAUSE_S in setup() so this stays fast).

  It 'cover: MusicBrainz release search retries once after a transient rate-limit failure, then lands the cover'
    enrich_setup
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_CURL_LOG"
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  *musicbrainz*/release/)
    n=0
    [ -f "$RIP_SANDBOX/mb_release_count" ] && n=$(cat "$RIP_SANDBOX/mb_release_count")
    n=$((n+1))
    echo "$n" > "$RIP_SANDBOX/mb_release_count"
    [ "$n" -eq 1 ] && exit 22   # simulate a 503: curl -sf fails silently
    echo '{"releases":[{"id":"mbid-1"}]}' ;;
  *coverartarchive*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] && printf 'JPEGDATA' > "$out" ;;
  *lrclib*) echo '{"syncedLyrics":"[00:01.00] la la","plainLyrics":"la la"}' ;;
  *itunes*) echo '{"results":[]}' ;;
  *deezer*) echo '{"data":[]}' ;;
  *inc=url-rels*) echo '{"relations":[]}' ;;
  *musicbrainz*artist/) echo '{"artists":[]}' ;;
  *wikidata*) echo '{"claims":{}}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/curl"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_FAKE_MF_LOG" should include "--import-picture-from"
    # proves the retry actually fired — not just that the end state happened
    The result of function mb_release_call_count should equal "2"
  End

  It 'artist image: MusicBrainz artist search retries once after a transient rate-limit failure, then still lands the image'
    enrich_setup
    fake_copy_rsync
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_CURL_LOG"
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  *musicbrainz*artist/)
    n=0
    [ -f "$RIP_SANDBOX/mb_artist_count" ] && n=$(cat "$RIP_SANDBOX/mb_artist_count")
    n=$((n+1))
    echo "$n" > "$RIP_SANDBOX/mb_artist_count"
    [ "$n" -eq 1 ] && exit 22   # simulate a 503: curl -sf fails silently
    echo '{"artists":[{"id":"mbid-artist-1"}]}' ;;
  *inc=url-rels*) echo '{"relations":[{"url":{"resource":"https://www.wikidata.org/wiki/Q42"}}]}' ;;
  *musicbrainz*) echo '{"releases":[{"id":"mbid-1"}]}' ;;
  *deezer*) echo '{"data":[]}' ;;
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
    The path "$RIP_SANDBOX/server/music/Art/artist.jpg" should be exist
    The contents of file "$RIP_SANDBOX/server/music/Art/artist.jpg" should equal "COMMONSJPEG"
    The result of function mb_artist_call_count should equal "2"
  End

  # Final consolidated-review fix wave (round 4, 2026-08-20): three
  # Importants against the round-3 code.

  # Finding 1: embedded-first used to probe ONLY ${flacs[1]} — find/
  # listfile order is arbitrary, so a partially-embedded album whose
  # first-enumerated track happens to be art-less still external-fetched,
  # burying a LATER track's correct embedded art under a wrong cover.jpg.
  # Fix loops every listed flac and exports from the first one (in listed
  # order) that carries a PICTURE block. Drives rip::_enrich_music
  # directly with a hand-built listfile (rather than going through
  # push_worker's find-based one) specifically so the art-less-first
  # ordering is deterministic, not filesystem-traversal-order-dependent.
  It 'cover embedded-first loops ALL listed flacs — an art-less track enumerated first must not bury a later art-bearing track under an external fetch'
    enrich_setup
    mkdir -p "$RIP_STAGING_ROOT/music/Art/Alb"
    touch "$RIP_STAGING_ROOT/music/Art/Alb/01 NoArt.flac" "$RIP_STAGING_ROOT/music/Art/Alb/02 HasArt.flac"
    cat > "$RIP_SANDBOX/metaflac" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_MF_LOG"
case "$*" in
  *"--list --block-type=PICTURE"*"01 NoArt.flac") exit 0 ;;
  *"--list --block-type=PICTURE"*"02 HasArt.flac") echo "METADATA block #2"; echo "  type: 6 (PICTURE)" ;;
  *--export-picture-to=*)
    out=""
    for a in "$@"; do case "$a" in --export-picture-to=*) out="${a#--export-picture-to=}";; esac; done
    [ -n "$out" ] && printf 'EMBEDDEDJPEG' > "$out" ;;
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
    listfile="$RIP_SANDBOX/enrich.list"
    # art-less track listed FIRST — the exact ordering the old ${flacs[1]}-
    # only code would have gotten wrong.
    printf 'Art/Alb/01 NoArt.flac\nArt/Alb/02 HasArt.flac\n' > "$listfile"
    When run zsh -c "source $RIPLIB && rip::_enrich_music '$RIP_STAGING_ROOT/music' '$listfile'"
    The status should equal 0
    The contents of file "$RIP_FAKE_MF_LOG" should include "--export-picture-to"
    The path "$RIP_STAGING_ROOT/music/Art/Alb/cover.jpg" should be exist
    The contents of file "$RIP_STAGING_ROOT/music/Art/Alb/cover.jpg" should equal "EMBEDDEDJPEG"
    # no external cover source was ever consulted
    The contents of file "$RIP_SANDBOX/curl.log" should not include "coverartarchive"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "itunes"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "/release/"
    # the artist-image step also runs here (calling rip::_enrich_music
    # directly still exercises it) and best-effort misses via the shared
    # enrich_setup curl fake — unrelated to this example's assertion, but
    # covered so shellspec doesn't flag it as unaccounted-for stdout
    The output should include "no artist image found"
  End

  # Finding 2: rip::_mb_call used to retry on ANY empty parse, including a
  # clean, successful, legitimately-empty response (a real miss — e.g. the
  # by-design date-filtered miss in rip::_fetch_cover) — doubling MB
  # traffic and adding up to 8s of sleep on every ordinary miss. Fix
  # retries ONLY on curl's own transport failure (its rc, captured
  # separately from jq's parse). The "retries on a genuine transport
  # failure" half is already covered by the two MB-retry examples above
  # (their fakes `exit 22` on the first call — a transport failure, not an
  # empty parse); this example is the other half: a clean 200 with an
  # empty body must NOT trigger a second call.
  It 'rip::_mb_call does not retry a clean, successful, empty MusicBrainz response (a real miss, not a rate-limit symptom)'
    enrich_setup
    cat > "$RIP_SANDBOX/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_FAKE_CURL_LOG"
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a";; esac; done
case "$url" in
  *musicbrainz*/release/)
    n=0
    [ -f "$RIP_SANDBOX/mb_release_count" ] && n=$(cat "$RIP_SANDBOX/mb_release_count")
    n=$((n+1))
    echo "$n" > "$RIP_SANDBOX/mb_release_count"
    echo '{"releases":[]}' ;;   # clean 200, genuinely no match
  *coverartarchive*) : ;;
  *lrclib*) echo '{"syncedLyrics":"[00:01.00] la la","plainLyrics":"la la"}' ;;
  *itunes*) echo '{"results":[]}' ;;
  *deezer*) echo '{"data":[]}' ;;
  *inc=url-rels*) echo '{"relations":[]}' ;;
  *musicbrainz*artist/) echo '{"artists":[]}' ;;
  *wikidata*) echo '{"claims":{}}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/curl"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The stderr should include "enrich"
    The result of function mb_release_call_count should equal "1"
  End

  # Finding 3: cover.jpg lacked the server-side already-exists check that
  # artist.jpg has — a future re-rip of an art-less album would refetch
  # and rsync-overwrite a curated server cover (live case: the
  # hand-corrected "MTV ao Vivo"). Fix mirrors the artist.jpg tri-state
  # check (rip::_remote_has_file, shared helper) ahead of any export or
  # fetch; when the server already has cover.jpg, the ENTIRE cover step is
  # skipped this run — no export, no fetch, no per-track embeds — logged
  # once.
  It 'cover: server already has cover.jpg — entire cover step skipped this run (no export, no fetch, no embeds), logged once'
    enrich_setup
    mkdir -p "$RIP_SANDBOX/server/music/Art/Alb"
    printf 'CURATED-SERVER-COVER' > "$RIP_SANDBOX/server/music/Art/Alb/cover.jpg"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The output should include "rip: cover — server already has Art/Alb/cover.jpg, skipping this run"
    The path "$RIP_STAGING_ROOT/music/Art/Alb/cover.jpg" should not be exist
    The contents of file "$RIP_FAKE_MF_LOG" should not include "--export-picture-to"
    The contents of file "$RIP_FAKE_MF_LOG" should not include "--import-picture-from"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "coverartarchive"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "itunes"
    The contents of file "$RIP_SANDBOX/curl.log" should not include "/release/"
  End

  # Regression guard (round 4 leak, live-caught in review while adding the
  # findings above): a genuine zsh behavior — confirmed identically on
  # stock zsh 5.9 and this fleet's zsh build — prints "name=value" to
  # STDOUT whenever `local name` (bare, no `=value`) re-declares a
  # variable that's ALREADY local in the current scope with a value set.
  # rip::_enrich_music's per-album loop used to re-declare several bare
  # `local`s (including the pre-existing `rel2`) INSIDE the loop body,
  # which is silent for a single-album run but leaks every one of those
  # variables' previous-album values as bare "name=value" stdout lines on
  # the SECOND and later albums of any multi-album push. Fixed by hoisting
  # every bare `local` to the top of the function, declared exactly once.
  It 'enrichment never leaks bare "name=value" lines on a multi-album run'
    mkdir -p "$RIP_STAGING_ROOT/music/Art/Alb1" "$RIP_STAGING_ROOT/music/Art/Alb2"
    touch "$RIP_STAGING_ROOT/music/Art/Alb1/01 Song.flac" "$RIP_STAGING_ROOT/music/Art/Alb2/01 Other.flac"
    printf '#!/bin/sh\nexit 0\n' > "$RIP_SANDBOX/rsync"; chmod +x "$RIP_SANDBOX/rsync"
    export RIP_RSYNC_BIN="$RIP_SANDBOX/rsync"
    When run zsh -c "source $RIPLIB && rip::push_worker music"
    The status should equal 0
    The output should include "verified"
    The output should not include "='"
    The output should not include "rel2="
    The output should not include "artist_rel="
  End

  It 'sidecar: written from the meta index, work key null at ingest'
    mkdir -p "$RIP_SANDBOX/bk"
    printf '%s\n' '{"path":"Brandon Sanderson/Steelheart","title":"Steelheart","subtitle":"The Reckoners, Book 1","authors":["Brandon Sanderson"],"narrators":["MacLeod Andrews"],"duration_s":45720,"series":"Reckoners","series_position":"1","language":"en","abridged":false,"ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","provider_version":"13.7.10","acquired_utc":"2026-08-22T15:18:03Z","format":"m4b"}' \
      > "$RIP_SANDBOX/index.jsonl"
    export RIP_AB_META_INDEX="$RIP_SANDBOX/index.jsonl"
    When run zsh -c "source $RIPLIB && rip::_book_meta_for 'Brandon Sanderson/Steelheart' > $RIP_SANDBOX/m.json && rip::_book_sidecar $RIP_SANDBOX/bk $RIP_SANDBOX/m.json && jq -c '[.schema,.kind,.title,.ids[\"audible.asin\"],.work,.source.provider,.abridged]' $RIP_SANDBOX/bk/.fleet-book.json"
    The status should equal 0
    The output should equal '[1,"audiobook","Steelheart","B00ECDZ08I",null,"libation",false]'
  End

  It 'sidecar: minimal identity when the book is not in the index'
    mkdir -p "$RIP_SANDBOX/bk"
    export RIP_AB_META_INDEX="$RIP_SANDBOX/missing.jsonl"
    When run zsh -c "source $RIPLIB && rip::_book_meta_for 'Some Author/Some Title' > $RIP_SANDBOX/m.json && rip::_book_sidecar $RIP_SANDBOX/bk $RIP_SANDBOX/m.json && jq -c '[.title,.authors,.ids,.work,.source.provider]' $RIP_SANDBOX/bk/.fleet-book.json"
    The status should equal 0
    The output should equal '["Some Title",["Some Author"],{},null,"unknown"]'
  End

  It 'sidecar: merge never clobbers a resolved work key or foreign ids'
    mkdir -p "$RIP_SANDBOX/bk"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"Steelheart","ids":{"audible.asin":"B00ECDZ08I","isbn13":"9780593344",  "librofm.id":"x1"},"work":{"openlibrary":"OL15168631W"},"source":{"provider":"libation"}}' \
      | jq . > "$RIP_SANDBOX/bk/.fleet-book.json"
    printf '%s\n' '{"path":"A/B","title":"Steelheart","authors":["Brandon Sanderson"],"ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","provider_version":"13.7.10","acquired_utc":"2026-08-22T15:18:03Z","format":"m4b"}' \
      > "$RIP_SANDBOX/m.json"
    When run zsh -c "source $RIPLIB && rip::_book_sidecar $RIP_SANDBOX/bk $RIP_SANDBOX/m.json && jq -c '[.work.openlibrary,.ids[\"librofm.id\"],.authors]' $RIP_SANDBOX/bk/.fleet-book.json"
    The status should equal 0
    The output should equal '["OL15168631W","x1",["Brandon Sanderson"]]'
  End

  It 'sidecar: re-running leaves the file byte-identical'
    mkdir -p "$RIP_SANDBOX/bk"
    printf '%s\n' '{"path":"A/B","title":"B","authors":["A"],"ids":{},"provider":"unknown","acquired_utc":"2026-08-22T15:18:03Z","format":"m4b"}' > "$RIP_SANDBOX/m.json"
    When run zsh -c "source $RIPLIB && rip::_book_sidecar $RIP_SANDBOX/bk $RIP_SANDBOX/m.json && cp $RIP_SANDBOX/bk/.fleet-book.json $RIP_SANDBOX/first && mtime1=\$(stat -f %m $RIP_SANDBOX/bk/.fleet-book.json) && sleep 1 && rip::_book_sidecar $RIP_SANDBOX/bk $RIP_SANDBOX/m.json && cmp -s $RIP_SANDBOX/first $RIP_SANDBOX/bk/.fleet-book.json && mtime2=\$(stat -f %m $RIP_SANDBOX/bk/.fleet-book.json) && [ -z \"\$(find $RIP_SANDBOX/bk -name '.fleet-book.json.tmp.*' 2>/dev/null)\" ] && [ \"\$mtime1\" = \"\$mtime2\" ] && echo stable"
    The status should equal 0
    The output should equal "stable"
  End
End
