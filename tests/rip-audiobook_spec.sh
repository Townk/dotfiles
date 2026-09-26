# rip-audiobook, part 1 of 4 — the provider contract, the libation provider, retag, enrich and plan.
# Hermetic: sandboxed staging, fake LibationCli (RIP_LIBATION_BIN), fake ssh
# (RIP_SSH_BIN), no network, no GUI. The sandbox and shared helpers live in
# tests/rip_audiobook_helper.sh.
Describe 'rip audiobooks'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  PROVIDER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-libation"
  ABS_BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-abs-authors"
  Include tests/rip_helper.sh
  Include tests/rip_audiobook_helper.sh
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'provider: capabilities describes itself'
    When run zsh "$PROVIDER" capabilities
    The status should equal 0
    The output should include '"name":"libation"'
    The output should include '"can_acquire":true'
  End

  It 'provider: list emits one JSON line per title in the common schema'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include '"id":"B00ECDZ08I"'
    The line 1 should include '"duration_s":45720'
    The line 1 should include '"acquired":false'
    The line 1 should include '"audible.asin":"B00ECDZ08I"'
    The line 2 should include '"acquired":true'
    The line 2 should include '"has_pdf":true'
  End

  It 'seam: libation list still works with no root, and ignores one if given'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include '"id"'
  End

  It 'seam: libation list ignores a root argument rather than failing'
    When run zsh "$PROVIDER" list /tmp/somewhere
    The status should equal 0
    The line 1 should include '"id"'
  End

  It 'seam: ab_library forwards a root to the provider'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-probe" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf 'ROOT=[%s]\n' "$2"
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-probe"
    When run zsh -c "source $RIPLIB && rip::ab_library probe /some/root"
    The status should equal 0
    The output should equal "ROOT=[/some/root]"
  End

  It 'seam: ab_library passes NO second argument when no root is given'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-probe" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf 'ARGC=%s\n' "$#"
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-probe"
    When run zsh -c "source $RIPLIB && rip::ab_library probe"
    The status should equal 0
    The output should equal "ARGC=1"
  End

  It 'provider: rows carry the published date, null when the export omits it'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include '"published":"2013-09-24T07:00:00"'
    The line 2 should include '"published":null'
  End

  It 'provider: path carries Title: Subtitle, the folder Libation actually writes'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include '"path":"Brandon Sanderson/Steelheart: The Reckoners, Book 1"'
    The line 1 should include '"title":"Steelheart"'
    The line 2 should include '"path":"Brandon Sanderson/Wind and Truth"'
  End

  # An Audible Plus title is LICENSED while it sits in the catalog, not
  # owned: when it leaves, the licence goes with it and Libation can never
  # liberate it again. Both facts are already in `export -j` output —
  # IsAudiblePlus and AbsentFromLastScan — and neither was surfaced, which is
  # how four Talon Saga books were lost with no warning at all. The default
  # fixture carries neither key, which pins the // false fallback: a row that
  # predates them must read as "owned, present", never as undefined.
  It 'provider: rows carry the Audible Plus and absent-from-last-scan flags'
    cat > "$RIP_SANDBOX/plus-library.json" <<'JSON'
[
 {"AudibleProductId":"B08X1","Title":"Network Effect","Subtitle":"",
  "AuthorNames":"Martha Wells","NarratorNames":"Kevin R. Free","LengthInMinutes":480,
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true},
 {"AudibleProductId":"B08X2","Title":"Fugitive Telemetry","Subtitle":"",
  "AuthorNames":"Martha Wells","NarratorNames":"Kevin R. Free","LengthInMinutes":300,
  "BookStatus":"NotLiberated","IsAudiblePlus":true,"AbsentFromLastScan":false},
 {"AudibleProductId":"B08X3","Title":"Owned Outright","Subtitle":"",
  "AuthorNames":"Somebody Else","NarratorNames":"N","LengthInMinutes":100,
  "BookStatus":"Liberated"}
]
JSON
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
out=""
while [ $# -gt 0 ]; do
  case "$1" in -p|--path) out="$2" ;; esac
  shift
done
cp "$RIP_SANDBOX/plus-library.json" "$out"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include '"plus":true'
    The line 1 should include '"absent":true'
    The line 2 should include '"plus":true'
    The line 2 should include '"absent":false'
    # the export omits both keys entirely for this one
    The line 3 should include '"plus":false'
    The line 3 should include '"absent":false'
  End

  It 'provider: rows the export says nothing about read as owned and present'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include '"plus":false'
    The line 1 should include '"absent":false'
  End

  It 'provider: cover prefers the local cache, falls back to the CDN'
    touch "$RIP_LIBATION_IMAGES/51kzMpLGP7L_80x80.jpg"
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include "file://$RIP_LIBATION_IMAGES/51kzMpLGP7L_80x80.jpg"
    The line 2 should include "https://m.media-amazon.com/images/I/81abcDEF.jpg"
  End

  It 'provider: never invokes set-status'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The contents of file "$RIP_SANDBOX/libation.log" should not include "set-status"
    The output should include '{"id":"B00ECDZ08I"'
  End

  It 'provider: a missing LibationCli fails cleanly'
    export RIP_LIBATION_BIN="$RIP_SANDBOX/nope"
    When run zsh "$PROVIDER" list
    The status should equal 3
    The stderr should include "LibationCli not found"
  End

  It 'provider: acquire writes into the given dir and reports progress'
    When run zsh "$PROVIDER" acquire B00ECDZ08I "$RIP_STAGING_ROOT/audiobooks"
    The status should equal 0
    The path "$RIP_STAGING_ROOT/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
    The output should include "progress 25"
    The output should include "progress 90"
    The contents of file "$RIP_SANDBOX/libation.log" should include "--id B00ECDZ08I"
    The contents of file "$RIP_SANDBOX/libation.log" should include "Books=$RIP_STAGING_ROOT/audiobooks"
  End

  It 'provider: acquire propagates a download failure'
    export FAKE_LIBERATE_FAIL=1
    When run zsh "$PROVIDER" acquire B00ECDZ08I "$RIP_STAGING_ROOT/audiobooks"
    The status should equal 4
    The stderr should include "download failed"
  End

  # --- rip::ab_provider_bin's name guard (final-review finding, 2026-08-22:
  # "verified correct by inspection only" — these examples are the missing
  # executable proof, not a bug fix). ------------------------------------

  It 'ab_provider_bin: rejects a name containing a slash'
    When run zsh -c "source $RIPLIB && rip::ab_provider_bin 'a/b'"
    The status should equal 2
    The stderr should include "bad provider name"
  End

  # NOTE (found while writing this proof, 2026-08-22): the "" arm of the
  # guard's case pattern is unreachable dead code, NOT a gap this fix is
  # scoped to close — `local name="${1:-${RIP_AB_PROVIDER:-libation}}"`
  # treats an explicitly-empty $1 exactly like an unset one (zsh/bash `:-`
  # semantics), so it always falls through to the "libation" default before
  # the case statement ever sees an empty string; there is no call shape
  # that reaches the "" branch. Confirmed live: `zsh -c 'f() { local
  # name="${1:-${RIP_AB_PROVIDER:-libation}}"; print -r -- "$name"; }; f
  # ""'` prints "libation". Left unchanged (out of this fix's scope, which
  # is test proof for the existing guard, not new guard behavior) — flagged
  # in the fix report instead.

  It 'ab_provider_bin: rejects "."'
    When run zsh -c "source $RIPLIB && rip::ab_provider_bin '.'"
    The status should equal 2
    The stderr should include "bad provider name"
  End

  It 'ab_provider_bin: rejects ".."'
    When run zsh -c "source $RIPLIB && rip::ab_provider_bin '..'"
    The status should equal 2
    The stderr should include "bad provider name"
  End

  It 'ab_provider_bin: resolves the DEPLOYED (non-executable_-prefixed) name when present'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec-deployed"
    mkdir -p "$RIP_LIBEXEC_DIR"
    printf '#!/bin/sh\n' > "$RIP_LIBEXEC_DIR/rip-provider-libation"
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_provider_bin libation"
    The status should equal 0
    The output should equal "$RIP_LIBEXEC_DIR/rip-provider-libation"
  End

  It 'CLI: --library passes the provider rows through'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --library
    The status should equal 0
    The line 1 should include '"id":"B00ECDZ08I"'
  End

  It 'CLI: --server-library lists Author/Title with ONE ssh call'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cd "$RIP_SANDBOX/server/audiobooks" || exit 2
find . -mindepth 2 -maxdepth 2 -type d | sed 's|^\./||'
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --server-library
    The status should equal 0
    The output should equal "Brandon Sanderson/Steelheart"
    The result of function ssh_calls should equal "1"
  End

  It 'CLI: --server-library works against a plain local remote base'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B" "$RIP_SANDBOX/server/audiobooks/A/C"
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --server-library
    The status should equal 0
    The output should include "A/B"
    The output should include "A/C"
  End

  # CONTROLLER OVERRIDE of the brief's local-directory NFC example: macOS
  # APFS path lookup is normalization-insensitive, so an NFD query finds an
  # NFC file whether or not rip::ab_have (via rip::_remote_has_file) ever
  # normalizes anything — that example cannot fail against a broken
  # rip::_nfc. Exercised on the ssh branch instead, mirroring
  # tests/rip-push_spec.sh's 'remote-existence check NFC-normalizes its
  # relpath (NFD local vs NFC server)': a byte-strict fake ssh answers
  # "exists" ONLY to the composed (NFC) bytes, and the call is made with
  # the decomposed (NFD) form — the real server (ext4 over ssh) is
  # byte-strict, so this is the shape that made rip::_remote_has_file
  # NFC-normalize in the first place.
  It 'CLI: --have is tri-state and NFC-normalizes the path (ssh branch, byte-strict)'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<FAKESSH
#!/bin/sh
case "\$*" in
  *"test -d "*"audiobooks/$(printf 'Ant\xc3\xb4nio')/Livro"*) exit 0 ;;
esac
exit 1
FAKESSH
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_have \"\$(printf 'Anto\xcc\x82nio/Livro')\"; echo rc=\$?"
    The status should equal 0
    The output should equal "rc=0"
  End

  It 'CLI: --have reports absent'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --have "Nobody/Nothing"
    The status should equal 1
  End

  # --- final review F2: --have must be PROVIDER-BLIND ----------------------
  #
  # rip::ab_have used to probe "<Author>/<Title>/<Title>.m4b" — an invariant
  # rip::ab_import upholds and Libation satisfies, but one the folder
  # provider never does: it copies source basenames verbatim (the fixture at
  # "worker: forwards the folder provider's plan path" below pins exactly
  # that, landing RawFolder.m4b inside "Edited Author/Edited Title"). So the
  # "already on cantina" refusal could never fire for a locally imported
  # book.
  #
  # THE HARD CONSTRAINT ON THE FIX: this check is shared with the Libation
  # path against ~248 already-stored books, some predating sidecars. Anything
  # stricter than the directory — a .fleet-book.json probe, an *.m4b probe —
  # would report a legacy shape as ABSENT and re-push the whole library. Each
  # legacy shape gets its own line below, and every one must answer 0.
  It 'have: a folder-provider book answers present even though its .m4b is not named after the title'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Edited Author/Edited Title"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/Edited Author/Edited Title/RawFolder.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_have 'Edited Author/Edited Title'; echo rc=\$?"
    The output should equal "rc=0"
  End

  It 'have: every legacy stored shape still answers present, and a missing book still answers absent'
    # 1. Libation's own <Title>/<Title>.m4b, no sidecar (the pre-sidecar era)
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Libation"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/Libation/Libation.m4b"
    # 2. a manual import carrying whatever filename it was given, no sidecar
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Manual"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/Manual/some other name.m4b"
    # 3. a book stored in a format rip::ab_import accepts but the old probe
    #    hardcoded away (.mp3 / .m4a)
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Mp3"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/Mp3/Mp3.mp3"
    # 4. an uppercase extension (the 2026-08-23 finding's shape)
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Upper"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/Upper/Upper.M4B"
    When run zsh -c "source $RIPLIB
      for b in 'A/Libation' 'A/Manual' 'A/Mp3' 'A/Upper' 'A/Missing'; do
        rip::ab_have \"\$b\"; print -r -- \"\$b rc=\$?\"
      done"
    The line 1 of output should equal "A/Libation rc=0"
    The line 2 of output should equal "A/Manual rc=0"
    The line 3 of output should equal "A/Mp3 rc=0"
    The line 4 of output should equal "A/Upper rc=0"
    The line 5 of output should equal "A/Missing rc=1"
  End

  It 'have: an unreachable server is still UNKNOWN (rc 2), never "absent"'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    printf '#!/bin/sh\nexit 255\n' > "$RIP_SANDBOX/ssh"
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_have 'A/B'; echo rc=\$?"
    The output should equal "rc=2"
  End

  # End to end through the worker, on the exact fixture shape the epic's own
  # spec pins: a folder book already on the server under a DIFFERENT filename
  # must be refused, not silently re-acquired into a directory that would
  # then hold two differently-named .m4b (rsync has no --delete).
  It 'session: a folder book already stored under a different filename is refused, not re-acquired'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Edited Author/Edited Title"
    printf 'stored audio\n' > "$RIP_SANDBOX/server/audiobooks/Edited Author/Edited Title/RawFolder.m4b"
    mkdir -p "$RIP_SANDBOX/incoming/RawFolder"
    printf 'retagged audio\n' > "$RIP_SANDBOX/incoming/RawFolder/Edited Title.m4b"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/RawFolder/Edited Title.m4b\",\"path\":\"Edited Author/Edited Title\",\"title\":\"Edited Title\"}]}" > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The stderr should include "already on cantina"
    The stderr should include "Edited Author/Edited Title"
    The stdout should include "nothing settled to push"
    The path "$RIP_SANDBOX/server/audiobooks/Edited Author/Edited Title/Edited Title.m4b" should not be exist
  End

  # --- author identity ------------------------------------------------------

  It 'author norm: punctuation and case collapse, distinct names stay distinct'
    When run zsh -c "source $RIPLIB
      print -r -- \$(rip::_author_norm 'J. R. R. Tolkien')
      print -r -- \$(rip::_author_norm 'J.R.R. Tolkien')
      print -r -- \$(rip::_author_norm 'John Ronald Reuel Tolkien')"
    The status should equal 0
    The line 1 should equal "jrrtolkien"
    The line 2 should equal "jrrtolkien"
    The line 3 should equal "johnronaldreueltolkien"
  End

  It 'author display: initials get a space after the period'
    When run zsh -c "source $RIPLIB
      print -r -- \$(rip::_author_display 'J.K. Rowling')
      print -r -- \$(rip::_author_display 'J.R.R. Tolkien')
      print -r -- \$(rip::_author_display 'e.e. cummings')
      print -r -- \$(rip::_author_display 'A.A. Milne')"
    The status should equal 0
    The line 1 should equal "J. K. Rowling"
    The line 2 should equal "J. R. R. Tolkien"
    The line 3 should equal "e. e. cummings"
    The line 4 should equal "A. A. Milne"
  End

  # The negative cases are the point: a rule that spaces every period would
  # mangle both of these. "Dr" is two letters before the period (not a lone
  # initial); "St. Martin" already has its space and must not gain another.
  It 'author display: two letters before the period is not an initial'
    When run zsh -c "source $RIPLIB && rip::_author_display 'Dr.Smith'"
    The status should equal 0
    The output should equal "Dr.Smith"
  End

  It 'author display: a period already followed by a space is left alone'
    When run zsh -c "source $RIPLIB && rip::_author_display 'St. Martin'"
    The status should equal 0
    The output should equal "St. Martin"
  End

  It 'author display: a name with no periods is untouched'
    When run zsh -c "source $RIPLIB && rip::_author_display 'Brandon Sanderson'"
    The status should equal 0
    The output should equal "Brandon Sanderson"
  End

  It 'author display: empty input stays empty'
    When run zsh -c "source $RIPLIB && rip::_author_display ''"
    The status should equal 0
    The output should equal ""
  End

  It 'author display: idempotent — a second pass changes nothing'
    When run zsh -c "source $RIPLIB
      once=\$(rip::_author_display 'J.K. Rowling')
      twice=\$(rip::_author_display \"\$once\")
      print -r -- \"\$once\"
      print -r -- \"\$twice\"
      print -r -- \$(rip::_author_display 'J. K. Rowling')"
    The status should equal 0
    The line 1 should equal "J. K. Rowling"
    The line 2 should equal "J. K. Rowling"
    The line 3 should equal "J. K. Rowling"
  End

  # THE THIRD IMPLEMENTATION of that same rule, and the reason this example
  # exists. `--retag`'s one shared predicate (_RIP_JQ_TAGS_OK) now has to ask
  # "is this file's `artist` already in its canonical form?" — of probe JSON,
  # inside jq, for a whole library at a time. jq cannot call a zsh function
  # and the sweep cannot fork one per book, so the rule is written a second
  # time in jq as `_canon`, exactly as the panel writes it a second time in
  # JavaScript above.
  #
  # The drift here would be worse than the panel's, because the two halves
  # sit on opposite sides of a write: rip::_author_display PRODUCES the value
  # the staged retag writes, `_canon` DECIDES whether what came back is
  # canonical. A disagreement means a book the writer just repaired reads
  # back as still wrong — refused, retried, refused again, forever.
  #
  # Row for row against rip::_author_display's own table, plus the accented
  # names that are the obvious place for a zsh `[A-Za-z]` range and jq's
  # Oniguruma character class to part ways.
  It 'author display: the jq _canon the predicate uses is the same rule, row for row'
    When run zsh -c "source $RIPLIB
      names=('J.K. Rowling' 'J.R.R. Tolkien' 'e.e. cummings' 'A.A. Milne'
             'Dr.Smith' 'St. Martin' 'Brandon Sanderson' '' 'J. K. Rowling'
             'J.D. Jackson' 'Jim Dale' '.A' 'A.' 'A.B.C' 'AB.C' '1.A'
             'J.K.Rowling' 'Ph.D. Smith' 'María J.L. Ñoño' 'É.K. Test')
      for n in \"\${names[@]}\"; do
        z=\$(rip::_author_display \"\$n\")
        j=\$(jq -rn --arg s \"\$n\" \"\$_RIP_JQ_TAGS_OK\"'\$s|_canon' 2>/dev/null)
        [[ \"\$z\" == \"\$j\" ]] || print -r -- \"DRIFT: [\$n] zsh=[\$z] jq=[\$j]\"
      done
      print -r -- compared"
    The status should equal 0
    The output should equal "compared"
  End

  # --- authoritative tags: the retag (design doc S2/S3) ---------------------
  #
  # The defect this section exists to pin: seven Harry Potter books were
  # ripped with the operator correcting each title in the panel, and
  # Audiobookshelf showed something else — because ABS reads the file's
  # EMBEDDED tags and nothing in this pipeline had ever written one. Two of
  # the seven carried album_artist absent / artist="Jim Dale" and displayed
  # the NARRATOR as the author.
  #
  # The examples below run against REAL media, built here by ffmpeg: a
  # one-second m4b (~1.9KB) with aac audio, a chapter and an attached cover
  # picture. The retag is a REMUX, and the only honest way to know that
  # chapters and cover art survive a remux is to remux something that has
  # them. Where a stub appears it stubs exactly one failure — never the
  # verification, which is the whole point of the feature.

  # rt_real — the retag under test uses the REAL ffmpeg/ffprobe. setup()
  # points RIP_FFMPEG_BIN/RIP_FFPROBE_BIN at the suite's fake pair (see
  # tests/rip_helper.sh) so the ~50 push examples in this file that stage
  # six-byte "m4b" text files keep working; every example in THIS section is
  # about what the real tools actually do to real media, so it opts back in.
  rt_real() { export RIP_FFMPEG_BIN=ffmpeg RIP_FFPROBE_BIN=ffprobe; }

  # rt_fixture <dir> — a real m4b at <dir>/book.m4b, carrying the exact tag
  # shape the defect had: an album_artist in the un-spaced initials form, an
  # artist holding the NARRATOR, a composer, and an album/title that disagree
  # with the path the book is about to land under.
  rt_fixture() {
    mkdir -p "$1"
    printf '%s\n' ';FFMETADATA1' '[CHAPTER]' 'TIMEBASE=1/1000' 'START=0' 'END=1000' \
      'title=Chapter One' > "$RIP_SANDBOX/chap.txt"
    ffmpeg -v error -y -f lavfi -t 1 -i 'anullsrc=r=8000:cl=mono' -c:a aac -b:a 8k "$RIP_SANDBOX/a.m4a"
    ffmpeg -v error -y -f lavfi -i 'color=c=red:s=16x16:d=1' -frames:v 1 "$RIP_SANDBOX/cover.jpg"
    ffmpeg -v error -y -i "$RIP_SANDBOX/a.m4a" -i "$RIP_SANDBOX/cover.jpg" -i "$RIP_SANDBOX/chap.txt" \
      -map 0:a -map 1:v -map_metadata 2 -map_chapters 2 \
      -c:a copy -c:v mjpeg -disposition:v attached_pic \
      -metadata album_artist='J.K. Rowling' -metadata artist='Jim Dale' \
      -metadata composer='Comp Person' -metadata album='Wrong Album' \
      -metadata title='Wrong Title' "$1/book.m4b"
  }

  # rt_fixture_tags <dir> <album_artist> <artist> <composer> <album/title> —
  # the same real m4b, with the two NEVER-REPLACED tags and the book name
  # under the example's control. A literal `-` means the tag is not written
  # at ALL, which is the only honest way to build the "absent stays absent"
  # case: `-metadata artist=` would DELETE a tag rather than never create one,
  # and the two are indistinguishable afterwards.
  #
  # artist/composer go in through the FFMETADATA file rather than as
  # -metadata flags precisely so they can be omitted conditionally without
  # assembling a command line out of a string, which would split every value
  # containing a space (every author's name).
  rt_fixture_tags() {
    mkdir -p "$1"
    { printf '%s\n' ';FFMETADATA1'
      [ "$3" = "-" ] || printf 'artist=%s\n' "$3"
      [ "$4" = "-" ] || printf 'composer=%s\n' "$4"
      printf '%s\n' '[CHAPTER]' 'TIMEBASE=1/1000' 'START=0' 'END=1000' 'title=Chapter One'
    } > "$RIP_SANDBOX/chap.txt"
    ffmpeg -v error -y -f lavfi -t 1 -i 'anullsrc=r=8000:cl=mono' -c:a aac -b:a 8k "$RIP_SANDBOX/a.m4a"
    ffmpeg -v error -y -f lavfi -i 'color=c=red:s=16x16:d=1' -frames:v 1 "$RIP_SANDBOX/cover.jpg"
    ffmpeg -v error -y -i "$RIP_SANDBOX/a.m4a" -i "$RIP_SANDBOX/cover.jpg" -i "$RIP_SANDBOX/chap.txt" \
      -map 0:a -map 1:v -map_metadata 2 -map_chapters 2 \
      -c:a copy -c:v mjpeg -disposition:v attached_pic \
      -metadata album_artist="$2" -metadata album="$5" -metadata title="$5" "$1/book.m4b"
  }

  # rt_has <file> <tag>... — "true"/"false" per tag, from the merged
  # format+stream view. `has()`, not a value read: an absent tag and a tag
  # written empty both read back as "", and this feature's promise is that an
  # absent one is never CREATED.
  RT_HAS='rt_has() { f="$1"; shift; ffprobe -v error -select_streams a:0 -show_entries format_tags:stream_tags -of json -- "$f" 2>/dev/null | jq -r --args "((.format.tags // {}) + (.streams[0].tags // {})) as \$t | [ \$ARGS.positional[] as \$k | (\$t | has(\$k) | tostring) ] | join(\" \")" "$@"; }'

  # rt_stub_copy — an ffmpeg that exits 0 and writes a byte-identical COPY,
  # i.e. the write "worked" and the tags did not take. Unlike the silent stub
  # this one DOES produce a temp file, which is what makes the "nothing is
  # left behind in staging" assertion below able to fail.
  rt_stub_copy() {
    cat > "$RIP_SANDBOX/ffmpeg-copy" <<'EOF'
#!/bin/sh
in=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) in="$2"; shift ;;
    --) shift; out="$1" ;;
  esac
  shift
done
[ -n "$in" ] && [ -n "$out" ] && cp "$in" "$out"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/ffmpeg-copy"
    export RIP_FFMPEG_BIN="$RIP_SANDBOX/ffmpeg-copy" RIP_FFPROBE_BIN=ffprobe
  }

  # VERBATIM, deliberately — the author is written exactly as handed in, with
  # no canonicalization on the way (coordinator ruling, 2026-08-26). The tag
  # must equal what the PATH says, or `--retag` (which compares stored tags
  # against the path) reports a mismatch on every run and rewrites every book
  # on the server forever: a sweep with no fixed point. The canonical initials
  # form enters through the PATH instead — the panel normalises on blur, and
  # --canonicalize-authors repairs stored paths, after which the tags follow
  # and the sweep goes quiet.
  It 'retag: writes album_artist, album and title exactly as given, author verbatim'
    rt_real
    rt_fixture "$RIP_SANDBOX/b1"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::_retag_book '$RIP_SANDBOX/b1/book.m4b' 'J.K. Rowling' 'Deathly Hallows (Full Cast)' || exit 9
      rt_probe '$RIP_SANDBOX/b1/book.m4b' album_artist
      rt_probe '$RIP_SANDBOX/b1/book.m4b' album
      rt_probe '$RIP_SANDBOX/b1/book.m4b' title"
    The status should equal 0
    The line 1 should equal "J.K. Rowling"
    The line 2 should equal "Deathly Hallows (Full Cast)"
    The line 3 should equal "Deathly Hallows (Full Cast)"
  End

  # THE CONVERGENCE PROPERTY, pinned directly. Two things have to be true for
  # the library-wide `--retag` sweep to ever reach a fixed point: the tags a
  # second pass reads must already be right, and that second pass must not
  # rewrite the file. The ffmpeg seam here counts its own invocations, so
  # "did not rewrite" is observed rather than inferred.
  It 'retag: a second pass finds the tags already correct and does not rewrite the file'
    rt_real
    rt_fixture "$RIP_SANDBOX/b6"
    printf '%s\n' '#!/bin/sh' 'printf "run\n" >> "$RIP_SANDBOX/ffmpeg.count"' 'exec ffmpeg "$@"' \
      > "$RIP_SANDBOX/ffmpeg-counting"
    chmod +x "$RIP_SANDBOX/ffmpeg-counting"
    export RIP_FFMPEG_BIN="$RIP_SANDBOX/ffmpeg-counting"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::_retag_book '$RIP_SANDBOX/b6/book.m4b' 'J.K. Rowling' 'Deathly Hallows' || exit 9
      print -r -- \"after-first=\$(wc -l < '$RIP_SANDBOX/ffmpeg.count' | tr -d ' ')\"
      rip::_retag_book '$RIP_SANDBOX/b6/book.m4b' 'J.K. Rowling' 'Deathly Hallows' || exit 9
      print -r -- \"after-second=\$(wc -l < '$RIP_SANDBOX/ffmpeg.count' | tr -d ' ')\"
      rt_probe '$RIP_SANDBOX/b6/book.m4b' album_artist
      rt_probe '$RIP_SANDBOX/b6/book.m4b' album"
    The status should equal 0
    # the first pass really did remux (without this the second-pass count
    # below would prove nothing)
    The line 1 should equal "after-first=1"
    # the second found them already correct and touched nothing
    The line 2 should equal "after-second=1"
    The line 3 should equal "J.K. Rowling"
    The line 4 should equal "Deathly Hallows"
  End

  # "We did not write it" is NOT "it survived the remux" — a remux that
  # dropped these two would look identical from the writing side. Neither is
  # ever REPLACED: artist holds the NARRATOR in some files and the author in
  # others, and guessing is what produced the defect. Both names here are
  # already canonical (no initials to space), so the normalise-in-place pass
  # is a no-op on them and the assertion is BY VALUE, byte for byte — which
  # is the only way to tell "left alone" from "quietly rewritten".
  It 'retag: artist and composer come through the remux with their values intact'
    rt_real
    rt_fixture "$RIP_SANDBOX/b2"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::_retag_book '$RIP_SANDBOX/b2/book.m4b' 'J.K. Rowling' 'Deathly Hallows' || exit 9
      rt_probe '$RIP_SANDBOX/b2/book.m4b' artist
      rt_probe '$RIP_SANDBOX/b2/book.m4b' composer"
    The status should equal 0
    The line 1 should equal "Jim Dale"
    The line 2 should equal "Comp Person"
  End

  # NORMALISED IN PLACE — the follow-up this section grew (2026-08-26, second
  # amendment). Measured on the live library, on a book pushed twenty minutes
  # after the first version landed: album_artist="J. K. Rowling" (ours,
  # canonical) beside artist="J.K. Rowling" (the source file's, untouched) —
  # and Audiobookshelf displayed the UNNORMALISED one. Writing album_artist
  # was not sufficient; ABS reads `artist` in preference in some
  # configurations.
  #
  # Still never REPLACED — `artist` holds the narrator in some of these files
  # and the author in others, and there is no reliable narrator to write. Only
  # the SPELLING is normalised, through the same rip::_author_display the path
  # goes through. That distinction is the whole safety argument: normalising in
  # place cannot introduce a name that was not already in the file. A narrator
  # genuinely called "J.D. Jackson" becomes "J. D. Jackson", which is a
  # correction and not a guess.
  It 'retag: an un-spaced artist and composer are canonicalised IN PLACE, never replaced'
    rt_real
    rt_fixture_tags "$RIP_SANDBOX/n1" 'J. K. Rowling' 'J.D. Jackson' 'A.B. Comp' 'Wrong Title'
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::_retag_book '$RIP_SANDBOX/n1/book.m4b' 'J. K. Rowling' 'Deathly Hallows' || exit 9
      rt_probe '$RIP_SANDBOX/n1/book.m4b' artist
      rt_probe '$RIP_SANDBOX/n1/book.m4b' composer
      rt_probe '$RIP_SANDBOX/n1/book.m4b' album_artist"
    The status should equal 0
    # the narrator is still the narrator — only the initials moved
    The line 1 should equal "J. D. Jackson"
    The line 2 should equal "A. B. Comp"
    The line 3 should equal "J. K. Rowling"
  End

  # ABSENT STAYS ABSENT. A book with no `artist` must not acquire one — the
  # only value this pipeline could invent for it is the author, which is
  # exactly the guess that produced the original defect. has(), not a value
  # read: a tag written empty and a tag never created both read back as "".
  #
  # A GUARD, not a driver: this example passes against the code as it stood
  # before this change too (which wrote neither tag). It is here because the
  # obvious cheap implementation — always pass -metadata artist=<canonical>
  # — would DELETE the tag on a book that had one and never create one on a
  # book that did not, and nothing else in this file would notice.
  It 'retag: an absent artist or composer is never created'
    rt_real
    rt_fixture_tags "$RIP_SANDBOX/n2" 'J. K. Rowling' - - 'Wrong Title'
    When run zsh -c "source $RIPLIB
      $RT_HAS
      rip::_retag_book '$RIP_SANDBOX/n2/book.m4b' 'J. K. Rowling' 'Deathly Hallows' || exit 9
      rt_has '$RIP_SANDBOX/n2/book.m4b' artist composer album_artist"
    The status should equal 0
    The output should equal "false false true"
  End

  # THE EXAMPLE THE SWEEP CONVERGES OR DIVERGES ON. rip::_tags_match answers
  # BOTH "is there anything to do?" and "did it take?" — one predicate, on
  # purpose, so the skip can never be looser than the verify. Now that
  # `artist` is normalised, that predicate must ALSO ask whether artist and
  # composer equal their own canonical form; without it, --retag skips a book
  # whose only fault is an un-spaced `artist`, and the operator's 258 stored
  # books are never repaired — which is the entire point of the change.
  #
  # The ffmpeg seam counts its own invocations, so "was a candidate" and
  # "did not rewrite on the second pass" are both OBSERVED. first=1 is what
  # fails without the predicate change (the book is skipped outright);
  # second=1 is what fails if rip::_author_display were not idempotent, or if
  # the writer and the checker disagreed about what canonical means.
  It 'retag: a book whose ONLY fault is an un-spaced artist is a candidate, and then converges'
    rt_real
    rt_fixture_tags "$RIP_SANDBOX/n3" 'J. K. Rowling' 'J.K. Rowling' - 'Deathly Hallows'
    printf '%s\n' '#!/bin/sh' 'printf "run\n" >> "$RIP_SANDBOX/ffmpeg.count"' 'exec ffmpeg "$@"' \
      > "$RIP_SANDBOX/ffmpeg-counting"
    chmod +x "$RIP_SANDBOX/ffmpeg-counting"
    : > "$RIP_SANDBOX/ffmpeg.count"
    export RIP_FFMPEG_BIN="$RIP_SANDBOX/ffmpeg-counting"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::_retag_book '$RIP_SANDBOX/n3/book.m4b' 'J. K. Rowling' 'Deathly Hallows' || exit 9
      print -r -- \"first=\$(wc -l < '$RIP_SANDBOX/ffmpeg.count' | tr -d ' ')\"
      rip::_retag_book '$RIP_SANDBOX/n3/book.m4b' 'J. K. Rowling' 'Deathly Hallows' || exit 9
      print -r -- \"second=\$(wc -l < '$RIP_SANDBOX/ffmpeg.count' | tr -d ' ')\"
      rt_probe '$RIP_SANDBOX/n3/book.m4b' artist
      rt_probe '$RIP_SANDBOX/n3/book.m4b' album_artist
      rt_probe '$RIP_SANDBOX/n3/book.m4b' album"
    The status should equal 0
    The line 1 should equal "first=1"
    The line 2 should equal "second=1"
    The line 3 should equal "J. K. Rowling"
    The line 4 should equal "J. K. Rowling"
    The line 5 should equal "Deathly Hallows"
  End

  # A remux, not a re-encode: the audio stream, the chapter list and the
  # attached picture all have to be on the other side of it. `-map 0` alone
  # does NOT achieve that on an m4b — the ipod muxer refuses to copy the
  # input's own chapter text track ("Tag text incompatible with output codec
  # id") and fails the whole write, so the input's data streams are excluded
  # and the chapters are re-generated from -map_chapters.
  It 'retag: the audio, the chapters and the attached cover art survive'
    rt_real
    rt_fixture "$RIP_SANDBOX/b3"
    When run zsh -c "source $RIPLIB
      rip::_retag_book '$RIP_SANDBOX/b3/book.m4b' 'J.K. Rowling' 'Deathly Hallows' || exit 9
      ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 -- '$RIP_SANDBOX/b3/book.m4b'
      ffprobe -v error -show_chapters -of json -- '$RIP_SANDBOX/b3/book.m4b' | jq -r '.chapters | length, (.[0].tags.title // \"\")'
      ffprobe -v error -select_streams v -show_entries stream_disposition=attached_pic -of csv=p=0 -- '$RIP_SANDBOX/b3/book.m4b'"
    The status should equal 0
    The line 1 should equal "aac"
    The line 2 should equal "1"
    The line 3 should equal "Chapter One"
    The line 4 should equal "1"
  End

  It 'retag: an ffmpeg that exits 0 having written nothing is REFUSED, not believed'
    rt_real
    rt_fixture "$RIP_SANDBOX/b4"
    rt_stub_silent
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::_retag_book '$RIP_SANDBOX/b4/book.m4b' 'J.K. Rowling' 'Deathly Hallows'
      print -r -- \"rc=\$?\"
      rt_probe '$RIP_SANDBOX/b4/book.m4b' album
      rt_probe '$RIP_SANDBOX/b4/book.m4b' album_artist"
    The status should equal 0
    The line 1 should equal "rc=1"
    # the staged file is exactly as it arrived — not half-written, not partly
    # tagged
    The line 2 should equal "Wrong Album"
    The line 3 should equal "J.K. Rowling"
    The stderr should include "tags"
  End

  It 'retag: an ffmpeg that exits 0 with the tags unchanged is REFUSED, and leaves no temp behind'
    rt_real
    rt_fixture "$RIP_SANDBOX/b5"
    rt_stub_copy
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::_retag_book '$RIP_SANDBOX/b5/book.m4b' 'J.K. Rowling' 'Deathly Hallows'
      print -r -- \"rc=\$?\"
      rt_probe '$RIP_SANDBOX/b5/book.m4b' album
      print -r -- \"temps=\$(find '$RIP_STAGING_ROOT' -name 'retag.*' 2>/dev/null | wc -l | tr -d ' ')\""
    The status should equal 0
    The line 1 should equal "rc=1"
    The line 2 should equal "Wrong Album"
    # the stub DID write a temp (that is what makes this assertion able to
    # fail); the refusal has to have removed it
    The line 3 should equal "temps=0"
    The stderr should include "tags"
  End

  It 'retag: a file that is not there at all is a failure, never a quiet success'
    rt_real
    When run zsh -c "source $RIPLIB && rip::_retag_book '$RIP_SANDBOX/nope.m4b' 'A' 'B'"
    The status should equal 1
    The stderr should include "nope.m4b"
  End

  # --- containers that keep their tags somewhere else -----------------------
  #
  # `-show_entries format_tags` is not "the file's tags", it is one of the two
  # places a tag can live. ogg and opus keep VorbisComment on the audio
  # STREAM, so a format-level read of an opus book returns {} — the
  # comparison could never match, the retag could never be verified, and the
  # book was refused on every single retry. Retry is the entire remedy this
  # design offers, and it cannot clear a deterministic failure: the book sat
  # in staging forever, rc 1 forever. Writing has the same two levels, and
  # `-metadata` alone reaches only the format one (measured: an opus remux
  # with -metadata album_artist=… came back carrying the OLD stream tag).

  # rt_opus <dir> — a real one-second opus book whose tags live on the stream.
  rt_opus() {
    mkdir -p "$1"
    ffmpeg -v error -y -f lavfi -t 1 -i 'anullsrc=r=8000:cl=mono' -c:a libopus \
      -metadata:s:a:0 album_artist='Old AA' -metadata:s:a:0 album='Wrong Album' \
      -metadata:s:a:0 title='Wrong Title' "$1/book.opus"
  }

  It 'retag: an opus book, whose tags live on the STREAM, is written, verified and converges'
    rt_real
    rt_opus "$RIP_SANDBOX/op"
    printf '%s\n' '#!/bin/sh' 'printf "run\n" >> "$RIP_SANDBOX/ffmpeg.count"' 'exec ffmpeg "$@"' \
      > "$RIP_SANDBOX/ffmpeg-counting"
    chmod +x "$RIP_SANDBOX/ffmpeg-counting"
    export RIP_FFMPEG_BIN="$RIP_SANDBOX/ffmpeg-counting"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::_retag_book '$RIP_SANDBOX/op/book.opus' 'Ann Leckie' 'Ancillary Justice' || exit 9
      rt_probe '$RIP_SANDBOX/op/book.opus' album_artist
      rt_probe '$RIP_SANDBOX/op/book.opus' album
      rt_probe '$RIP_SANDBOX/op/book.opus' title
      # THE SECOND PASS IS THE POINT: a book that cannot be verified is
      # refused on every retry forever, so 'it converges' and 'it is not
      # permanently wedged' are the same assertion here.
      rip::_retag_book '$RIP_SANDBOX/op/book.opus' 'Ann Leckie' 'Ancillary Justice' || exit 8
      print -r -- \"remuxes=\$(wc -l < '$RIP_SANDBOX/ffmpeg.count' | tr -d ' ')\""
    The status should equal 0
    The line 1 should equal "Ann Leckie"
    The line 2 should equal "Ancillary Justice"
    The line 3 should equal "Ancillary Justice"
    The line 4 should equal "remuxes=1"
  End

  # WAV's RIFF INFO has no album-artist chunk (two of the three tags take, one
  # can never), and raw ADTS .aac has no metadata container at all. Neither
  # can ever satisfy the verification, so neither may be allowed to become a
  # push that can never succeed. They are excluded DELIBERATELY and said out
  # loud, beside .aax/.aaxc — a warning the operator can act on, not a refusal
  # the operator can only retry.
  It 'retag: containers that cannot carry album_artist are warned about and pushed, never wedged'
    rt_real
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/A/Wav Book" "$RIP_STAGING_ROOT/audiobooks/A/Aac Book"
    ffmpeg -v error -y -f lavfi -t 1 -i 'anullsrc=r=8000:cl=mono' -c:a pcm_s16le \
      "$RIP_STAGING_ROOT/audiobooks/A/Wav Book/book.wav"
    ffmpeg -v error -y -f lavfi -t 1 -i 'anullsrc=r=8000:cl=mono' -c:a aac \
      "$RIP_STAGING_ROOT/audiobooks/A/Aac Book/book.aac"
    When run zsh -c "source $RIPLIB && rip::push_worker audiobooks"
    The status should equal 0
    The stderr should include "book.wav"
    The stderr should include "book.aac"
    The stderr should not include "refusing to push"
    The path "$RIP_SANDBOX/server/audiobooks/A/Wav Book/book.wav" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/A/Aac Book/book.aac" should be exist
    The stdout should include "verified on cantina"
  End

  # --- the enrichment wiring ------------------------------------------------
  #
  # The invariant, end to end: a book's tags say exactly what its PATH says.
  # The book name is taken from the staged directory, not from the provider
  # row's `.title` — those two are NOT the same string (the libation provider
  # emits title "Steelheart" for a directory named "Steelheart: The
  # Reckoners, Book 1"), and it is the directory that the library shows.

  It 'enrich: the pushed book carries the tags its path says, edition and all'
    rt_real
    rt_fixture "$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Goblet of Fire (Full Cast)"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::push_worker audiobooks >/dev/null || exit 9
      book='$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Goblet of Fire (Full Cast)/book.m4b'
      rt_probe \"\$book\" album_artist
      rt_probe \"\$book\" album
      rt_probe \"\$book\" title
      rt_probe \"\$book\" artist"
    The status should equal 0
    # the author dir's own spelling, verbatim — the tag agrees with the path
    # byte for byte, which is what makes the invariant checkable in both
    # directions and what lets the --retag sweep converge
    The line 1 should equal "J.K. Rowling"
    The line 2 should equal "Goblet of Fire (Full Cast)"
    The line 3 should equal "Goblet of Fire (Full Cast)"
    The line 4 should equal "Jim Dale"
    The stderr should not include "refusing"
  End

  It 'enrich: a book whose retag cannot be verified never reaches the rsync'
    rt_real
    rt_fixture "$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Order of the Phoenix"
    rt_stub_silent
    When run zsh -c "source $RIPLIB && rip::push_worker audiobooks"
    The status should equal 1
    The stderr should include "refusing to push"
    # not on the server…
    The path "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Order of the Phoenix" should not be exist
    # …still staged, so the operator's retry has something to retry
    The path "$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Order of the Phoenix/book.m4b" should be exist
    The stdout should not include "verified on cantina"
  End

  # ONE item's failure is that ITEM's failure — the batch rule this worker
  # already follows for a failed acquire. The two books here are named so
  # that the refused one's relpath is a strict PREFIX of its sibling's:
  # dropping "J.K. Rowling/Order" from the push list must not take
  # "J.K. Rowling/Order of the Phoenix" with it.
  It 'enrich: one book being refused does not cost its sibling — not even the sibling whose name it prefixes'
    rt_real
    rt_fixture "$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Order"
    rt_fixture "$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Order of the Phoenix"
    printf '%s\n' '#!/bin/sh' 'for a in "$@"; do case "$a" in */Order/*) exit 0 ;; esac; done' 'exec ffmpeg "$@"' \
      > "$RIP_SANDBOX/ffmpeg-selective"
    chmod +x "$RIP_SANDBOX/ffmpeg-selective"
    export RIP_FFMPEG_BIN="$RIP_SANDBOX/ffmpeg-selective"
    When run zsh -c "source $RIPLIB && rip::push_worker audiobooks"
    The status should equal 1
    The stderr should include 'refusing to push "J.K. Rowling/Order"'
    The path "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Order of the Phoenix/book.m4b" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Order" should not be exist
    # the pushed one was verified and cleaned; the refused one is still here
    The path "$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Order of the Phoenix" should not be exist
    The path "$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Order/book.m4b" should be exist
    # the surviving book really did go the whole way, not just avoid the drop
    The stdout should include "verified on cantina"
  End

  # A book is <Author>/<Title>. The enrichment derives the tags from ${rel:h},
  # so a book whose audio sits one level deeper — "<Author>/<Title>/Disc 1/…",
  # which `rip::ab_import`'s directory copy will happily produce — used to
  # hand the retag the WRONG TWO SEGMENTS: album_artist="<Title>",
  # album="Disc 1". Audiobookshelf would then show a book called "Disc 1" by
  # an author called "Deathly Hallows", written authoritatively into the audio
  # instead of merely read out of it: the exact wrong this phase exists to
  # fix, made permanent. Refuse rather than guess — the same branch the
  # empty-author case already takes.
  It 'enrich: a book whose audio sits a level deeper is refused, never tagged from the wrong segments'
    rt_real
    rt_fixture "$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Deathly Hallows/Disc 1"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::push_worker audiobooks >/dev/null
      print -r -- \"rc=\$?\"
      rt_probe '$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Deathly Hallows/Disc 1/book.m4b' album
      rt_probe '$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Deathly Hallows/Disc 1/book.m4b' album_artist"
    The line 1 should equal "rc=1"
    # NOT "Disc 1" and NOT "Deathly Hallows": the file was left exactly as it
    # arrived rather than stamped from the wrong two path segments
    The line 2 should equal "Wrong Album"
    The line 3 should equal "J.K. Rowling"
    The stderr should include "refusing to push"
    The path "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Deathly Hallows" should not be exist
    The path "$RIP_STAGING_ROOT/audiobooks/J.K. Rowling/Deathly Hallows/Disc 1/book.m4b" should be exist
  End

  # THE SECOND-ORDER EFFECT OF THAT REFUSAL (review finding, 2026-08-26).
  # rip::_enrich_audiobooks derives its book set from ${rel:h} per listed
  # file, with no notion of nesting — so ONE book laid out the way
  # rip::ab_import's `cp -R` produces it,
  #
  #     <Author>/<Title>/zz-notes.pdf
  #     <Author>/<Title>/Disc 1/book.m4b
  #
  # arrives as TWO entries: the valid two-segment "<Author>/<Title>" and the
  # invalid three-segment "<Author>/<Title>/Disc 1". The refusal above
  # correctly drops the deep one — but the shallow one is a perfectly valid
  # book path in its own right, so it was still processed as its own book and
  # wrote a `.fleet-book.json` for a book whose audio had just been refused.
  # Worse, rip::_enrich_add RE-ADDS that sidecar to the push list, so when the
  # deep sibling was refused FIRST the sidecar was added back after the drop
  # and shipped: an orphan identity on cantina for a book that never arrived,
  # with the push reporting rc 1 and "verified on cantina" in the same breath.
  #
  # ORDER DECIDES WHICH SYMPTOM YOU GET, and the order is `find`'s unsorted
  # readdir order — so this was intermittent, not absent, and a test that
  # takes whatever order it is handed is a test that passes here and fails on
  # the operator's machine. The two examples below therefore drive
  # rip::_enrich_audiobooks with a HAND-WRITTEN listfile and force each order
  # explicitly. Both must end with nothing written and nothing listed: the
  # group is refused ONCE, up front, before any member is processed.

  # nested_book — one book, audio a level down, a companion at the top.
  nested_book() {
    rt_fixture "$RIP_STAGING_ROOT/audiobooks/A/T/Disc 1"
    printf 'notes\n' > "$RIP_STAGING_ROOT/audiobooks/A/T/zz-notes.pdf"
  }
  # nested_probe — rc, what survives in the push list, and whether a sidecar
  # was written for the refused book. `sidecars=0` is what catches BOTH
  # orderings: companion-first left the file in staging without shipping it,
  # disc-first shipped it.
  NESTED_PROBE='rip::_enrich_audiobooks "$RIP_STAGING_ROOT/audiobooks" "$RIP_SANDBOX/lf"
      print -r -- "rc=$?"
      print -r -- "listed=$(wc -l < "$RIP_SANDBOX/lf" | tr -d " ")"
      print -r -- "sidecars=$(find "$RIP_STAGING_ROOT/audiobooks" -name .fleet-book.json | wc -l | tr -d " ")"'

  It 'enrich: a nested book is refused as ONE book — companion listed first'
    rt_real
    nested_book
    printf '%s\n' 'A/T/zz-notes.pdf' 'A/T/Disc 1/book.m4b' > "$RIP_SANDBOX/lf"
    When run zsh -c "source $RIPLIB
      $NESTED_PROBE"
    The line 1 should equal "rc=3"
    The line 2 should equal "listed=0"
    The line 3 should equal "sidecars=0"
    The stderr should include "refusing to push"
  End

  It 'enrich: a nested book is refused as ONE book — the deep audio listed first'
    rt_real
    nested_book
    printf '%s\n' 'A/T/Disc 1/book.m4b' 'A/T/zz-notes.pdf' > "$RIP_SANDBOX/lf"
    When run zsh -c "source $RIPLIB
      $NESTED_PROBE"
    The line 1 should equal "rc=3"
    # THIS is the ordering that shipped an orphan: the drop happened, and then
    # the shallow sibling put its sidecar back on the list
    The line 2 should equal "listed=0"
    The line 3 should equal "sidecars=0"
    The stderr should include "refusing to push"
  End

  # And the same thing end to end, because "nothing was listed" is a claim
  # about a file while "nothing reached cantina" is the claim that matters.
  # Whichever order find happens to return here, the server must be untouched
  # and every staged byte must still be staged.
  It 'enrich: a nested book leaves NOTHING on the server and everything in staging'
    rt_real
    nested_book
    When run zsh -c "source $RIPLIB && rip::push_worker audiobooks"
    The status should equal 1
    The stderr should include "refusing to push"
    # not one file, not even an identity sidecar
    The path "$RIP_SANDBOX/server/audiobooks/A" should not be exist
    The path "$RIP_STAGING_ROOT/audiobooks/A/T/Disc 1/book.m4b" should be exist
    The path "$RIP_STAGING_ROOT/audiobooks/A/T/zz-notes.pdf" should be exist
    The stdout should not include "verified on cantina"
  End

  # macOS writes accented staged names DECOMPOSED (NFD: "é" = e + combining
  # acute) and this module deliberately leaves LOCAL staging paths that way,
  # while the push --iconv's to NFC on the wire — so the server, and every
  # comparison spec S4's `--retag` sweep makes against it, speaks NFC. A tag
  # written from the raw staged bytes would disagree with the server path on
  # every accented author, and the sweep would rewrite those books on every
  # run: the same non-convergence the verbatim-author ruling just removed,
  # coming back through another door.
  It 'enrich: an NFD staged author is tagged with the NFC bytes the server holds'
    rt_real
    nfd_author="$(printf 'Jose\xcc\x81 Saramago')"
    rt_fixture "$RIP_STAGING_ROOT/audiobooks/$nfd_author/Blindness"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      find '$RIP_STAGING_ROOT/audiobooks' -type f | sed 's|^$RIP_STAGING_ROOT/audiobooks/||' > '$RIP_SANDBOX/lf'
      rip::_enrich_audiobooks '$RIP_STAGING_ROOT/audiobooks' '$RIP_SANDBOX/lf' || exit 9
      rt_probe '$RIP_STAGING_ROOT/audiobooks/$nfd_author/Blindness/book.m4b' album_artist
      print -r -- \"bytes=\$(rt_probe '$RIP_STAGING_ROOT/audiobooks/$nfd_author/Blindness/book.m4b' album_artist | tr -d '\\n' | wc -c | tr -d ' ')\""
    The status should equal 0
    # composed, not decomposed — the spelling the server will hold
    The line 1 should equal "José Saramago"
    # 14 bytes (NFC), not 15 (NFD): asserted on the bytes as well, because the
    # two spellings render identically and a string compare alone reads as a
    # typo to the next person
    The line 2 should equal "bytes=14"
  End

  # A file staged loose at the top of the type's tree is not a shape this
  # pipeline produces, but it is a shape a plain `rip-push audiobooks` can be
  # handed — and it is the one where "drop this book's entries from the push
  # list" has no <Author>/<Title> prefix to drop by. It must not become the
  # single case where a refusal ships the book anyway.
  It 'enrich: a book staged loose at the top of the tree is refused, not quietly shipped'
    rt_real
    rt_fixture "$RIP_STAGING_ROOT/audiobooks"
    rt_stub_silent
    When run zsh -c "source $RIPLIB && rip::push_worker audiobooks"
    The status should equal 1
    The stderr should include "refusing to push"
    The path "$RIP_SANDBOX/server/audiobooks/book.m4b" should not be exist
    The path "$RIP_STAGING_ROOT/audiobooks/book.m4b" should be exist
    The stdout should not include "verified on cantina"
  End

  # The load-bearing guarantee of the whole folder-import flow: the retag
  # runs on the STAGED COPY. The operator's own file is read and never
  # written — it is the only original there is.
  It 'session: the operator source file is never retagged, only the staged copy'
    rt_real
    rt_fixture "$RIP_SANDBOX/incoming"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/book.m4b\",\"path\":\"J.K. Rowling/Chamber of Secrets\",\"title\":\"Chamber of Secrets\"}]}" > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      rip::ab_worker '$RIP_SANDBOX/plan.json' >/dev/null || exit 9
      rt_probe '$RIP_SANDBOX/incoming/book.m4b' album
      rt_probe '$RIP_SANDBOX/incoming/book.m4b' album_artist
      rt_probe '$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Chamber of Secrets/book.m4b' album
      rt_probe '$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Chamber of Secrets/book.m4b' album_artist"
    The status should equal 0
    The line 1 should equal "Wrong Album"
    The line 2 should equal "J.K. Rowling"
    The line 3 should equal "Chamber of Secrets"
    The line 4 should equal "J.K. Rowling"
    The stderr should not include "refusing"
  End

  It 'canonical author: adopts the spelling the server already uses'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Two Towers"
    When run zsh -c "source $RIPLIB && rip::_canonical_author 'J.R.R. Tolkien'"
    The status should equal 0
    The output should equal "J. R. R. Tolkien"
  End

  # REVIEW FINDING F2 (2026-08-26). "The server wins" converges two arbitrary
  # spellings, which is the whole point of this function — but the key is
  # rip::_author_norm, which STRIPS punctuation, so "J.K. Rowling" and
  # "J. K. Rowling" are the same key and the server's RAW form was adopted
  # over the panel's canonical one. With 248 books stored under the raw
  # spelling, the panel showed "J. K. Rowling" and the library got
  # "J.K. Rowling" — spec §1's stated reason for having a panel rule at all,
  # silently inert until --canonicalize-authors swept afterwards (at the cost
  # of a remux of everything already written).
  #
  # It still converges: the sweep moves the server to this same form. It just
  # converges on the RIGHT spelling, first time.
  It 'canonical author: the caller keeps the canonical form of what the server holds raw'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Deathly Hallows"
    When run zsh -c "source $RIPLIB && rip::_canonical_author 'J. K. Rowling'"
    The status should equal 0
    The output should equal "J. K. Rowling"
  End

  # …and the direction that must NOT change: a caller holding the raw form
  # still adopts the server's, which is what makes a re-ingest converge
  # instead of oscillating. Only the canonical form outranks the server.
  It 'canonical author: a raw caller spelling still adopts the server, canonical or not'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows"
    When run zsh -c "source $RIPLIB && rip::_canonical_author 'J.K. Rowling'"
    The status should equal 0
    The output should equal "J. K. Rowling"
  End

  It 'canonical author: an author the server does not know is returned unchanged'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Ann Leckie/Ancillary Justice"
    When run zsh -c "source $RIPLIB && rip::_canonical_author 'Martha Wells'"
    The status should equal 0
    The output should equal "Martha Wells"
  End

  It 'canonical author: a name that does not normalize equal is NOT adopted'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit"
    When run zsh -c "source $RIPLIB && rip::_canonical_author 'John Ronald Reuel Tolkien'"
    The status should equal 0
    The output should equal "John Ronald Reuel Tolkien"
  End

  It 'canonical author: an unreachable server yields the input, never an error'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::_canonical_author 'J.R.R. Tolkien'; echo rc=\$?"
    The status should equal 0
    The output should include "J.R.R. Tolkien"
    The output should include "rc=0"
  End

  It 'canonical author: the server list is fetched ONCE per process, not once per call'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Two Towers"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cd "$RIP_SANDBOX/server/audiobooks" || exit 2
find . -mindepth 2 -maxdepth 2 -type d | sed 's|^\./||'
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
    When run zsh -c "source $RIPLIB
      rip::_canonical_author 'J.R.R. Tolkien' >/dev/null
      rip::_canonical_author 'Martha Wells' >/dev/null"
    The status should equal 0
    The result of function ssh_calls should equal "1"
  End

  # --- session plan validation + enqueue -----------------------------------

  queued_plans() {
    local -a f=("$RIP_STAGING_ROOT"/.work/ab-plans/*.json(N))
    print -r -- "${#f}"
  }

  It 'plan: rejects a plan selecting nothing'
    When run zsh -c "source $RIPLIB && rip::ab_enqueue \$(printf '%s' '$RIP_SANDBOX/empty.json')"
    The status should equal 2
    The stderr should include "no such session plan"
  End

  It 'plan: rejects an item whose path escapes the library'
    printf '%s\n' '{"provider":"libation","items":[{"id":"X","path":"../etc/Steelheart"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_enqueue $RIP_SANDBOX/plan.json"
    The status should equal 2
    The stderr should include "may not be . or .."
  End

  # author/title are derived from the FIRST/LAST slash only
  # (${bpath%%/*} / ${bpath##*/}), so a middle "../../etc" segment is
  # silently dropped by the split and never reaches rip::_check_title:
  # "A/../../etc/passwd" splits clean to author "A" title "passwd". Only
  # the roundtrip check (author/title reassembles to the original bpath)
  # catches this (review finding, 2026-08-22).
  It 'plan: rejects a mid-string traversal payload the split alone would miss'
    printf '%s\n' '{"provider":"libation","items":[{"id":"X","path":"A/../../etc/passwd"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_enqueue $RIP_SANDBOX/plan.json"
    The status should equal 2
    The stderr should include "must be exactly <Author>/<Title>"
    The path "$JOB_FAKE_LOG" should not be exist
  End

  It 'plan: rejects two items composing the same book path'
    printf '%s\n' '{"provider":"libation","items":[{"id":"X","path":"A/B"},{"id":"Y","path":"A/B"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_enqueue $RIP_SANDBOX/plan.json"
    The status should equal 2
    The stderr should include "composes the same book twice"
  End

  It 'plan: enqueues ONE heavy job titled by the batch'
    printf '%s\n' '{"provider":"libation","items":[{"id":"X","path":"A/B","title":"B"},{"id":"Y","path":"A/C","title":"C"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_enqueue $RIP_SANDBOX/plan.json"
    The status should equal 0
    The contents of file "$JOB_FAKE_LOG" should include "--group heavy"
    The result of function titles should include "rip audiobooks: 2 books"
    The contents of file "$JOB_FAKE_LOG" should include "/rip-audiobook --session-worker"
  End

  It 'plan: the queued copy survives under .work/ab-plans, not loose in .work'
    printf '%s\n' '{"provider":"libation","items":[{"id":"X","path":"A/B","title":"B"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_enqueue $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function queued_plans should equal "1"
  End

  # The "n > 0" empty-selection guard, hit directly with a well-formed but
  # empty items array — distinct from the missing-FILE example above,
  # which never reaches plan content at all.
  It 'plan: rejects a plan whose items array is empty'
    printf '%s\n' '{"provider":"libation","items":[]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_enqueue $RIP_SANDBOX/plan.json"
    The status should equal 2
    The stderr should include "selects nothing"
  End

  # A malformed item (no id, no path) must be REJECTED, not silently
  # dropped from validation — the blanket "both empty, skip" the earlier
  # implementation had would let a batch of one good item plus one "{}"
  # enqueue one book short with no error at all (review finding,
  # 2026-08-22).
  It 'plan: rejects an item with neither id nor path, and enqueues nothing'
    printf '%s\n' '{"provider":"libation","items":[{"id":"X","path":"A/B"},{}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_enqueue $RIP_SANDBOX/plan.json"
    The status should equal 2
    The stderr should include "plan item has no id"
    The path "$JOB_FAKE_LOG" should not be exist
  End

  # --- session worker -------------------------------------------------------

  It 'worker: acquires only what the server lacks, then pushes'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Have"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/Have/Have.m4b"
    printf '%s\n' '{"provider":"libation","items":[{"id":"HAVE","path":"A/Have","title":"Have"},{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","authors":["Brandon Sanderson"],"ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","provider_version":"13.7.10","format":"m4b"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The contents of file "$RIP_SANDBOX/libation.log" should include "--id B00ECDZ08I"
    The contents of file "$RIP_SANDBOX/libation.log" should not include "--id HAVE"
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
    The path "$RIP_STAGING_ROOT/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should not be exist
    The stderr should include 'error: rip: already on cantina, refusing to re-acquire: A/Have'
    The output should include 'skipped refused=1 dup=0'
  End

  # The worker MUST forward the plan item's own path as the folder
  # provider's third argument — that path is authoritative: it is what the
  # panel displayed and what a later task lets the operator EDIT before
  # ripping (Task 3 review). A source directory named "RawFolder" whose
  # plan item carries a DIFFERENT, edited path must stage — and land on the
  # server — under the PLAN's path, never anything derived from the source
  # directory's own name. Runs the REAL rip-provider-folder binary
  # (RIP_LIBEXEC_DIR points at the real, tracked libexec dir for this whole
  # file), so this is an end-to-end proof the worker's third argument
  # actually reaches cmd_acquire and wins.
  It "worker: forwards the folder provider's plan path — an inline edit survives acquire"
    mkdir -p "$RIP_SANDBOX/incoming/RawFolder"
    printf 'audio\n' > "$RIP_SANDBOX/incoming/RawFolder/RawFolder.m4b"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/RawFolder/RawFolder.m4b\",\"path\":\"Edited Author/Edited Title\",\"title\":\"Edited Title\",\"authors\":[\"Edited Author\"]}]}" > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The path "$RIP_SANDBOX/server/audiobooks/Edited Author/Edited Title/RawFolder.m4b" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/RawFolder" should not be exist
    The output should include 'rip: audiobooks verified on cantina — cleaning staging'
  End

  # The operator asked to be TOLD, not to have the batch aborted (Task 4):
  # a book already on the server is a refusal worth logging, and the
  # remaining books still acquire. This check stays at ACQUIRE time only —
  # see rip-push_spec.sh for the sibling guard pinning that push stays
  # idempotent.
  It 'session: a book already on the server logs a failure, is counted, and the batch continues'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Have"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/Have/Have.m4b"
    printf '%s\n' '{"provider":"libation","items":[{"id":"HAVE","path":"A/Have","title":"Have"},{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The stderr should include "already on cantina"
    The stderr should include "A/Have"
    The contents of file "$RIP_SANDBOX/libation.log" should not include "--id HAVE"
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
    The output should include 'skipped refused=1 dup=0'
  End

  It 'session: the refusal count is reported when the run finishes'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Have"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/Have/Have.m4b"
    printf '%s\n' '{"provider":"libation","items":[{"id":"HAVE","path":"A/Have","title":"Have"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The stderr should include "1 already on cantina"
    # ...and a MACHINE marker beside the prose. Mode B, 2026-08-25: a run that
    # refused everything exits 0 (nothing failed — the book is already there),
    # so a capsule that only reports non-zero showed plain success for a run
    # that shipped nothing. The marker is what lets the caller say so.
    The output should include "skipped refused=1 dup=0"
  End

  # The marker must NOT appear when there is nothing to report, or the caller
  # would raise an alarm on every ordinary successful run.
  It 'session: no skip marker is emitted when nothing was skipped'
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The output should not include "skipped refused="
  End

  # Task 4: a DIFFERENT refusal, keyed on BYTES rather than on path — the
  # "already on cantina" pair above still fires unchanged (proven by the
  # untouched fixture right above this one). The hash happens at ACQUIRE
  # time only ("list" never hashes), so the fixture gives the duplicate
  # item a real source directory with a real .m4b in it — the REAL
  # rip-provider-folder binary runs here (this whole file's setup() points
  # RIP_LIBEXEC_DIR at the real, tracked libexec dir), exactly like "worker:
  # forwards the folder provider's plan path" above. A bare "already have
  # it" would send the operator hunting through 247 books, so the refusal
  # must NAME the stored book it collided with.
  It 'session: a local book whose bytes are already stored is refused BY NAME and the batch continues'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Ann Leckie/Ancillary Justice"
    mkdir -p "$RIP_SANDBOX/incoming/DupBook"
    printf 'the bytes\n' > "$RIP_SANDBOX/incoming/DupBook/dup.m4b"
    sha=$(shasum -a 256 "$RIP_SANDBOX/incoming/DupBook/dup.m4b" | cut -d" " -f1)
    printf '%s\n' "{\"schema\":1,\"kind\":\"audiobook\",\"title\":\"Ancillary Justice\",\"authors\":[\"Ann Leckie\"],\"ids\":{\"local.sha256\":\"$sha\"}}" \
      | jq . > "$RIP_SANDBOX/server/audiobooks/Ann Leckie/Ancillary Justice/.fleet-book.json"
    mkdir -p "$RIP_SANDBOX/incoming/Fresh"
    printf 'fresh bytes\n' > "$RIP_SANDBOX/incoming/Fresh/fresh.m4b"
    # a plan naming the duplicate first and a fresh book second — the batch
    # must not abort on the duplicate.
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/DupBook/dup.m4b\",\"path\":\"Ann Leckie/Dup\",\"title\":\"Dup\"},{\"id\":\"$RIP_SANDBOX/incoming/Fresh/fresh.m4b\",\"path\":\"A/Fresh\",\"title\":\"Fresh\"}]}" > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The stderr should include "already stored as"
    The stderr should include "Ann Leckie/Ancillary Justice"
    The path "$RIP_SANDBOX/server/audiobooks/A/Fresh/fresh.m4b" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/Ann Leckie/Dup" should not be exist
    The output should include 'skipped refused=0 dup=1'
  End

  It 'session: the duplicate refusal is counted and reported at the end'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Ann Leckie/Ancillary Justice"
    mkdir -p "$RIP_SANDBOX/incoming/DupBook"
    printf 'the bytes\n' > "$RIP_SANDBOX/incoming/DupBook/dup.m4b"
    sha=$(shasum -a 256 "$RIP_SANDBOX/incoming/DupBook/dup.m4b" | cut -d" " -f1)
    printf '%s\n' "{\"schema\":1,\"kind\":\"audiobook\",\"title\":\"Ancillary Justice\",\"authors\":[\"Ann Leckie\"],\"ids\":{\"local.sha256\":\"$sha\"}}" \
      | jq . > "$RIP_SANDBOX/server/audiobooks/Ann Leckie/Ancillary Justice/.fleet-book.json"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/DupBook/dup.m4b\",\"path\":\"Ann Leckie/Dup\",\"title\":\"Dup\"}]}" > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The stderr should include "1 already stored"
    The output should include 'skipped refused=0 dup=1'
  End

  # --- Task 5, Step 3b: identity assigned at import ----------------------
  #
  # ids["local.sha256"] used to be written only by --repair-sidecars Case C,
  # gated to provider "manual" — so a folder-acquired book never got it in
  # its OWN sidecar, and Task 4's byte-level duplicate refusal above (which
  # this file's fixtures always hand-author) could never fire against a
  # re-import of a book THIS feature itself imported. These two examples
  # prove the gap is closed: no hand-authored sidecar anywhere below — the
  # first import's own sidecar is what the second import's refusal reads.
  #
  # The acquire is now the ONLY writer of that key (review finding F3,
  # 2026-08-26), and deliberately so: it is the only place that ever holds
  # the SOURCE file to hash. Case C, repairing a book already on the server,
  # records `local.stored.sha256` instead.

  It 'session: a folder-provider acquire mints a fleet.uid and records the real hash of the primary file'
    mkdir -p "$RIP_SANDBOX/incoming/Orig"
    printf 'the bytes\n' > "$RIP_SANDBOX/incoming/Orig/orig.m4b"
    want_sha=$(shasum -a 256 "$RIP_SANDBOX/incoming/Orig/orig.m4b" | cut -d' ' -f1)
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/Orig/orig.m4b\",\"path\":\"A/Orig\",\"title\":\"Orig\",\"provider\":\"folder\"}]}" > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json >/dev/null 2>&1 && jq -r '((.ids[\"fleet.uid\"]//\"\")|length>0)' $RIP_SANDBOX/server/audiobooks/A/Orig/.fleet-book.json && jq -r '.ids[\"local.sha256\"]' $RIP_SANDBOX/server/audiobooks/A/Orig/.fleet-book.json"
    The status should equal 0
    The lines of output should equal 2
    The line 1 of output should equal "true"
    The line 2 of output should equal "$want_sha"
  End

  It 'session: identity assigned at import closes the loop — a folder-provider re-import of the same bytes is refused'
    mkdir -p "$RIP_SANDBOX/incoming/Orig"
    printf 'the bytes\n' > "$RIP_SANDBOX/incoming/Orig/orig.m4b"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/Orig/orig.m4b\",\"path\":\"A/Orig\",\"title\":\"Orig\",\"provider\":\"folder\"}]}" > "$RIP_SANDBOX/plan.json"
    zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json" >/dev/null 2>&1

    mkdir -p "$RIP_SANDBOX/incoming/Copy"
    printf 'the bytes\n' > "$RIP_SANDBOX/incoming/Copy/copy.m4b"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/Copy/copy.m4b\",\"path\":\"A/Copy\",\"title\":\"Copy\"}]}" > "$RIP_SANDBOX/plan2.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan2.json"
    The status should equal 0
    The stderr should include "already stored as"
    The stderr should include "A/Orig"
    The path "$RIP_SANDBOX/server/audiobooks/A/Copy" should not be exist
    The output should include 'skipped refused=0 dup=1'
  End

  # --- final review F1: "ids": [] from the panel's Lua encode --------------
  #
  # THE PANEL REALLY SENDS AN ARRAY. rip-provider-folder emits `ids: {}` —
  # it is the only producer of an EMPTY ids object — and Hammerspoon 1.1.1
  # encodes an empty Lua table as `[]`, not `{}` (LuaSkin Skin.m at tag
  # 1.1.1: with maxNatIndex == countNatIndex == 0 it selects NSMutableArray).
  # The panel re-encodes the plan on its way to the queue, so `"ids": []` is
  # what actually lands in the plan file for a locally imported book.
  #
  # EVERY OTHER folder fixture in this file OMITS ids entirely, which is why
  # the suite could not see this: with the key absent, `.ids // {}` supplied
  # the object and everything worked. These two examples send the array —
  # the real shape — and nothing else.
  It 'session: a folder plan carrying the panel empty-table "ids": [] still mints a full identity'
    mkdir -p "$RIP_SANDBOX/incoming/Orig"
    printf 'the bytes\n' > "$RIP_SANDBOX/incoming/Orig/orig.m4b"
    want_sha=$(shasum -a 256 "$RIP_SANDBOX/incoming/Orig/orig.m4b" | cut -d' ' -f1)
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/Orig/orig.m4b\",\"path\":\"A/Orig\",\"title\":\"Orig\",\"provider\":\"folder\",\"ids\":[]}]}" > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json >/dev/null 2>&1
      sidecar=$RIP_SANDBOX/server/audiobooks/A/Orig/.fleet-book.json
      jq -r '.ids | type' \$sidecar
      jq -r '((.ids[\"fleet.uid\"]//\"\")|length>0)' \$sidecar
      jq -r '.ids[\"local.sha256\"]' \$sidecar"
    The status should equal 0
    The line 1 of output should equal "object"
    The line 2 of output should equal "true"
    The line 3 of output should equal "$want_sha"
  End

  # The dangerous half: with the array left uncoerced the first import writes
  # a sidecar with no local.sha256 at all, so rip::_stored_sha_index has
  # nothing to key on and the BYTE-level duplicate refusal can never fire
  # again for that book — dedupe silently off, rc 0, no warning anywhere.
  # This is the "closes the loop" example above with the panel's real ids
  # shape on the FIRST plan, and nothing else changed.
  It 'session: byte-dedupe still fires against a book first imported with "ids": []'
    mkdir -p "$RIP_SANDBOX/incoming/Orig"
    printf 'the bytes\n' > "$RIP_SANDBOX/incoming/Orig/orig.m4b"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/Orig/orig.m4b\",\"path\":\"A/Orig\",\"title\":\"Orig\",\"provider\":\"folder\",\"ids\":[]}]}" > "$RIP_SANDBOX/plan.json"
    zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json" >/dev/null 2>&1

    mkdir -p "$RIP_SANDBOX/incoming/Copy"
    printf 'the bytes\n' > "$RIP_SANDBOX/incoming/Copy/copy.m4b"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/Copy/copy.m4b\",\"path\":\"A/Copy\",\"title\":\"Copy\",\"ids\":[]}]}" > "$RIP_SANDBOX/plan2.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan2.json"
    The status should equal 0
    The stderr should include "already stored as"
    The stderr should include "A/Orig"
    # Refused before any copy, so the push finds nothing staged. Asserted
    # rather than left to the reporter's stdout warning: this line IS the
    # proof that the refusal happened ahead of the acquire, not after it.
    The stdout should include "nothing settled to push"
    The path "$RIP_SANDBOX/server/audiobooks/A/Copy" should not be exist
  End

  # The READ side, independently of who wrote the sidecar: a book already on
  # the server carrying `"ids": []` must still be ENUMERATED. Fed straight
  # into rip::_sidecar_index (its contract is stdin), poisoned row FIRST so
  # the ordering is fixed rather than left to `find`. Uncoerced,
  # `.ids["audible.asin"]` raises on the array, the raise is swallowed by the
  # function's own 2>/dev/null, and the row is DROPPED — so --repair-sidecars
  # cannot see the one book whose identity is actually corrupt.
  It 'sidecar index: a stored sidecar with "ids": [] is enumerated as empty, not dropped'
    When run zsh -c "source $RIPLIB
      printf '%s\n' '{\"schema\":1,\"ids\":[],\"_path\":\"A/Poison\"}' '{\"schema\":1,\"ids\":{\"audible.asin\":\"B01\"},\"_path\":\"Z/Good\"}' | rip::_sidecar_index"
    The status should equal 0
    The lines of output should equal 2
    The line 1 of output should include "A/Poison"
    The line 1 of output should include "empty"
    The line 1 of output should include '"ids":{}'
    The line 2 of output should include "Z/Good"
  End

  # And the same poison must not cost the byte-dedupe index the OTHER books:
  # rip::_stored_sha_index is what the acquire loop keys on, and a library
  # holding one poisoned sidecar must still report every book that does carry
  # a hash. Driven through rip::_server_sidecars over the sandbox's own
  # plain-dir remote base (no colon, no ssh).
  It 'stored-sha index: a poisoned sidecar does not cost the library its hashed books'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A Poison/Book" "$RIP_SANDBOX/server/audiobooks/Z Good/Book"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"Poison","ids":[]}' > "$RIP_SANDBOX/server/audiobooks/A Poison/Book/.fleet-book.json"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"Good","ids":{"local.sha256":"deadbeef"}}' > "$RIP_SANDBOX/server/audiobooks/Z Good/Book/.fleet-book.json"
    When run zsh -c "source $RIPLIB && rip::_stored_sha_index"
    The status should equal 0
    The output should include "deadbeef"
    The output should include "Z Good/Book"
  End

  # --- final review F4: the keep-staged retry path -------------------------
  #
  # "A push or verify failure keeps everything staged for a plain `rip-push
  # audiobooks` retry with no re-download" is this worker's own documented
  # failure-honesty rule. Re-running the SESSION over that staging tree used
  # to make rip-provider-folder re-copy every book in full and then `die`
  # ("already staged"), which ab_worker counted as an acquire failure and
  # returned as rc 2 — for a push that then delivered every byte. The plan's
  # id here points at a source directory that is deliberately EMPTY of the
  # staged filename, so a re-copy would be visible in the result: only the
  # already-staged bytes can reach the server.
  It 'session: re-running a session over an already-staged book succeeds and pushes it'
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/A/Kept"
    printf 'staged by the previous run\n' > "$RIP_STAGING_ROOT/audiobooks/A/Kept/Kept.m4b"
    mkdir -p "$RIP_SANDBOX/incoming/Kept"
    printf 'a different, fresher copy\n' > "$RIP_SANDBOX/incoming/Kept/Kept.m4b"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/Kept/Kept.m4b\",\"path\":\"A/Kept\",\"title\":\"Kept\"}]}" > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The stderr should not include "acquire failed"
    # the provider took the idempotent path rather than re-copying
    The stdout should include "already staged"
    The path "$RIP_SANDBOX/server/audiobooks/A/Kept/Kept.m4b" should be exist
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/Kept/Kept.m4b" should equal "staged by the previous run"
  End

  # The index is a DEDUPE check (Task 3's own contract): an unreachable
  # server must never read as "not a duplicate" — that would silently
  # disable dedupe on an outage. Simulated with the sandbox's own plain-dir
  # remote base (no ssh, no rsync target change — no colon anywhere here,
  # so this stays on the local-filesystem branch every other test in this
  # file uses; a colon-based RIP_REMOTE_BASE would send the later push's
  # real rsync at a real ssh, which this suite must never do): removing
  # audiobooks/ makes rip::_server_sidecars' `cd` fail exactly the way Task
  # 3's own "unreachable server" example forces it to fail over ssh. The
  # worker must say so AND must not block the batch on it — an unknown is
  # not a refusal, the same "never block on unknown" rule
  # rip::_remote_has_file's rc-2 callers already follow.
  It 'session: cantina unreachable for the byte-dedupe check warns and still acquires — never a silent, permanently-disabled check'
    rm -rf "$RIP_SANDBOX/server/audiobooks"
    mkdir -p "$RIP_SANDBOX/incoming/Fresh"
    printf 'fresh bytes\n' > "$RIP_SANDBOX/incoming/Fresh/fresh.m4b"
    printf '%s\n' "{\"provider\":\"folder\",\"items\":[{\"id\":\"$RIP_SANDBOX/incoming/Fresh/fresh.m4b\",\"path\":\"A/Fresh\",\"title\":\"Fresh\"}]}" > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The stderr should include "could not reach cantina"
    The path "$RIP_SANDBOX/server/audiobooks/A/Fresh/fresh.m4b" should be exist
    The output should include 'rip: audiobooks verified on cantina — cleaning staging'
  End

  # Regression guard (final-review finding, 2026-08-22): rip::staging_for
  # honors RIP_AB_STAGING, but rip::ab_worker used to hardcode
  # "$(rip::staging_root)/audiobooks" as its acquire destination and derive
  # books_root from THAT — with the override set, the session acquired into
  # one tree and pushed from another (rip::push_worker's src IS
  # rip::staging_for audiobooks), so the push saw an empty staging dir and
  # the session vanished silently. Both must derive from the same seam.
  It 'worker: honors RIP_AB_STAGING — acquires into and pushes from the overridden tree'
    local custom="$RIP_SANDBOX/custom-staging"
    export RIP_AB_STAGING="$custom"
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","format":"m4b"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
    # nothing was ever acquired into (or left behind in) the default tree
    The path "$RIP_STAGING_ROOT/audiobooks/Brandon Sanderson" should not be exist
    # the override tree itself is empty again after the verified push
    The path "$custom/Brandon Sanderson" should not be exist
    The output should include 'rip: audiobooks verified on cantina — cleaning staging'
  End

  It 'worker: the sidecar carries the plan identity, not the path fallback'
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","subtitle":"The Reckoners, Book 1","authors":["Brandon Sanderson"],"narrators":["MacLeod Andrews"],"duration_s":45720,"ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","provider_version":"13.7.10","format":"m4b"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json >/dev/null && jq -c '[.subtitle,.ids[\"audible.asin\"],.source.provider,.work]' '$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/.fleet-book.json'"
    The status should equal 0
    The output should equal '["The Reckoners, Book 1","B00ECDZ08I","libation",null]'
  End
End
