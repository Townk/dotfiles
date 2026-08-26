Describe 'rip-provider-folder'
  setup() {
    export RIP_SANDBOX=$(mktemp -d)
    export FOLDER_BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-folder"
    export ROOT="$RIP_SANDBOX/incoming"
    mkdir -p "$ROOT"
    # Canonicalize: on macOS $TMPDIR sits under /var, itself a symlink to
    # /private/var. fd --absolute-path resolves that symlink when it walks
    # the tree, and so does the provider's own `root="${root:A}"` (needed so
    # its later prefix-strip against fd's output actually matches) — so an
    # unresolved $ROOT would never equal the id/path this spec expects back.
    ROOT="${ROOT:A}"
  }
  cleanup() { rm -rf "$RIP_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A book whose directory structure carries the identity: <Author>/<Title>/x.m4b
  mkdirbook() {
    mkdir -p "$ROOT/$1/$2"
    printf 'fake audio\n' > "$ROOT/$1/$2/$2.m4b"
  }

  # `The result of "wc -l"` etc. is not valid shellspec 0.28.1 grammar — that
  # modifier only accepts a defined shell FUNCTION name (shellspec_is_function
  # rejects anything with a space or paren), so each ad-hoc pipeline from the
  # brief becomes a named helper here instead.
  linecount() { wc -l | tr -d ' '; }
  jq_title() { jq -r .title; }
  jq_cover_is_sibling() { jq -r '.cover | endswith("cover.jpg")'; }
  jq_id() { jq -r .id; }
  jq_provider() { jq -r .provider; }
  jq_ids() { jq -c .ids; }
  jq_authors() { jq -c .authors; }
  jq_derived_from() { jq -r .derived_from; }
  jq_path() { jq -r .path; }

  # bonus_pdf_anywhere() — count of "0-bonus.pdf" ANYWHERE under
  # $RIP_SANDBOX/staging, not just under the book's own final path — the
  # temp-then-rename guard's whole point is that a file copied before a
  # LATER failure never survives under ANY name, including the hidden temp
  # one, not merely that it fails to land at the final path (a naive
  # "build under the final name, rm -rf on failure" implementation can
  # satisfy "the final path doesn't exist" with a single unreadable
  # source file just as well, since nothing was ever copied at all).
  bonus_pdf_anywhere() {
    find "$RIP_SANDBOX/staging" -name '0-bonus.pdf' 2>/dev/null | wc -l | tr -d ' '
  }

  # bonus_seen_under_dest() — how many times "0-bonus.pdf" shows up in the
  # cp-shim log: a `find "$RIP_SHIM_DEST"` snapshot taken immediately
  # before EVERY cp call this run makes, including the one that copies the
  # SECOND file (the .m4b). That snapshot is the discriminator "a partly-
  # copied book is never left in place" cannot be, because it looks at
  # state DURING the copy, not what survives cleanup afterward: a "build
  # directly under the final name" implementation would already show
  # 0-bonus.pdf sitting under $RIP_SHIM_DEST by the time the second file's
  # cp runs (it landed there on the first cp); the temp-anchored
  # implementation never does, because the temp lives outside $RIP_SHIM_DEST
  # entirely and no snapshot of $RIP_SHIM_DEST ever sees it.
  bonus_seen_under_dest() {
    [ -f "$RIP_SANDBOX/cp-shim.log" ] || { printf '%s\n' 0; return; }
    grep -c '0-bonus.pdf' "$RIP_SANDBOX/cp-shim.log" | tr -d ' '
  }

  # cp_calls() — how many times `cp` ran at all. "Did not re-copy" is only
  # provable by counting the copies; a post-hoc look at the destination
  # cannot tell "never copied" from "copied and then cleaned up".
  cp_calls() {
    [ -f "$RIP_SANDBOX/cp-calls.log" ] || { printf '%s\n' 0; return; }
    wc -l < "$RIP_SANDBOX/cp-calls.log" | tr -d ' '
  }

  It 'capabilities: announces itself as an acquiring provider'
    When run zsh "$FOLDER_BIN" capabilities
    The status should equal 0
    The output should include '"name":"folder"'
    The output should include '"can_acquire":true'
  End

  It 'list: an empty root yields no rows and succeeds'
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should equal ""
  End

  It 'list: refuses a root that does not exist rather than reporting an empty library'
    When run zsh "$FOLDER_BIN" list "$ROOT/nope"
    The status should equal 2
    The stderr should include "no such directory"
  End

  It 'list: derives author and title from the directory structure'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"authors":["Ann Leckie"]'
    The output should include '"title":"Ancillary Justice"'
    The output should include '"path":"Ann Leckie/Ancillary Justice"'
    The output should include '"format":"m4b"'
    The output should include '"derived_from":"path"'
  End

  It 'list: one directory is ONE book however many m4b files it holds'
    mkdir -p "$ROOT/Ann Leckie/Ancillary Justice"
    printf 'a\n' > "$ROOT/Ann Leckie/Ancillary Justice/part1.m4b"
    printf 'b\n' > "$ROOT/Ann Leckie/Ancillary Justice/part2.m4b"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function linecount should equal "1"
  End

  It 'list: finds books at any depth, with no recursion limit'
    mkdirbook "deep/deeper/Ann Leckie" "Ancillary Sword"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"title":"Ancillary Sword"'
  End

  It 'list: ignores non-m4b files entirely'
    mkdir -p "$ROOT/Someone/Book"
    printf 'x\n' > "$ROOT/Someone/Book/book.mp3"
    printf 'x\n' > "$ROOT/Someone/Book/notes.txt"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should equal ""
  End

  It 'list: a title with quotes and a dollar sign survives as JSON'
    mkdirbook 'Guns N Roses' 'It''s $HOME: "quoted"'
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_title should equal 'It''s $HOME: "quoted"'
  End

  It 'list: records a sibling cover when one is present, null when not'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    printf 'jpg\n' > "$ROOT/Ann Leckie/Ancillary Justice/cover.jpg"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_cover_is_sibling should equal "true"
  End

  It 'list: the id is the book directory, so acquire can find it again'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_id should equal "$ROOT/Ann Leckie/Ancillary Justice"
  End

  It 'list: never claims Audible concepts for a local file'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"plus":false'
    The output should include '"absent":false'
    The output should include '"acquired":true'
  End

  It 'list: reports its own provider identity, never "unknown"'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_provider should equal "folder"
  End

  It 'list: a local file carries no external identity — ids is empty'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_ids should equal "{}"
  End

  It 'list: a sibling pdf is a real local signal — has_pdf true'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    printf 'pdf\n' > "$ROOT/Ann Leckie/Ancillary Justice/companion.pdf"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"has_pdf":true'
  End

  It 'list: no sibling pdf — has_pdf false, never guessed'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"has_pdf":false'
  End

  It 'list: a one-level-deep book with no tags falls through to filename, not path'
    mkdir -p "$ROOT/SingleBook"
    printf 'fake audio\n' > "$ROOT/SingleBook/x.m4b"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_title should equal "SingleBook"
    The result of function jq_authors should equal "[]"
    The result of function jq_derived_from should equal "filename"
    The result of function jq_path should equal "SingleBook"
  End

  It 'list: m4b files loose directly in the root do not invent an author from the parent'
    printf 'fake audio\n' > "$ROOT/loose.m4b"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_authors should equal "[]"
    The result of function jq_derived_from should equal "filename"
  End

  It 'list: derived_from is always tags, path or filename — never empty'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    mkdir -p "$ROOT/SingleBook"
    printf 'fake audio\n' > "$ROOT/SingleBook/x.m4b"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should not include '"derived_from":""'
    The output should include '"derived_from":"path"'
    The output should include '"derived_from":"filename"'
  End

  It 'list: multiple books emit clean JSON lines only — no stray shell output between rows'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    mkdirbook "Brandon Sanderson" "Steelheart"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function linecount should equal "2"
    The output should not include "one="
  End

  # The caller (rip::ab_worker) always passes the plan item's own path as
  # the third argument now — this mirrors that: production never relies on
  # directory-structure derivation, so the examples that need a nested
  # <Author>/<Title> destination pass it explicitly too.
  It 'acquire: copies the book into <dest>/<Author>/<Title>/ and leaves the source alone'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" acquire "$ROOT/Ann Leckie/Ancillary Justice" "$RIP_SANDBOX/staging" "Ann Leckie/Ancillary Justice"
    The status should equal 0
    The path "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should be exist
    The path "$ROOT/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should be exist
    The output should include "progress -1 copying"
  End

  It 'acquire: carries companion files across, not just the audio'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    printf 'pdf\n' > "$ROOT/Ann Leckie/Ancillary Justice/bonus.pdf"
    printf 'jpg\n' > "$ROOT/Ann Leckie/Ancillary Justice/cover.jpg"
    When run zsh "$FOLDER_BIN" acquire "$ROOT/Ann Leckie/Ancillary Justice" "$RIP_SANDBOX/staging" "Ann Leckie/Ancillary Justice"
    The status should equal 0
    The path "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice/bonus.pdf" should be exist
    The path "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice/cover.jpg" should be exist
  End

  # Final review F3 (2026-08-25): cmd_acquire was deliberately fixed to
  # follow symlinked audio (the example below), but cmd_list's `fd` had no
  # --follow, so `--type f` examined the dirent itself: a symlinked .m4b is
  # not a file and a symlinked directory is never descended into. Both shapes
  # were silently ABSENT from browse — which makes acquire's symlink support
  # unreachable, since nothing can be selected that was never listed. Three
  # shapes, one example, each of which fd 10.4.2 misses without --follow:
  # a book directory reached THROUGH a symlink, a symlinked .m4b sitting
  # beside real files, and a book directory whose only audio is a symlink.
  It 'list: symlinked audio and symlinked book directories are visible to browse'
    mkdir -p "$RIP_SANDBOX/real-store/Ann Leckie/Ancillary Justice" \
             "$RIP_SANDBOX/real-store/loose"
    printf 'real audio\n' > "$RIP_SANDBOX/real-store/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b"
    printf 'real audio\n' > "$RIP_SANDBOX/real-store/loose/Loose.m4b"
    # 1. the whole book directory is a symlink into the real store
    mkdir -p "$ROOT/Ann Leckie"
    ln -s "$RIP_SANDBOX/real-store/Ann Leckie/Ancillary Justice" "$ROOT/Ann Leckie/Ancillary Justice"
    # 2. a real book directory whose only .m4b is a symlink
    mkdir -p "$ROOT/Ann Leckie/Provenance"
    ln -s "$RIP_SANDBOX/real-store/loose/Loose.m4b" "$ROOT/Ann Leckie/Provenance/Provenance.m4b"
    # 3. a plain, entirely real book — the control: it was always visible,
    #    and must not stop being so.
    mkdirbook "Ann Leckie" "Translation State"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"path":"Ann Leckie/Ancillary Justice"'
    The output should include '"path":"Ann Leckie/Provenance"'
    The output should include '"path":"Ann Leckie/Translation State"'
    The result of function linecount should equal "3"
  End

  # Finding 5 (review, 2026-08-25): the precondition (`*.m4b(N)`, no type
  # qualifier) counts a SYMLINKED .m4b as present — exactly the shape an
  # operator's collection takes when it points into their real store — but
  # the OLD copy glob (`*(N.)`, plain-file type examined via lstat, which
  # never follows a link) silently skipped it: the book would publish with
  # a cover and no audio, exit 0. `(N-.)` on the copy makes the type check
  # follow the link, so the two globs agree.
  It 'acquire: a symlinked m4b is followed and copied, not silently skipped'
    mkdir -p "$RIP_SANDBOX/real-store/Ann Leckie/Ancillary Justice"
    printf 'real audio\n' > "$RIP_SANDBOX/real-store/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b"
    mkdir -p "$ROOT/Ann Leckie/Ancillary Justice"
    ln -s "$RIP_SANDBOX/real-store/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" \
          "$ROOT/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b"
    When run zsh "$FOLDER_BIN" acquire "$ROOT/Ann Leckie/Ancillary Justice" "$RIP_SANDBOX/staging" "Ann Leckie/Ancillary Justice"
    The status should equal 0
    The path "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should be exist
    The contents of file "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should equal "real audio"
  End

  It 'acquire: the caller-supplied relpath wins over any derivation'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" acquire "$ROOT/Ann Leckie/Ancillary Justice" "$RIP_SANDBOX/staging" "Edited Author/Edited Title"
    The status should equal 0
    The path "$RIP_SANDBOX/staging/Edited Author/Edited Title/Ancillary Justice.m4b" should be exist
    The path "$RIP_SANDBOX/staging/Ann Leckie" should not be exist
  End

  It 'acquire: a book sitting directly under the root derives no bogus author'
    mkdir -p "$ROOT/LooseBook"
    printf 'a\n' > "$ROOT/LooseBook/LooseBook.m4b"
    When run zsh "$FOLDER_BIN" acquire "$ROOT/LooseBook" "$RIP_SANDBOX/staging"
    The status should equal 0
    The path "$RIP_SANDBOX/staging/LooseBook/LooseBook.m4b" should be exist
  End

  It 'acquire: refuses a source directory holding no m4b'
    mkdir -p "$ROOT/Someone/Empty"
    When run zsh "$FOLDER_BIN" acquire "$ROOT/Someone/Empty" "$RIP_SANDBOX/staging"
    The status should equal 2
    The stderr should include "no m4b"
    The path "$RIP_SANDBOX/staging/Someone/Empty" should not be exist
  End

  It 'acquire: refuses an id that is not a directory'
    When run zsh "$FOLDER_BIN" acquire "$ROOT/nope" "$RIP_SANDBOX/staging"
    The status should equal 2
    The stderr should include "no such directory"
  End

  # TWO source files, the SECOND (alphabetically: "0-bonus.pdf" sorts
  # before "Ancillary Justice.m4b", and zsh's default glob order is
  # sorted — verified) unreadable: a single unreadable file never
  # distinguishes temp-then-rename from "build under the final name,
  # rm -rf on any failure" — both leave nothing, since nothing was ever
  # copied. With a first file that DOES land successfully before the
  # second one fails, only the temp-then-rename shape can ever be
  # PROVEN never to have surfaced it under the final path or the hidden
  # temp name once the run is done.
  It 'acquire: a partly-copied book is never left in place under the final name'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    printf 'bonus\n' > "$ROOT/Ann Leckie/Ancillary Justice/0-bonus.pdf"
    chmod 000 "$ROOT/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b"
    When run zsh "$FOLDER_BIN" acquire "$ROOT/Ann Leckie/Ancillary Justice" "$RIP_SANDBOX/staging" "Ann Leckie/Ancillary Justice"
    The status should not equal 0
    The path "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice" should not be exist
    The result of function bonus_pdf_anywhere should equal "0"
    chmod 644 "$ROOT/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b"
  End

  # Finding B (review, 2026-08-25): the ONLY thing pinning the temp anchor
  # (Finding 1, Critical) was a push_worker-level example — it guarded the
  # belt-and-braces half, never the provider itself. Reverting
  # `local tmp="${dest:h}/.rip-folder.$$"` back to
  # `local tmp="${staging:h}/.rip-folder.$$"` left the whole suite green.
  #
  # A `cp` shim on PATH snapshots the destination (`find "$RIP_SHIM_DEST"`)
  # immediately before every real copy runs, then execs the genuine
  # /bin/cp. Two source files ensure at least two snapshots: whatever the
  # first cp call already placed is exactly what the SECOND snapshot can
  # catch sitting under the destination while the run is still in
  # progress — the discriminator Finding C names (bytes' location DURING
  # the copy), which a post-hoc "does the final path exist" check cannot
  # ever see, cleanup having already erased the evidence either way.
  # Final review F4 (2026-08-25): the already-staged test used to sit AFTER
  # the copy loop and `die`. Two harms, both proven here. (1) On the
  # DOCUMENTED keep-staged retry path — "a push or verify failure keeps
  # everything staged for a plain `rip-push audiobooks` retry with no
  # re-download" — every staged book was re-copied in full and then thrown
  # away, which for this operator's library is multiple gigabytes of pure
  # waste per retry. (2) It reported an acquire FAILURE (rc 2, and via
  # rip::ab_worker a whole-session rc 2) for a book that is already exactly
  # where the caller asked for it.
  It 'acquire: an already-staged book is not re-copied and is not an error'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    # a previous session's staged copy, kept for the retry path
    mkdir -p "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice"
    printf 'staged by the previous run\n' > "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b"
    mkdir -p "$RIP_SANDBOX/shim"
    cat > "$RIP_SANDBOX/shim/cp" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_CP_LOG"
exec /bin/cp "$@"
EOF
    chmod +x "$RIP_SANDBOX/shim/cp"
    export PATH="$RIP_SANDBOX/shim:$PATH"
    export RIP_CP_LOG="$RIP_SANDBOX/cp-calls.log"
    When run zsh "$FOLDER_BIN" acquire "$ROOT/Ann Leckie/Ancillary Justice" "$RIP_SANDBOX/staging" "Ann Leckie/Ancillary Justice"
    The status should equal 0
    The output should include "already staged"
    The result of function cp_calls should equal "0"
    # and the staged copy is left exactly as it was
    The contents of file "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should equal "staged by the previous run"
  End

  It 'acquire: nothing under the destination is visible while the copy is running — the temp anchor'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    printf 'bonus\n' > "$ROOT/Ann Leckie/Ancillary Justice/0-bonus.pdf"
    mkdir -p "$RIP_SANDBOX/shim"
    cat > "$RIP_SANDBOX/shim/cp" <<'EOF'
#!/bin/sh
find "$RIP_SHIM_DEST" >> "$RIP_SHIM_LOG" 2>/dev/null
exec /bin/cp "$@"
EOF
    chmod +x "$RIP_SANDBOX/shim/cp"
    export PATH="$RIP_SANDBOX/shim:$PATH"
    export RIP_SHIM_DEST="$RIP_SANDBOX/staging"
    export RIP_SHIM_LOG="$RIP_SANDBOX/cp-shim.log"
    When run zsh "$FOLDER_BIN" acquire "$ROOT/Ann Leckie/Ancillary Justice" "$RIP_SANDBOX/staging" "Ann Leckie/Ancillary Justice"
    The status should equal 0
    The path "$RIP_SANDBOX/staging/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should be exist
    The result of function bonus_seen_under_dest should equal "0"
  End
End
