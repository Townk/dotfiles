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
    The path "$RIP_STAGING_ROOT/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should not be exist
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

  # --- ABS author enrichment (rip-abs-authors + the RIP_AB_REMOTE_HOPS
  # first entry, rip::_abs_match_authors) ------------------------------------
  #
  # Hermetic per the file header's own doctrine: fake curl behind
  # RIP_CURL_BIN, RIP_ABS_URL pointed at a sandbox value, never the real
  # cantina. AUDIOBOOKSHELF_API_KEY is explicitly unset before every use so
  # a value sitting in the real environment can never leak in.

  abs_get_calls() { grep -c '/api/libraries/lib-book/authors' "$RIP_SANDBOX/abscurl.log" 2>/dev/null || true; }

  # fake_abs_curl <authors_json> — a fake ABS: /api/libraries answers with
  # a DECOY podcast library FIRST and the book library second (so a test
  # that hardcoded "the first library" instead of filtering on mediaType
  # would pick the wrong one and fail), /api/libraries/lib-book/authors
  # answers with <authors_json>, and /api/authors/<id>/match always
  # succeeds and logs which id it was called for.
  fake_abs_curl() {
    export RIP_ABS_URL="http://cantina:13378"
    printf '%s' "$1" > "$RIP_SANDBOX/abs-authors.json"
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
  */api/authors/*/match)
    id="\${url%/match}"; id="\${id##*/}"
    printf '{"updated":true,"author":{"id":"%s"}}' "\$id" ;;
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
End
