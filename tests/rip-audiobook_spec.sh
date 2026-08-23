# rip-audiobook — the provider contract, the libation provider, the CLI and
# the session worker. Hermetic: sandboxed staging, fake LibationCli
# (RIP_LIBATION_BIN), fake ssh (RIP_SSH_BIN), no network, no GUI.
Describe 'rip audiobooks'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  PROVIDER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-libation"

  setup() {
    export RIP_SANDBOX=$(mktemp -d)
    export RIP_STAGING_ROOT="$RIP_SANDBOX/Rips"
    export RIP_REMOTE_BASE="$RIP_SANDBOX/server"
    export JOB_STATE_ROOT="$RIP_SANDBOX/state"
    export JOB_FAKE_LOG="$RIP_SANDBOX/pueue.log"
    export RIP_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export RIP_LIBEXEC_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec"
    export RIP_PUSH_MIN_AGE_S=0
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Books" "$RIP_SANDBOX/server/audiobooks"
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
  "HasPdf":false,"PictureId":"51kzMpLGP7L","BookStatus":"NotLiberated","LastDownloaded":null},
 {"AudibleProductId":"B0DGKKZ123","Title":"Wind and Truth","Subtitle":"",
  "AuthorNames":"Brandon Sanderson","NarratorNames":"Michael Kramer","LengthInMinutes":3360,
  "SeriesNames":"The Stormlight Archive","SeriesOrder":"5 : The Stormlight Archive","Language":"english",
  "IsAbridged":false,"HasPdf":true,"PictureId":"81abcDEF","BookStatus":"Liberated",
  "LastDownloaded":"2026-08-22 08:18:03.838369"}
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
  mkdir -p "$books/Books/Brandon Sanderson/Steelheart"
  printf 'audio\n' > "$books/Books/Brandon Sanderson/Steelheart/Steelheart.m4b"
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

  It 'provider: path carries Title: Subtitle, the folder Libation actually writes'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include '"path":"Brandon Sanderson/Steelheart: The Reckoners, Book 1"'
    The line 1 should include '"title":"Steelheart"'
    The line 2 should include '"path":"Brandon Sanderson/Wind and Truth"'
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
    The path "$RIP_STAGING_ROOT/audiobooks/Books/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
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
  *"audiobooks/$(printf 'Ant\xc3\xb4nio')/Livro/Livro.m4b"*) exit 0 ;;
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
    The path "$RIP_STAGING_ROOT/audiobooks/Books/Brandon Sanderson/Steelheart/Steelheart.m4b" should not be exist
  End

  It 'worker: the sidecar carries the plan identity, not the path fallback'
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","subtitle":"The Reckoners, Book 1","authors":["Brandon Sanderson"],"narrators":["MacLeod Andrews"],"duration_s":45720,"ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","provider_version":"13.7.10","format":"m4b"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json >/dev/null && jq -c '[.subtitle,.ids[\"audible.asin\"],.source.provider,.work]' '$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/.fleet-book.json'"
    The status should equal 0
    The output should equal '["The Reckoners, Book 1","B00ECDZ08I","libation",null]'
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
mkdir -p "$books/Books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "$books/Books/Brandon Sanderson/Steelheart/Steelheart.m4b"
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
mkdir -p "\$books/Books/Brandon Sanderson/${nfd}"
printf 'audio\n' > "\$books/Books/Brandon Sanderson/${nfd}/${nfd}.m4b"
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
End
