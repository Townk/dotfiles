# rip-audiobook — the provider contract, the libation provider, the CLI and
# the session worker. Hermetic: sandboxed staging, fake LibationCli
# (RIP_LIBATION_BIN), fake ssh (RIP_SSH_BIN), no network, no GUI.
Describe 'rip audiobooks'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  PROVIDER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-libation"
  ABS_BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-abs-authors"

  setup() {
    export RIP_SANDBOX=$(mktemp -d)
    export RIP_STAGING_ROOT="$RIP_SANDBOX/Rips"
    export RIP_REMOTE_BASE="$RIP_SANDBOX/server"
    export JOB_STATE_ROOT="$RIP_SANDBOX/state"
    export JOB_FAKE_LOG="$RIP_SANDBOX/pueue.log"
    export RIP_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export RIP_LIBEXEC_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec"
    export RIP_PUSH_MIN_AGE_S=0
    # rip::_abs_match_authors (rip.zsh) is a DEFAULT RIP_AB_REMOTE_HOPS
    # entry, so EVERY audiobooks push in this whole file now shells out to
    # "$RIP_BIN_DIR/rip-abs-authors" after a verified push. Left at its
    # production default ($HOME/.local/bin) that would resolve to a REAL
    # path on whatever machine runs the suite — exactly the live-network
    # escape this suite has already been bitten by once. An empty sandbox
    # dir means the shell-out 404s (command not found) and the hop's own
    # `|| log_warn` swallows it — hermetic by construction, not by
    # per-example discipline.
    export RIP_BIN_DIR="$RIP_SANDBOX/bin"
    mkdir -p "$RIP_STAGING_ROOT/audiobooks" "$RIP_SANDBOX/server/audiobooks" "$RIP_BIN_DIR"
    cat > "$RIP_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in add) echo "7" ;; esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$RIP_SANDBOX/pueue"

    # Fake LibationCli: `export -j -p <file>` writes a two-record library,
    # one Liberated and one not. Any other verb records its argv so an
    # example can assert what was (and was NOT) invoked.
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
if [ "$1" = "export" ]; then
  out=""
  while [ $# -gt 0 ]; do
    case "$1" in -p|--path) out="$2" ;; esac
    shift
  done
  cat > "$out" <<'JSON'
[
 {"AudibleProductId":"B00ECDZ08I","Title":"Steelheart","Subtitle":"The Reckoners, Book 1",
  "AuthorNames":"Brandon Sanderson","NarratorNames":"MacLeod Andrews","LengthInMinutes":762,
  "SeriesNames":"Reckoners","SeriesOrder":"1 : Reckoners","Language":"english","IsAbridged":false,
  "HasPdf":false,"PictureId":"51kzMpLGP7L","BookStatus":"NotLiberated","LastDownloaded":null,
  "DatePublished":"2013-09-24T07:00:00"},
 {"AudibleProductId":"B0DGKKZ123","Title":"Wind and Truth","Subtitle":"",
  "AuthorNames":"Brandon Sanderson","NarratorNames":"Michael Kramer","LengthInMinutes":3360,
  "SeriesNames":"The Stormlight Archive","SeriesOrder":"5 : The Stormlight Archive","Language":"english",
  "IsAbridged":false,"HasPdf":true,"PictureId":"81abcDEF","BookStatus":"Liberated",
  "LastDownloaded":"2026-08-22 08:18:03.838369","DatePublished":null}
]
JSON
  echo "Library exported to: $out"
  exit 0
fi
if [ "$1" = "liberate" ]; then
  books=""
  while [ $# -gt 0 ]; do
    case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
    shift
  done
  [ -n "$books" ] || { echo "no Books override" >&2; exit 1; }
  [ -n "${FAKE_LIBERATE_FAIL:-}" ] && { echo "download failed" >&2; exit 4; }
  mkdir -p "$books/Brandon Sanderson/Steelheart"
  printf 'audio\n' > "$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
  echo "Decrypting  25%"
  echo "Decrypting  90%"
  echo "Completed"
  exit 0
fi
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    export RIP_LIBATION_BIN="$RIP_SANDBOX/LibationCli"
    export RIP_LIBATION_IMAGES="$RIP_SANDBOX/Images"
    mkdir -p "$RIP_LIBATION_IMAGES"
  }
  cleanup() { rm -rf "$RIP_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # ssh_calls() — how many times the fake ssh ran. --server-library must
  # make exactly ONE ssh call regardless of library size (the panel's
  # hide-filter is a set-membership test against its output; 460 rows must
  # never become 460 round-trips).
  ssh_calls() { wc -l < "$RIP_SANDBOX/ssh.count" 2>/dev/null | tr -d ' '; }

  # find_temp_dirs() — count .rip-import.* temp directories in the sandbox
  find_temp_dirs() {
    find "$RIP_SANDBOX" -maxdepth 2 -name '.rip-import.*' -type d 2>/dev/null | wc -l | tr -d ' '
  }

  # find_temp_dirs_anywhere() — count .rip-import.* temp directories ANYWHERE
  # under the sandbox, unbounded depth. Unlike find_temp_dirs (maxdepth 2,
  # which only covers the top-level parent-of-staging location), this also
  # catches a temp dir nested inside a destination — the exact failure mode
  # of the mv-nesting bug this guard exists to prevent.
  find_temp_dirs_anywhere() {
    find "$RIP_SANDBOX" -name '.rip-import.*' -type d 2>/dev/null | wc -l | tr -d ' '
  }

  # dest_entry_count() — count entries directly inside the fixed
  # Author/Title destination used by the dot-directory nesting test below,
  # to verify the destination is left exactly as it was (nothing added,
  # nothing removed).
  dest_entry_count() {
    find "$RIP_STAGING_ROOT/audiobooks/Author/Title" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
  }

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

  It 'canonical author: adopts the spelling the server already uses'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Two Towers"
    When run zsh -c "source $RIPLIB && rip::_canonical_author 'J.R.R. Tolkien'"
    The status should equal 0
    The output should equal "J. R. R. Tolkien"
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

  # titles() — read every enqueued job's title straight from its meta.json
  titles() { cat "$JOB_STATE_ROOT"/*/meta.json 2>/dev/null; }

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
  End

  # --- Task 5, Step 3b: identity assigned at import ----------------------
  #
  # ids["local.sha256"] used to be written ONLY by --repair-sidecars Case C,
  # gated to provider "manual" — so a folder-acquired book never got it in
  # its OWN sidecar, and Task 4's byte-level duplicate refusal above (which
  # this file's fixtures always hand-author) could never fire against a
  # re-import of a book THIS feature itself imported. These two examples
  # prove the gap is closed: no hand-authored sidecar anywhere below — the
  # first import's own sidecar is what the second import's refusal reads.

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
  End

  It 'worker: the sidecar carries the plan identity, not the path fallback'
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","subtitle":"The Reckoners, Book 1","authors":["Brandon Sanderson"],"narrators":["MacLeod Andrews"],"duration_s":45720,"ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","provider_version":"13.7.10","format":"m4b"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json >/dev/null && jq -c '[.subtitle,.ids[\"audible.asin\"],.source.provider,.work]' '$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/.fleet-book.json'"
    The status should equal 0
    The output should equal '["The Reckoners, Book 1","B00ECDZ08I","libation",null]'
  End

  # --- work: an object, protected across a second push (Task 1) ------------
  #
  # rip::_book_sidecar is the composer EVERY push runs (rip::_enrich_audiobooks
  # calls it once per staged book dir, right before the rsync). It merges the
  # freshly composed sidecar over whatever ALREADY sits at that path with the
  # old file winning at every depth for a non-null value — the same rule that
  # protects `ids` across a retried/re-enriched push. `work` has carried that
  # same protection since it was introduced, but always as `null`, so nothing
  # has ever exercised it: this pins it now that `work` is about to become an
  # object a later task actually writes.
  work_book_sidecar_meta() {
    printf '%s\n' '{"title":"B","authors":["A"],"provider":"libation","format":"m4b"}' \
      > "$RIP_SANDBOX/work-meta.json"
  }

  It 'sidecar: a composed row with no edition still writes work: null — byte-identical to today'
    work_book_sidecar_meta
    mkdir -p "$RIP_SANDBOX/work-book-a"
    When run zsh -c "source $RIPLIB \
      && rip::_book_sidecar '$RIP_SANDBOX/work-book-a' '$RIP_SANDBOX/work-meta.json' >/dev/null \
      && jq -c '.work' '$RIP_SANDBOX/work-book-a/.fleet-book.json'"
    The status should equal 0
    The output should equal "null"
  End

  It 'sidecar: work already recorded as an object survives a second push unchanged'
    work_book_sidecar_meta
    mkdir -p "$RIP_SANDBOX/work-book-b"
    When run zsh -c "source $RIPLIB
      rip::_book_sidecar '$RIP_SANDBOX/work-book-b' '$RIP_SANDBOX/work-meta.json' >/dev/null
      # Simulate a work already resolved on this staged sidecar — nothing in
      # this task sets it yet (that is Task 3); this stands in for it so the
      # merge that will protect it has something non-null to protect.
      jq '.work = {uid:\"9f1c2a4e-1111-4b22-8aa0-abc123456789\",edition:\"Full Cast\"}' \
        '$RIP_SANDBOX/work-book-b/.fleet-book.json' > '$RIP_SANDBOX/work-book-b/.fleet-book.json.next'
      mv '$RIP_SANDBOX/work-book-b/.fleet-book.json.next' '$RIP_SANDBOX/work-book-b/.fleet-book.json'
      # The second push: same meta, same composer — the old, non-null work
      # must win over the freshly composed work: null.
      rip::_book_sidecar '$RIP_SANDBOX/work-book-b' '$RIP_SANDBOX/work-meta.json' >/dev/null
      jq -c '.work' '$RIP_SANDBOX/work-book-b/.fleet-book.json'"
    The status should equal 0
    The output should equal '{"uid":"9f1c2a4e-1111-4b22-8aa0-abc123456789","edition":"Full Cast"}'
  End

  # --- work: the worker resolves the uid an edition shares (Task 3) ---------
  #
  # An item carrying a non-empty `edition` is a DIFFERENT EDITION of a book
  # cantina may already hold. Its `path` already carries the " (<Edition>)"
  # suffix — the panel composes it — so the base book's path is that path with
  # that exact suffix removed. NEVER a general parenthesis parse: a book
  # legitimately titled "Something (Unabridged)" with no edition set must be
  # left completely alone, which the no-edition example at the end of this
  # section pins.
  #
  # The uid is resolved against the base book's stored sidecar: reused when it
  # has one, minted and written BACK to it when it has none, minted fresh when
  # no such book is stored (design doc S4). The write-back is the only place
  # in this phase that touches ANOTHER book's sidecar — the file holding the
  # only copy of that book's identity — so it must be additive and must never
  # overwrite a uid that is already there.

  wu_ed_path()   { printf '%s' "$RIP_SANDBOX/server/audiobooks/A/B (Full Cast)/.fleet-book.json"; }
  wu_base_path() { printf '%s' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }

  # wu_base <uid-or-empty> — the stored BASE book, schema-shaped and pretty,
  # carrying a work uid only when one is given. Deliberately rich (a subtitle,
  # a real asin, companions) so "additive" has something to be additive about.
  wu_base() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'base bytes\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    jq -n --arg u "$1" '{schema:1,kind:"audiobook",title:"B",subtitle:"The Sub",
      authors:["A"],narrators:["N"],series:null,duration_s:1200,language:"english",
      abridged:false,published:"2013-09-24T07:00:00",
      ids:{"audible.asin":"B0BASE0001","fleet.uid":"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"},
      work:(if $u == "" then null else {uid:$u,edition:null} end),
      companions:[],
      source:{provider:"libation",provider_version:"13.7.10",acquired_utc:null,format:"m4b"}}' \
      > "$(wu_base_path)"
  }

  # wu_plan <edition|omit> — a one-item folder plan whose path ALREADY carries
  # the " (Full Cast)" suffix, exactly as the panel composes it.
  wu_plan() {
    mkdir -p "$RIP_SANDBOX/incoming/Full"
    printf 'full cast bytes\n' > "$RIP_SANDBOX/incoming/Full/full.m4b"
    if [ "$1" = "omit" ]; then
      jq -nc --arg id "$RIP_SANDBOX/incoming/Full/full.m4b" \
        '{provider:"folder",items:[{id:$id,path:"A/B (Full Cast)",title:"B",
          authors:["A"],provider:"folder"}]}' > "$RIP_SANDBOX/plan.json"
    else
      jq -nc --arg id "$RIP_SANDBOX/incoming/Full/full.m4b" --arg e "$1" \
        '{provider:"folder",items:[{id:$id,path:"A/B (Full Cast)",title:"B",
          authors:["A"],provider:"folder",edition:$e}]}' > "$RIP_SANDBOX/plan.json"
    fi
  }

  wu_ed_work()   { jq -c '.work' "$(wu_ed_path)" 2>/dev/null; }
  wu_ed_uid()    { jq -r '.work.uid // ""' "$(wu_ed_path)" 2>/dev/null; }
  wu_base_sha()  { shasum -a 256 "$(wu_base_path)" | cut -d' ' -f1; }
  # The NON-work bytes of the base sidecar. `jq 'del(.work)'` renders both
  # sides through one deterministic pretty-printer, so this compares the
  # actual TEXT of everything the write-back was not allowed to touch — an
  # assertion that merely re-read a field would pass against a rewrite that
  # happened to preserve it.
  wu_base_nonwork() { jq 'del(.work)' "$(wu_base_path)" 2>/dev/null; }
  wu_base_work()    { jq -c '.work' "$(wu_base_path)" 2>/dev/null; }
  wu_is_uuid4() {
    printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
      && echo "uuidv4" || echo "NOT A UUIDV4: $1"
  }
  wu_ed_uid_shape() { wu_is_uuid4 "$(wu_ed_uid)"; }
  # The whole point of the mint-and-write-back branch: BOTH books end up
  # carrying the SAME uid, or the two editions never group.
  wu_uids_shared() {
    e=$(wu_ed_uid); b=$(jq -r '.work.uid // ""' "$(wu_base_path)" 2>/dev/null)
    if [ -n "$e" ] && [ "$e" = "$b" ]; then wu_is_uuid4 "$e"; else echo "edition=$e base=$b"; fi
  }
  # Every stored file's path and content EXCEPT the new edition's own book
  # dir — "nothing was written to any other path", proved against the whole
  # sandbox server tree rather than against the absence of a log line.
  wu_digest_but_edition() {
    ( cd "$RIP_SANDBOX/server" && find . -type f | grep -v '/A/B (Full Cast)/' \
        | LC_ALL=C sort | while IFS= read -r f; do
            printf '%s\n' "$f"; shasum -a 256 "$f" | cut -d' ' -f1
          done ) | shasum -a 256 | cut -d' ' -f1
  }

  It 'work uid: an edition whose base book already anchors a work REUSES that uid'
    wu_base "9f1c2a4e-2222-4b22-8aa0-abc123456789"
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_ed_work should equal '{"uid":"9f1c2a4e-2222-4b22-8aa0-abc123456789","edition":"Full Cast"}'
  End

  It 'work uid: a base book with no uid is MINTED one, written back additively, and shared'
    wu_base ""
    wu_plan "Full Cast"
    before=$(wu_base_nonwork)
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_uids_shared should equal "uuidv4"
    # ...and the base book anchors the work rather than claiming the edition
    # label, which belongs to the book that was just ripped.
    The result of function wu_base_work should include '"edition":null'
    # ADDITIVE: every other key of that sidecar comes back byte-identical.
    The result of function wu_base_nonwork should equal "$before"
  End

  It 'work uid: no base book stored mints a fresh uid and writes to no other path'
    # A bystander book, so "nothing else was written" is measured against a
    # non-empty tree.
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Z/Other"
    printf 'other\n' > "$RIP_SANDBOX/server/audiobooks/Z/Other/Other.m4b"
    wu_plan "Full Cast"
    before=$(wu_digest_but_edition)
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_ed_uid_shape should equal "uuidv4"
    The path "$RIP_SANDBOX/server/audiobooks/A/B" should not be exist
    The result of function wu_digest_but_edition should equal "$before"
  End

  It 'work uid: an existing non-null work.uid is NEVER overwritten'
    # Deliberately irregular formatting and a pre-existing edition label — a
    # write that merely re-serialized to the same parsed value would still
    # fail this, because the check is on the raw bytes.
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'base bytes\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf '%s' '{"schema":1,   "kind":"audiobook","title":"B","authors":["A"],"ids":{},"work":{"uid":"11111111-1111-4111-8111-111111111111","edition":"Abridged"},"source":{"provider":"libation"}}' \
      > "$(wu_base_path)"
    before=$(wu_base_sha)
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_base_sha should equal "$before"
    The result of function wu_ed_uid should equal "11111111-1111-4111-8111-111111111111"
  End

  # The STRUCTURAL guard, in isolation. A uid of the wrong type is non-null,
  # so it must not be overwritten — but it is not a uid either, so it must
  # not be reused. The read-side check refuses to reuse it (it is not a
  # string) and hands control to the write path, where the jq program's own
  # `empty` branch is the only thing left standing between a hand-edited
  # sidecar and a rewrite. Nothing may be written; the edition gets its own
  # fresh uid and the operator is told the two will not group.
  It 'work uid: a work.uid of the wrong type is neither reused nor overwritten'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'base bytes\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf '%s' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{},"work":{"uid":12345},"source":{"provider":"libation"}}' \
      > "$(wu_base_path)"
    before=$(wu_base_sha)
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_base_sha should equal "$before"
    The result of function wu_ed_uid_shape should equal "uuidv4"
    The stderr should include "could not record the shared work uid"
  End

  # `work` REALLY CAN ARRIVE AS AN ARRAY: Hammerspoon encodes an empty Lua
  # table as `[]`, not `{}` (see _RIP_JQ_IDS_DEF for the measurement), and a
  # sidecar written from a plan that round-tripped through the panel can
  # carry it. `.work.uid` RAISES on an array and `[] | del(.uid)` raises too,
  # so without the `_work_obj` coercion on BOTH sides the write-back composes
  # nothing and the two editions silently never group. The array means "no
  # work recorded", which is exactly the mint-and-write-back case.
  It 'work uid: a stored "work": [] is treated as no work at all and is filled'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'base bytes\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf '%s' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{},"work":[],"source":{"provider":"libation"}}' \
      > "$(wu_base_path)"
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_uids_shared should equal "uuidv4"
    The result of function wu_base_work should include '"edition":null'
  End

  # THE NO-EDITION CASE, on the very path that would tempt a parenthesis
  # parser: the book is titled "B (Full Cast)" and the operator set no
  # edition. Nothing may be resolved, nothing read, nothing written — the
  # sidecar is byte-identical to what today's worker produces, `work: null`.
  It 'work uid: an item with no edition is left exactly as it is — no parenthesis parsing'
    wu_base "9f1c2a4e-2222-4b22-8aa0-abc123456789"
    wu_plan omit
    before=$(wu_base_sha)
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_ed_work should equal "null"
    The result of function wu_base_sha should equal "$before"
  End

  It 'worker: one failing acquire does not abort the batch'
    printf '%s\n' '{"provider":"libation","items":[{"id":"BAD","path":"A/Bad","title":"Bad"},{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"}]}' > "$RIP_SANDBOX/plan.json"
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
case "$*" in
  *"--id BAD"*) echo "download failed" >&2; exit 4 ;;
esac
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "$books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should not equal 0
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
    The stderr should include "acquire failed"
  End

  It 'worker: re-keys the identity when the folder that landed differs'
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart: The Reckoners, Book 1","title":"Steelheart","subtitle":"The Reckoners, Book 1","ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","format":"m4b"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json >/dev/null && jq -c '[.subtitle,.ids[\"audible.asin\"]]' '$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/.fleet-book.json'"
    The status should equal 0
    The output should equal '["The Reckoners, Book 1","B00ECDZ08I"]'
    The stderr should include "re-keying"
  End

  # The re-key writes the LANDED folder name (raw directory-listing bytes)
  # as the index's new lookup key, but rip::_book_meta_for (the index's only
  # reader) NFC-normalizes its own query key before matching .path. A
  # provider that lands an NFD-decomposed name — composed (NFC) in the plan,
  # decomposed (NFD) on disk, byte-explicit here the same way the ssh/--have
  # example above is (review finding, same bug class as 21322287) — must
  # still re-key to something the NFC-normalized lookup can find, or the
  # sidecar silently falls back to the path-derived minimal identity.
  #
  # PLATFORM NOTE (found while verifying this example can fail against the
  # un-normalized code): unlike the ssh/--have example above, this step has
  # no remote/byte-strict branch to exercise instead — `landed` comes ONLY
  # from a local zsh glob (`*(N/om)`) over the acquire destination. On this
  # fleet's zsh (verified on both the custom build AND stock /bin/zsh 5.9),
  # that glob itself already returns NFC-composed names for an on-disk NFD
  # directory — confirmed by comparison: `ls`/`find`/python's listdir() all
  # return the raw NFD bytes for the SAME directory, only zsh's own glob
  # normalizes. So on THIS platform `${landed[1]:t}` is already NFC before
  # rip::_nfc ever runs, and this example cannot itself fail against a
  # broken (un-normalized) re-key — same caveat as the ab_have example
  # above, for a different underlying reason. The explicit rip::_nfc call
  # is kept anyway: it is the consistent, defensive contract every other
  # filesystem-derived identity lookup key in this file already follows,
  # and it is what protects a zsh build or platform (e.g. the project's
  # Linux dev-shell) whose glob does NOT do this normalization. This
  # example still guards the full round trip end-to-end (NFD-on-disk name
  # in, correct plan identity out) even though it cannot pin the specific
  # line.
  It 'worker: the reconcile re-key is NFC-normalized, so an NFD landed name still resolves'
    nfc=$(printf 'Ant\xc3\xb4nio')
    nfd=$(printf 'Anto\xcc\x82nio')
    printf '%s\n' "{\"provider\":\"libation\",\"items\":[{\"id\":\"B00ECDZ08I\",\"path\":\"Brandon Sanderson/${nfc}: The Reckoners, Book 1\",\"title\":\"${nfc}\",\"subtitle\":\"The Reckoners, Book 1\",\"ids\":{\"audible.asin\":\"B00ECDZ08I\"},\"provider\":\"libation\",\"format\":\"m4b\"}]}" > "$RIP_SANDBOX/plan.json"
    cat > "$RIP_SANDBOX/LibationCli" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\$RIP_SANDBOX/libation.log"
books=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o|--override) case "\$2" in Books=*) books="\${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "\$books/Brandon Sanderson/${nfd}"
printf 'audio\n' > "\$books/Brandon Sanderson/${nfd}/${nfd}.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json >/dev/null && jq -c '[.subtitle,.ids[\"audible.asin\"]]' '$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/${nfc}/.fleet-book.json'"
    The status should equal 0
    The output should equal '["The Reckoners, Book 1","B00ECDZ08I"]'
    The stderr should include "re-keying"
  End

  It 'worker: the queued plan copy is removed once read'
    cp "$RIP_SANDBOX/plan.json" "$RIP_STAGING_ROOT/.work/ab-plans/x.json" 2>/dev/null || mkdir -p "$RIP_STAGING_ROOT/.work/ab-plans"
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"}]}' > "$RIP_STAGING_ROOT/.work/ab-plans/x.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_STAGING_ROOT/.work/ab-plans/x.json"
    The status should equal 0
    The path "$RIP_STAGING_ROOT/.work/ab-plans/x.json" should not be exist
  End

  # --- the acquire's OUTCOME, not its exit code -----------------------------
  #
  # LibationCli exits 0 for a title whose Audible Plus licence has lapsed,
  # having liberated nothing at all (reproduced live 2026-08-24 with
  # Pierce Brown/Red Rising). The worker's only failure signal used to be
  # that rc, so it called the item a success, the push found no new files,
  # and the operator got a "ripping complete" toast for a book that never
  # arrived — this subsystem's NINTH "success asserted from control flow
  # reaching a line" defect. These examples pin the fix: the claim rests on
  # files that exist.

  # locked_libation <id> — a fake LibationCli whose liberate EXITS 0 and
  # writes nothing for <id>, and lands Steelheart for anything else. That
  # asymmetry is the point: the batch must survive the silent no-op.
  locked_libation() {
    cat > "$RIP_SANDBOX/LibationCli" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\$RIP_SANDBOX/libation.log"
case "\$*" in
  *"--id $1"*) echo "Done. Downloaded 0 books."; exit 0 ;;
esac
books=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o|--override) case "\$2" in Books=*) books="\${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "\$books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "\$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
  }

  It 'worker: an acquire that exits 0 but produces no files is reported as a failure, and the batch continues'
    locked_libation LOCKED
    printf '%s\n' '{"provider":"libation","items":[{"id":"LOCKED","path":"Pierce Brown/Red Rising","title":"Red Rising"},{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    # the failure is the RUN's exit code, not just a log line
    The status should not equal 0
    The stderr should include "acquire produced no files for Pierce Brown/Red Rising"
    # …and the rest of the batch still landed on the server
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
    # NEVER a cause we did not establish: this row carries no plus/absent, so
    # the message must not blame a licence.
    The stderr should not include "licence"
  End

  # A book directory that EXISTS but holds no audio is the same failure: a
  # provider that created its destination and then bailed must not be read as
  # a success by the mere presence of the folder.
  It 'worker: an empty book directory is not a successful acquire'
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "$books/Pierce Brown/Red Rising"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    printf '%s\n' '{"provider":"libation","items":[{"id":"LOCKED","path":"Pierce Brown/Red Rising","title":"Red Rising"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should not equal 0
    The stderr should include "acquire produced no files for Pierce Brown/Red Rising"
  End

  # The diagnostic, built from the ROW'S OWN DATA: a Plus title Audible's
  # last scan no longer returns is a lapsed licence, and saying so is the
  # difference between "something went wrong" and "this book is gone".
  It 'worker: a Plus + absent-from-last-scan row names the lapsed licence'
    locked_libation LOCKED
    printf '%s\n' '{"provider":"libation","items":[{"id":"LOCKED","path":"Pierce Brown/Red Rising","title":"Red Rising","plus":true,"absent":true}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should not equal 0
    The stderr should include "acquire produced no files for Pierce Brown/Red Rising"
    The stderr should include "Audible Plus and absent from Audible's last scan"
    The stderr should include "licence has lapsed"
    # Warned before the attempt, never refused: AbsentFromLastScan can be
    # stale, and refusing on stale metadata would block a legitimate rip.
    The stderr should include "attempting anyway"
    The contents of file "$RIP_SANDBOX/libation.log" should include "--id LOCKED"
  End

  # The sibling-credit trap. The reconcile step falls back to "the newest
  # book dir under this author", so in a batch of two books by ONE author it
  # would happily hand book two the folder book one just created — a failed
  # acquire re-keyed onto, and verified against, a sibling's files. Only a
  # directory that was not there before this item's acquire can be it.
  It 'worker: a failed acquire is not credited with a sibling book by the same author'
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
case "$*" in
  *"--id LOCKED"*) echo "Done."; exit 0 ;;
esac
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "$books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"},{"id":"LOCKED","path":"Brandon Sanderson/Wind and Truth","title":"Wind and Truth"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should not equal 0
    The stderr should include "acquire produced no files for Brandon Sanderson/Wind and Truth"
    The stderr should not include "Wind and Truth landed as"
  End

  # …and the same batch, judged on ARTEFACTS rather than stderr (review
  # finding 3, 2026-08-24): the successful sibling must keep its own identity
  # in the sidecar, the failed book must not be pushed, and the meta index
  # must still key both books by their own paths — a re-key of the failed
  # item onto the sibling would hand the sibling the wrong identity on the
  # next push.
  It 'worker: a sibling-success/sibling-failure batch leaves the sidecar and the meta index correct'
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
# argv is CAPTURED before the parse loop: the loop shifts it away, so a
# `case "$*"` after it would match nothing at all (and silently turn this
# fixture into "every acquire succeeds").
argv="$*"
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
case "$argv" in
  # The live shape of a lapsed licence: the destination is CREATED and then
  # nothing is written into it, and the CLI still exits 0.
  *"--id LOCKED"*) mkdir -p "$books/Brandon Sanderson/Wind and Truth"; exit 0 ;;
esac
mkdir -p "$books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","subtitle":"The Reckoners, Book 1","ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","format":"m4b"},{"id":"LOCKED","path":"Brandon Sanderson/Wind and Truth","title":"Wind and Truth"}]}' > "$RIP_SANDBOX/plan.json"
    # rip::ab_worker removes the meta index at the very END of the run (after
    # the push), so it cannot be read once `When run` returns. Snapshot it at
    # the moment the push reads it — the state the sidecar writer actually
    # sees — by wrapping rip::push_worker around a copy of itself.
    cat > "$RIP_SANDBOX/run.zsh" <<EOF
source "$RIPLIB"
functions -c rip::push_worker rip::_real_push_worker
rip::push_worker() {
  cp -- "\$RIP_STAGING_ROOT/.work/ab-meta.jsonl" "\$RIP_SANDBOX/ab-meta.snapshot" 2>/dev/null
  rip::_real_push_worker "\$@"
}
rip::ab_worker "\$RIP_SANDBOX/plan.json"
EOF
    When run zsh "$RIP_SANDBOX/run.zsh"
    The status should not equal 0
    The stderr should include "acquire produced no files for Brandon Sanderson/Wind and Truth"
    # THE NON-FACT: the empty composed dir the provider left behind is itself
    # "new since the snapshot", so the fallback used to name the book as
    # having landed as ITSELF and spend a jq+mv rewrite of the index on it.
    The stderr should not include "landed as"
    The contents of file "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/.fleet-book.json" should include "B00ECDZ08I"
    The contents of file "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/.fleet-book.json" should include "The Reckoners, Book 1"
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Wind and Truth" should not be exist
    # both books still keyed by their OWN paths: no rewrite happened at all
    The contents of file "$RIP_SANDBOX/ab-meta.snapshot" should include '"path":"Brandon Sanderson/Steelheart"'
    The contents of file "$RIP_SANDBOX/ab-meta.snapshot" should include '"path":"Brandon Sanderson/Wind and Truth"'
  End

  # THE MTIME-ORDER TRAP the same fix closes. A provider that writes its
  # files into a sanitized sibling and creates the composed dir AFTERWARDS
  # left the empty dir sorting first under (om), so a genuinely successful
  # acquire was reported as having produced nothing. Files decide, not mtime.
  It 'worker: a sanitized sibling holding the files beats an empty composed dir created after it'
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "$books/Brandon Sanderson/Steelheart (Unabridged)"
printf 'audio\n' > "$books/Brandon Sanderson/Steelheart (Unabridged)/Steelheart.m4b"
mkdir -p "$books/Brandon Sanderson/Steelheart"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","subtitle":"The Reckoners, Book 1","ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","format":"m4b"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The stderr should include "landed as Brandon Sanderson/Steelheart (Unabridged)"
    The stderr should not include "acquire produced no files"
    The contents of file "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart (Unabridged)/.fleet-book.json" should include "B00ECDZ08I"
  End

  # --- ABS author enrichment (rip-abs-authors + the RIP_AB_REMOTE_HOPS
  # first entry, rip::_abs_match_authors) ------------------------------------
  #
  # Hermetic per the file header's own doctrine: fake curl behind
  # RIP_CURL_BIN, RIP_ABS_URL pointed at a sandbox value, never the real
  # cantina. AUDIOBOOKSHELF_API_KEY is explicitly unset before every use so
  # a value sitting in the real environment can never leak in.

  abs_get_calls() { grep -c '/api/libraries/lib-book/authors' "$RIP_SANDBOX/abscurl.log" 2>/dev/null || true; }

  # fake_abs_curl <authors_json> [items_json] — a fake ABS: /api/libraries
  # answers with a DECOY podcast library FIRST and the book library second
  # (so a test that hardcoded "the first library" instead of filtering on
  # mediaType would pick the wrong one and fail), /api/libraries/lib-book/authors
  # answers with <authors_json>, /api/libraries/lib-book/items answers with
  # <items_json> (default: one item, relPath "A/B", id "item-1" — the Task 7
  # brief's canned fixture), /api/authors/<id>/match always succeeds and
  # logs which id it was called for, and the item/author PATCH/DELETE
  # endpoints used by the Task 7 verbs just echo {} and log the request.
  fake_abs_curl() {
    export RIP_ABS_URL="http://cantina:13378"
    printf '%s' "$1" > "$RIP_SANDBOX/abs-authors.json"
    # The items fixture must NOT be written as a "${2:-<json>}" default: the
    # shell scans for the closing brace of the expansion through the JSON's
    # own braces and silently rewrites the literal (it emitted
    # ...,"relPath":"A/B"]}} — invalid JSON that jq rejects, so --find-item
    # found nothing). Pick the default with a plain test instead.
    abs_items_json="${2:-}"
    [ -n "$abs_items_json" ] || abs_items_json='{"results":[{"id":"item-1","relPath":"A/B"}]}'
    printf '%s' "$abs_items_json" > "$RIP_SANDBOX/abs-items.json"
    cat > "$RIP_SANDBOX/abscurl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/abscurl.log"
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a";; esac; done
case "\$url" in
  */api/libraries)
    echo '{"libraries":[{"id":"lib-pod","name":"Podcasts","mediaType":"podcast"},{"id":"lib-book","name":"Audiobooks","mediaType":"book"}]}' ;;
  */api/libraries/lib-book/authors)
    cat "$RIP_SANDBOX/abs-authors.json" ;;
  */api/libraries/lib-book/items)
    cat "$RIP_SANDBOX/abs-items.json" ;;
  */api/authors/*/match)
    id="\${url%/match}"; id="\${id##*/}"
    printf '{"updated":true,"author":{"id":"%s"}}' "\$id" ;;
  */api/items/*/media)
    echo '{}' ;;
  */api/items/*)
    echo '{}' ;;
  */api/authors/*)
    echo '{}' ;;
  *) echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/abscurl"
    export RIP_CURL_BIN="$RIP_SANDBOX/abscurl"
  }

  It 'abs-authors: the book library is discovered by mediaType, not hardcoded'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[{"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":null,"imagePath":null}]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 0
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/libraries/lib-book/authors"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/api/libraries/lib-pod/authors"
  End

  It 'abs-authors: an author with both fields empty gets matched'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[{"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":null,"imagePath":null}]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 0
    The output should include "matched Brandon Sanderson"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/authors/auth-1/match"
  End

  It 'abs-authors: an author with an existing image is skipped — no match call'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[{"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":null,"imagePath":"/var/lib/audiobookshelf/metadata/authors/auth-1.jpg"}]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 0
    The output should include "skip (already populated)"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/match"
  End

  It 'abs-authors: an author with an existing bio is skipped — no match call'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[{"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":"Already has a bio.","imagePath":null}]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 0
    The output should include "skip (already populated)"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/match"
  End

  It 'abs-authors: --all matches every needing author and skips the rest'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[
      {"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":null,"imagePath":null},
      {"id":"auth-2","name":"Andy Weir","asin":"B123","description":"has one","imagePath":"/x.jpg"}
    ]}'
    When run zsh -f "$ABS_BIN" --all
    The status should equal 0
    The output should include "matched Brandon Sanderson"
    The output should include "skip (already populated)"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/authors/auth-1/match"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/api/authors/auth-2/match"
  End

  It 'abs-authors: a missing API key exits 3 without any HTTP call'
    # zsh -f: skip ~/.zshenv, which re-injects the real AUDIOBOOKSHELF_API_KEY
    # from system-secrets — a bare unset is not hermetic once the key exists
    # in the real environment (same gotcha as rip-tmdb-search's TMDB_API_KEY
    # example).
    unset AUDIOBOOKSHELF_API_KEY
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 3
    The stderr should include "AUDIOBOOKSHELF_API_KEY"
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  It 'abs-authors: an author absent from ABS is polled then given up on without error'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[]}'
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    When run zsh -f "$ABS_BIN" "Nobody Home"
    The status should equal 0
    The output should include "gave up waiting"
    The result of function abs_get_calls should equal "2"
  End

  # AN UNRECOGNIZED FLAG IS AN ERROR, NOT AN AUTHOR NAME (live finding,
  # 2026-08-24). The dispatcher's `*)` arm was a bare `cmd_names "$@"`, so a
  # typo'd flag became a lookup for an author of that name and entered the
  # poll loop at its DEFAULTS — 12 tries x 5s, roughly a minute per argument
  # with no output at all. That is what made the operator's first command
  # look frozen. Note these examples deliberately do NOT throttle the poll
  # seams: the whole point is that no polling may happen. If the guard is
  # ever removed, they take ~60s and then fail.
  It 'abs-authors: an unrecognized flag is refused immediately, never polled as an author name'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --find-itme "A/B"
    The status should equal 2
    The stderr should include "unknown option: --find-itme"
    # Not a single HTTP call: the refusal happens before any lookup.
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  It 'abs-authors: a flag typo in second position is refused too'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson" --dry-run
    The status should equal 2
    The stderr should include "unknown option: --dry-run"
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  # …and the refusal must not cost us author names that legitimately start
  # with a dash: `--` ends the options, exactly as it does everywhere else.
  It 'abs-authors: -- ends the options so a dash-leading author name is still reachable'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[{"id":"auth-7","name":"-dash Author","asin":null,"description":null,"imagePath":null}]}'
    When run zsh -f "$ABS_BIN" -- "-dash Author"
    The status should equal 0
    The output should include "matched -dash Author"
    # The marker itself is CONSUMED, never looked up as a name of its own:
    # the old dispatcher handed "--" straight to cmd_names, which polled for
    # an author called "--" and gave up on it.
    The output should not include "gave up waiting"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/authors/auth-7/match"
  End

  It 'abs-authors: -- with nothing after it is refused, not treated as a lookup'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --
    The status should equal 2
    The stderr should include "at least one author name required"
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  # --- ABS primitives for retire + author repair (Task 7) -------------------
  #
  # Five new verbs on the same bin, consumed by a later task to retire a
  # book and repair duplicate author records: --find-item, --author-id,
  # --repoint-item, --delete-item, --delete-author. Same hermetic doctrine
  # as the enrichment examples above.
  #
  # Every example also throttles the ABS_AUTHOR_POLL_* seams (TRIES=2,
  # INTERVAL_S=0), exactly as the "gave up waiting" example above does. Not
  # for these examples' own sake — the flags below never reach cmd_names —
  # but as a regression guard: the dispatcher's `*)` arm falls through to
  # cmd_names "$@" for anything it does not recognize, so if a future change
  # ever un-wires one of these verbs from the case statement, the flag would
  # silently be treated as an author name and the example would hang for up
  # to a minute (12 tries * 5s) polling instead of failing fast.

  It 'abs: --find-item resolves an item by its relative path'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --find-item "A/B"
    The status should equal 0
    The output should equal "item-1"
  End

  It 'abs: --find-item exits 1 for a path the server does not hold'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --find-item "No/Such"
    The status should equal 1
  End

  It 'abs: --repoint-item PATCHes the item metadata with the given author'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --repoint-item item-1 auth-9 "J. R. R. Tolkien"
    The status should equal 0
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "PATCH"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/items/item-1/media"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "auth-9"
  End

  It 'abs: --delete-item and --delete-author issue DELETEs'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -c "zsh -f $ABS_BIN --delete-item item-1 && zsh -f $ABS_BIN --delete-author auth-9"
    The status should equal 0
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/items/item-1"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/authors/auth-9"
  End

  It 'abs: --author-id resolves an author by exact name, reusing the authors listing'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[{"id":"auth-9","name":"J. R. R. Tolkien","asin":null,"description":null,"imagePath":null}]}'
    When run zsh -f "$ABS_BIN" --author-id "J. R. R. Tolkien"
    The status should equal 0
    The output should equal "auth-9"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/match"
  End

  It 'abs: --author-id exits 1 for a name the server does not hold'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --author-id "Nobody"
    The status should equal 1
  End

  It 'abs: the new verbs exit 3 without an API key'
    unset AUDIOBOOKSHELF_API_KEY
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --find-item "A/B"
    The status should equal 3
    The stderr should include "AUDIOBOOKSHELF_API_KEY"
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  # --- rip::_abs_match_authors (the RIP_AB_REMOTE_HOPS entry itself) --------

  # fake_rip_abs_authors_bin — a stand-in for the deployed CLI, logging one
  # line per invocation with its full argv, so an example can assert both
  # HOW MANY TIMES the hop invoked it and WITH WHAT.
  fake_rip_abs_authors_bin() {
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/hop-calls.log"
${1:-exit 0}
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
  }

  hop_call_count() { wc -l < "$RIP_SANDBOX/hop-calls.log" 2>/dev/null | tr -d ' '; }

  It 'hop: derives and dedupes author names from relpaths — one call for two books by one author'
    fake_rip_abs_authors_bin
    When run zsh -c "source $RIPLIB && rip::_abs_match_authors '$RIP_SANDBOX/server' 'Brandon Sanderson/Steelheart/Steelheart.m4b' 'Brandon Sanderson/Wind and Truth/Wind and Truth.m4b' 'Other Author/Book/Book.m4b'"
    The status should equal 0
    The result of function hop_call_count should equal "1"
    The contents of file "$RIP_SANDBOX/hop-calls.log" should include "Brandon Sanderson"
    The contents of file "$RIP_SANDBOX/hop-calls.log" should include "Other Author"
  End

  It 'hop: no relpaths means no call at all'
    fake_rip_abs_authors_bin
    When run zsh -c "source $RIPLIB && rip::_abs_match_authors '$RIP_SANDBOX/server'"
    The status should equal 0
    The path "$RIP_SANDBOX/hop-calls.log" should not be exist
  End

  It 'hop: a failing/hanging ABS never fails the push — rip::_enrich_audiobooks_remote swallows it'
    fake_rip_abs_authors_bin "exit 1"
    printf '%s\n' "Brandon Sanderson/Steelheart/Steelheart.m4b" > "$RIP_SANDBOX/listfile"
    When run zsh -c "source $RIPLIB && rip::_enrich_audiobooks_remote $RIP_SANDBOX/listfile"
    The status should equal 0
    The stderr should include "remote enrichment hop failed"
    The result of function hop_call_count should equal "1"
  End

  # --- import (manual provider) ----------------------------------------------

  It 'import: stages a single file as <Author>/<Title>/<Title>.<ext>'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Ann Leckie' 'Ancillary Justice'"
    The status should equal 0
    The path "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should be exist
    The contents of file "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should equal "audio"
  End

  It 'import: stages a directory by copying its contents into the book dir'
    mkdir -p "$RIP_SANDBOX/incoming"
    printf 'audio\n' > "$RIP_SANDBOX/incoming/part1.m4b"
    printf 'art\n' > "$RIP_SANDBOX/incoming/cover.jpg"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming' 'Ann Leckie' 'Ancillary Sword'"
    The status should equal 0
    The path "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Sword/part1.m4b" should be exist
    The path "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Sword/cover.jpg" should be exist
  End

  It 'import: records a manual-provider identity row in the meta index'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Ann Leckie' 'Ancillary Justice' && jq -c '{path,title,authors,provider}' \$(rip::_ab_meta_index_default)"
    The status should equal 0
    The output should equal '{"path":"Ann Leckie/Ancillary Justice","title":"Ancillary Justice","authors":["Ann Leckie"],"provider":"manual"}'
  End

  It 'import: rejects a traversing author or title'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' '..' 'X'"
    The status should equal 2
    The stderr should include "may not be . or .."
  End

  It 'import: refuses a missing source'
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/nope.m4b' 'A' 'B'"
    The status should equal 2
    The stderr should include "no such source"
  End

  It 'import: refuses to clobber a book already staged'
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice"
    printf 'old\n' > "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b"
    printf 'new\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Ann Leckie' 'Ancillary Justice'"
    The status should equal 2
    The stderr should include "already staged"
    The contents of file "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should equal "old"
  End

  It 'manual provider: capabilities says it cannot acquire, list is empty'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-manual" capabilities
    The status should equal 0
    The output should include '"name":"manual"'
    The output should include '"can_acquire":false'
  End

  It 'import: single-file basename is NFC-normalized (accented title)'
    nfc=$(printf 'Ant\xc3\xb4nio')
    nfd=$(printf 'Anto\xcc\x82nio')
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Test Author' '${nfd}'"
    The status should equal 0
    # The staged file must use NFC bytes in its name, even though the title arg was NFD
    The path "$RIP_STAGING_ROOT/audiobooks/Test Author/${nfc}/${nfc}.m4b" should be exist
  End

  It 'import: a failed copy leaves nothing in the watched staging tree'
    mkdir -p "$RIP_SANDBOX/fake-cp-bin"
    cat > "$RIP_SANDBOX/fake-cp-bin/cp" <<'FAKECP'
#!/bin/sh
# Fake cp: fail on recursive copy (directory import case)
if [ "$1" = "-R" ]; then
  echo "I/O error: cannot copy" >&2
  exit 1
fi
# Otherwise, copy like normal cp
exec /bin/cp "$@"
FAKECP
    chmod +x "$RIP_SANDBOX/fake-cp-bin/cp"
    export PATH="$RIP_SANDBOX/fake-cp-bin:$PATH"
    mkdir -p "$RIP_SANDBOX/incoming"
    printf 'part1\n' > "$RIP_SANDBOX/incoming/part1.m4b"
    printf 'part2\n' > "$RIP_SANDBOX/incoming/part2.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming' 'A' 'B'"
    The status should equal 1
    The stderr should include "could not copy"
    # Verify the destination directory does not exist (not even empty)
    The path "$RIP_STAGING_ROOT/audiobooks/A/B" should not be exist
  End

  It 'import: rejects a source file with no extension'
    printf 'audio\n' > "$RIP_SANDBOX/incoming"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming' 'A' 'B'"
    The status should equal 2
    The stderr should include "no extension"
  End

  It 'import: records the actual format from a single-file import'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.mp3"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.mp3' 'Ann Leckie' 'Test' && jq -c '.format' \$(rip::_ab_meta_index_default)"
    The status should equal 0
    The output should equal '"mp3"'
  End

  # rip::ab_have's --have check hardcodes the lowercase "${rel:t}.m4b" —
  # an uppercase source extension taken verbatim would stage <Title>.M4B
  # and record format:"M4B", so the book could never match and would look
  # permanently absent from the server (2026-08-23 review finding).
  It 'import: lowercases an uppercase source extension in both the staged filename and the recorded format'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.M4B"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.M4B' 'Ann Leckie' 'Ancillary Mercy' && jq -c '.format' \$(rip::_ab_meta_index_default)"
    The status should equal 0
    The output should equal '"m4b"'
    The path "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Mercy/Ancillary Mercy.m4b" should be exist
  End

  It 'import: directory with no audio files omits the format key'
    mkdir -p "$RIP_SANDBOX/incoming"
    printf 'text\n' > "$RIP_SANDBOX/incoming/readme.txt"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming' 'A' 'B' && jq -c 'has(\"format\")' \$(rip::_ab_meta_index_default)"
    The status should equal 0
    The output should equal 'false'
  End

  It 'import: RIP_AB_STAGING override uses same-filesystem temp, leaves no debris'
    # Override staging to an entirely different tree outside the default root
    local custom_staging="$RIP_SANDBOX/custom-audiobooks"
    export RIP_AB_STAGING="$custom_staging"
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Test' 'Book'"
    The status should equal 0
    # Book lands in the override tree
    The path "$custom_staging/Test/Book/Book.m4b" should be exist
    # No debris in default staging root (verify Test/ dir never created there)
    The path "$RIP_STAGING_ROOT/audiobooks/Test" should not be exist
    # No temp debris left anywhere: count .rip-import.* dirs in parent
    The result of function find_temp_dirs should equal "0"
  End

  It 'import: dotfile-only destination (e.g. .DS_Store) is treated as empty'
    # Create destination containing only .DS_Store, which Finder creates
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Author/Title"
    printf 'macOS\n' > "$RIP_STAGING_ROOT/audiobooks/Author/Title/.DS_Store"
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Author' 'Title'"
    The status should equal 0
    # Book lands directly under Title/, not nested
    The path "$RIP_STAGING_ROOT/audiobooks/Author/Title/Title.m4b" should be exist
    # .DS_Store is gone (cleaned before rename)
    The path "$RIP_STAGING_ROOT/audiobooks/Author/Title/.DS_Store" should not be exist
  End

  It 'import: refuses destination with real files, even if it also has dotfiles'
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Author/Title"
    printf 'old\n' > "$RIP_STAGING_ROOT/audiobooks/Author/Title/old.m4b"
    printf 'macOS\n' > "$RIP_STAGING_ROOT/audiobooks/Author/Title/.DS_Store"
    printf 'new\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Author' 'Title'"
    The status should equal 2
    The stderr should include "already staged"
    # Old file remains unchanged
    The contents of file "$RIP_STAGING_ROOT/audiobooks/Author/Title/old.m4b" should equal "old"
  End

  It 'import: destination containing a dot-directory refuses rather than nesting'
    # A dot-DIRECTORY (unlike a dotfile) survives both the clobber guard's
    # blind glob AND the pre-rename cleanup: `find -type f -delete` only
    # removes files, so the dot-directory remains, `rmdir` then fails
    # (directory not empty), and $dest survives to the mv. Without an
    # explicit invariant check, mv would nest the temp inside $dest instead
    # of publishing — the exact bug three review rounds already closed for
    # dotfiles, reopened here for dot-directories.
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Author/Title/.stray"
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Author' 'Title'"
    The status should equal 2
    The stderr should include "Author/Title"
    # Destination is left exactly as it was: the dot-directory survives,
    # nothing else was added (no nested import, no published book).
    The path "$RIP_STAGING_ROOT/audiobooks/Author/Title/.stray" should be exist
    The result of function dest_entry_count should equal "1"
    # No temp directory survives anywhere, nested or not.
    The result of function find_temp_dirs_anywhere should equal "0"
  End

  # rip::ab_editions — works stored in more than one edition. --editions
  # reads what is STORED, not what a provider offers, so these stage
  # sidecars directly in the sandbox "server" tree.
  mkbook() { # <author> <dir-title> <asin> <published> <bare-title>
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$1/$2"
    jq -nc --arg t "$3" --arg p "$4" --arg ti "$5" --arg a "$1" \
      '{schema:1,kind:"audiobook",title:$ti,authors:[$a],ids:{"audible.asin":$t},published:(if $p=="" then null else $p end)}' \
      > "$RIP_SANDBOX/server/audiobooks/$1/$2/.fleet-book.json"
  }

  It 'editions: two editions of one work group, newest marked'
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should include "Edgedancer"
    The output should include "B07626B9D2"
    The output should include "B0B5M28HZK"
    The output should include "newest"
  End

  It 'editions: parts of one issue sharing a publication date do NOT group (control edition still reported)'
    mkbook "Scientific American" "Scientific American, January 2001: Part 1" B002VE9P9A 2001-01-01T00:00:00 "Scientific American, January 2001"
    mkbook "Scientific American" "Scientific American, January 2001: Part 2" B0037FF924 2001-01-01T00:00:00 "Scientific American, January 2001"
    # Control book in the SAME fixture: a genuine two-date edition pair that
    # must still be reported. Without this, an example asserting only "the
    # output should not include X" would pass unchanged against a stub
    # `rip::ab_editions() { return 0 }` — no proof the grouping logic ran at
    # all (review finding 2026-08-24).
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Scientific American"
    The output should include "Edgedancer"
  End

  It 'editions: a cluster with any repeated date is suppressed ENTIRELY, not just the tied pair'
    # Regression for the shipped-jq defect (review finding 2026-08-24,
    # Critical): the old filter asked "does this cluster contain at least
    # one date difference anywhere" instead of "are ALL members' dates
    # distinct". Reproduced against the shipped program with exactly this
    # shape — two rows dated 2001-01-01 plus a third dated 2005-06-01 — and
    # all three printed side by side. A mixed cluster can never be safely
    # presented as an edition list: some of its rows are parts of one issue,
    # not alternative editions, and the report's downstream action is
    # deleting a "stale" copy the server holds the only copy of.
    mkbook "Scientific American" "Test Digest, Vol 3: Part 1" P1 2001-01-01T00:00:00 "Test Digest, Vol 3"
    mkbook "Scientific American" "Test Digest, Vol 3: Part 2" P2 2001-01-01T00:00:00 "Test Digest, Vol 3"
    mkbook "Scientific American" "Test Digest, Vol 3: Part 3" P3 2005-06-01T00:00:00 "Test Digest, Vol 3"
    # Control book in the SAME fixture — see rationale above.
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Test Digest"
    The output should include "Edgedancer"
  End

  It 'editions: two rows sharing a calendar date but not a time do NOT group (control edition still reported)'
    # Review finding 2, 2026-08-24: the cluster filter compared the RAW
    # `published` field while the line it prints one step later is
    # \(.published[0:10]) — and the panel's own edition mark slices the same
    # ten characters. `published` is Libation's DatePublished, a full
    # timestamp, so two parts of one issue that share a calendar date but
    # differ in the time component passed the all-distinct test and were
    # printed as an edition set: two IDENTICAL printed dates with one marked
    # `<- newest`, and a deletion as the only downstream action — while the
    # panel showed no mark at all for the same pair, so the two operator
    # surfaces disagreed. T07:00:00/T08:00:00 are midnight-Pacific
    # renderings, so a plain-date record mixed with a converted one on the
    # same day is the natural way this arrives.
    mkbook "Scientific American" "Test Digest, Vol 4: Part 1" Q1 2001-01-01T00:00:00 "Test Digest, Vol 4"
    mkbook "Scientific American" "Test Digest, Vol 4: Part 2" Q2 2001-01-01T07:00:00 "Test Digest, Vol 4"
    # Control book in the SAME fixture — see rationale above.
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Test Digest"
    The output should include "Edgedancer"
  End

  # The one-token hardening folded in with the date fix: the group key is
  # (first author, bare title), so two books with NO author at all would
  # cluster on ("", "<title>") and be offered up as editions of each other.
  It 'editions: two authorless books sharing a bare title never group'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Unknown/One" "$RIP_SANDBOX/server/audiobooks/Unknown/Two"
    printf '%s' '{"schema":1,"title":"Anthology","authors":[],"ids":{"audible.asin":"Z1"},"published":"2001-01-01T00:00:00"}' \
      > "$RIP_SANDBOX/server/audiobooks/Unknown/One/.fleet-book.json"
    printf '%s' '{"schema":1,"title":"Anthology","authors":[],"ids":{"audible.asin":"Z2"},"published":"2009-01-01T00:00:00"}' \
      > "$RIP_SANDBOX/server/audiobooks/Unknown/Two/.fleet-book.json"
    # Control book in the SAME fixture — see rationale above.
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Anthology"
    The output should include "Edgedancer"
  End

  It 'editions: a dramatized adaptation is a different title and does NOT group (control edition still reported)'
    mkbook "Brandon Sanderson" "Tress of the Emerald Sea: A Cosmere Novel" B0B1 2023-01-10T00:00:00 "Tress of the Emerald Sea"
    mkbook "Brandon Sanderson" "Tress of the Emerald Sea (Dramatized Adaptation)" B0B2 2024-01-10T00:00:00 "Tress of the Emerald Sea (Dramatized Adaptation)"
    # Control book in the SAME fixture — see rationale above.
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Tress"
    The output should include "Edgedancer"
  End

  It 'editions: a book with no published date is never grouped'
    mkbook "A" "T one" X1 "" T
    mkbook "A" "T two" X2 2020-01-01T00:00:00 T
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "X1"
  End

  It 'editions: an empty library reports nothing and succeeds'
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should equal ""
  End

  # server_sidecars_ssh <dir> — install a fake ssh implementing the exact
  # enumeration rip::_server_sidecars sends over the wire (mindepth/maxdepth
  # 3, .fleet-book.json only), counting its own invocations into
  # ssh.count. Ignores the actual remote command argv, like the
  # --server-library fake above — it re-does the equivalent walk locally
  # against the sandbox server dir, which is all these examples need.
  server_sidecars_ssh() {
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cd "$RIP_SANDBOX/server/audiobooks" || exit 2
find . -mindepth 3 -maxdepth 3 -name .fleet-book.json 2>/dev/null | while read -r f; do
  d=${f#./}; d=${d%/.fleet-book.json}
  printf "%s\t" "$d"; tr -d "\n" < "$f"; printf "\n"
done
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
  }

  # rip::_stored_sha_index — the dedupe key acquire consults for a locally
  # imported book: "<sha256>\t<Author>/<Title>" for every stored sidecar
  # carrying ids["local.sha256"]. Derived from the same rip::_server_sidecars
  # enumeration the editions report above already uses, not a second ssh —
  # pinned here with a real (fake) ssh rather than the plain-local-dir
  # remote base the two examples used before, so ssh_calls() means something.
  It 'stored-sha index: maps a stored local.sha256 to its book path'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{"fleet.uid":"u1","local.sha256":"deadbeef"}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    server_sidecars_ssh
    When run zsh -c "source $RIPLIB && rip::_stored_sha_index"
    The status should equal 0
    The output should include "deadbeef	A/B"
    The result of function ssh_calls should equal "1"
  End

  It 'stored-sha index: a sidecar with no local.sha256 contributes nothing'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{"audible.asin":"X1"}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    server_sidecars_ssh
    When run zsh -c "source $RIPLIB && rip::_stored_sha_index"
    The status should equal 0
    The output should equal ""
    The result of function ssh_calls should equal "1"
  End

  # Finding 2 (review, 2026-08-25): rip::_stored_sha_index used to swallow
  # rip::_server_sidecars' own failure propagation behind `2>/dev/null`,
  # returning rc 0 with empty output — indistinguishable from "asked the
  # server, it has no locally-hashed books" for a DEDUPE check, which reads
  # an empty index as "not a duplicate": an unreachable server would
  # silently DISABLE dedupe rather than refuse. Mirrors the editions
  # unreachable-server example above exactly, including the message.
  It 'stored-sha index: an unreachable server returns non-zero and says so, never a silently empty index'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::_stored_sha_index"
    The status should not equal 0
    The output should equal ""
    The stderr should include "could not read the stored sidecars"
  End

  # Finding D (review, 2026-08-25): the example above pins only that a
  # failure is reported — not the load-bearing OTHER half, that
  # _RIP_STORED_SHA_FETCHED stays unset on that failure so a LATER call in
  # the same process retries instead of being stuck with the poisoned
  # empty cache forever. A future `_RIP_STORED_SHA_FETCHED=1` creeping back
  # above the `return $rc` would break exactly this while the example above
  # stayed green. A sentinel file makes the fake ssh unreachable for the
  # FIRST call and reachable for the second, both within one process (one
  # `zsh -c`, so the cache globals genuinely persist between the two calls).
  It 'stored-sha index: an unreachable server does not poison the cache — a later call in the same process recovers'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{"fleet.uid":"u1","local.sha256":"deadbeef"}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    touch "$RIP_SANDBOX/ssh-sentinel"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
if [ -e "$RIP_SANDBOX/ssh-sentinel" ]; then
  exit 255
fi
cd "$RIP_SANDBOX/server/audiobooks" || exit 2
find . -mindepth 3 -maxdepth 3 -name .fleet-book.json 2>/dev/null | while read -r f; do
  d=${f#./}; d=${d%/.fleet-book.json}
  printf "%s\t" "$d"; tr -d "\n" < "$f"; printf "\n"
done
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
    When run zsh -c "source $RIPLIB
      rip::_stored_sha_index >/dev/null 2>/dev/null
      first_rc=\$?
      rm -f '$RIP_SANDBOX/ssh-sentinel'
      rip::_stored_sha_index
      print -ru2 -- \"first_rc=\$first_rc\""
    The status should equal 0
    The output should include "deadbeef	A/B"
    The stderr should include "first_rc=2"
  End

  # THE REPORT AN OPERATOR READS BEFORE DECIDING WHAT TO DELETE (review
  # finding 4, 2026-08-24). rip::_server_sidecars used to discard the ssh
  # status on both branches, so an unreachable server produced rc 0 and
  # empty output — byte-identical to "your library has no duplicate
  # editions". --canonicalize-authors already returns 2 in the same
  # situation and --backfill-published at least names the possibility.
  It 'editions: an unreachable server returns 2 and says so, never a silent clean bill of health'
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 2
    The output should equal ""
    The stderr should include "could not read the stored sidecars"
  End

  # …and the failure must reach the panel's feed too: the Hammerspoon
  # library panel keeps SERVER_EDITIONS_KNOWN false only when the task
  # exits non-zero, which is what preserves its tri-state discipline
  # (an empty list with KNOWN true would assert "no other editions exist").
  It 'CLI: --server-editions propagates an unreachable server as a non-zero exit'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --server-editions
    The status should not equal 0
    The output should equal ""
    The stderr should include "could not read the stored sidecars"
  End

  # --server-editions — the panel's edition-mark feed. Thin: one jq filter
  # over rip::_server_sidecars (already covered above), shaped to
  # {author, title, published, path}. Exercised through the CLI dispatcher,
  # not the raw function, so this also proves the verb is actually wired in.
  It 'CLI: --server-editions emits published rows as {author,title,published,path}'
    mkbook "A" "B" X1 2020-01-01T00:00:00 T
    mkbook "A" "C" X2 "" T2
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --server-editions
    The status should equal 0
    The output should include '"author":"A"'
    The output should include '"title":"T"'
    The output should include '"published":"2020-01-01T00:00:00"'
    The output should include '"path":"A/B"'
    The output should not include "X2"
    The output should not include '"path":"A/C"'
  End

  # --- --at-risk: which of my stored books can I never get again? -----------
  #
  # The runbook's backup doctrine — "audiobooks are not backed up; Audible is
  # the permanent copy" — is true for a book you BOUGHT and false for one you
  # BORROWED. A stored Audible Plus title whose licence has already lapsed
  # cannot be liberated again by anyone, so cantina's copy is the only copy in
  # existence. This verb is the durable answer to "which ones are those".

  # at_risk_library <json> — point the fake LibationCli's export at a
  # hand-written library so an example can state exactly which titles are
  # Plus and which have lapsed.
  at_risk_library() {
    cat > "$RIP_SANDBOX/atrisk-library.json"
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
out=""
while [ $# -gt 0 ]; do
  case "$1" in -p|--path) out="$2" ;; esac
  shift
done
cp "$RIP_SANDBOX/atrisk-library.json" "$out"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
  }

  It 'CLI: --at-risk lists the stored books whose Audible Plus licence has lapsed'
    mkbook "Martha Wells" "Network Effect" B08X1 "" "Network Effect"
    mkbook "Martha Wells" "All Systems Red" B08X2 "" "All Systems Red"
    mkbook "Brandon Sanderson" "Wind and Truth" B08X3 "" "Wind and Truth"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X1","Title":"Network Effect","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true},
 {"AudibleProductId":"B08X2","Title":"All Systems Red","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true},
 {"AudibleProductId":"B08X3","Title":"Wind and Truth","Subtitle":"","AuthorNames":"Brandon Sanderson",
  "BookStatus":"Liberated","IsAudiblePlus":false,"AbsentFromLastScan":false},
 {"AudibleProductId":"B08X4","Title":"Never Ripped","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"NotLiberated","IsAudiblePlus":true,"AbsentFromLastScan":true}
]
JSON
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --at-risk
    The status should equal 0
    The output should include "Martha Wells/Network Effect"
    The output should include "Martha Wells/All Systems Red"
    # owned outright — not at risk
    The output should not include "Wind and Truth"
    # lapsed but never ripped: already gone, and NOT a stored book, so it has
    # no place on a list of what the server alone is keeping alive
    The output should not include "Never Ripped"
    # the header has to say what the list MEANS, not just print paths
    The output should include "2 stored book(s) can NEVER be re-acquired"
    The output should include "the only copy that exists"
  End

  It 'CLI: --at-risk says so plainly when nothing is at risk'
    mkbook "Brandon Sanderson" "Wind and Truth" B08X3 "" "Wind and Truth"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X3","Title":"Wind and Truth","Subtitle":"","AuthorNames":"Brandon Sanderson",
  "BookStatus":"Liberated","IsAudiblePlus":false,"AbsentFromLastScan":false}
]
JSON
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --at-risk
    The status should equal 0
    The output should include "nothing at risk"
  End

  # A borrowed title still IN the catalog is not at risk yet — it is the one
  # the panel nags about ripping. It must not be listed here, or the verb's
  # answer stops meaning "irreplaceable".
  It 'at-risk: a Plus title still in the catalog is not listed'
    mkbook "Martha Wells" "Fugitive Telemetry" B08X2 "" "Fugitive Telemetry"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X2","Title":"Fugitive Telemetry","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":false}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "nothing at risk"
    The output should not include "Fugitive Telemetry"
  End

  # FALSE REASSURANCE IS THE FAILURE THIS VERB MUST NEVER PRODUCE. Read
  # through `< <(...)` an unreachable server is byte-identical to an empty
  # library, and "nothing at risk" for a server we never reached is exactly
  # the wrong answer.
  It 'at-risk: an unreachable server is an error, never "nothing at risk"'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 2
    The output should not include "nothing at risk"
    The stderr should include "could not read the stored sidecars"
  End

  # …and the same for a provider that answers with nothing: an empty library
  # cannot be told apart from "Libation did not answer".
  It 'at-risk: an empty provider library is an error, never "nothing at risk"'
    mkbook "Martha Wells" "Network Effect" B08X1 "" "Network Effect"
    at_risk_library <<'JSON'
[]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 2
    The output should not include "nothing at risk"
    The stderr should include "refusing to report an at-risk set"
  End

  # THE JOIN MUST NOT BE EXACT-PATH-ONLY (review finding 1, 2026-08-24).
  # Libation files a book under "Shawn Speakman - editor" where the server
  # holds "Shawn Speakman" — a divergence rip::ab_repair_sidecars already
  # carries a title-tier fallback for, and rip::_canonical_author measured
  # live. With the exact join alone the stored book matched NOTHING and was
  # folded into "not at risk": a lapsed Plus title, the only copy in
  # existence, reported as safe.
  It 'at-risk: a lapsed book whose server author spelling differs from Libation is still found'
    # No ASIN on this sidecar — the ASIN tier only fires when there is one to
    # try, so this exercises the title-tier FALLBACK the ASIN tier now sits
    # in front of, exactly as before.
    mkbook "Shawn Speakman" "Unfettered III" "" "" "Unfettered III"
    mkbook "Martha Wells" "Network Effect" B08X1 "" "Network Effect"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X9","Title":"Unfettered III","Subtitle":"","AuthorNames":"Shawn Speakman - editor",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true},
 {"AudibleProductId":"B08X1","Title":"Network Effect","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "2 stored book(s) can NEVER be re-acquired"
    The output should include "Shawn Speakman/Unfettered III"
    The output should include "Martha Wells/Network Effect"
    The output should not include "nothing at risk"
    # matched by title, so nothing is left unaccounted for
    The output should not include "Plus status is unknown"
  End

  # THE ASIN TIER IS THE HEADLINE FIX (2026-08-24): it must resolve a stored
  # book even when NEITHER the composed path NOR the bare title matches — the
  # exact scenario the exact-path and title tiers both fail on. Author AND
  # title both diverge from Libation's own spelling here, on purpose, so
  # nothing but the ASIN can carry this match. Pre-fix (no ASIN tier at all)
  # this book matches no row by any means and lands in the leftover bucket
  # instead of "can NEVER be re-acquired" — this example fails pre-fix.
  It 'at-risk: the ASIN join finds a lapsed book despite BOTH author and title spelling differing from Libation'
    mkbook "Shawn Speakman" "Unfettered III Anthology" B08X9 "" "Unfettered III Anthology"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X9","Title":"Unfettered III","Subtitle":"","AuthorNames":"Shawn Speakman - editor",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "1 stored book(s) can NEVER be re-acquired"
    The output should include "Shawn Speakman/Unfettered III Anthology"
    The output should not include "does not seem to be an Audible book"
    The output should not include "could not be established"
  End

  # AND THE REAL ANOMALY: a sidecar that CARRIES an Audible ASIN, but no
  # provider row lists it any more. This is not "unknown" the way a plain
  # unmatched book is — it is evidence Libation dropped a book that claims an
  # Audible identity, and the report must say exactly that shape and nothing
  # more (a lapsed Plus licence, a returned purchase and an account change
  # all look identical from here — this subsystem does not guess which).
  It 'at-risk: a stored book carrying an ASIN Libation no longer lists gets its own line, not silence'
    mkbook "Some Author" "Ripped Elsewhere" B0FAKEGONE "" "Ripped Elsewhere"
    mkbook "Brandon Sanderson" "Wind and Truth" B08X3 "" "Wind and Truth"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X3","Title":"Wind and Truth","Subtitle":"","AuthorNames":"Brandon Sanderson",
  "BookStatus":"Liberated","IsAudiblePlus":false,"AbsentFromLastScan":false}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "1 stored book(s) carries an Audible ASIN that libation no longer lists"
    The output should include "its Plus status could not be established"
    The output should include "Some Author/Ripped Elsewhere"
    # THE FALSE REASSURANCE THIS VERB EXISTS TO PREVENT: with a book it could
    # not speak for in hand, it must not say every book on cantina is
    # owned-or-in-catalogue.
    The output should not include "every book on cantina"
    # the book it DID resolve is still reported as not at risk
    The output should include "nothing at risk among the books that matched"
    The output should not include "can NEVER be re-acquired"
    The output should not include "does not seem to be an Audible book"
  End

  # A MANUAL IMPORT — no `audible.asin` in the sidecar at all — is not an
  # Audible book to begin with, so calling its Plus status "unknown" is
  # alarmist and wrong: this check simply does not apply to it. It must be
  # named plainly and kept out of the "not established" anomaly bucket
  # above, and its presence alone must not force the "matched a row" hedge
  # either — every Audible-provider title on cantina WAS resolved.
  It 'at-risk: a manual import with no ASIN is reported as not an Audible book, not as an anomaly'
    mkbook "Ernest Cline" "Ready Player One" "" "" "Ready Player One"
    mkbook "Brandon Sanderson" "Wind and Truth" B08X3 "" "Wind and Truth"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X3","Title":"Wind and Truth","Subtitle":"","AuthorNames":"Brandon Sanderson",
  "BookStatus":"Liberated","IsAudiblePlus":false,"AbsentFromLastScan":false}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "1 stored book(s) does not seem to be an Audible book:"
    The output should include "Ernest Cline/Ready Player One"
    The output should not include "could not be established"
    The output should not include "can NEVER be re-acquired"
    # not the hedge — no Audible-identified book was left unresolved, only a
    # book that was never in this check's scope
    The output should not include "matched a libation row"
    The output should not include "every book on cantina"
    The output should include "nothing at risk among cantina's Audible titles"
  End

  # rip::ab_backfill_published — sweep the 248 sidecars already on the server
  # (0 of which carry `published`, measured 2026-08-24) so edition detection
  # has something to group on. Each example redirects RIP_LIBEXEC_DIR into
  # the sandbox FIRST: setup() points it at the real tracked libexec dir, and
  # writing a fake provider without redirecting would overwrite the repo's
  # own source file.
  #
  # book_published() — the stored sidecar's `published` field for the fixed
  # A/B fixture every example below writes via mkbook. shellspec's "result"
  # modifier only accepts a defined shell function as its subject (see
  # dest_entry_count/find_temp_dirs above), not an arbitrary command string.
  book_published() {
    jq -r '.published' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
  }

  It 'backfill: dry-run names the books it would fill and writes nothing'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    The output should include "A/B"
    The output should include "2019-05-07"
    The output should include "re-run with --apply"
    The result of function book_published should equal "null"
  End

  It 'backfill: --apply fills the missing date and leaves every other field alone'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply && jq -c '[.published,.title,.authors[0],.ids[\"audible.asin\"],.kind]' $RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    The status should equal 0
    The output should include '["2019-05-07T07:00:00","B","A","X1","audiobook"]'
  End

  It 'backfill: a sidecar that already has a date is never rewritten'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 2001-01-01T00:00:00 B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply && jq -r '.published' $RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    The status should equal 0
    # "nothing to backfill" is now unconditional (review finding 2026-08-24,
    # Risk 1): an already-dated book is the to_fill==0 case in BOTH modes, so
    # stdout is that message followed by the unchanged date, not the date
    # alone. Asserting the message is itself a stub-defeating check: a
    # `rip::ab_backfill_published() { return 0 }` stub prints nothing, so
    # only the pre-existing mkbook date would appear and this line would fail.
    The output should include "nothing to backfill"
    The output should include "2001-01-01T00:00:00"
  End

  It 'backfill: a stored book the provider does not offer is reported unmatched, not touched'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" XORPHAN "" B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    # rc 1 and a summary line naming the count, not a bare "nothing to
    # backfill" with rc 0 (review finding 3B, 2026-08-24) — see the
    # every-candidate-failed example below.
    The status should equal 1
    The output should include "still undated"
    The stderr should include "no provider row"
    # …and the sidecar itself is untouched: still undated, nothing rewritten.
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"published":null'
  End

  # Review finding 3B, 2026-08-24: the seen==0 branch tells "the enumerator
  # produced nothing" apart from "the library is satisfied", but NOT from
  # "every candidate was seen and every one failed to match a provider row".
  # Reproduced with a provider whose export fails (exit 3 — LibationCli
  # missing, unauthorized, or mid-update): the warnings scroll past, then
  # `rip: nothing to backfill` lands on stdout with rc 0. The operator reads
  # the last line, concludes the one-shot sweep is done, sees --editions
  # report nothing, and concludes the library has no duplicates.
  It 'backfill: every candidate failing to match is reported as such, not as "nothing to backfill"'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    mkbook "A" "C" X2 "" C
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
echo "LibationCli not found" >&2
exit 3
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 1
    The output should include "2 book(s) still undated"
    The output should not include "nothing to backfill"
    The stderr should include "no provider row"
  End

  # The same distinction for the OTHER continue: a sidecar with no ASIN at
  # all cannot be backfilled either, and must not be summarised as a clean
  # sweep.
  It 'backfill: a candidate with no ASIN is counted in the undated summary too'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s' '{"schema":1,"title":"B","authors":["A"],"ids":{},"published":null}' \
      > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 1
    The output should include "1 book(s) still undated"
    The stderr should include "no ASIN"
  End

  It 'backfill: nothing to fill reports so and succeeds'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 2001-01-01T00:00:00 B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    The output should include "nothing to backfill"
    # Distinguishes this branch (sidecars WERE seen, all already dated) from
    # the "enumerator produced zero lines" branch below — review round 2,
    # 2026-08-24: without this negative assertion a real bug that always
    # emitted the "no sidecars found" wording, even when sidecars exist,
    # would pass this example unnoticed.
    The output should not include "cantina reachable"
  End

  It 'backfill: an enumerator that returns nothing is distinguished from a satisfied library'
    # Review finding 2026-08-24, round 2: "rip: nothing to backfill" alone
    # does not tell an operator whether every stored sidecar genuinely
    # already has a date, or whether rip::_server_sidecars produced ZERO
    # lines because the ssh to the server failed (that ssh runs under
    # 2>/dev/null, so an unreachable server and a satisfied library both
    # yield rc 0 and an empty work list). This is a one-shot sweep over 248
    # books — a false "nothing to backfill" here reads as "the sweep is
    # done" and a real gap propagates silently into --editions reporting no
    # duplicates either. An empty library legitimately produces zero lines
    # too (no mkbook call below — nothing staged in $RIP_SANDBOX/server at
    # all), so the wording only names the possibility, it does not assert
    # server-unreachability as fact.
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    The output should include "no sidecars found on the server"
    The output should include "cantina reachable"
  End

  It 'backfill: a malformed stored sidecar is warned about, not silently dropped'
    # Regression for review finding 2026-08-24 (Risk 2): rip::_server_sidecars
    # runs a per-line `jq -c ... 2>/dev/null`, which used to silently DROP any
    # line that fails to parse — the book never entered the backfill loop, so
    # it wasn't "skipped and warned", it was invisible. Same enumerator feeds
    # rip::ab_editions, so a corrupt sidecar would vanish from every report
    # the operator uses to reason about the library.
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    mkdir -p "$RIP_SANDBOX/server/audiobooks/C/D"
    printf '%s' '{"schema":1, "title": "D", BROKEN' > "$RIP_SANDBOX/server/audiobooks/C/D/.fleet-book.json"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    # The healthy book is still processed correctly — a `return 0` stub
    # would print none of this.
    The output should include "A/B"
    The output should include "2019-05-07"
    # The malformed sidecar is warned about, not silently absent.
    The stderr should include "malformed"
    The stderr should include "C/D"
  End

  # Final-fix review, 2026-08-24 (R1): a PARTIAL sweep — some sidecars filled,
  # some left undated — used to report only "backfilled N of N sidecar(s)"
  # with rc 0, which reads as a complete sweep even though other candidates
  # were skipped. This is a one-shot run over 248 real books; a partial
  # success masquerading as a clean bill of health is exactly the shape that
  # let a real gap propagate silently into --editions finding no duplicates.
  It 'backfill: a partial --apply sweep reports the still-undated remainder and fails'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    mkbook "A" "C" X2 "" C
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    # A/B matches the provider row and gets filled; A/C has no matching row
    # and stays undated — the summary must say so, not just the tally for
    # the books it touched, and the exit code must tell a wrapper too.
    The status should equal 1
    The output should include "backfilled 1 of 1 sidecar(s)"
    The output should include "1 book(s) still undated"
    The stderr should include "no provider row for A/C"
  End

  # Same partial-sweep gap in dry-run mode: "would fill: A/B … (1 book(s);
  # re-run with --apply)" read alone claims the WHOLE sweep is one book, when
  # a second candidate (A/C) was seen and could not be matched.
  It 'backfill: a partial dry run reports the still-undated remainder and fails'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    mkbook "A" "C" X2 "" C
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 1
    The output should include "would fill: A/B"
    The output should include "re-run with --apply"
    The output should include "1 book(s) still undated"
    The stderr should include "no provider row for A/C"
    # Nothing was written — dry run.
    The result of function book_published should equal "null"
  End

  # Final-fix review, 2026-08-24 (R2): both "no ASIN" and "no provider row"
  # increment the same counter, and the summary always blamed LibationCli
  # ("no provider row matched; is LibationCli available?") even when the
  # real cause is a sidecar with no ASIN at all — precisely the fingerprint
  # of an orphaned-identity book the operator most needs to recognise during
  # live validation. The summary must name the ASIN cause instead.
  It 'backfill: a no-ASIN sidecar is named in the summary, not blamed on LibationCli'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s' '{"schema":1,"title":"B","authors":["A"],"ids":{},"published":null}' \
      > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 1
    The output should include "1 book(s) still undated"
    The output should include "no ASIN"
    The output should not include "LibationCli"
    The stderr should include "no ASIN"
  End

  # --- the WRITE path against a server that has no jq ------------------------
  #
  # LIVE FINDING, 2026-08-24. `--backfill-published --apply` failed for all
  # 245 candidate books ("backfilled 0 of 245"): the write path shipped a
  # remote script that ran `jq` ON THE SERVER, and cantina (stock Debian,
  # media@ without passwordless sudo) has no jq. Every example above runs
  # the plain-local-dir branch, where jq sits on the dev machine's PATH — so
  # the suite could not see it. These run the ssh branch through a fake ssh
  # whose PATH holds a HANDPICKED set of stock binaries and, deliberately,
  # NO jq: a re-introduced remote-jq dependency fails here the same way it
  # failed live.
  #
  # fake_server_ssh — an ssh that actually EXECUTES the command it is handed,
  # against the sandbox server tree, under that restricted PATH. It also logs
  # every remote command string so an example can assert what was asked of
  # the server.
  #
  # `stat`, `sha256sum` and `shasum` joined the list for --repair-sidecars'
  # Case C hash, which cantina computes with sha256sum. jq is STILL absent and
  # must stay absent: that is the whole point of the handpicked list.
  fake_server_ssh() {
    mkdir -p "$RIP_SANDBOX/remotebin"
    for c in sh find sed tr mv rm mkdir rmdir head cat ls printf test base64 stat sha256sum shasum; do
      p=$(command -v "$c" 2>/dev/null || true)
      if [ -n "$p" ]; then ln -sf "$p" "$RIP_SANDBOX/remotebin/$c"; fi
    done
    # The server's login shell runs the command string with a genuinely
    # POSIX /bin/sh (dash on Debian) — macOS's own /bin/sh is bash 3.2,
    # which (unlike dash) understands $'...' ANSI-C quoting, so it can't
    # catch a ${(q)} vs ${(qq)} quoting regression in rip.zsh's write
    # path. Fail loudly rather than silently falling back to /bin/sh,
    # which would just re-blind this guard.
    local dash_bin
    dash_bin=$(command -v dash 2>/dev/null || true)
    if [ -z "$dash_bin" ]; then
      print -u2 -- "fake_server_ssh: no dash on PATH — refusing to fall back to /bin/sh (would blind the POSIX-quoting regression guard)"
      return 1
    fi
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cmd=""
for a in "\$@"; do cmd="\$a"; done
printf '%s\n' "\$cmd" >> "$RIP_SANDBOX/ssh.cmds"
PATH="$RIP_SANDBOX/remotebin"; export PATH
exec "$dash_bin" -c "\$cmd"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    export RIP_REMOTE_BASE="media@cantina:$RIP_SANDBOX/server"
  }

  # fake_server_ssh_reads_stdin — fake_server_ssh, plus the ONE behaviour of
  # ssh(1) the shared fake does not model: without -n, ssh reads the local
  # stdin EAGERLY and forwards it to the remote, whether or not the remote
  # command consumes it. `test -f` never consumes it, so a probe run inside a
  # `while read` loop fed by a here-string swallowed the whole remaining
  # library and the loop ended after ONE book (review finding, 2026-08-24) —
  # invisible to a fake that never touches fd 0.
  #
  # A VARIANT, deliberately, not a change to the shared fake: every other
  # example here feeds ssh a payload batch on stdin, and a slurping fake would
  # be one more moving part in all of them.
  #
  # -n is HONOURED, exactly as ssh honours it — that is what makes the guard
  # observable: with -n the fake reads nothing, without it the fake drains.
  fake_server_ssh_reads_stdin() {
    fake_server_ssh || return 1
    local dash_bin
    dash_bin=$(command -v dash 2>/dev/null || true)
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cmd=""
noinput=0
for a in "\$@"; do
  [ "\$a" = "-n" ] && noinput=1
  cmd="\$a"
done
printf '%s\n' "\$cmd" >> "$RIP_SANDBOX/ssh.cmds"
PATH="$RIP_SANDBOX/remotebin"; export PATH
if [ "\$noinput" = 1 ]; then
  exec "$dash_bin" -c "\$cmd" < /dev/null
fi
slurp="$RIP_SANDBOX/ssh.stdin.\$\$"
cat > "\$slurp"
"$dash_bin" -c "\$cmd" < "\$slurp"
rc=\$?
rm -f "\$slurp"
exit \$rc
EOF
    chmod +x "$RIP_SANDBOX/ssh"
  }

  # fake_server_ssh_probe_fails — fake_server_ssh whose `test -f` probe exits
  # 255, the rc a real ssh gives when the connection itself never happened.
  # rip::_remote_has_file's tri-state turns that into 2 ("the check did not
  # run"), which is the branch whose closing line must not claim a sidecar
  # exists. Every other remote command still runs normally, so the sweep
  # reaches that branch the way it would live.
  fake_server_ssh_probe_fails() {
    fake_server_ssh || return 1
    local dash_bin
    dash_bin=$(command -v dash 2>/dev/null || true)
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cmd=""
for a in "\$@"; do cmd="\$a"; done
printf '%s\n' "\$cmd" >> "$RIP_SANDBOX/ssh.cmds"
case "\$cmd" in
  "test -f"*) exit 255 ;;
esac
PATH="$RIP_SANDBOX/remotebin"; export PATH
exec "$dash_bin" -c "\$cmd"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
  }

  fake_provider_two() {
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
if [ "$1" = list ]; then
  printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
  printf '%s\n' '{"id":"X2","path":"C/D","title":"D","published":"2021-11-30T08:00:00"}'
fi
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
  }

  two_dates() {
    printf '%s %s\n' \
      "$(jq -r '.published' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json")" \
      "$(jq -r '.published' "$RIP_SANDBOX/server/audiobooks/C/D/.fleet-book.json")"
  }

  It 'backfill: --apply writes through a server with NO jq, in ONE ssh for the whole batch'
    fake_provider_two
    mkbook "A" "B" X1 "" B
    mkbook "C" "D" X2 "" D
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    The status should equal 0
    The output should include "backfilled 2 of 2 sidecar(s)"
    The result of function two_dates should equal "2019-05-07T07:00:00 2021-11-30T08:00:00"
    # TWO ssh calls for two books, not three: one to enumerate the sidecars,
    # ONE for the whole write batch. 245 books must not be 245 round-trips.
    The result of function ssh_calls should equal "2"
    # …and nothing the server was asked to run mentions jq. The restricted
    # PATH above already makes a remote jq fail; this names the regression.
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "jq"
  End

  # The trap this fix had to dodge: rip::_server_sidecars ANNOTATES each row
  # it emits with a `_path` key that is NOT in the stored file. Composing the
  # replacement from that annotated object — the obvious way to do it once
  # the compose moved local — would permanently add a bogus `_path` field to
  # every sidecar the sweep touches, on the only copy of every book's
  # identity. Everything else must survive the round trip byte for byte,
  # including a false-valued field, a null, nested objects, and a title full
  # of characters that would wreck an unquoted remote command line.
  RICH_JSON='{"schema":1,"kind":"audiobook","title":"Elantris: 10th $Ann - Omega","authors":["Sanderson, B. \"Bran\""],"ids":{"audible.asin":"X1","isbn":null},"series":{"name":"The Cosmere","order":"1"},"work":{"language":"english","abridged":false},"source":{"provider":"libation","fetched":"2026-08-22"}}'
  RICH_AUTHOR='Sanderson, B. "Bran"'
  RICH_TITLE='Elantris: 10th $Ann - Omega'
  rich_file() { printf '%s' "$RIP_SANDBOX/server/audiobooks/$RICH_AUTHOR/$RICH_TITLE/.fleet-book.json"; }
  rich_without_published() { jq -c 'del(.published)' "$(rich_file)"; }
  rich_published() { jq -r '.published' "$(rich_file)"; }
  rich_has_path() { jq -r 'has("_path")' "$(rich_file)"; }

  It 'backfill: the written sidecar gains ONLY published — no _path, nothing else altered'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR" "$RIP_SANDBOX/server/audiobooks/$RICH_AUTHOR/$RICH_TITLE"
    printf '%s' "$RICH_JSON" > "$(rich_file)"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"x","title":"x","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    The status should equal 0
    The output should include "backfilled 1 of 1 sidecar(s)"
    The result of function rich_published should equal "2019-05-07T07:00:00"
    The result of function rich_has_path should equal "false"
    The result of function rich_without_published should equal "$RICH_JSON"
  End

  stray_tmp_files() {
    find "$RIP_SANDBOX/server" -name '*.tmp.*' | wc -l | tr -d ' '
  }

  It 'backfill: a write that fails leaves the good sidecar untouched and reports the book failed'
    # The book directory is made unwritable, so the remote script's temp
    # file cannot be created at all. The pre-existing sidecar must survive
    # exactly as it was, no temp file may be left behind, and the book must
    # be counted as NOT filled — the server holds the only copy.
    fake_provider_two
    mkbook "A" "B" X1 "" B
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      chmod 555 '$RIP_SANDBOX/server/audiobooks/A/B'
      rip::ab_backfill_published --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/A/B'
      exit \$rc"
    The status should equal 1
    The output should include "backfilled 0 of 1 sidecar(s)"
    The output should include "1 sidecar(s) could not be written"
    The stderr should include "could not backfill A/B"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"published":null'
    The result of function stray_tmp_files should equal "0"
  End

  It 'backfill: a write connection that never answers fills nothing and says so'
    # The enumeration succeeds and the write ssh dies (255, an unreachable
    # host). Nothing may be reported as filled on the strength of the call
    # having been made — only on a per-book "ok" coming back.
    fake_provider_two
    mkbook "A" "B" X1 "" B
    fake_server_ssh
    # Same POSIX-shell rationale as fake_server_ssh above: the login shell
    # must be real dash, not macOS's bash-flavored /bin/sh.
    local dash_bin
    dash_bin=$(command -v dash 2>/dev/null || true)
    if [ -z "$dash_bin" ]; then
      print -u2 -- "no dash on PATH — refusing to fall back to /bin/sh"
      return 1
    fi
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
cmd=""
for a in "\$@"; do cmd="\$a"; done
case "\$cmd" in *base64*) exit 255 ;; esac
PATH="$RIP_SANDBOX/remotebin"; export PATH
exec "$dash_bin" -c "\$cmd"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    The status should equal 1
    The output should include "backfilled 0 of 1 sidecar(s)"
    The stderr should include "could not backfill A/B"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"published":null'
  End

  It 'backfill: a dry run against the ssh branch writes nothing and opens no write connection'
    fake_provider_two
    mkbook "A" "B" X1 "" B
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    The output should include "re-run with --apply"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"published":null'
    # The enumeration ssh, and nothing else.
    The result of function ssh_calls should equal "1"
  End

  # --- retire + author canonicalization sweep (destructive operators) -------
  #
  # Both default to a DRY RUN. The server holds the only copy of every book
  # (staging is emptied after each verified push, and the audio cannot be
  # re-derived), so --apply is required before anything is deleted or moved.
  #
  # fake_abs_ops_bin — stands in for the Task 7 verbs on
  # $RIP_BIN_DIR/rip-abs-authors and logs its full argv, so an example can
  # assert exactly which ABS calls were made AND, just as importantly, that
  # none were made when the operator was refused.
  fake_abs_ops_bin() {
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item)
    case "\$2" in
      "A/B") echo item-1 ;;
      *"/The Hobbit") echo item-1 ;;
      *) exit 1 ;;
    esac
    ;;
  --author-id) echo auth-9 ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
  }

  It 'retire: dry-run prints the plan and changes nothing'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/B'"
    The status should equal 0
    The output should include "would remove"
    The output should include "A/B"
    The path "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b" should be exist
    # A dry run may LOOK the book up, but must never ask ABS to delete it.
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-item"
  End

  It 'retire: --apply removes the files and deletes the ABS item'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/B' --apply"
    The status should equal 0
    The output should include "retired A/B"
    The path "$RIP_SANDBOX/server/audiobooks/A/B" should not be exist
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-item item-1"
  End

  # CLAIM ONLY WHAT ACTUALLY HAPPENED (review finding 3A, 2026-08-24). The
  # ABS delete's failure used to be warned about and then followed,
  # unconditionally, by "rip: retired $rel" and rc 0 — files gone, item
  # alive, stdout announcing a clean retire. That is exactly the
  # half-retired state this function's header resolves the item early to
  # avoid (Audiobookshelf keeps an item whose files vanished and marks it
  # missing; a rescan does not drop it), reported as a success. This is the
  # most destructive verb in the module.
  It 'retire: a failed ABS item delete is reported as such, never as a completed retire'
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-1 ;;
  --delete-item) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/B' --apply"
    The status should equal 1
    The output should not include "retired A/B"
    The stderr should include "could NOT be deleted"
    The stderr should include "item-1"
    # The delete WAS attempted, and the files really are gone — the point is
    # that the message and the rc tell the truth about what remains.
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-item item-1"
    The path "$RIP_SANDBOX/server/audiobooks/A/B" should not be exist
  End

  # A book the server does not hold is NOT a book whose files we may guess
  # at. Membership is tested against rip::ab_server_library — the server's
  # own listing — not against a guessed "<Title>/<Title>.m4b", which is only
  # Libation's naming convention: a manually imported book carries whatever
  # filename it was given and would otherwise read as "not stored" forever.
  It 'retire: refuses a path the server does not hold'
    fake_abs_ops_bin
    When run zsh -c "source $RIPLIB && rip::ab_retire 'No/Such' --apply"
    The status should equal 2
    The stderr should include "not stored"
    # Refused before ABS was touched at all.
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  # An unreachable server must refuse, never guess: rip::ab_server_library
  # returns 2 and prints nothing, so membership cannot be established and
  # nothing is deleted.
  It 'retire: an unreachable server refuses rather than guessing'
    fake_abs_ops_bin
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/B' --apply"
    The status should equal 2
    The stderr should include "not stored"
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  # THE ordering invariant. Audiobookshelf keeps an item whose files have
  # vanished and marks it "missing" — a rescan does not drop it — so a
  # half-retired book (files gone, item present) is worse than one left
  # alone. The item is resolved BEFORE anything is deleted, and an
  # unresolvable item refuses and touches nothing.
  It 'retire: refuses when the ABS item cannot be resolved, leaving files intact'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Orphan"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/Orphan/Orphan.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/Orphan' --apply"
    The status should equal 2
    The stderr should include "could not resolve"
    The path "$RIP_SANDBOX/server/audiobooks/A/Orphan/Orphan.m4b" should be exist
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-item"
  End

  It 'sweep: dry-run reports the collision and changes nothing'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors"
    The status should equal 0
    The output should include "J.R.R. Tolkien"
    The output should include "J. R. R. Tolkien"
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  # Renaming the folder is NOT enough for Audiobookshelf: it matches the
  # moved item by inode and updates its path, but keeps the item's STORED
  # author, so the split survives in its database until the item is
  # repointed (verified live 2026-08-23). Move, then repoint, then delete
  # the emptied author record.
  It 'sweep: --apply moves the book, repoints the ABS item and deletes the emptied author'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The output should include "author variants"
    The output should include "J.R.R. Tolkien"
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien" should not be exist
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--repoint-item"
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-author"
  End

  It 'sweep: a library with no collisions reports nothing to do'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Ann Leckie/Ancillary Justice"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors"
    The status should equal 0
    The output should include "nothing to do"
  End

  It 'CLI: --retire and --canonicalize-authors are wired and dry-run by default'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --retire "A/B"
    The status should equal 0
    The output should include "would remove"
    The path "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b" should be exist
  End

  # --- the sweep's ssh branch (review findings 1-3, 2026-08-24) -------------
  #
  # Every sweep example above runs the plain-local-dir branch, which is why
  # three defects lived in the ssh and failure paths unnoticed. These
  # exercise the branch the real server actually takes.
  #
  # fake_ssh_server — a fake ssh that behaves like the real one in the two
  # ways that matter here:
  #   1. IT READS STDIN. Real ssh does, and that is the whole of finding 1:
  #      an ssh reached from inside a `while read … done <<< "$variants"`
  #      loop swallows the remaining variants. A fake that ignores stdin
  #      cannot reproduce the bug, so the regression guard would be
  #      worthless. Guarded by `[ -t 0 ]` so an interactive shellspec run
  #      cannot hang on a terminal.
  #   2. It RUNS the command it is given, against the sandbox, after
  #      rewriting the remote root — so the ${(q)} quoting, the `mv -n`
  #      no-clobber semantics and `rmdir`'s exit status are all the real
  #      ones, not a mock's opinion of them.
  fake_ssh_server() {
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
[ -t 0 ] || cat > /dev/null
printf '%s\n' "\$*" >> "$RIP_SANDBOX/ssh.log"
cmd=""
while [ \$# -gt 0 ]; do cmd="\$1"; shift; done
sh -c "\$(printf '%s' "\$cmd" | sed 's|/srv/media|$RIP_SANDBOX/server|g')"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
  }

  # fake_abs_ops_bin_any — resolves every --find-item and --author-id, so an
  # example can assert on WHICH destructive verbs were issued rather than on
  # a lookup failing.
  fake_abs_ops_bin_any() {
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) echo auth-x ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
  }

  # FINDING 1 regression guard. Four spellings of one author: the plan lists
  # three variants, and every one of them must actually be swept. Against
  # the pre-fix code the first ssh drains the here-string and exactly ONE
  # variant is processed — silently, rc 0, no warning.
  It 'sweep (ssh): every variant in a group is swept, not just the first'
    fake_abs_ops_bin_any
    fake_ssh_server
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Return of the King" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit" \
             "$RIP_SANDBOX/server/audiobooks/J R R Tolkien/Leaf by Niggle" \
             "$RIP_SANDBOX/server/audiobooks/JRR Tolkien/Farmer Giles"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The output should include "author variants"
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Leaf by Niggle" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Farmer Giles" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien" should not be exist
    The path "$RIP_SANDBOX/server/audiobooks/J R R Tolkien" should not be exist
    The path "$RIP_SANDBOX/server/audiobooks/JRR Tolkien" should not be exist
  End

  # FINDING 2. `mv -n` exits 0 when it REFUSES, so a same-title collision
  # leaves the book under the old spelling while every command reports
  # success. Deleting the variant's author record there would leave the
  # library asserting something false: book present, its item still storing
  # the variant spelling, and the record that spelling pointed at gone.
  # Audio is never at risk — mv -n and rmdir both refuse correctly — but the
  # ABS record must survive too.
  It 'sweep (ssh): a same-title collision keeps the book AND its author record'
    fake_abs_ops_bin_any
    fake_ssh_server
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    printf 'canon\n' > "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit/h.m4b"
    printf 'variant\n' > "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit/h.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The output should include "author variants"
    The stderr should include "still holds books"
    # The only copy of the variant's audio is untouched, and unchanged.
    The contents of file "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit/h.m4b" should equal "variant"
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit/h.m4b" should equal "canon"
    # …and the author record it still points at was NOT deleted.
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
  End

  # FINDING 2, second reachable path: the books move, but the canonical
  # author cannot be resolved, so nothing gets repointed. Deleting the
  # variant record then strands every moved item on a record that no longer
  # exists.
  It 'sweep (ssh): an unresolvable canonical author keeps the variant record'
    fake_ssh_server
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) case "\$2" in "J. R. R. Tolkien") exit 1 ;; *) echo auth-x ;; esac ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The output should include "author variants"
    The stderr should include "could not be repointed"
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
  End

  # FINDING 3. An unreachable server must refuse, not assert a clean
  # library: stderr alone is invisible to a wrapper or a cron job checking
  # the exit status.
  It 'sweep: an unreachable server refuses instead of claiming a clean library'
    fake_abs_ops_bin_any
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors"
    The status should equal 2
    The output should not include "nothing to do"
    The stderr should include "could not list the audiobook library"
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  # FINDING (round 2). `rmdir` failing is NOT the same fact as "books remain".
  # rip::ab_server_library lists only depth-2 DIRECTORIES, so a stray
  # .DS_Store — reachable through any Finder mount of the share — sits
  # directly under the author folder, defeats `rmdir` after every book has
  # already moved, and made the sweep warn something untrue. It also drops
  # the variant out of the listing for good (nothing at depth 2 any more),
  # so a kept author record would be unreachable by every future sweep.
  # The record is therefore removed once no books remain, and the leftover
  # directory is named rather than misdescribed.
  It 'sweep (ssh): a stray .DS_Store is reported accurately, not as "still holds books"'
    fake_abs_ops_bin_any
    fake_ssh_server
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/.DS_Store"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    # Not a clean sweep: a directory is left behind for the operator.
    The status should equal 1
    The output should include "author variants"
    # The book really did move.
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit" should not be exist
    # The message states what is actually true…
    The stderr should include "holds no books but is not empty"
    The stderr should include "left the directory for you to clean up"
    # …and never the falsehood.
    The stderr should not include "still holds books"
    # The bookless author record is removed — the variant will never appear in
    # the server listing again, so this is the last chance to reach it.
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-author"
    # The leftover is left alone, not deleted blind.
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/.DS_Store" should be exist
  End

  # FINDING (round 3). The state-11 branch announced a deletion that may
  # never have occurred: $stale can be empty (the id never resolved), and
  # --delete-author's own exit status was discarded. Both are PERMANENT
  # here — by this point the variant has left rip::ab_server_library's
  # listing, so no future sweep will ever see this author again — which is
  # precisely the artifact the state-11 branch exists to prevent, and
  # claiming success would hide it.

  It 'sweep (ssh): an unresolvable variant author id is reported, never claimed as removed'
    fake_ssh_server
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) case "\$2" in "J.R.R. Tolkien") exit 1 ;; *) echo auth-canon ;; esac ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/.DS_Store"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The output should include "author variants"
    # The book still moved and was repointed — only the record is unaccounted for.
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The stderr should include "could not resolve its Audiobookshelf author record"
    The stderr should include "no future sweep will see"
    # …and NOT the claim that it was removed.
    The stderr should not include "removed its Audiobookshelf author record"
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
  End

  It 'sweep (ssh): a --delete-author that fails is reported, never claimed as removed'
    fake_ssh_server
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) echo auth-x ;;
  --delete-author) exit 4 ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/.DS_Store"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The output should include "author variants"
    The stderr should include "could not remove its Audiobookshelf author record"
    The stderr should include "remove it in the Audiobookshelf UI"
    The stderr should not include "removed its Audiobookshelf author record"
    # It WAS attempted — this is a real failure, not a skipped call.
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-author"
  End

  # The same exposure on the state-0 path: the variant directory is gone
  # entirely, so a record that failed to delete is just as unreachable. A
  # silent rc 0 there would be the same false success.
  It 'sweep (ssh): a fully-swept variant whose record will not delete still reports it'
    fake_ssh_server
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) echo auth-x ;;
  --delete-author) exit 4 ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The output should include "author variants"
    # The sweep itself worked: the book moved and the variant folder is gone.
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien" should not be exist
    The stderr should include "could not remove its Audiobookshelf author record"
    The stderr should include "no future sweep will see"
  End

  # --- sidecar repair: --repair-sidecars / --adopt-asin ---------------------
  #
  # Four outcomes, discriminated on EVIDENCE (is a provider row findable?)
  # rather than on the sidecar's own `provider` field, which is the least
  # trustworthy thing about a book whose identity was lost:
  #
  #   A  no sidecar + exact-path row      -> written (the only automatic write)
  #   B  empty ids + a findable row       -> REPORTED ONLY, never written
  #   C  empty ids + no row + "manual"    -> fleet.uid + local.sha256 assigned
  #   4  empty ids + no row + not manual  -> unidentifiable, nothing written
  #
  # Every example here runs the SSH branch through fake_server_ssh: the two
  # defects live validation found on 2026-08-24 (a remote `jq`, and ${(q)}'s
  # $'\n' reaching a real POSIX sh) were both invisible to the plain-local-dir
  # branch, and both of these verbs write to the only copy of a book's
  # identity.

  # fake_provider_rows <json-lines> — a provider whose `list` prints exactly
  # the given rows. RIP_LIBEXEC_DIR is redirected into the sandbox first:
  # setup() points it at the REAL tracked libexec, and a fake written there
  # would be a write into the repo.
  fake_provider_rows() {
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    {
      printf '#!/bin/sh\n[ "$1" = list ] || exit 0\ncat <<%s\n' "'ROWS'"
      printf '%s\n' "$1"
      printf 'ROWS\n'
    } > "$RIP_LIBEXEC_DIR/rip-provider-libation"
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
  }

  # A full provider row for the book that started this: 1.7 GB on cantina with
  # no sidecar at all, and a `path` composed exactly the way the server stores
  # it (verified live 2026-08-24).
  WIND='Brandon Sanderson/Wind and Truth: Book Five of the Stormlight Archive'
  ROW_WIND='{"id":"B0CQ3759C3","path":"Brandon Sanderson/Wind and Truth: Book Five of the Stormlight Archive","title":"Wind and Truth","subtitle":"Book Five of the Stormlight Archive","authors":["Brandon Sanderson"],"narrators":["Michael Kramer","Kate Reading"],"duration_s":220320,"series":"The Stormlight Archive","series_position":"5","language":"english","abridged":false,"published":"2024-12-06T08:00:00","ids":{"audible.asin":"B0CQ3759C3"},"provider":"libation","provider_version":"13.7.10","format":"m4b"}'

  # Case B, from real data: Libation files the pair under "Shawn Speakman -
  # editor" while the server has "Shawn Speakman", so the exact-path join
  # misses and normalized author matching fails too. What matches exactly is
  # the composed TITLE.
  UNF='Shawn Speakman/Unfettered III: New Tales by Masters of Fantasy'
  ROW_UNF='{"id":"B07PX3DC46","path":"Shawn Speakman - editor/Unfettered III: New Tales by Masters of Fantasy","title":"Unfettered III","subtitle":"New Tales by Masters of Fantasy","authors":["Shawn Speakman"],"narrators":["Nick Podehl","Kate Rudd"],"duration_s":93600,"series":"Unfettered","series_position":"3","language":"english","abridged":false,"published":"2019-05-07T07:00:00","ids":{"audible.asin":"B07PX3DC46"},"provider":"libation","provider_version":"13.7.10","format":"m4b"}'
  ROW_UNF_TWIN='{"id":"B0AMBIG999","path":"Someone Else/Unfettered III: New Tales by Masters of Fantasy","title":"Unfettered III","authors":["Someone Else"],"published":"2011-01-01T07:00:00","ids":{"audible.asin":"B0AMBIG999"},"provider":"libation","format":"m4b"}'

  # TWO SERVER BOOKS, ONE PROVIDER ROW — the inverse ambiguity. The
  # author-variant collision --canonicalize-authors exists for ("J. R. R.
  # Tolkien" vs "J.R.R. Tolkien") gives the library two folders for one work;
  # one joins the row by exact path and the other by the title fallback, and
  # both are handed the SAME ASIN.
  HOB_A='J.R.R. Tolkien/The Hobbit'
  HOB_B='J. R. R. Tolkien/The Hobbit'
  ROW_HOB='{"id":"B0DUP00001","path":"J.R.R. Tolkien/The Hobbit","title":"The Hobbit","authors":["J.R.R. Tolkien"],"published":"2012-01-01T00:00:00","ids":{"audible.asin":"B0DUP00001"},"provider":"libation","format":"m4b"}'

  RPO='Ernest Cline/Ready Player One'

  # mkbook_bare <Author/Title> — a stored book with audio and NO sidecar.
  mkbook_bare() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$1"
    printf 'audio-bytes-%s\n' "$1" > "$RIP_SANDBOX/server/audiobooks/$1/${1##*/}.m4b"
  }

  # mkbook_empty <Author/Title> <provider> — a stored book whose sidecar is in
  # schema shape but carries NO identity: `ids: {}`. That is the fingerprint
  # the canonicalization bug left behind (fixed 2f649ae6) and the shape all
  # three of Case B, Case C and the unidentifiable refusal start from.
  mkbook_empty() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$1"
    printf 'audio-bytes-%s\n' "$1" > "$RIP_SANDBOX/server/audiobooks/$1/${1##*/}.m4b"
    jq -n --arg t "${1##*/}" --arg a "${1%%/*}" --arg p "$2" \
      '{schema:1,kind:"audiobook",title:$t,subtitle:null,authors:[$a],narrators:[],
        series:null,duration_s:null,language:null,abridged:null,published:null,
        ids:{},work:null,
        source:{provider:$p,provider_version:null,acquired_utc:null,format:"m4b"}}' \
      > "$RIP_SANDBOX/server/audiobooks/$1/.fleet-book.json"
  }

  # mkbook_malformed <Author/Title> — a stored book whose sidecar EXISTS but
  # does not parse: truncated mid-object, the shape a hand edit or an
  # interrupted write leaves behind. It still carries a resolved `work` and an
  # id — recoverable by a human reading it, and unrecoverable once something
  # composes a fresh sidecar over the top. rip::_server_sidecars warns and
  # DROPS it, so to the classifier it is indistinguishable from a book with no
  # sidecar at all, which is Case A: the one branch that writes.
  mkbook_malformed() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$1"
    printf 'audio-bytes-%s\n' "$1" > "$RIP_SANDBOX/server/audiobooks/$1/${1##*/}.m4b"
    printf '%s\n' '{"schema":1,"kind":"audiobook","work":{"id":"OL99W"},"ids":{"audible.asin":"B0HAND0001"},' \
      > "$RIP_SANDBOX/server/audiobooks/$1/.fleet-book.json"
  }

  sidecar_at() { printf '%s' "$RIP_SANDBOX/server/audiobooks/$1/.fleet-book.json"; }

  # snapshot / sidecar_unchanged — the report-only guard. "Never written, not
  # even under --apply" is only proved by comparing the BYTES before and
  # after; an assertion that merely re-reads a field would pass against a
  # rewrite that happened to preserve it.
  snapshot() { SNAP_REL="$1"; cp "$(sidecar_at "$1")" "$RIP_SANDBOX/snapshot.json"; }
  sidecar_unchanged() {
    if cmp -s "$RIP_SANDBOX/snapshot.json" "$(sidecar_at "$SNAP_REL")"; then
      echo "byte-identical"
    else
      echo "CHANGED"
    fi
  }

  wind_identity() {
    jq -c '[.ids["audible.asin"],.published,.narrators[0],.duration_s,.series.name,
            .language,.abridged,.source.provider,.work,has("_path")]' "$(sidecar_at "$WIND")"
  }

  It 'repair: a book with NO sidecar and an exact-path provider row is created, through a server with no jq'
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 0
    The output should include "repaired: $WIND"
    The output should include "repaired 1 of 1 sidecar(s)"
    # The WHOLE row lands, not just the ASIN, and `_path` — the annotation
    # rip::_server_sidecars adds — never reaches the file.
    The result of function wind_identity should equal '["B0CQ3759C3","2024-12-06T08:00:00","Michael Kramer",220320,"The Stormlight Archive","english",false,"libation",null,false]'
    # FOUR ssh calls for one book: enumerate the library, enumerate the
    # sidecars, ONE `test -f` confirming the sidecar really is absent before
    # Case A composes over that path (review finding 2, 2026-08-24), ONE write
    # batch. 247 books must never be 247 round-trips.
    The result of function ssh_calls should equal "4"
    # …and nothing the server was asked to run mentions jq. cantina has none.
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "jq"
  End

  It 'repair: a dry run writes nothing and opens no write connection'
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars"
    The status should equal 0
    The output should include "would create sidecar: $WIND"
    The output should include "re-run with --apply"
    The path "$(sidecar_at "$WIND")" should not be exist
    # The two enumerations plus the Case A absence re-check — and NO write
    # batch: `mv --` appears only in rip::_sidecars_write's remote script, so
    # its absence from the command log is the proof, independent of the count.
    The result of function ssh_calls should equal "3"
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: a dry run states the plan but NEVER a write tally — nothing was attempted'
    # Review finding 1, 2026-08-24. The dry-run caller passes repaired=0
    # because a dry run deliberately opens no write connection, and the
    # summary printed that as "repaired 0 of 2 sidecar(s)" followed by
    # "2 sidecar(s) could not be written" — two failures reported for two
    # writes nobody attempted, on the first command an operator runs, exiting
    # 0 while saying it. The seventh line in this subsystem to state an
    # outcome nothing captured; there must not be an eighth. One Case A and
    # one Case C candidate, so `intended` is 2 and the old tally is
    # unmistakable if it comes back.
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    mkbook_empty "$RPO" manual
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars"
    The status should equal 0
    The output should include "would create sidecar: $WIND"
    The output should include "would assign local identity: $RPO"
    The output should include "(2 book(s); re-run with --apply)"
    The output should not include "repaired 0 of"
    The output should not include "could not be written"
    The path "$(sidecar_at "$WIND")" should not be exist
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: a book with no sidecar and NO provider row is named, skipped, and the run exits non-zero'
    # The provider answers (a non-empty library), it simply has no row for
    # this book. Refuse rather than guess: a wrong identity is worse than a
    # missing one.
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "Nobody At All/Orphan Book"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "unrepairable (no sidecar, no provider row): Nobody At All/Orphan Book"
    The output should include "1 book(s) have no sidecar and no provider row"
    The path "$(sidecar_at "Nobody At All/Orphan Book")" should not be exist
  End

  It 'repair: a MALFORMED sidecar is reported as unreadable, left BYTE-IDENTICAL, and the run exits non-zero'
    # Review finding 2, 2026-08-24. sc_state is built only from sidecars
    # rip::_server_sidecars could parse, so an unparseable one arrived at the
    # classifier as "absent" and fell into Case A — which composed a fresh
    # sidecar and moved it over the only copy, printing "repaired" on stdout
    # while stderr said "malformed sidecar … skipped" and the run exited 0.
    # A stray trailing comma is recoverable by a human right up until this
    # verb overwrites it. The design forbids it twice: never overwrite an
    # existing sidecar, and repairing a malformed one is out of scope.
    fake_provider_rows "$ROW_WIND"
    mkbook_malformed "$WIND"
    snapshot "$WIND"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    # THE load-bearing assertion: the bytes on disk, not a re-read field.
    The result of function sidecar_unchanged should equal "byte-identical"
    The output should include "unreadable sidecar (not repaired): $WIND"
    The output should include "does not parse"
    The output should include "1 book(s) have a sidecar that could not be read"
    # …and never the contradicting success line the defect printed alongside.
    The output should not include "repaired: $WIND"
    The output should not include "repaired 1 of"
    The stderr should include "malformed sidecar"
    # No write batch was ever opened.
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: an already-identified sidecar is left byte-identical and the run reports the count'
    fake_provider_rows "$ROW_WIND"
    mkbook "Brandon Sanderson" "Steelheart" B00ECDZ08I 2013-09-24T07:00:00 Steelheart
    snapshot "Brandon Sanderson/Steelheart"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 0
    The output should include "nothing to repair (1 book(s) checked, 1 already identified)"
    The result of function sidecar_unchanged should equal "byte-identical"
    # No write connection was opened at all.
    The result of function ssh_calls should equal "2"
  End

  # NFC vs NFD. The server is NFC (the push's rsync --iconv guarantees it) and
  # macOS composes NFD, so a provider row for an accented author must still
  # join the server's folder. Without rip::_nfc on BOTH sides this book reads
  # as "no provider row" and is silently skipped — the exact bug
  # rip::_remote_has_file was bitten by.
  NFC_AUTHOR=$(printf '\303\211mile Zola')
  NFD_AUTHOR=$(printf 'E\314\201mile Zola')
  nfd_row() {
    jq -nc --arg p "$NFD_AUTHOR/Germinal" \
      '{id:"B0NFD00001",path:$p,title:"Germinal",authors:["Emile Zola"],
        published:"2020-01-01T00:00:00",ids:{"audible.asin":"B0NFD00001"},
        provider:"libation",format:"m4b"}'
  }
  nfd_asin() { jq -r '.ids["audible.asin"] // "MISSING"' "$(sidecar_at "$NFC_AUTHOR/Germinal")"; }

  It 'repair: an NFD provider row still matches the NFC folder the server holds'
    fake_provider_rows "$(nfd_row)"
    mkbook_bare "$NFC_AUTHOR/Germinal"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 0
    The output should include "repaired 1 of 1 sidecar(s)"
    The result of function nfd_asin should equal "B0NFD00001"
  End

  It 'repair: --apply leaves a Case B book BYTE-IDENTICAL while still reporting it'
    # The load-bearing assertion of the whole verb. Case B is REPORT-ONLY, and
    # "report-only" quietly becoming "writes anyway" in a future refactor is
    # exactly what this catches: the title fallback is looser than an exact
    # path match, and the cost of being wrong is a book permanently stamped
    # with another book's ASIN.
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The result of function sidecar_unchanged should equal "byte-identical"
    The output should include "recoverable (needs confirmation): $UNF"
    The output should include "proposed ASIN : B07PX3DC46"
    The output should include "matched row   : Shawn Speakman - editor/Unfettered III: New Tales by Masters of Fantasy"
    The output should include "matched on    : title (author differs)"
    The output should include "confirm with  : rip-audiobook --adopt-asin \"$UNF\" B07PX3DC46"
    The output should include "1 book(s) need confirmation"
    # No write batch was ever opened: the two enumerations only.
    The result of function ssh_calls should equal "2"
  End

  It 'repair: two provider rows sharing one title are reported as ambiguous and nothing is written'
    fake_provider_rows "$(printf '%s\n%s' "$ROW_UNF" "$ROW_UNF_TWIN")"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "ambiguous (nothing written): $UNF"
    The output should include "B07PX3DC46"
    The output should include "B0AMBIG999"
    The output should include "pick one with : rip-audiobook --adopt-asin"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'repair: one ASIN proposed for TWO books is ambiguous on both, never a high-confidence proposal'
    # Review finding 3, 2026-08-24. Ambiguity was detected in one direction
    # only — one server book, two provider rows. The inverse (two server
    # books, one row) went unnoticed, and the author-variant collision this
    # module already knows about produces it: the exact-path join claims one
    # folder and the title fallback claims the other, both proposing
    # B0DUP00001, and one of them labelled "matched on: path (exact)", which
    # reads as high confidence. Adopting both would leave two folders carrying
    # one audible.asin — the duplicated edition identity the sidecar exists to
    # prevent. A proposal that is not unique is an ambiguity.
    fake_provider_rows "$ROW_HOB"
    mkbook_empty "$HOB_A" unknown
    mkbook_empty "$HOB_B" unknown
    snapshot "$HOB_A"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "ambiguous (nothing written): $HOB_A"
    The output should include "ambiguous (nothing written): $HOB_B"
    The output should include "also proposed for 1 other book(s)"
    The output should not include "recoverable (needs confirmation)"
    The output should not include "confirm with"
    The output should include "2 book(s) are ambiguous"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  rpo_uid_ok() {
    jq -r '.ids["fleet.uid"] // ""' "$(sidecar_at "$RPO")" \
      | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
      && echo "uuidv4" || echo "NOT A UUIDV4"
  }
  rpo_sha_ok() {
    want=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/$RPO/Ready Player One.m4b" | cut -d' ' -f1)
    got=$(jq -r '.ids["local.sha256"] // ""' "$(sidecar_at "$RPO")")
    if [ -n "$got" ] && [ "$want" = "$got" ]; then echo "hash matches the audio"; else echo "MISMATCH want=$want got=$got"; fi
  }
  rpo_untouched_fields() { jq -c '[.title,.source.provider,.published,.work]' "$(sidecar_at "$RPO")"; }

  It 'repair: a manual book with no provider row is assigned fleet.uid + a server-computed local.sha256'
    # Case C. Both keys deliberately: a minted uid alone repeats the exposure
    # that started this work (lose the sidecar, lose the id forever), and a
    # hash alone dies at the next re-encode. The uid is the join key; the hash
    # is the recovery anchor, and it is computed where the bytes are.
    fake_provider_rows "$ROW_WIND"
    mkbook_empty "$RPO" manual
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 0
    The output should include "repaired: $RPO"
    The output should include "repaired 1 of 1 sidecar(s)"
    The result of function rpo_uid_ok should equal "uuidv4"
    The result of function rpo_sha_ok should equal "hash matches the audio"
    # Additive: nothing else on the sidecar is rewritten.
    The result of function rpo_untouched_fields should equal '["Ready Player One","manual",null,null]'
    # library + sidecars + hash + write.
    The result of function ssh_calls should equal "4"
    # The hash is sha256sum's job, not jq's — the server has no jq.
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "jq"
  End

  It 'repair: re-running --apply on a repaired Case C book mints no second uid'
    fake_provider_rows "$ROW_WIND"
    mkbook_empty "$RPO" manual
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      rip::ab_repair_sidecars --apply >/dev/null 2>&1
      u1=\$(jq -r '.ids[\"fleet.uid\"] // \"\"' '$RIP_SANDBOX/server/audiobooks/$RPO/.fleet-book.json')
      rip::ab_repair_sidecars --apply
      u2=\$(jq -r '.ids[\"fleet.uid\"] // \"\"' '$RIP_SANDBOX/server/audiobooks/$RPO/.fleet-book.json')
      [ -n \"\$u1\" ] && [ \"\$u1\" = \"\$u2\" ] && print -r -- 'uid stable' || print -r -- 'UID CHANGED'"
    The status should equal 0
    The output should include "uid stable"
    The output should include "nothing to repair"
  End

  ghost_ids() { jq -c '.ids' "$(sidecar_at "Ghost Author/Returned Book")"; }

  It 'repair: an empty-identity book with no provider row and a non-manual provider is unidentifiable, never minted'
    # THE FOURTH OUTCOME. A Libation book that was returned or removed from
    # the account lands here. Minting a fleet.uid would permanently disconnect
    # it from an ASIN it may still be entitled to, so it is named and left
    # exactly as it is.
    fake_provider_rows "$ROW_WIND"
    mkbook_empty "Ghost Author/Returned Book" unknown
    snapshot "Ghost Author/Returned Book"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "unidentifiable (empty identity, no provider row, provider \"unknown\"): Ghost Author/Returned Book"
    The output should include "1 book(s) are unidentifiable"
    The result of function sidecar_unchanged should equal "byte-identical"
    The result of function ghost_ids should equal "{}"
  End

  It 'repair: a provider that answers with nothing refuses the whole sweep rather than guessing'
    # An empty provider list cannot be told apart from "Libation did not
    # answer", and that difference decides whether a book is stamped with a
    # locally minted uid it can never lose.
    fake_provider_rows ""
    mkbook_empty "$RPO" manual
    snapshot "$RPO"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 2
    The stderr should include "returned no rows"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  # The verbs through the REAL CLI, not just the functions. The executable
  # runs under `set -eu -o pipefail`, which the sourced-function examples
  # above do not: an unset array or associative-array read that is harmless in
  # a plain zsh -c aborts the whole command here.
  It 'cli: --repair-sidecars --apply reaches the function and repairs under set -eu'
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    fake_server_ssh
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --repair-sidecars --apply
    The status should equal 0
    The output should include "repaired 1 of 1 sidecar(s)"
    The result of function wind_identity should equal '["B0CQ3759C3","2024-12-06T08:00:00","Michael Kramer",220320,"The Stormlight Archive","english",false,"libation",null,false]'
  End

  # --- --adopt-asin: the confirmation verb ----------------------------------

  unf_identity() {
    jq -c '[.ids["audible.asin"],.published,.narrators,.duration_s,.series.name,
            .series.position,.language,.abridged,.source.provider,.title,.authors,.work,has("_path")]' \
      "$(sidecar_at "$UNF")"
  }

  It 'adopt: an ASIN the provider does not know is refused and nothing is written'
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$UNF' B0NOTREAL01 --apply"
    The status should equal 2
    The stderr should include "has no B0NOTREAL01"
    The stderr should include "resolves to nothing"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'adopt: a sidecar that already carries an ASIN is refused and nothing is written'
    fake_provider_rows "$ROW_WIND"
    mkbook "Brandon Sanderson" "Wind and Truth: Book Five of the Stormlight Archive" B0OLDASIN1 "" "Wind and Truth"
    snapshot "$WIND"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$WIND' B0CQ3759C3 --apply"
    The status should equal 2
    The stderr should include "already carries audible.asin B0OLDASIN1"
    The stderr should include "never overwrites"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'adopt: an ASIN ANOTHER stored sidecar already carries is refused (guard 5)'
    # Review finding 3(b), 2026-08-24. Guard 2 only ever inspected the TARGET
    # book's sidecar, so the same proposed ASIN could be adopted for two
    # different folders one command at a time — no guard, no warning. The
    # rows index is already in hand for guard 2, so seeing every row costs
    # nothing.
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    mkbook "Shawn Speakman" "Unfettered II" B07PX3DC46 2016-01-01T07:00:00 "Unfettered II"
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$UNF' B07PX3DC46 --apply"
    The status should equal 2
    The stderr should include "Shawn Speakman/Unfettered II already carries audible.asin B07PX3DC46"
    The stderr should include "one ASIN identifies one book"
    The output should not include "adopted"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'adopt: --apply populates the FULL row and corrects source.provider away from unknown'
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$UNF' B07PX3DC46 --apply"
    The status should equal 0
    The output should include "rip: adopted B07PX3DC46 for $UNF"
    # published, narrators, duration_s, series, language and abridged all
    # arrive — recovering the ASIN alone would leave the book half-identified.
    # The SERVER's author spelling survives (the row says "Shawn Speakman -
    # editor" only because that is how Libation files it), `work` stays null,
    # and `_path` never reaches the file.
    The result of function unf_identity should equal '["B07PX3DC46","2019-05-07T07:00:00",["Nick Podehl","Kate Rudd"],93600,"Unfettered","3","english",false,"libation","Unfettered III: New Tales by Masters of Fantasy",["Shawn Speakman"],null,false]'
  End

  It 'adopt: a dry run reports the plan and writes nothing'
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$UNF' B07PX3DC46"
    The status should equal 0
    The output should include "would adopt: $UNF"
    The output should include "ASIN         : B07PX3DC46"
    The output should include "re-run with --apply"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'adopt: a write the server never confirms reports failure and leaves the sidecar alone'
    # Outcome-gated, like every other success line in this module: "adopted"
    # is printed only when the remote loop said ok for THIS book's key.
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      chmod 555 '$RIP_SANDBOX/server/audiobooks/$UNF'
      rip::ab_adopt_asin '$UNF' B07PX3DC46 --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/$UNF'
      exit \$rc"
    The status should equal 1
    The stderr should include "could not write the sidecar"
    The output should not include "adopted"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  # --- review round 3, 2026-08-24 ------------------------------------------

  # THREE bare books, so the order `find` happens to return them in cannot
  # decide whether the bug shows: every one of them is a Case A candidate, so
  # whichever comes first probes the server and — pre-fix — ate the rest of
  # the here-string the classification loop reads from.
  ROW_FD1='{"id":"B0FD000001","path":"Ann Leckie/Ancillary Justice","title":"Ancillary Justice","authors":["Ann Leckie"],"published":"2013-10-01T00:00:00","ids":{"audible.asin":"B0FD000001"},"provider":"libation","format":"m4b"}'
  ROW_FD2='{"id":"B0FD000002","path":"Becky Chambers/A Closed and Common Orbit","title":"A Closed and Common Orbit","authors":["Becky Chambers"],"published":"2016-10-20T00:00:00","ids":{"audible.asin":"B0FD000002"},"provider":"libation","format":"m4b"}'
  ROW_FD3='{"id":"B0FD000003","path":"Cixin Liu/The Three-Body Problem","title":"The Three-Body Problem","authors":["Cixin Liu"],"published":"2014-11-11T00:00:00","ids":{"audible.asin":"B0FD000003"},"provider":"libation","format":"m4b"}'

  It 'repair: an ssh probe inside the classification loop does NOT eat the library — every book is classified'
    # THE BLOCKER (review finding 1, 2026-08-24). rip::_remote_has_file ran
    # `ssh … "test -f …"` with no -n and no stdin redirect, from inside the
    # loop fed by `done <<< "$lib"`. ssh(1) without -n reads local stdin
    # eagerly and forwards it; `test -f` never consumes it; the whole
    # remaining library (~10 KB live, one read) vanished into the first probe
    # and the loop ended after ONE book — rc 0, a report that looked complete,
    # and every other book never examined. Third appearance of this fd-0
    # family in this subsystem, so the fix is in the helper, not the call
    # site, and this example is the guard: its fake ssh READS STDIN the way
    # the real one does.
    fake_provider_rows "$ROW_FD1"$'\n'"$ROW_FD2"$'\n'"$ROW_FD3"
    mkbook_bare "Ann Leckie/Ancillary Justice"
    mkbook_bare "Becky Chambers/A Closed and Common Orbit"
    mkbook_bare "Cixin Liu/The Three-Body Problem"
    fake_server_ssh_reads_stdin
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars < /dev/null"
    The status should equal 0
    The output should include "would create sidecar: Ann Leckie/Ancillary Justice"
    The output should include "would create sidecar: Becky Chambers/A Closed and Common Orbit"
    The output should include "would create sidecar: Cixin Liu/The Three-Body Problem"
    # The count is the assertion that cannot be satisfied by a truncated
    # sweep: pre-fix this said "(1 book(s); …)".
    The output should include "(3 book(s); re-run with --apply)"
    # library + sidecars + one absence probe per candidate. Pre-fix: 3.
    The result of function ssh_calls should equal "5"
  End

  It 'repair: one provider row proposed for a Case A book AND a Case B book is ambiguous on both — nothing is written'
    # Review finding 2, 2026-08-24. The dedupe pre-pass counted proposals
    # across b_report ONLY, and a Case A candidate never enters b_report. One
    # row, two folders: "J.R.R. Tolkien/The Hobbit" is bare (Case A, exact
    # path, the AUTOMATIC write) and "J. R. R. Tolkien/The Hobbit" carries an
    # empty-ids sidecar (Case B, title fallback). The dry run presented one as
    # a high-confidence adopt and the other as a write, both B0DUP00001, and
    # an operator following the printed instructions in the printed order got
    # two folders with one edition identity, rc 0, no warning. Guard 5 only
    # catches the reverse order.
    fake_provider_rows "$ROW_HOB"
    mkbook_bare "$HOB_A"
    mkbook_empty "$HOB_B" unknown
    snapshot "$HOB_B"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "ambiguous (nothing written): $HOB_A"
    The output should include "ambiguous (nothing written): $HOB_B"
    The output should include "also proposed for 1 other book(s)"
    The output should include "2 book(s) are ambiguous"
    # The Case A half never becomes a plan, a write, or a "repaired" line…
    The output should not include "would create sidecar"
    The output should not include "repaired"
    # …and the Case B half is never dressed up as high confidence.
    The output should not include "recoverable (needs confirmation)"
    The output should not include "confirm with"
    The path "$(sidecar_at "$HOB_A")" should not be exist
    The result of function sidecar_unchanged should equal "byte-identical"
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: a Case A row whose ASIN another STORED sidecar already carries is refused, not written'
    # The same collision one run later: the second folder is no longer a
    # proposal, it is a stored fact. An ASIN identifies one book, so the bare
    # folder gets nothing — the automatic write is the one nobody is asked
    # about.
    fake_provider_rows "$ROW_HOB"
    mkbook_bare "$HOB_A"
    mkbook "J. R. R. Tolkien" "The Hobbit" B0DUP00001 2012-01-01T00:00:00 "The Hobbit"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "ambiguous (nothing written): $HOB_A"
    The output should include "already carried by $HOB_B"
    The output should not include "would create sidecar"
    The output should not include "repaired"
    The path "$(sidecar_at "$HOB_A")" should not be exist
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: a probe that never ran is reported as an unconfirmed absence, never as a sidecar that exists'
    # Review finding 3, 2026-08-24. The rc-2 branch is right to refuse — an
    # absence that was not established is never written over — but the closing
    # line said "N book(s) have a sidecar that could not be read", asserting
    # the existence of a file nothing established. Eighth instance of this
    # subsystem's recurring defect: a line stating an outcome nothing
    # captured. The two causes now have two counts and two sentences.
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    fake_server_ssh_probe_fails
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "unreadable sidecar (not repaired): $WIND"
    The output should include "could not confirm whether a sidecar is there"
    The output should include "1 book(s) were left alone: whether a sidecar is there could not be confirmed"
    # The sentence the refusal could not support.
    The output should not include "have a sidecar that could not be read"
    The output should not include "does not parse"
    The path "$(sidecar_at "$WIND")" should not be exist
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  # Two id-less rows: rip-provider-libation composes `id: (.AudibleProductId
  # // "")`, empty for a book the account no longer lists, and
  # rip::_provider_index turns that into its never-empty filler "-".
  ROW_NIL1='{"path":"Nil One/Alpha","title":"Alpha","authors":["Nil One"],"published":"2001-01-01T00:00:00","provider":"libation","format":"m4b"}'
  ROW_NIL2='{"path":"Nil Two/Beta","title":"Beta","authors":["Nil Two"],"published":"2002-02-02T00:00:00","provider":"libation","format":"m4b"}'

  It 'repair: two books with their OWN id-less provider rows do not cross-match on the "-" filler'
    # Review finding 4, 2026-08-24. "-" is a placeholder, not an identifier,
    # and counting it collapsed every id-less row onto one key: two unrelated
    # books were reported as sharing an ASIN, with an unusable
    # `--adopt-asin "<the one book that is ->" -` remedy line to match.
    fake_provider_rows "$ROW_NIL1"$'\n'"$ROW_NIL2"
    mkbook_empty "Nil One/Alpha" unknown
    mkbook_empty "Nil Two/Beta" unknown
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "recoverable (needs confirmation): Nil One/Alpha"
    The output should include "recoverable (needs confirmation): Nil Two/Beta"
    The output should include "2 book(s) need confirmation"
    The output should not include "ambiguous"
    The output should not include "also proposed for"
    The output should not include "the one book that is -"
  End

  It 'cli: --adopt-asin refuses an ASIN the provider does not know'
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --adopt-asin "$UNF" B0NOTREAL01 --apply
    The status should equal 2
    The stderr should include "resolves to nothing"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  # --- companion repair: --repair-companions (Task 6) -----------------------
  #
  # The retroactive half of the companions feature. Measured on the live
  # library 2026-08-24: 13 stored books carry a PDF and 246 carry a cover
  # image, and the library describes NONE of them — they survive only because
  # rsync moves whole directories. Task 5 records companions for every book
  # written from now on; this sweep describes the ones already stored.
  #
  # Every example that writes runs the SSH branch through fake_server_ssh: the
  # server has no jq, the JSON is assembled locally, and the remote side lists
  # names, sizes and hashes with POSIX tools plus sha256sum.

  rc_sha()   { shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1; }
  rc_kinds() { jq -c '[.companions[].kind] | sort' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }
  rc_view()  { jq -c '[(.companions|map(.kind)|sort),.ids["audible.asin"],.work.openlibrary]' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }
  rc_type()  { jq -r '.companions | type' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }
  rc_has_path() { jq -r 'has("_path")' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }
  rc_without_companions() { jq -Sc 'del(.companions)' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }

  # rc_mkbook — the stored book A/B: one audio file and one unrecorded PDF.
  rc_mkbook() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf 'pdf\n'   > "$RIP_SANDBOX/server/audiobooks/A/B/B.pdf"
  }
  rc_plain_sidecar() {
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
  }

  It 'repair-companions: dry run reports a book whose PDF is unrecorded and writes nothing'
    rc_mkbook
    rc_plain_sidecar
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions"
    The status should equal 0
    The output should include "A/B"
    The output should include "re-run with --apply"
    The result of function rc_sha should equal "$before"
  End

  It 'repair-companions: --apply records the companion and touches nothing else'
    rc_mkbook
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{"audible.asin":"X1"},"work":{"openlibrary":"OL9W"}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The output should include "recorded companions for 1 of 1"
    The result of function rc_view should equal '[["pdf"],"X1","OL9W"]'
  End

  # The recorded row is the REAL size and the REAL hash of the stored file,
  # computed on the server (which holds the only copy) — not a placeholder.
  It 'repair-companions: the recorded row carries the real size and hash'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply && jq -c '.companions[0] | [.file,.kind,.bytes,.sha256]' $RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    The status should equal 0
    The output should include "[\"B.pdf\",\"pdf\",4,\"$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/B.pdf" | cut -d' ' -f1)\"]"
  End

  It 'repair-companions: a book whose companions are already correct is left byte-identical'
    rc_mkbook
    jq -n --arg s "$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/B.pdf" | cut -d' ' -f1)" \
      '{schema:1,kind:"audiobook",title:"B",authors:["A"],ids:{},companions:[{file:"B.pdf",kind:"pdf",bytes:4,sha256:$s}]}' \
      > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The output should include "nothing to record"
    The result of function rc_sha should equal "$before"
  End

  # THE LESSON THIS SUBSYSTEM ALREADY PAID FOR: rip::_server_sidecars silently
  # DROPS a sidecar it cannot parse, so "unparseable" is indistinguishable from
  # "absent" unless the sweep checks the directory itself. Overwriting one
  # destroys identity a human could otherwise have recovered by hand.
  It 'repair-companions: a malformed sidecar is reported, never overwritten'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf 'pdf\n'   > "$RIP_SANDBOX/server/audiobooks/A/B/B.pdf"
    printf '%s' '{"schema":1, "title": "B", BROKEN' > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should not equal 0
    The output should include "A/B"
    The output should not include "recorded companions for 1"
    The stderr should include "malformed sidecar"
    The result of function rc_sha should equal "$before"
  End

  # A DRY RUN OPENS NO WRITE CONNECTION. Two ssh calls — enumerate the
  # sidecars, list the files — and the write script (its `mv --` is the only
  # thing that replaces a sidecar) is never handed to the server at all.
  It 'repair-companions: a dry run opens no write connection'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions"
    The status should equal 0
    The output should include "re-run with --apply"
    The result of function ssh_calls should equal "2"
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv --"
  End

  It 'repair-companions: --apply writes through a server with NO jq, in ONE ssh for the whole batch'
    rc_mkbook
    rc_plain_sidecar
    mkdir -p "$RIP_SANDBOX/server/audiobooks/C/D"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/C/D/D.m4b"
    printf 'jpg\n'   > "$RIP_SANDBOX/server/audiobooks/C/D/cover.jpg"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"D","authors":["C"],"ids":{}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/C/D/.fleet-book.json"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The output should include "recorded companions for 2 of 2"
    # THREE ssh calls for two books: enumerate, list, and ONE write batch.
    # 247 books must not be 247 round-trips.
    The result of function ssh_calls should equal "3"
    # …and nothing the server was asked to run mentions jq. fake_server_ssh's
    # handpicked PATH holds none; this names the regression.
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "jq"
    The result of function rc_kinds should equal '["pdf"]'
  End

  # rip::_server_sidecars ANNOTATES every row with a `_path` key that is NOT
  # in the stored file; writing the annotated object back would permanently
  # add a bogus field to the only copy of a book's identity. Everything else
  # — a resolved `work`, existing `ids`, a null, a false, a title full of
  # characters that would wreck an unquoted remote command line — must
  # survive byte for byte.
  RC_RICH='{"schema":1,"kind":"audiobook","title":"Elantris: 10th $Ann - Omega","authors":["Sanderson, B. \"Bran\""],"ids":{"audible.asin":"X1","isbn":null},"abridged":false,"work":{"openlibrary":"OL9W"},"source":{"provider":"libation","acquired_utc":"2026-08-22"}}'

  It 'repair-companions: the written sidecar gains ONLY companions — no _path, nothing else altered'
    rc_mkbook
    printf '%s' "$RC_RICH" > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    expected=$(printf '%s' "$RC_RICH" | jq -Sc .)
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The output should include "recorded companions for 1 of 1"
    The result of function rc_has_path should equal "false"
    The result of function rc_without_companions should equal "$expected"
  End

  # ONE answer for what counts as audio. The module already answers it in
  # rip::_dir_has_audio, rip::_sidecars_hash_primary's server-side scan and
  # rip::_companions_json with the same 11 extensions; the remote listing this
  # sweep ships must not be a fourth, narrower one. A retained Libation `.aax`
  # and an uppercase `.MP3` chapter are both audio — recording either would
  # also mean the server sha256s multi-gigabyte files it has no reason to read.
  It 'repair-companions: audio is never recorded as a companion, whatever its case'
    rc_mkbook
    printf 'source-audio\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.aax"
    printf 'chapter\n' > "$RIP_SANDBOX/server/audiobooks/A/B/01 - Chapter One.MP3"
    rc_plain_sidecar
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The result of function rc_kinds should equal '["pdf"]'
  End

  # A book with NO companion files at all still gains the field: `[]` means
  # "scanned, nothing there", an absent key means "never looked". jq's
  # `length` returns 0 for `null` as well as `[]`, so `type` is what actually
  # discriminates the two.
  It 'repair-companions: a book with no companion files gains an empty array, not a missing key'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    rc_plain_sidecar
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The result of function rc_type should equal "array"
    The result of function rc_kinds should equal "[]"
  End

  # A server that was never reached must not read as a library with nothing to
  # record — the same refusal --backfill-published and --editions already make.
  It 'repair-companions: an unreachable server records nothing and never says "nothing to record"'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh
    printf '#!/bin/sh\nexit 255\n' > "$RIP_SANDBOX/ssh"
    chmod +x "$RIP_SANDBOX/ssh"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 2
    The output should not include "nothing to record"
    The output should not include "recorded companions"
    The stderr should include "refusing"
    The result of function rc_sha should equal "$before"
  End

  # A write that cannot land leaves the good sidecar exactly as it was, leaves
  # no temp file behind, and is COUNTED AS A FAILURE — never inferred from the
  # call having been made.
  rc_stray_tmp() { find "$RIP_SANDBOX/server" -name '*.tmp.*' | wc -l | tr -d ' '; }

  It 'repair-companions: a write that fails leaves the good sidecar untouched and reports it'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB
      chmod 555 '$RIP_SANDBOX/server/audiobooks/A/B'
      rip::ab_repair_companions --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/A/B'
      exit \$rc"
    The status should equal 1
    The output should include "recorded companions for 0 of 1"
    The output should include "1 sidecar(s) could not be written"
    The result of function rc_sha should equal "$before"
    The result of function rc_stray_tmp should equal "0"
  End

  # REVIEW FINDING 1 (2026-08-25). The malformed guard used to test NON-EMPTY,
  # not SHAPE — and a sidecar whose entire content is the JSON literal `null`
  # survives the read path: jq accepts a null left operand for `+`, so
  # rip::_server_sidecars turns it into `{"_path":"A/B"}` and
  # rip::_sidecar_index strips that back to `{}`, which is non-empty. The book
  # was laundered out of the malformed report and rewritten as
  # `{"companions":[...]}` — an identity-less file that now looks SWEPT. The
  # other malformed shapes (empty, truncated, bare array, string, number) were
  # already reported correctly; only `null` slipped through.
  It 'repair-companions: a sidecar that is the JSON literal null is reported, never rewritten'
    rc_mkbook
    printf 'null' > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should not equal 0
    The output should include "A/B"
    The output should not include "recorded companions for 1"
    The result of function rc_sha should equal "$before"
  End

  # A stored empty object carries no identity either, and is indistinguishable
  # from the `null` above by the time rip::_sidecar_index has run — so the same
  # refusal covers both. Writing companions into it would manufacture a book
  # that looks scanned and identifies nothing.
  It 'repair-companions: a sidecar that is an empty object is reported, never rewritten'
    rc_mkbook
    printf '{}' > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should not equal 0
    The output should include "A/B"
    The result of function rc_sha should equal "$before"
  End

  # REVIEW FINDING 2 (2026-08-25), the eleventh defect of this class in this
  # subsystem. The remote enumeration is `find … | while read`, and a POSIX
  # pipeline reports the LAST command status — so find exiting non-zero
  # because it could not descend into a directory was DISCARDED, and the sweep
  # printed "recorded companions for 2 of 2" with rc 0 for a library where a
  # third book was never seen. rip::_server_sidecars under-enumerates
  # identically, so the denominator agrees with the short listing and nothing
  # internal catches the discrepancy: a tally claiming a completeness it never
  # established, on the very count the operator is told to read before writing
  # 247 files.
  rc_a2_companions() { jq -r '.companions // "ABSENT"' "$RIP_SANDBOX/server/audiobooks/A2/B2/.fleet-book.json"; }

  It 'repair-companions: a directory find could not read never reads as a complete sweep'
    rc_mkbook
    rc_plain_sidecar
    mkdir -p "$RIP_SANDBOX/server/audiobooks/C/D" "$RIP_SANDBOX/server/audiobooks/A2/B2"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/C/D/D.m4b"
    printf 'jpg\n'   > "$RIP_SANDBOX/server/audiobooks/C/D/cover.jpg"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"D","authors":["C"],"ids":{}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/C/D/.fleet-book.json"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A2/B2/B2.m4b"
    printf 'pdf\n'   > "$RIP_SANDBOX/server/audiobooks/A2/B2/B2.pdf"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B2","authors":["A2"],"ids":{}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A2/B2/.fleet-book.json"
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      chmod 000 '$RIP_SANDBOX/server/audiobooks/A2'
      rip::ab_repair_companions --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/A2'
      exit \$rc"
    The status should equal 1
    The output should include "incomplete"
    # The two books it COULD see are still recorded — the refusal is about the
    # tally claiming to be the whole library, not about refusing to work.
    The result of function rc_kinds should equal '["pdf"]'
    # …and the book behind the unreadable directory is demonstrably untouched.
    The result of function rc_a2_companions should equal "ABSENT"
  End

  # REVIEW TEST GAP (2026-08-25). `ssh` reads and forwards local stdin unless
  # given -n, so one inside a loop fed by a pipe swallows the rest of the list
  # and the loop silently ends after ONE item. Three occurrences in this
  # module so far, and a guard nobody tests is a guard that gets removed.
  # fake_server_ssh_reads_stdin is the only fake that models the slurp, and it
  # HONOURS -n exactly as ssh does — which is what makes this observable.
  It 'repair-companions: the listing ssh never eats the caller stdin'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh_reads_stdin
    cat > "$RIP_SANDBOX/probe.zsh" <<EOF
source $RIPLIB
base="\$(rip::remote_base)"
n=0
while IFS= read -r l; do
  n=\$(( n + 1 ))
  rip::_server_companion_files "\$base" >/dev/null 2>&1
done < <(printf 'a\nb\nc\n')
print -r -- "loops=\$n"
EOF
    When run zsh "$RIP_SANDBOX/probe.zsh"
    The status should equal 0
    The output should include "loops=3"
  End

  It 'cli: --repair-companions is dispatched, and the usage names it'
    rc_mkbook
    rc_plain_sidecar
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --repair-companions
    The status should equal 0
    The output should include "re-run with --apply"
  End

  It 'cli: the usage line names --repair-companions'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --help
    The status should equal 2
    The stderr should include "--repair-companions"
  End

  # --- --browse <root>: the folder provider as an alternative library ------
  #
  # `--browse` is `--library` pointed at a local tree instead of Libation's
  # catalogue: the SAME JSON-lines shape out, so the panel, the session
  # worker and the push all keep working without knowing which side it came
  # from. These assert the pass-through, not the provider (that is
  # tests/rip-folder-provider_spec.sh's whole file).
  browse_a_tree() {
    mkdir -p "$RIP_SANDBOX/incoming/Martha Wells/Network Effect"
    printf 'audio\n' > "$RIP_SANDBOX/incoming/Martha Wells/Network Effect/Network Effect.m4b"
    zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" \
      --browse "$RIP_SANDBOX/incoming"
  }

  It 'cli: --browse emits the folder provider rows for a root'
    When call browse_a_tree
    The status should equal 0
    The output should include '"provider":"folder"'
    The output should include '"path":"Martha Wells/Network Effect"'
    The output should include '"derived_from":"path"'
  End

  It 'cli: --browse without a root refuses rather than scanning something'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --browse
    The status should not equal 0
    The stderr should include "root required"
  End

  It 'cli: the usage line names --browse'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --help
    The status should equal 2
    The stderr should include "--browse"
  End

  # --- the library panel's Audible Plus marks (rip-library.html) ------------
  #
  # The panel's row rendering is JavaScript, so a mark that stops rendering is
  # invisible to every shell-level example above — and one of them did stop:
  # the "borrowed; rip before it lapses" line was gated on SERVER_KNOWN, so a
  # failed `--server-library` fetch (server down, VPN off) made the warning
  # vanish for the panel's whole lifetime. That is the warning whose absence
  # cost four Talon Saga books, and it must be at its loudest exactly when
  # the server cannot be reached.
  #
  # node runs the panel's OWN IIFE unmodified against a small DOM stub (at
  # boot it touches nothing but document.getElementById / addEventListener),
  # so these examples assert the real function rather than a transcription.
  PANEL_HTML="$SHELLSPEC_PROJECT_ROOT/home/dot_config/hammerspoon/Assets/html/rip-library.html"
  no_node() { ! command -v node >/dev/null 2>&1; }

  # panel_rows <rows-json> [server-paths-json] — the rendered #rows innerHTML.
  # OMIT the second argument to leave the server listing UNKNOWN, which is
  # exactly what a failed or absent --server-library fetch leaves behind
  # (library-dialog.lua returns without calling setServerLibrary).
  panel_rows() {
    cat > "$RIP_SANDBOX/panel.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
// The second <script> block is the panel itself; the first is the onerror
// shim. %%LIBRARY_JSON%% is library-dialog.lua's payload placeholder.
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub() {
  return { innerHTML: '', textContent: '', value: '',
           classList: { add() {}, remove() {}, toggle() {} },
           addEventListener() {}, setAttribute() {},
           getAttribute() { return null; }, setSelectionRange() {} };
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub()); },
  addEventListener() {}
};
global.window = global;
(0, eval)(src);
window.__setRows(JSON.parse(process.argv[2]));
if (process.argv[3] !== undefined) window.__setServerLibrary(JSON.parse(process.argv[3]));
process.stdout.write(els.rows.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel.js" "$@"
  }

  # panel_rows_shown <rows-json> <server-paths-json> — same, with the "show
  # library" chip ON, which is the only state in which a stored row is
  # rendered at all (with it off, visible() filters it out entirely).
  panel_rows_shown() {
    cat > "$RIP_SANDBOX/panel2.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub() {
  return { innerHTML: '', textContent: '', value: '',
           classList: { add() {}, remove() {}, toggle() {} },
           addEventListener() {}, setAttribute() {},
           getAttribute() { return null; }, setSelectionRange() {} };
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub()); },
  addEventListener() {}
};
global.window = global;
(0, eval)(src);
// The source MUST be switched first: __setRows discards a delivery whose
// sourceKind does not match the current SOURCE.kind (the guard that stops a
// folder scan landing in an Audible panel), so tagging it 'folder' while the
// panel is still in library mode silently renders nothing.
window.__setSource({ kind: 'folder', root: '/incoming' });
window.__setRows(JSON.parse(process.argv[2]), 'folder');
window.__setServerLibrary(JSON.parse(process.argv[3]));
window.__setShowLibrary(true);
process.stdout.write(els.rows.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel2.js" "$@"
  }

  # Mode B, 2026-08-25: re-ripping a book the server already held was refused,
  # but only in the job log — the panel let it be armed and the session exited
  # 0, so it read as success. The refusal is keyed on the composed path, which
  # the panel already knows, so it can be prevented instead of reported.
  It 'panel: a book already on cantina is blocked, with the reason and the way out'
    Skip if 'node is unavailable' no_node
    When call panel_rows_shown '[{"id":"1","path":"A/B","title":"B","authors":["A"],"narrators":[],"acquired":true}]' '["A/B"]'
    The status should equal 0
    The output should include 'data-blocked="true"'
    The output should include "already on cantina"
    # the way out is the edition route, and it must be stated in the row
    The output should include "edit the title"
  End

  It 'panel: a book the server does NOT hold is left rippable'
    Skip if 'node is unavailable' no_node
    When call panel_rows_shown '[{"id":"1","path":"A/B","title":"B","authors":["A"],"narrators":[],"acquired":true}]' '["Someone/Else"]'
    The status should equal 0
    The output should include 'data-blocked="false"'
    The output should not include "already on cantina"
  End

  BORROWED='[{"id":"1","path":"Martha Wells/Fugitive Telemetry","title":"Fugitive Telemetry","authors":["Martha Wells"],"narrators":[],"plus":true,"absent":false,"acquired":false}]'

  It 'panel: the borrowed mark renders even when the server listing is unknown'
    Skip if 'node is unavailable' no_node
    When call panel_rows "$BORROWED"
    The status should equal 0
    The output should include "rip before it lapses"
  End

  It 'panel: the borrowed mark still renders once the server listing lands without this book'
    Skip if 'node is unavailable' no_node
    When call panel_rows "$BORROWED" '["Brandon Sanderson/Wind and Truth"]'
    The status should equal 0
    The output should include "rip before it lapses"
  End

  # The lapsed mark comes off the row alone and never needed the server.
  It 'panel: a lapsed Plus title is marked with the server listing unknown'
    Skip if 'node is unavailable' no_node
    When call panel_rows '[{"id":"1","path":"A/B","title":"B","authors":[],"narrators":[],"plus":true,"absent":true}]'
    The status should equal 0
    The output should include "licence lapsed"
    The output should not include "rip before it lapses"
  End

  # WHAT MUST NOT REGRESS: neverPushedHtml asserts a divergence BETWEEN TWO
  # SYSTEMS ("Libation has it, cantina does not"), so its tri-state gate is
  # correct and stays — silent until the server actually answers.
  It 'panel: "liberated, never pushed" stays silent until the server listing lands'
    Skip if 'node is unavailable' no_node
    When call panel_rows '[{"id":"1","path":"A/B","title":"B","authors":[],"narrators":[],"acquired":true}]'
    The status should equal 0
    The output should not include "never pushed"
  End

  It 'panel: "liberated, never pushed" appears once the server listing lands without the book'
    Skip if 'node is unavailable' no_node
    When call panel_rows '[{"id":"1","path":"A/B","title":"B","authors":[],"narrators":[],"acquired":true}]' '[]'
    The status should equal 0
    The output should include "never pushed"
  End

  # --- Files mode: the browsed source, and inline identity editing ---------
  #
  # The whole point of the folder source is that the operator FIXES a bad
  # guess in the panel instead of retyping three fields per book, and the
  # thing that must actually change is the row's `path` — that is what
  # rip::ab_worker passes to `rip-provider-folder acquire` as its third
  # argument and what the book stages (and pushes) under. So these examples
  # drive the panel's own handlers and assert on the PLAN IT POSTS, not on
  # the rendered markup: a row whose display looks right but whose posted
  # `path` still carries the guess would ship the book to the wrong shelf.
  #
  # This also pins the trap normalizeRow has already sprung once (it dropped
  # keys, and the sidecar recorded a false identity permanently): a NEW
  # provider key, `derived_from`, has to survive the round trip — including
  # when its value is falsy, which a truthiness-based copy would silently
  # drop while a non-empty value sailed through.
  #
  # panel_files <rows-json> [edits-json] [server-paths-json] [root]
  #   edits-json: [[<row id>, "author"|"title", "<new value>"], ...], each
  #   replayed through the panel's real delegated `input` handler.
  #   A 5th arg sets the browsed root; a 6th sets the source kind
  #   ("folder", the default, or "library").
  # Prints the posted plan as JSON, then #rows, #source and #summary raw.
  panel_files() {
    cat > "$RIP_SANDBOX/panel-files.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  const listeners = {};
  const el = {
    id: id, innerHTML: '', textContent: '', value: '', hidden: false,
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    setAttribute() {}, getAttribute() { return null; }, setSelectionRange() {},
    fire(type, ev) { (listeners[type] || []).forEach((f) => f.call(el, ev)); }
  };
  return el;
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {},
  querySelector() { return null; }
};
const POSTED = [];
global.window = global;
global.webkit = { messageHandlers: { ripLibrary: { postMessage(m) { POSTED.push(m); } } } };
(0, eval)(src);

// Fake event targets: closestAttr() only ever calls getAttribute/parentNode,
// so these stand in for the real nodes without needing a DOM.
const ev = () => ({ preventDefault() {} });
function toggleTarget(id) {
  return { getAttribute: (a) => (a === 'data-toggle' ? id : null), parentNode: null };
}
function editTarget(id, field, value) {
  return {
    value: value, selectionStart: value.length, setSelectionRange() {},
    classList: { add() {}, remove() {}, toggle() {} },
    getAttribute: (a) => (a === 'data-edit-row' ? id : a === 'data-field' ? field : null),
    parentNode: null
  };
}

const rows = JSON.parse(process.argv[2]);
const edits = JSON.parse(process.argv[3] || '[]');
window.__setSource({ kind: process.argv[6] || 'folder', root: process.argv[5] || '/Volumes/Media/Incoming' });
window.__setRows(rows);
if (process.argv[4] !== undefined && process.argv[4] !== '') {
  window.__setServerLibrary(JSON.parse(process.argv[4]));
}
for (const [id, field, value] of edits) {
  els.rows.fire('input', Object.assign(ev(), { target: editTarget(String(id), field, value) }));
}
for (const r of rows) {
  els.rows.fire('mousedown', Object.assign(ev(), { target: toggleTarget(String(r.id)) }));
}
els.btnStart.fire('mousedown', ev());
// The posted plan as JSON, then the rendered markup RAW. One combined
// JSON.stringify would escape every quote inside the innerHTML strings, so
// a `data-blocked="true"` assertion could never match what the panel
// actually emitted.
process.stdout.write(JSON.stringify(POSTED) + '\n'
  + els.rows.innerHTML + '\n' + els.source.innerHTML + '\n' + els.summary.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-files.js" "$@"
  }

  FOLDER_ROW='[{"id":"/inc/Anncillary/Ancilary Justice","path":"Anncillary/Ancilary Justice","title":"Ancilary Justice","subtitle":null,"authors":["Anncillary"],"narrators":[],"derived_from":"path","provider":"folder","provider_version":"1","format":"m4b","acquired":true,"duration_s":0}]'

  It 'panel: a browsed row carries derived_from through to the posted plan'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW"
    The status should equal 0
    The output should include '"derived_from":"path"'
    The output should include '"provider":"folder"'
  End

  # The falsy case specifically: a copy written as `if (r.derived_from)` keeps
  # "path" above and silently drops "" here.
  It 'panel: an EMPTY derived_from still survives into the posted plan'
    Skip if 'node is unavailable' no_node
    When call panel_files '[{"id":"1","path":"A/B","title":"B","authors":["A"],"narrators":[],"derived_from":""}]'
    The status should equal 0
    The output should include '"derived_from":""'
  End

  It 'panel: editing the author rewrites the row path the worker stages under'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","author","Ann Leckie"]]'
    The status should equal 0
    The output should include '"path":"Ann Leckie/Ancilary Justice"'
  End

  It 'panel: editing the title rewrites the row path the worker stages under'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","title","Ancillary Justice"]]'
    The status should equal 0
    The output should include '"path":"Anncillary/Ancillary Justice"'
  End

  # An emptied author must not leave a leading "/" in the path (that would be
  # an absolute path on the server side) — AND the row must not ship at all.
  # rip::_validate_ab_plan refuses a single-segment path for the WHOLE plan,
  # so a blank author here would abort a 40-book session after the panel has
  # already closed. Blocking the one row is the difference.
  It 'panel: clearing the author blocks that row instead of shipping a bare title'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","author",""]]'
    The status should equal 0
    The output should not include '"path":"/Ancilary Justice"'
    The output should not include '"action":"start"'
    The output should include 'data-blocked="true"'
  End

  # A derived identity is a GUESS, and the panel has to say which kind: the
  # operator scans for the weak ones rather than re-reading every row.
  It 'panel: each files-mode row shows where its identity was guessed from'
    Skip if 'node is unavailable' no_node
    When call panel_files '[{"id":"1","path":"B","title":"B","authors":[],"narrators":[],"derived_from":"filename"}]'
    The status should equal 0
    The output should include "from the filename"
  End

  # A mis-picked folder surfacing hundreds of rows must be obvious BEFORE the
  # operator starts selecting, so the root itself is on screen, not just a
  # "Files" label.
  It 'panel: the source chip names the browsed root and the candidate count'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[]' '' '/Volumes/Media/Wrong Folder'
    The status should equal 0
    The output should include "/Volumes/Media/Wrong Folder"
    The output should include "1 candidate"
  End

  # "liberated, never pushed" is Libation vocabulary about a divergence
  # between Audible and cantina. Every folder row carries acquired:true (the
  # bytes are on this disk), so without a mode gate the line would fire on
  # EVERY browsed row the server does not hold — noise on exactly the rows
  # the operator is about to select.
  # A browse that never lands must cost the operator NOTHING. The switch to
  # the folder source clears the rows (they belong to the library being
  # left), so a failure that merely ended the loading state would leave
  # "nothing to show" where a perfectly good library used to be — and the
  # panel offers no way to re-fetch it short of dismissing and reopening.
  # library.browseFailed() puts the whole switch back.
  panel_browse_failed() {
    cat > "$RIP_SANDBOX/panel-failed.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  return { id: id, innerHTML: '', textContent: '', value: '',
           classList: { add() {}, remove() {}, toggle() {} },
           addEventListener() {}, setAttribute() {},
           getAttribute() { return null; }, setSelectionRange() {} };
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {}, querySelector() { return null; }
};
global.window = global;
(0, eval)(src);
window.__setRows(JSON.parse(process.argv[2]));
window.__setSource({ kind: 'folder', root: '/nope' });
window.__sourceFailed();
process.stdout.write(els.rows.innerHTML + '' + els.source.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-failed.js" "$@"
  }

  It 'panel: a failed browse restores the library that was already on screen'
    Skip if 'node is unavailable' no_node
    When call panel_browse_failed '[{"id":"1","path":"Martha Wells/Network Effect","title":"Network Effect","authors":["Martha Wells"],"narrators":[]}]'
    The status should equal 0
    The output should include "Network Effect"
    # .source-name only renders for the Audible source; files mode renders
    # .source-root instead — so this pins the SOURCE going back too, not
    # just the rows. (The literal words "Audible library" would not: the
    # way-back control in files mode carries them as its own label.)
    The output should include 'class="source-name"'
    The output should not include "/nope"
    The output should not include "nothing to show"
  End

  # --- library-dialog.lua under a stubbed hs (review round 3) --------------
  #
  # WHY THIS EXISTS. 344 green examples could not see a one-line Lua type
  # error, because nothing in this suite executed library-dialog.lua at all —
  # the node examples above run the PANEL's JavaScript, and the shell
  # examples run the CLI, but the module that bridges them was untested by
  # construction. The bug that got through: M.setRows tagged its delivery
  # with json_for_script(kind) on a BARE STRING. hs.json.encode requires a
  # table (LS_TTABLE) and raises on anything else, so the call aborted the
  # hs.task completion callback before evaluateJavaScript ever ran — and
  # since only a row delivery clears LOADING, the panel sat on
  # "loading library…" forever. Exactly the regression 1845a71b fixed,
  # through a different door.
  #
  # So the stub's encode() REFUSES a non-table, mirroring LS_TTABLE. That
  # refusal is the whole point: soften it and this harness goes blind to the
  # only class of bug it exists to catch.
  no_lua() { ! command -v lua >/dev/null 2>&1; }

  # panel_lua <verb> [arg] — drive one library-dialog setter and print every
  # string it handed to webview:evaluateJavaScript.
  panel_lua() {
    cat > "$RIP_SANDBOX/dialog.lua" <<'LUA'
local HS_DIR = os.getenv("HS_DIR")

-- hs.json.encode is NSJSONSerialization dataWithJSONObject:, which escapes
-- backslash, double quote, the control characters AND the forward slash
-- (`\/`) — see modules/ripper/session-dialog.lua's json_for_script, whose
-- whole rationale rests on that last one. A stub that emitted a bare
-- '"' .. v .. '"' would make every escaping assertion in this file pass
-- against the STUB rather than against the bridge, which is precisely the
-- self-validating failure this harness exists to prevent.
local ESC = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['/'] = '\\/',
  ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function encstr(v)
  local out = v:gsub('[%c"\\/]', function(c)
    return ESC[c] or string.format('\\u%04x', c:byte())
  end)
  return '"' .. out .. '"'
end

local function encode(v)
  -- hs.json.encode requires LS_TTABLE. Mirrored exactly.
  if type(v) ~= "table" then
    error("ERROR: incorrect type '" .. type(v) .. "' for argument (expected table)", 2)
  end
  local isArray, n = true, 0
  for k in pairs(v) do
    n = n + 1
    if type(k) ~= "number" then isArray = false end
  end
  if n == 0 then return "{}" end
  local parts = {}
  if isArray then
    for _, item in ipairs(v) do parts[#parts + 1] = encode(item) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local val, enc = v[k], nil
    if type(val) == "table" then enc = encode(val)
    elseif type(val) == "string" then enc = encstr(val)
    else enc = tostring(val) end
    parts[#parts + 1] = encstr(k) .. ":" .. enc
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local JS = {}
local webviewStub = setmetatable({}, { __index = function(_, key)
  return function(_, a)
    if key == "evaluateJavaScript" then JS[#JS + 1] = a end
    return nil
  end
end })

hs = {
  configdir = HS_DIR,
  json = { encode = encode },
  base64 = { encode = function() return "BASE64" end },
  printf = function() end,
  drawing = { windowLevels = { modalPanel = 1 } },
  window = { focusedWindow = function() return nil end },
  screen = { mainScreen = function()
    return { fullFrame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
  end },
  webview = {
    usercontent = { new = function() return { setCallback = function() end } end },
    new = function() return webviewStub end,
  },
}

package.preload["system.dismiss-on-blur"] = function()
  return { dismissOthers = function() end, dismissingViaSwitcher = false }
end

local M = dofile(HS_DIR .. "/modules/ripper/library-dialog.lua")

-- Every setter is a no-op until the panel is actually open.
M.show({ rows = {}, loading = true })
local verb, a = arg[1], arg[2]
if verb == "setRows" then
  M.setRows({}, a)
elseif verb == "setSource" then
  M.setSource(a, arg[3])
elseif verb == "sourceFailed" then
  M.sourceFailed()
end
for _, js in ipairs(JS) do print(js) end
LUA
    HS_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_config/hammerspoon" lua "$RIP_SANDBOX/dialog.lua" "$@"
  }

  It 'dialog: setRows tags the delivery without tripping hs.json.encode'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setRows library
    The status should equal 0
    The output should include 'window.__setRows({}, "library")'
  End

  It 'dialog: the folder tag survives the same path'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setRows folder
    The status should equal 0
    The output should include 'window.__setRows({}, "folder")'
  End

  # An untagged delivery is the preview harness, which has no source opinion.
  # It must emit ONE argument, not a bogus tag and not an error.
  It 'dialog: an untagged setRows emits no second argument'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setRows
    The status should equal 0
    The output should include 'window.__setRows({})'
  End

  # The other two evaluateJavaScript emitters this round added, equally
  # invisible to the node examples.
  It 'dialog: setSource crosses the bridge with kind and root'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setSource folder /Volumes/Media/Incoming
    The status should equal 0
    The output should include '"kind":"folder"'
    # The LIVE form. hs.json.encode is NSJSONSerialization, which escapes the
    # forward slash — asserting the bare path would have passed only under a
    # stub that did not, i.e. it would have validated the stub.
    The output should include '"root":"\/Volumes\/Media\/Incoming"'
  End

  # The property json_for_script EXISTS for, pinned end to end. A root is
  # operator-supplied and reaches an HTML <script> element, so it is exactly
  # as attacker-adjacent as a book title: the JSON encoder handles the
  # quote, the backslash and the slash, and json_for_script's own gsub turns
  # '<' into \u003C so '<script' cannot switch WebKit's tokenizer into the
  # double-escaped state and swallow the element's real closing tag
  # (session-dialog.lua documents that failure at length).
  It 'dialog: a hostile root is escaped on the way across the bridge'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setSource folder '/inc/a"b\c<script>'
    The status should equal 0
    The output should include '\/inc\/a'
    The output should include '\"b'
    The output should include '\\c'
    The output should include '\u003Cscript'
    # The raw sequence must not survive anywhere in the emitted JS.
    The output should not include '<script>'
  End

  It 'dialog: sourceFailed calls the restore entry point'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua sourceFailed
    The status should equal 0
    The output should include 'window.__sourceFailed()'
  End

  # --- review round 2: the four findings ----------------------------------

  # FINDING 1. Switching source does not un-ask a fetch already walking a
  # large tree. The two row-producing fetches are separately anchored, and an
  # anchor's identity guard only ever defends it against its OWN successor —
  # never against the other source's answer arriving after the switch. Lua
  # now terminates the outgoing fetch, but terminate() is only SIGTERM: a
  # fetch that already finished writing still delivers rc = 0. The delivery
  # TAG is the half that cannot race, and it is the half testable here.
  #
  # panel_late_delivery <switch1-json> <switch2-json> <rows-json> [tag]
  #   Switches source twice, then delivers rows tagged for the FIRST source —
  #   exactly the late reply. Prints #rows + #source innerHTML.
  panel_late_delivery() {
    cat > "$RIP_SANDBOX/panel-late.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  return { id: id, innerHTML: '', textContent: '', value: '',
           classList: { add() {}, remove() {}, toggle() {} },
           addEventListener() {}, setAttribute() {},
           getAttribute() { return null; }, setSelectionRange() {} };
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {}, querySelector() { return null; }
};
global.window = global;
(0, eval)(src);
window.__setSource(JSON.parse(process.argv[2]));
window.__setSource(JSON.parse(process.argv[3]));
window.__setRows(JSON.parse(process.argv[4]), process.argv[5]);
process.stdout.write(els.rows.innerHTML + '' + els.source.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-late.js" "$@"
  }

  AUDIBLE_ROW='[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","authors":["Brandon Sanderson"],"narrators":[],"ids":{"audible.asin":"B00ECDZ08I"}}]'

  It 'panel: a late browse delivery is dropped after the switch back to the library'
    Skip if 'node is unavailable' no_node
    When call panel_late_delivery '{"kind":"folder","root":"/inc"}' '{"kind":"library"}' "$FOLDER_ROW" folder
    The status should equal 0
    The output should not include "Ancilary Justice"
  End

  # The mirror, and the worse one: Audible rows landing in files mode would
  # render real ASINs as editable identities and post them under provider
  # "folder", which rip::ab_worker hands to rip-provider-folder as a source
  # DIRECTORY.
  It 'panel: a late library delivery is dropped after the switch to a folder'
    Skip if 'node is unavailable' no_node
    When call panel_late_delivery '{"kind":"library"}' '{"kind":"folder","root":"/inc"}' "$AUDIBLE_ROW" library
    The status should equal 0
    The output should not include "Steelheart"
  End

  # Positive control: the tag must not be swallowing everything. A delivery
  # for the source ACTUALLY on screen still renders.
  It 'panel: a delivery tagged for the current source still lands'
    Skip if 'node is unavailable' no_node
    When call panel_late_delivery '{"kind":"library"}' '{"kind":"folder","root":"/inc"}' "$FOLDER_ROW" folder
    The status should equal 0
    The output should include "Ancilary Justice"
  End

  # FINDING 2, the un-edited case. The folder provider emits a single-segment
  # path for EVERY derived_from:"filename" row — a flat tree of loose .m4b
  # files, which is exactly what browse mode exists to import — and
  # rip::_validate_ab_plan aborts the whole plan on the first one.
  FLAT_ROW='[{"id":"/inc/Network Effect","path":"Network Effect","title":"Network Effect","authors":[],"narrators":[],"derived_from":"filename"}]'

  It 'panel: an author-less row is never posted, even with no edit at all'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FLAT_ROW"
    The status should equal 0
    The output should not include '"action":"start"'
  End

  It 'panel: an author-less row says so before it is selected'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FLAT_ROW"
    The status should equal 0
    The output should include 'data-blocked="true"'
    The output should include 'edit-author invalid'
  End

  It 'panel: supplying the missing author unblocks the row'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FLAT_ROW" '[["/inc/Network Effect","author","Martha Wells"]]'
    The status should equal 0
    The output should include '"path":"Martha Wells/Network Effect"'
    # The block has to LIFT, not just the post go through: an edited row that
    # still rendered as blocked would leave the operator staring at a warning
    # they had already answered.
    The output should include 'data-blocked="false"'
  End

  # A blocked row must not take its healthy neighbours down with it — that is
  # the entire difference between a per-row block and _validate_ab_plan's
  # whole-session refusal.
  It 'panel: a blocked row does not stop its valid neighbour from shipping'
    Skip if 'node is unavailable' no_node
    When call panel_files '[{"id":"1","path":"Network Effect","title":"Network Effect","authors":[],"narrators":[],"derived_from":"filename"},{"id":"2","path":"Martha Wells/Fugitive Telemetry","title":"Fugitive Telemetry","authors":["Martha Wells"],"narrators":[],"derived_from":"tags"}]'
    The status should equal 0
    The output should include '"path":"Martha Wells/Fugitive Telemetry"'
    The output should not include '"path":"Network Effect"'
  End

  # FINDING 3. PROVIDER is read from the payload and only __setLibrary ever
  # rewrites it, so a COLD browse seeding provider:"folder" left the way back
  # posting Audible rows under the folder provider. Task 8's Quick Action is
  # the cold-browse entry point that arms this.
  panel_cold_browse_back() {
    cat > "$RIP_SANDBOX/panel-cold.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', process.argv[2]);
const els = {};
function stub(id) {
  const listeners = {};
  const el = {
    id: id, innerHTML: '', textContent: '', value: '',
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    setAttribute() {}, getAttribute() { return null; }, setSelectionRange() {},
    fire(type, ev) { (listeners[type] || []).forEach((f) => f.call(el, ev)); }
  };
  return el;
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {}, querySelector() { return null; }
};
const POSTED = [];
global.window = global;
global.webkit = { messageHandlers: { ripLibrary: { postMessage(m) { POSTED.push(m); } } } };
(0, eval)(src);
const ev = () => ({ preventDefault() {} });
const rows = JSON.parse(process.argv[3]);
window.__setSource({ kind: 'library' });
window.__setRows(rows, 'library');
for (const r of rows) {
  els.rows.fire('mousedown', Object.assign(ev(), {
    target: { getAttribute: (a) => (a === 'data-toggle' ? String(r.id) : null), parentNode: null }
  }));
}
els.btnStart.fire('mousedown', ev());
process.stdout.write(JSON.stringify(POSTED));
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-cold.js" "$@"
  }

  It 'panel: a cold browse then back to the library posts the catalogue provider'
    Skip if 'node is unavailable' no_node
    When call panel_cold_browse_back '{"loading":true,"rows":[],"provider":"folder","source":{"kind":"folder","root":"/inc"}}' "$AUDIBLE_ROW"
    The status should equal 0
    The output should include '"provider":"libation"'
    The output should not include '"provider":"folder"'
  End

  # FINDING 4. The way back loses just as much as a browse does: 400 browsed
  # books and 40 marks against one mid-update LibationCli. PREV_SOURCE holds
  # them; the failure path has to call the restore.
  panel_way_back_failed() {
    cat > "$RIP_SANDBOX/panel-wayback.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  const listeners = {};
  const el = {
    id: id, innerHTML: '', textContent: '', value: '',
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    setAttribute() {}, getAttribute() { return null; }, setSelectionRange() {},
    fire(type, ev) { (listeners[type] || []).forEach((f) => f.call(el, ev)); }
  };
  return el;
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {}, querySelector() { return null; }
};
global.window = global;
(0, eval)(src);
const rows = JSON.parse(process.argv[2]);
window.__setSource({ kind: 'folder', root: '/inc' });
window.__setRows(rows, 'folder');
// Mark one, then take the way back and have its fetch fail.
els.rows.fire('mousedown', {
  preventDefault() {},
  target: { getAttribute: (a) => (a === 'data-toggle' ? String(rows[0].id) : null), parentNode: null }
});
window.__setSource({ kind: 'library' });
window.__sourceFailed();
process.stdout.write(els.rows.innerHTML + '' + els.source.innerHTML + '' + els.summary.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-wayback.js" "$@"
  }

  It 'panel: a failed way-back restores the browsed rows AND the marks on them'
    Skip if 'node is unavailable' no_node
    When call panel_way_back_failed "$FOLDER_ROW"
    The status should equal 0
    The output should include "Ancilary Justice"
    The output should include "/inc"
    The output should include "1 book"
    The output should not include "nothing to show"
  End

  # FINDING 2 (round 3). pathValid is PER-PATH; rip::_validate_ab_plan also
  # refuses the WHOLE plan when two items compose the same <Author>/<Title>.
  # Reachable with no editing at all: rip-provider-folder keys a row by
  # DIRECTORY but composes `path` from the embedded tags first, so a
  # re-download under another folder, a second format, or a backup copy
  # yields two rows with distinct ids and one identical path. Both look
  # perfectly valid on their own — and the plan they compose kills every
  # other selected book with them, after the panel has closed.
  DUPES='[{"id":"/inc/2023/Network Effect","path":"Martha Wells/Network Effect","title":"Network Effect","authors":["Martha Wells"],"narrators":[],"derived_from":"tags"},{"id":"/inc/2024/Network Effect","path":"Martha Wells/Network Effect","title":"Network Effect","authors":["Martha Wells"],"narrators":[],"derived_from":"tags"},{"id":"/inc/Fugitive","path":"Martha Wells/Fugitive Telemetry","title":"Fugitive Telemetry","authors":["Martha Wells"],"narrators":[],"derived_from":"tags"}]'

  It 'panel: two rows composing one path are never both posted'
    Skip if 'node is unavailable' no_node
    When call panel_files "$DUPES"
    The status should equal 0
    # jq -c over the posted plan: exactly one item may carry that path.
    The output should include '"id":"/inc/2023/Network Effect"'
    The output should not include '"id":"/inc/2024/Network Effect"'
  End

  # The whole point of a per-row block: the distinct third book still ships,
  # and the footer counts what is actually going rather than what is ticked.
  It 'panel: a duplicate pair does not take the rest of the selection with it'
    Skip if 'node is unavailable' no_node
    When call panel_files "$DUPES"
    The status should equal 0
    The output should include '"path":"Martha Wells/Fugitive Telemetry"'
    The output should include '2 books'
    The output should include '1 duplicate of a book already selected'
  End

  # Silently dropping one copy would be its own defect — the operator has to
  # see WHICH copy was excluded, and on what grounds.
  It 'panel: the excluded duplicate says which book it collides with'
    Skip if 'node is unavailable' no_node
    When call panel_files "$DUPES"
    The status should equal 0
    The output should include "already stages as"
    The output should include 'data-blocked="true"'
  End

  # Provider-agnostic: two Audible rows can compose one path too (a
  # re-release under the same author and title), and the server rule does
  # not care which provider produced them.
  It 'panel: the duplicate rule applies to library-mode rows as well'
    Skip if 'node is unavailable' no_node
    When call panel_files '[{"id":"A1","path":"Brandon Sanderson/Steelheart","title":"Steelheart","authors":["Brandon Sanderson"],"narrators":[]},{"id":"A2","path":"Brandon Sanderson/Steelheart","title":"Steelheart","authors":["Brandon Sanderson"],"narrators":[]}]' '[]' '' '' library
    The status should equal 0
    The output should include '"id":"A1"'
    The output should not include '"id":"A2"'
  End

  It 'panel: a files-mode row is never marked "liberated, never pushed"'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[]' '[]'
    The status should equal 0
    The output should not include "never pushed"
  End

  # --- rip::ab_backfill_work_uid ---------------------------------------------
  #
  # Mints `work.uid` for every stored book whose `work` is null, leaving
  # `edition: null` behind — the anchor of a work, not a named edition of one
  # (design doc S5). Mirrors rip::ab_backfill_published's shape (dry run by
  # default, --apply required, compose locally + ship base64-framed payloads
  # because cantina has no jq) — reuses that section's mkbook_empty,
  # sidecar_at, fake_server_ssh and ssh_calls helpers, already defined above.
  #
  # This writes to the only copy of a book's identity on 248 real sidecars —
  # the byte-identity and distinct-uid guards below are the ones that matter
  # most: a book that already anchors a work must never be re-serialized, and
  # a loop that mints once and reuses the value would silently merge the
  # whole library into one "work".

  bwu_sha() { shasum -a 256 "$(sidecar_at "$1")" | cut -d' ' -f1; }
  bwu_uid_at() { jq -r '.work.uid // ""' "$(sidecar_at "$1")"; }
  bwu_uid_ok() {
    bwu_uid_at "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
      && echo "uuidv4" || echo "NOT A UUIDV4"
  }
  # "The result of function NAME" invokes NAME with no meaningful args (the
  # prior When's stdout/stderr/status land in $1-$3, unused here) — these
  # zero-arg wrappers close over a fixed path the way rpo_uid_ok closes over
  # $RPO above.
  bwu_uid_ok_ab() { bwu_uid_ok "A/B"; }
  bwu_already_sha() { bwu_sha "A/Already"; }
  bwu_two_uids_distinct() {
    u1=$(bwu_uid_at "A/One"); u2=$(bwu_uid_at "A/Two")
    if [ -n "$u1" ] && [ -n "$u2" ] && [ "$u1" != "$u2" ]; then
      echo "distinct"
    else
      echo "u1=$u1 u2=$u2"
    fi
  }
  # bwu_tree_digest — one hash covering every stored file's PATH and CONTENT,
  # so "the dry run writes nothing at all" is proved against the whole server
  # tree, not just the one sidecar an example happens to name (mission brief:
  # "prove it by comparing the whole sandbox server tree before and after,
  # not by trusting the absence of a log line").
  bwu_tree_digest() {
    ( cd "$RIP_SANDBOX/server" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s\n' "$f"
        shasum -a 256 "$f" | cut -d' ' -f1
      done ) | shasum -a 256 | cut -d' ' -f1
  }

  It 'backfill-work-uid: dry-run names the candidate and writes nothing at all'
    mkbook_empty "A/B" libation
    before=$(bwu_tree_digest)
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid"
    The status should equal 0
    The output should include "would assign a work uid: A/B"
    The output should include "re-run with --apply"
    The result of function bwu_tree_digest should equal "$before"
  End

  It 'backfill-work-uid: --apply mints a uuidv4 and leaves edition null'
    mkbook_empty "A/B" libation
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid --apply"
    The status should equal 0
    The output should include "backfilled 1 of 1 sidecar(s)"
    The result of function bwu_uid_ok_ab should equal "uuidv4"
  End

  It 'backfill-work-uid: a book that already carries a work object is untouched byte-for-byte'
    # Deliberately irregular formatting (extra spaces, a pre-existing edition
    # label) — a rewrite that merely re-serializes to the SAME parsed value
    # would still fail this, because the check is on the raw bytes.
    ALREADY='{"schema":1,   "kind":"audiobook","title":"Already","authors":["A"],"ids":{},"work":{"uid":"11111111-1111-4111-8111-111111111111","edition":"Full Cast"},"source":{"provider":"libation"}}'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Already"
    printf '%s' "$ALREADY" > "$(sidecar_at "A/Already")"
    before=$(bwu_sha "A/Already")
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid --apply"
    The status should equal 0
    The output should include "nothing to backfill"
    The result of function bwu_already_sha should equal "$before"
  End

  It 'backfill-work-uid: two candidate books mint two DIFFERENT uids'
    mkbook_empty "A/One" libation
    mkbook_empty "A/Two" libation
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid --apply"
    The status should equal 0
    The output should include "backfilled 2 of 2 sidecar(s)"
    The result of function bwu_two_uids_distinct should equal "distinct"
  End

  It 'backfill-work-uid: an enumerator that returns nothing is distinguished from a satisfied library'
    # No mkbook_empty call at all — nothing staged in $RIP_SANDBOX/server,
    # the same "seen==0" wording rip::ab_backfill_published uses so an
    # unreachable server is never conflated with a genuinely empty sweep.
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid"
    The status should equal 0
    The output should include "no sidecars found on the server"
    The output should include "cantina reachable"
  End

  It 'backfill-work-uid: --apply writes through a server with NO jq, in ONE ssh for the whole batch'
    mkbook_empty "A/B" libation
    mkbook_empty "C/D" libation
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid --apply"
    The status should equal 0
    The output should include "backfilled 2 of 2 sidecar(s)"
    # ONE ssh to enumerate, ONE for the whole write batch — not one per book.
    The result of function ssh_calls should equal "2"
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "jq"
  End

  It 'backfill-work-uid: a write that fails leaves the good sidecar untouched and reports the book failed'
    mkbook_empty "A/B" libation
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      chmod 555 '$RIP_SANDBOX/server/audiobooks/A/B'
      rip::ab_backfill_work_uid --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/A/B'
      exit \$rc"
    The status should equal 1
    The output should include "backfilled 0 of 1 sidecar(s)"
    The output should include "1 sidecar(s) could not be written"
    The stderr should include "could not backfill A/B"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"work": null'
    The result of function stray_tmp_files should equal "0"
  End

  It 'backfill-work-uid: a dry run against the ssh branch writes nothing and opens no write connection'
    mkbook_empty "A/B" libation
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid"
    The status should equal 0
    The output should include "re-run with --apply"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"work": null'
    The result of function ssh_calls should equal "1"
  End

  # --- rip::_remote_sidecar_json (the work-uid read path) --------------------
  #
  # ONE book's stored sidecar, in ONE ssh, through a server with no jq — the
  # read rip::ab_worker makes per edition item, inside its acquire loop.
  # rip::_server_sidecars ships the WHOLE library (~124 KB for 248 books) and
  # is the wrong tool for a single lookup.

  rsj_ssh_cmds() { cat "$RIP_SANDBOX/ssh.cmds" 2>/dev/null; }

  It 'remote sidecar: reads ONE stored sidecar over ssh, with no jq on the server'
    mkbook_empty "A/B" libation
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::_remote_sidecar_json 'A/B' | jq -r '.title'"
    The status should equal 0
    The output should equal "B"
    The result of function ssh_calls should equal "1"
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "jq"
  End

  It 'remote sidecar: a book with no sidecar is confirmed ABSENT, not unknown'
    mkbook_bare "A/NoSidecar"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::_remote_sidecar_json 'A/NoSidecar'"
    The status should equal 1
    The output should equal ""
  End

  # -n IS LOAD-BEARING, the same fd-0 guard rip::_remote_test carries: without
  # it ssh(1) drains THIS shell's stdin and forwards it to the remote, whether
  # or not the remote command consumes it. The fake honours -n exactly as ssh
  # does, so the sentinel survives only when the probe passed it.
  It 'remote sidecar: the read passes ssh -n and does not eat the caller stdin'
    mkbook_empty "A/B" libation
    fake_server_ssh_reads_stdin
    printf 'sentinel\n' > "$RIP_SANDBOX/in.txt"
    When run zsh -c "source $RIPLIB
      { rip::_remote_sidecar_json 'A/B' >/dev/null; cat; } < $RIP_SANDBOX/in.txt"
    The status should equal 0
    The output should equal "sentinel"
  End

  # An unreachable server must be UNKNOWN (rc 2), never "absent": the caller's
  # only write path fires on "the base book exists and has no uid", and an
  # absent verdict on an unread server would turn an outage into a mint that
  # can never match what the base book already carries.
  It 'remote sidecar: an ssh that never connects is unknown, not absent'
    mkbook_empty "A/B" libation
    fake_server_ssh
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::_remote_sidecar_json 'A/B'"
    The status should equal 2
    The output should equal ""
  End

  # A sidecar that EXISTS but does not parse is unknown too, for the same
  # reason with more at stake: composing a replacement over a truncated file
  # destroys the only copy of that book's identity.
  It 'remote sidecar: a malformed stored sidecar is unknown, never treated as readable'
    mkbook_malformed "A/Broken"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::_remote_sidecar_json 'A/Broken'"
    The status should equal 2
    The output should equal ""
  End

End
