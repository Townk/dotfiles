# rip-disc — makemkvcon auto-rip chained into the pipeline, one capsule,
# plus the Rip Session Review flow (--scan / --have / --session /
# --session-worker) the webview panel drives.
Describe 'rip.zsh disc'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"
  RIPBIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-disc"

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
    # fake makemkvcon.
    #
    # `-r info` prints three titles (idx 0 short, idx 1 long, idx 2 middling)
    # in the real -r TINFO shape: attr 9 = duration, attr 10 = human size
    # string, attr 11 = size in bytes (MakeMKV's ap_ItemAttributeId enum).
    # Deliberately interleaved with attributes the parse must IGNORE —
    # including a NAME (attr 2) whose value carries a comma and a source
    # filename (attr 27) — so a naive comma-split parse cannot pass.
    #
    # `mkv` emits PRGV progress and drops a file in the target dir under a
    # name of MakeMKV's own choosing (the session worker must not trust it:
    # it renames the newest file to title-<no>.mkv itself). RIP_FAKE_MKV_RC
    # fails every rip; RIP_FAKE_MKV_FAIL_TITLE fails only the named title
    # number (the mid-session rip failure).
    cat > "$RIP_SANDBOX/makemkvcon" <<'EOF'
#!/bin/sh
case "$*" in
  *info*)
    [ -n "${RIP_FAKE_INFO_EMPTY:-}" ] && exit 1
    echo 'TINFO:0,2,0,"Trailer, Theatrical"'
    echo 'TINFO:0,9,0,"0:00:38"'
    echo 'TINFO:0,10,0,"58.0 MB"'
    echo 'TINFO:0,11,0,"60817408"'
    echo 'TINFO:0,27,0,"title_t00.mkv"'
    echo 'TINFO:1,9,0,"2:08:59"'
    echo 'TINFO:1,10,0,"6.9 GB"'
    echo 'TINFO:1,11,0,"7408345088"'
    echo 'TINFO:2,9,0,"0:26:14"'
    echo 'TINFO:2,10,0,"1.1 GB"'
    echo 'TINFO:2,11,0,"1181116006"'
    ;;
  *mkv*)
    dir=""; prev=""; no=""
    for a in "$@"; do no="$prev"; prev="$dir"; dir="$a"; done
    no="$prev"
    printf '%s\n' "$*" >> "${RIP_FAKE_MKC_LOG:-/dev/null}"
    # CR-terminated, mimicking a real pty's ONLCR translation (\n -> \r\n)
    # — the fix under test has to tolerate that, not just a bare \n. Always
    # emitted first (even ahead of a forced failure below) so the
    # CR-tolerance example can see a genuine mid-rip percentage rather than
    # nothing at all.
    printf 'PRGV:16384,0,65536\r\n'
    [ -n "${RIP_FAKE_MKV_RC:-}" ] && exit "$RIP_FAKE_MKV_RC"
    [ "${RIP_FAKE_MKV_FAIL_TITLE:-none}" = "$no" ] && exit 1
    printf 'PRGV:32768,0,65536\r\n'
    printf 'PRGV:65536,0,65536\r\n'
    printf 'ripped-%s' "$no" > "$dir/makemkv_t$no.mkv"
    ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/makemkvcon"; export RIP_MAKEMKVCON_BIN="$RIP_SANDBOX/makemkvcon"
    # fake HandBrakeCLI: logs every invocation (so an example can assert an
    # item was NEVER encoded — the per-item server-idempotency path) and can
    # be failed for exactly one input file (RIP_FAKE_HB_FAIL_INPUT).
    export RIP_FAKE_HB_LOG="$RIP_SANDBOX/hb.log"; : > "$RIP_FAKE_HB_LOG"
    cat > "$RIP_SANDBOX/HandBrakeCLI" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${RIP_FAKE_HB_LOG:-/dev/null}"
out=""; inp=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "-i" ] && inp="$a"
  prev="$a"
done
case "$inp" in
  *"${RIP_FAKE_HB_FAIL_INPUT:-__never__}") exit 7 ;;
esac
echo 'Encoding: task 1 of 1, 100.00 %'
printf 'encoded' > "$out"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/HandBrakeCLI"; export RIP_HANDBRAKE_BIN="$RIP_SANDBOX/HandBrakeCLI"
    # copying fake (mirrors rip-extra_spec.sh / rip-push_spec.sh): actually
    # `cp`s the listed files into the local sandbox "remote" so an example
    # can assert on the bytes that landed server-side rather than inferring
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

  # A session plan on disk, as Hammerspoon's hs.json.encode would write it.
  write_plan() { cat > "$RIP_SANDBOX/plan.json"; }
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

  #==========================================================================
  # Rip Session Review — the panel-driven flow
  #==========================================================================

  # --- --scan: the panel's row data ----------------------------------------

  It '--scan emits one JSON line per title with duration, seconds, size, bytes'
    When run zsh "$RIPBIN" --scan
    The status should equal 0
    The line 1 of output should equal '{"no":0,"duration":"0:00:38","seconds":38,"size":"58.0 MB","bytes":60817408}'
    The line 2 of output should equal '{"no":1,"duration":"2:08:59","seconds":7739,"size":"6.9 GB","bytes":7408345088}'
    The line 3 of output should equal '{"no":2,"duration":"0:26:14","seconds":1574,"size":"1.1 GB","bytes":1181116006}'
    # The NAME attribute ("Trailer, Theatrical") and the source filename are
    # not title rows and must never leak into the stream.
    The output should not include "Theatrical"
    The output should not include "title_t00"
  End

  It '--scan reports rc 1 when the drive holds no readable titles'
    export RIP_FAKE_INFO_EMPTY=1
    When run zsh "$RIPBIN" --scan
    The status should equal 1
    The stderr should include "no titles"
  End

  It '--scan runs makemkvcon under the pty wrap seam'
    export RIP_FAKE_PTY_LOG="$RIP_SANDBOX/pty.log"; : > "$RIP_FAKE_PTY_LOG"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$RIP_FAKE_PTY_LOG"\nexec "$@"\n' > "$RIP_SANDBOX/ptywrap"
    chmod +x "$RIP_SANDBOX/ptywrap"
    export RIP_PTY_WRAP="$RIP_SANDBOX/ptywrap"
    When run zsh "$RIPBIN" --scan
    The status should equal 0
    The output should include '"no":1'
    The contents of file "$RIP_FAKE_PTY_LOG" should include "makemkvcon"
  End

  # --- --have: the server check behind the auto-extras flip -----------------

  It '--have exits 0 when the server already holds the movie'
    mkdir -p "$RIP_SANDBOX/server/movies/A Movie (2001)"
    printf 'x' > "$RIP_SANDBOX/server/movies/A Movie (2001)/A Movie (2001).mkv"
    When run zsh "$RIPBIN" --have "A Movie (2001)"
    The status should equal 0
    The output should equal ""
  End

  It '--have exits 1 when the server confirms the movie is absent'
    When run zsh "$RIPBIN" --have "A Movie (2001)"
    The status should equal 1
    The output should equal ""
  End

  It '--have exits 2 when the check itself cannot run (unknown, never guess)'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    printf '#!/bin/sh\nexit 255\n' > "$RIP_SANDBOX/ssh"; chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh "$RIPBIN" --have "A Movie (2001)"
    The status should equal 2
    The output should equal ""
  End

  It '--have rejects a movie title carrying a slash before it ever asks'
    When run zsh "$RIPBIN" --have "A/B (2001)"
    The status should equal 2
    The stderr should include "slash"
  End

  # --- session worker ------------------------------------------------------

  It 'session worker: feature + two extras rip, encode, publish and push'
    export JOB_ID="job-session-1"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    export RIP_FAKE_MKC_LOG="$RIP_SANDBOX/mkc.log"; : > "$RIP_FAKE_MKC_LOG"
    write_plan <<'EOF'
{"volume":"U2_360_ROSE_BOWL",
 "feature":{"no":1,"movie":"U2 360 at the Rose Bowl (2010)"},
 "extras":[{"no":2,"name":"Squaring the Circle","attachTo":"U2 360 at the Rose Bowl (2010)"},
           {"no":0,"name":"Trailer","attachTo":"U2 360 at the Rose Bowl (2010)"}],
 "skipped":[3]}
EOF
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::session_worker '$RIP_SANDBOX/plan.json'"
    The status should equal 0
    The output should include "verified"
    The path "$RIP_SANDBOX/server/movies/U2 360 at the Rose Bowl (2010)/U2 360 at the Rose Bowl (2010).mkv" should be exist
    The path "$RIP_SANDBOX/server/movies/U2 360 at the Rose Bowl (2010)/extras/Squaring the Circle.mkv" should be exist
    The path "$RIP_SANDBOX/server/movies/U2 360 at the Rose Bowl (2010)/extras/Trailer.mkv" should be exist
    # every selected title was ripped, the skipped one never was
    The contents of file "$RIP_FAKE_MKC_LOG" should include "mkv disc:0 1 "
    The contents of file "$RIP_FAKE_MKC_LOG" should include "mkv disc:0 2 "
    The contents of file "$RIP_FAKE_MKC_LOG" should include "mkv disc:0 0 "
    The contents of file "$RIP_FAKE_MKC_LOG" should not include "mkv disc:0 3 "
    # HandBrake encoded from the renamed session files, never MakeMKV's names
    The contents of file "$RIP_FAKE_HB_LOG" should include "title-1.mkv"
    The contents of file "$RIP_FAKE_HB_LOG" should not include "makemkv_t"
    The path "$RIP_STAGING_ROOT/movies/U2 360 at the Rose Bowl (2010)" should not be exist
    The path "$RIP_STAGING_ROOT/.work/session" should not be exist
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include " 100 "
  End

  It 'session worker: extras-only plan (no feature) lands only the extras'
    export JOB_ID="job-session-2"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    export RIP_FAKE_MKC_LOG="$RIP_SANDBOX/mkc.log"; : > "$RIP_FAKE_MKC_LOG"
    write_plan <<'EOF'
{"volume":"ELVIS_TTWII",
 "feature":null,
 "extras":[{"no":2,"name":"Rehearsals","attachTo":"Elvis TTWII (1970)"}],
 "skipped":[1]}
EOF
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::session_worker '$RIP_SANDBOX/plan.json'"
    The status should equal 0
    The output should include "verified"
    The path "$RIP_SANDBOX/server/movies/Elvis TTWII (1970)/extras/Rehearsals.mkv" should be exist
    The path "$RIP_SANDBOX/server/movies/Elvis TTWII (1970)/Elvis TTWII (1970).mkv" should not be exist
    The contents of file "$RIP_FAKE_MKC_LOG" should not include "mkv disc:0 1 "
    The path "$RIP_STAGING_ROOT/.work/session" should not be exist
  End

  It 'session worker: an item the server already has is never encoded'
    export JOB_ID="job-session-3"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    mkdir -p "$RIP_SANDBOX/server/movies/U2 (2010)/extras"
    printf 'already-there' > "$RIP_SANDBOX/server/movies/U2 (2010)/extras/Trailer.mkv"
    write_plan <<'EOF'
{"volume":"U2","feature":{"no":1,"movie":"U2 (2010)"},
 "extras":[{"no":0,"name":"Trailer","attachTo":"U2 (2010)"}],
 "skipped":[]}
EOF
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::session_worker '$RIP_SANDBOX/plan.json'"
    The status should equal 0
    The output should include "server already has"
    The path "$RIP_SANDBOX/server/movies/U2 (2010)/U2 (2010).mkv" should be exist
    The contents of file "$RIP_FAKE_HB_LOG" should include "title-1.mkv"
    The contents of file "$RIP_FAKE_HB_LOG" should not include "title-0.mkv"
    The contents of file "$RIP_SANDBOX/server/movies/U2 (2010)/extras/Trailer.mkv" should equal "already-there"
  End

  It 'session worker: one item failing to encode never strands the others'
    export JOB_ID="job-session-4"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    export RIP_FAKE_HB_FAIL_INPUT="title-2.mkv"
    write_plan <<'EOF'
{"volume":"U2","feature":{"no":1,"movie":"U2 (2010)"},
 "extras":[{"no":2,"name":"Squaring the Circle","attachTo":"U2 (2010)"},
           {"no":0,"name":"Trailer","attachTo":"U2 (2010)"}],
 "skipped":[]}
EOF
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::session_worker '$RIP_SANDBOX/plan.json'"
    The status should not equal 0
    The stderr should include "encode failed"
    The output should include "verified"
    The path "$RIP_SANDBOX/server/movies/U2 (2010)/U2 (2010).mkv" should be exist
    The path "$RIP_SANDBOX/server/movies/U2 (2010)/extras/Trailer.mkv" should be exist
    The path "$RIP_SANDBOX/server/movies/U2 (2010)/extras/Squaring the Circle.mkv" should not be exist
    The path "$RIP_STAGING_ROOT/.work/session-encode.mkv" should not be exist
  End

  It 'session worker: a mid-session rip failure aborts the whole session'
    export JOB_ID="job-session-5"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    export RIP_FAKE_MKV_FAIL_TITLE=2
    write_plan <<'EOF'
{"volume":"U2","feature":{"no":1,"movie":"U2 (2010)"},
 "extras":[{"no":2,"name":"Squaring the Circle","attachTo":"U2 (2010)"}],
 "skipped":[]}
EOF
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::session_worker '$RIP_SANDBOX/plan.json'"
    The status should equal 1
    The stderr should include "session rip failed"
    The path "$RIP_STAGING_ROOT/.work/session" should not be exist
    The path "$RIP_STAGING_ROOT/movies/U2 (2010)" should not be exist
    The contents of file "$RIP_FAKE_HB_LOG" should equal ""
  End

  # Live failure 2026-08-20 (the whole fleet's workers): the real bins source
  # ONLY rip.zsh, so a worker that does not load job.zsh itself writes no
  # sidecar at all. This example runs the session worker under the PRODUCTION
  # composition and demands the progress file.
  It 'session worker writes the progress sidecar without a pre-loaded job.zsh'
    export JOB_ID="job-session-prodcomp"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    write_plan <<'EOF'
{"volume":"U2","feature":{"no":1,"movie":"U2 (2010)"},"extras":[],"skipped":[]}
EOF
    When run zsh -c "source $RIPLIB && rip::session_worker '$RIP_SANDBOX/plan.json'"
    The status should equal 0
    The output should include "verified"
    The path "$JOB_STATE_ROOT/$JOB_ID/progress" should be exist
    The contents of file "$JOB_STATE_ROOT/$JOB_ID/progress" should include " 100 "
  End

  It 'session worker: the disc rip runs under the pty wrap seam'
    export JOB_ID="job-session-pty"; mkdir -p "$JOB_STATE_ROOT/$JOB_ID"
    export RIP_FAKE_PTY_LOG="$RIP_SANDBOX/pty.log"; : > "$RIP_FAKE_PTY_LOG"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$RIP_FAKE_PTY_LOG"\nexec "$@"\n' > "$RIP_SANDBOX/ptywrap"
    chmod +x "$RIP_SANDBOX/ptywrap"
    export RIP_PTY_WRAP="$RIP_SANDBOX/ptywrap"
    write_plan <<'EOF'
{"volume":"U2","feature":{"no":1,"movie":"U2 (2010)"},"extras":[],"skipped":[]}
EOF
    When run zsh -c "source $JOBLIB; source $RIPLIB && rip::session_worker '$RIP_SANDBOX/plan.json'"
    The status should equal 0
    The output should include "verified"
    The contents of file "$RIP_FAKE_PTY_LOG" should include "makemkvcon"
    The contents of file "$RIP_FAKE_PTY_LOG" should include "HandBrakeCLI"
  End

  # --- plan validation + enqueue -------------------------------------------

  It '--session rejects a feature movie carrying a slash and enqueues nothing'
    write_plan <<'EOF'
{"volume":"U2","feature":{"no":1,"movie":"Face/Off (1997)"},"extras":[],"skipped":[]}
EOF
    When run zsh "$RIPBIN" --session "$RIP_SANDBOX/plan.json"
    The status should equal 2
    The stderr should include "slash"
    The path "$JOB_FAKE_LOG" should not be exist
  End

  It '--session rejects an extra name of ".." and enqueues nothing'
    write_plan <<'EOF'
{"volume":"U2","feature":null,
 "extras":[{"no":2,"name":"..","attachTo":"U2 (2010)"}],"skipped":[]}
EOF
    When run zsh "$RIPBIN" --session "$RIP_SANDBOX/plan.json"
    The status should equal 2
    The stderr should include ".."
    The path "$JOB_FAKE_LOG" should not be exist
  End

  It '--session enqueues one heavy job and stages its own copy of the plan'
    titles() { cat "$JOB_STATE_ROOT"/*/meta.json 2>/dev/null; }
    staged() { cat "$RIP_STAGING_ROOT"/.work/session-*.json 2>/dev/null; }
    write_plan <<'EOF'
{"volume":"U2_360_ROSE_BOWL",
 "feature":{"no":1,"movie":"U2 360 at the Rose Bowl (2010)"},
 "extras":[{"no":2,"name":"Squaring the Circle","attachTo":"U2 360 at the Rose Bowl (2010)"}],
 "skipped":[3]}
EOF
    When run zsh "$RIPBIN" --session "$RIP_SANDBOX/plan.json"
    The status should equal 0
    The output should not equal ""
    The contents of file "$JOB_FAKE_LOG" should include "--group heavy"
    The contents of file "$JOB_FAKE_LOG" should include "/rip-disc --session-worker"
    # the job's command line points at the STAGED copy under .work, never at
    # the caller's temp file (which is gone by the time the job runs)
    The contents of file "$JOB_FAKE_LOG" should include "/.work/session-"
    The result of function titles should include "rip session: U2 360 at the Rose Bowl (2010)"
    The result of function staged should include "Squaring the Circle"
  End

  It '--session falls back to the volume name when the plan has no feature'
    titles() { cat "$JOB_STATE_ROOT"/*/meta.json 2>/dev/null; }
    write_plan <<'EOF'
{"volume":"ELVIS_TTWII","feature":null,
 "extras":[{"no":2,"name":"Rehearsals","attachTo":"Elvis TTWII (1970)"}],"skipped":[]}
EOF
    When run zsh "$RIPBIN" --session "$RIP_SANDBOX/plan.json"
    The status should equal 0
    The output should not equal ""
    The result of function titles should include "rip session: ELVIS_TTWII"
  End
End
