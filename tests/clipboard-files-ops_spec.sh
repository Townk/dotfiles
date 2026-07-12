# Tests for the clipboard-bridge dispatcher's Phase 6 file ops (spec
# docs/superpowers/specs/2026-07-11-clipboard-phase6-files-yazi-design.md).
Describe 'clipboard-bridge-dispatch: U set-file-urls'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    # Stub hs: the real one needs a running Hammerspoon. clip::hs_run invokes
    # it as `timeout 10 hs "$script"` (a single positional arg, no leading
    # flag -- confirmed by reading the dispatcher's clip::hs_run), so the
    # stub's own $1 is the generated script path. Record it verbatim so
    # assertions below can inspect the generated Lua.
    export PATH="$SHELLSPEC_TMPBASE/bin:$PATH"
    mkdir -p "$SHELLSPEC_TMPBASE/bin"
    printf '#!/bin/sh\ncat "$1" > "%s"\n' "$SHELLSPEC_TMPBASE/hs-script" \
      > "$SHELLSPEC_TMPBASE/bin/hs"
    chmod +x "$SHELLSPEC_TMPBASE/bin/hs"
  }
  BeforeEach 'setup'

  # -f: skip ~/.zshenv et al. Without it, this repo's ~/.zshenv unconditionally
  # re-exports XDG_STATE_HOME (~/.config/zsh/environment.sh, no ${VAR:-default}
  # guard) and clobbers the sandbox override above before the dispatcher ever
  # sees it -- confirmed empirically: the unguarded invocation silently wrote
  # to the real $HOME/.local/state/pick-clipboard/current-origin instead of
  # the test tmpdir. The dispatcher itself is self-contained (own zmodload/
  # setopt), so -f changes nothing it depends on.
  It 'acks payload form A (NUL-joined paths) and generates a writeAllData script'
    f1="$SHELLSPEC_TMPBASE/a.txt"; touch "$f1"
    payload=$(printf '%s' "$f1")
    len=${#payload}
    { printf 'U'; printf '\000\000\000'; printf "\\$(printf %03o "$len")"; printf '%s' "$payload"; } \
      > "$SHELLSPEC_TMPBASE/req"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$SHELLSPEC_TMPBASE/req"
    The status should be success
    The output should start with "O"
    The contents of file "$SHELLSPEC_TMPBASE/hs-script" should include "NSFilenamesPboardType"
    The contents of file "$SHELLSPEC_TMPBASE/hs-script" should include "public.file-url"
  End

  It 'rejects a relative path'
    { printf 'U\000\000\000\007not/abs'; } > "$SHELLSPEC_TMPBASE/req"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$SHELLSPEC_TMPBASE/req"
    The output should start with "E"
  End

  It 'routes id:<n> payloads to restore_by_id'
    { printf 'U\000\000\000\004id:7'; } > "$SHELLSPEC_TMPBASE/req"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$SHELLSPEC_TMPBASE/req"
    The output should start with "O"
    The contents of file "$SHELLSPEC_TMPBASE/hs-script" should include "restore_by_id(7)"
  End
End

# L list-files: resolves the manifest of the current clipboard entry through
# the store's latest row (files-yazi design §4). Seeds a temp SQLite store
# directly with the same schema clipboard-history.lua creates (CREATE TABLE
# statements at ~clipboard-history.lua:275-295) -- these tests never touch
# the real Hammerspoon watcher or a live pasteboard.
Describe 'clipboard-bridge-dispatch: L list-files'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    # SHELLSPEC_TMPBASE is shared across every It in this file (not reset
    # per-example), so a stale db from a previous example's setup() must be
    # cleared before CREATE TABLE -- otherwise "table clips already exists"
    # on the 2nd+ example, and worse, its leftover rows would silently
    # become the "latest row" for later tests.
    rm -f "$DB"
    sqlite3 "$DB" '
      CREATE TABLE clips (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text_preview TEXT,
        text_plain TEXT,
        len INTEGER,
        first_ts REAL,
        last_ts REAL,
        source_app TEXT,
        source_bundle_id TEXT,
        type_kind TEXT,
        regtype TEXT,
        pinned INTEGER DEFAULT 0,
        type_hash TEXT,
        source_host TEXT
      );
      CREATE TABLE clip_types (
        clip_id INTEGER,
        uti TEXT,
        blob BLOB,
        PRIMARY KEY (clip_id, uti)
      );
    '
    REQ="$SHELLSPEC_TMPBASE/req"
    RESP="$SHELLSPEC_TMPBASE/resp"
    # L: opcode + BE32(0) + no payload.
    printf 'L\000\000\000\000' > "$REQ"
  }
  BeforeEach 'setup'

  # -f: see the matching note above (skips ~/.zshenv, which unconditionally
  # re-exports XDG_STATE_HOME/XDG_DATA_HOME and would clobber the sandbox
  # overrides before the dispatcher ever sees them).
  #
  # The response is a framed byte stream (1 status byte + BE32 length +
  # payload); the reply payload itself is US(\037)-joined fields whose last
  # field may be a NUL-joined path LIST (multiple files). Converting both
  # \037 and \000 to newlines up front -- inside the same pipeline that reads
  # the raw response file, BEFORE anything crosses shellspec's own output
  # capture -- means no embedded NUL ever reaches a `$(...)` boundary (which
  # would silently truncate it). What lands in `The output` is plain text:
  # one field/path per line, plus a synthetic STATUS: line for the status
  # byte (safe on its own since it's a lone 'O'/'E' character).
  run_l() {
    zsh -f "$DISPATCH" < "$REQ" > "$RESP" 2>/dev/null
    printf 'STATUS:%s\n' "$(head -c1 "$RESP")"
    tail -c +6 "$RESP" | tr '\037\000' '\n\n'
  }

  # Raw variant for the exact-format test: emits the reply payload with
  # every \037 field separator rendered as a visible `<US>` token (1:1, so
  # the assertion still pins the exact byte positions -- a transposed or
  # missing field still fails). NOT left as raw \037 bytes: shellspec uses
  # US as its own internal field separator, and letting it cross the
  # capture leaks `(eval): ... field_...` noise from its reporter --
  # observed empirically. Substring checks alone would pass with kind/host
  # transposed; the reply format is a cross-task contract parsed
  # positionally by `pbpaste --manifest` (T4), so one test must pin the
  # exact order.
  run_l_raw() {
    zsh -f "$DISPATCH" < "$REQ" > "$RESP" 2>/dev/null
    printf 'STATUS:%s\n' "$(head -c1 "$RESP")"
    tail -c +6 "$RESP" | sed $'s/\037/<US>/g'
  }

  It 'resolves a single file via x-resolved-path (type_kind=file)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','laptop',100.5); SELECT last_insert_rowid();")
    pathfile="$SHELLSPEC_TMPBASE/resolved-path"
    printf '%s' "/tmp/single-file.txt" > "$pathfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-resolved-path', readfile('$pathfile'));"

    When call run_l
    The status should be success
    The output should include "STATUS:O"
    The output should include "file"
    The output should include "laptop"
    The output should include "/tmp/single-file.txt"
  End

  It 'emits the exact positional reply format kind US host US ts US paths'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','laptop',100.5); SELECT last_insert_rowid();")
    pathfile="$SHELLSPEC_TMPBASE/resolved-path"
    printf '%s' "/tmp/single-file.txt" > "$pathfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-resolved-path', readfile('$pathfile'));"
    expected=$(printf 'STATUS:O\nfile<US>laptop<US>100.5<US>/tmp/single-file.txt')

    When call run_l_raw
    The status should be success
    The output should equal "$expected"
  End

  It 'resolves two files via a real NSFilenamesPboardType XML plist (type_kind=files)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','laptop',200.25); SELECT last_insert_rowid();")
    plistfile="$SHELLSPEC_TMPBASE/filenames.plist"
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      printf '<plist version="1.0"><array>\n'
      printf '<string>/tmp/pboard-a.txt</string>\n'
      printf '<string>/tmp/pboard-b.txt</string>\n'
      printf '</array></plist>\n'
    } > "$plistfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'NSFilenamesPboardType', readfile('$plistfile'));"

    When call run_l
    The status should be success
    The output should include "STATUS:O"
    The output should include "files"
    The output should include "laptop"
    The output should include "/tmp/pboard-a.txt"
    The output should include "/tmp/pboard-b.txt"
  End

  # Regression: a path literally ending in `"` in NON-terminal array
  # position. plutil emits `"\/tmp\/quoted\"","..."` -- the parser's split
  # on the `",` boundary consumes the element's real closing quote, so a
  # per-element trailing-quote strip then ate the second half of the escaped
  # `\"` (content!), yielding `/tmp/quoted\` (stray backslash) instead of
  # `/tmp/quoted"`. Exact-equality assertion: silently-wrong path bytes are
  # the failure mode, substring checks could miss a mangled variant.
  It 'preserves a path ending in a literal quote (non-terminal plist element)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','laptop',250.5); SELECT last_insert_rowid();")
    plistfile="$SHELLSPEC_TMPBASE/quoted.plist"
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      printf '<plist version="1.0"><array>\n'
      printf '<string>/tmp/quoted"</string>\n'
      printf '<string>/tmp/plain.txt</string>\n'
      printf '</array></plist>\n'
    } > "$plistfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'NSFilenamesPboardType', readfile('$plistfile'));"
    expected=$(printf 'STATUS:O\nfiles\nlaptop\n250.5\n/tmp/quoted"\n/tmp/plain.txt')

    When call run_l
    The status should be success
    The output should equal "$expected"
  End

  It 'emits an x-file-manifest blob as-is, NUL-joined (type_kind=files, remote source_host)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',300.75); SELECT last_insert_rowid();")
    manifestfile="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s\000%s' "/tmp/dev-a.txt" "/tmp/dev-b.txt" > "$manifestfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$manifestfile'));"

    When call run_l
    The status should be success
    The output should include "STATUS:O"
    The output should include "files"
    The output should include "devbox"
    The output should include "/tmp/dev-a.txt"
    The output should include "/tmp/dev-b.txt"
  End

  # Regression: the HS watcher's classify_file_or_directory() only ever
  # inspects pasteboard item 1 (clipboard-history.lua ~L206-224), so a
  # genuine multi-file local capture (Finder multi-select, yazi multi-yank,
  # `pbcopy a b c`) still gets an x-resolved-path blob holding just the
  # FIRST of the N paths -- even though the SAME capture's
  # NSFilenamesPboardType blob (set once, on item 1, as the full array)
  # already carries all of them, and even though the refined kind often
  # lands as the singular 'file' (a pre-existing, unrelated mislabel --
  # unchanged here). Seeding BOTH blobs on one row, exactly as the watcher
  # produces for a real multi-file capture: L must resolve every path via
  # NSFilenamesPboardType, not silently truncate to the x-resolved-path
  # blob's single entry.
  It 'resolves ALL paths of a multi-file local clip (NSFilenamesPboardType over a single-path x-resolved-path)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','laptop',260.0); SELECT last_insert_rowid();")
    plistfile="$SHELLSPEC_TMPBASE/multi-filenames.plist"
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      printf '<plist version="1.0"><array>\n'
      printf '<string>/tmp/multi-a.txt</string>\n'
      printf '<string>/tmp/multi-b.txt</string>\n'
      printf '<string>/tmp/multi-c.txt</string>\n'
      printf '</array></plist>\n'
    } > "$plistfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'NSFilenamesPboardType', readfile('$plistfile'));"
    resolvedfile="$SHELLSPEC_TMPBASE/multi-resolved-path"
    printf '%s' "/tmp/multi-a.txt" > "$resolvedfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-resolved-path', readfile('$resolvedfile'));"

    When call run_l
    The status should be success
    The output should include "STATUS:O"
    The output should include "/tmp/multi-a.txt"
    The output should include "/tmp/multi-b.txt"
    The output should include "/tmp/multi-c.txt"
  End

  It 'errors not-files when the latest row is a plain text clip'
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','laptop',400.0,'hello');"

    When call run_l
    The status should be success
    The output should include "STATUS:E"
    The output should include "not-files"
  End

  It 'errors empty-store when the clips table has no rows'
    When call run_l
    The status should be success
    The output should include "STATUS:E"
    The output should include "empty-store"
  End
End

# N push-manifest: the cross-machine sibling of U (files-yazi design §5,
# T11). A machine SSH'd in, with the reverse bridge up, sends this instead of
# writing the pasteboard directly. Declares origin + sets the pasteboard text
# (reusing O's/T's cores) AND inserts a `files` row carrying the real
# x-file-manifest blob, so a later `L` resolves it instead of whatever the HS
# watcher's own capture of that text echo would have stamped.
Describe 'clipboard-bridge-dispatch: N push-manifest'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    # SHELLSPEC_TMPBASE is shared across every It in this file -- see the
    # matching note on the L describe block above.
    rm -f "$DB"
    sqlite3 "$DB" '
      CREATE TABLE clips (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text_preview TEXT,
        text_plain TEXT,
        len INTEGER,
        first_ts REAL,
        last_ts REAL,
        source_app TEXT,
        source_bundle_id TEXT,
        type_kind TEXT,
        regtype TEXT,
        pinned INTEGER DEFAULT 0,
        type_hash TEXT,
        source_host TEXT
      );
      CREATE TABLE clip_types (
        clip_id INTEGER,
        uti TEXT,
        blob BLOB,
        PRIMARY KEY (clip_id, uti)
      );
    '
    # A pre-existing row with an old last_ts -- stands in for whatever the HS
    # watcher's own capture of a PRIOR clip already stamped, so the "strictly
    # greater" assertion below has a concrete timestamp to beat.
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('text','laptop',1.0);"

    # Fake pbcopy: op N's pasteboard write reuses op T's core
    # (clip::set_pasteboard_core), which pipes the text through the bare
    # `pbcopy` command -- capture stdin here instead of touching the real
    # system clipboard (this dispatcher's own env has only PATH set, so the
    # unqualified `pbcopy` call resolves through whatever we put on PATH).
    export PATH="$SHELLSPEC_TMPBASE/bin:$PATH"
    mkdir -p "$SHELLSPEC_TMPBASE/bin"
    printf '#!/bin/sh\ncat > "%s"\n' "$SHELLSPEC_TMPBASE/pbcopy-stdin" \
      > "$SHELLSPEC_TMPBASE/bin/pbcopy"
    chmod +x "$SHELLSPEC_TMPBASE/bin/pbcopy"

    REQ="$SHELLSPEC_TMPBASE/n-req"
    RESP="$SHELLSPEC_TMPBASE/n-resp"
  }
  BeforeEach 'setup'

  # be32 <n> -- prints the 4-byte big-endian encoding of $n, mirroring the
  # dispatcher's own int_to_be32 (needed here since the N payload -- host +
  # multiple paths -- can exceed the single literal-octal-byte length these
  # tests use elsewhere for short U/O payloads).
  be32() {
    n=$1
    printf "\\$(printf %03o $(( (n >> 24) & 255 )))\\$(printf %03o $(( (n >> 16) & 255 )))\\$(printf %03o $(( (n >> 8) & 255 )))\\$(printf %03o $(( n & 255 )))"
  }

  # build_req <host> <path> [<path> ...] -- writes a framed N request to $REQ.
  build_req() {
    _host=$1; shift
    _payfile="$SHELLSPEC_TMPBASE/n-payload"
    printf '%s\037' "$_host" > "$_payfile"
    _first=1
    for _p in "$@"; do
      if [ "$_first" -eq 1 ]; then
        printf '%s' "$_p" >> "$_payfile"
        _first=0
      else
        printf '\000%s' "$_p" >> "$_payfile"
      fi
    done
    _len=$(wc -c < "$_payfile" | tr -d ' ')
    { printf 'N'; be32 "$_len"; cat "$_payfile"; } > "$REQ"
  }

  # -f: see the matching note on the U describe block above (skips
  # ~/.zshenv, which would clobber the sandbox XDG overrides).
  It 'acks O, sets the pasteboard text, and inserts a files row + x-file-manifest blob'
    build_req devbox /tmp/remote-a.txt /tmp/remote-b.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"

    pbcopy_stdin=$(cat "$SHELLSPEC_TMPBASE/pbcopy-stdin")
    The variable pbcopy_stdin should equal "$(printf '/tmp/remote-a.txt\n/tmp/remote-b.txt')"

    kind=$(sqlite3 "$DB" "SELECT type_kind FROM clips WHERE source_host='devbox';")
    The variable kind should equal "files"
    host=$(sqlite3 "$DB" "SELECT source_host FROM clips WHERE source_host='devbox';")
    The variable host should equal "devbox"
    preview=$(sqlite3 "$DB" "SELECT text_preview FROM clips WHERE source_host='devbox';")
    The variable preview should equal "$(printf '/tmp/remote-a.txt\n/tmp/remote-b.txt')"

    manifest_id=$(sqlite3 "$DB" "SELECT id FROM clips WHERE source_host='devbox';")
    manifestfile="$SHELLSPEC_TMPBASE/n-manifest-out"
    sqlite3 "$DB" "SELECT writefile('$manifestfile', blob) FROM clip_types WHERE clip_id=$manifest_id AND uti='x-file-manifest';" >/dev/null
    manifest_paths=$(tr '\000' '|' < "$manifestfile")
    The variable manifest_paths should equal "/tmp/remote-a.txt|/tmp/remote-b.txt"
  End

  It 'stamps last_ts strictly greater than a pre-existing row'
    build_req devbox /tmp/remote-c.txt
    prior_ts=$(sqlite3 "$DB" "SELECT last_ts FROM clips WHERE source_host='laptop';")
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"
    new_ts=$(sqlite3 "$DB" "SELECT last_ts FROM clips WHERE source_host='devbox';")
    is_greater=$(awk -v a="$new_ts" -v b="$prior_ts" 'BEGIN { print (a > b) ? "yes" : "no" }')
    The variable is_greater should equal "yes"
  End

  It 'errors on a malformed payload (missing US separator)'
    { printf 'N\000\000\000\010nohostie'; } > "$REQ"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End

  It 'errors on a malformed payload (empty host)'
    build_req "" /tmp/remote-d.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End

  It 'errors on a malformed payload (relative path)'
    build_req devbox relative/path.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End

  # Echo suppression (reviewer-confirmed fix): the HS watcher independently
  # captures N's own pasteboard text write ~0.5s later, under a DIFFERENT
  # type_hash formula (sha256 of the UTI=blob pairs vs the dispatcher's
  # sha256 of the text -- never dedups), landing a phantom text row NEWER
  # than the manifest. So N's origin declaration must carry the one-shot
  # suppress-echo flag (origin-file line 4) that captured_origin()/
  # capture_now() in clipboard-history.lua consume to skip exactly that one
  # capture. Lines 1-3 stay the pre-existing O format (host / sha256(text) /
  # epoch), so the provenance mechanics are byte-identical to a plain O.
  It 'declares origin with the one-shot suppress-echo flag (line 4)'
    build_req devbox /tmp/remote-e.txt /tmp/remote-f.txt
    originfile="$XDG_STATE_HOME/pick-clipboard/current-origin"
    expected_hash=$(printf '/tmp/remote-e.txt\n/tmp/remote-f.txt' | shasum -a 256 | awk '{print $1}')
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"
    The line 1 of contents of file "$originfile" should equal "devbox"
    The line 2 of contents of file "$originfile" should equal "$expected_hash"
    The line 4 of contents of file "$originfile" should equal "suppress-echo"
  End
End

# F fetch-file: M3 extends the existing raw-bytes op with one new error case
# -- handed a DIRECTORY it must reply `E is-directory` (exact string, not
# just "starts with E") rather than trying to `wc -c`/stream a directory as
# if it were a file. Task 13's remote pbpaste greps for this exact string to
# decide "retry this path as an A archive-stream instead" (files-yazi design
# §4/§8) -- a looser string would silently break that retry.
Describe 'clipboard-bridge-dispatch: F fetch-file'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
  }
  BeforeEach 'setup'

  It 'errors is-directory when handed a directory path'
    dir="$SHELLSPEC_TMPBASE/f-is-a-dir"
    mkdir -p "$dir"
    payload=$(printf '%s' "$dir")
    len=${#payload}
    { printf 'F'; printf '\000\000\000'; printf "\\$(printf %03o "$len")"; printf '%s' "$payload"; } \
      > "$SHELLSPEC_TMPBASE/f-req"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$SHELLSPEC_TMPBASE/f-req"
    The status should be success
    The output should equal "$(printf 'E\000\000\000\014is-directory')"
  End
End

# A archive-stream: M3's directory-pull sibling of F (files-yazi design §4).
# Reply on success: O + BE32 len=8 + BE64 total-byte-count -- a `du -sk`-
# based size ESTIMATE for progress display only, with NO directional
# guarantee (tar header/padding overhead and sparse files can push the real
# stream above OR below it -- empirically, this very fixture reports du 8192
# vs a 20480-byte real archive); see the header comment on
# clip::op_archive_stream.
# Then the raw `tar -cf -` stream of the directory until EOF, no trailing
# frame. Error frames (bad path, unreadable entries) look exactly like any
# other op's E frame and arrive BEFORE any stream bytes.
Describe 'clipboard-bridge-dispatch: A archive-stream'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    DIR="$SHELLSPEC_TMPBASE/archive-src"
    rm -rf "$DIR"
    mkdir -p "$DIR/sub"
    printf 'hello' > "$DIR/a.txt"
    printf 'world, this is a longer nested file body' > "$DIR/sub/b.txt"
    REQ="$SHELLSPEC_TMPBASE/a-req"
    RESP="$SHELLSPEC_TMPBASE/a-resp"
  }
  BeforeEach 'setup'

  # be32 <n> -- mirrors the dispatcher's own int_to_be32 (see the N describe
  # block above for the identical helper/rationale).
  be32() {
    n=$1
    printf "\\$(printf %03o $(( (n >> 24) & 255 )))\\$(printf %03o $(( (n >> 16) & 255 )))\\$(printf %03o $(( (n >> 8) & 255 )))\\$(printf %03o $(( n & 255 )))"
  }

  build_req() {
    _path=$1
    _len=${#_path}
    { printf 'A'; be32 "$_len"; printf '%s' "$_path"; } > "$REQ"
  }

  # be_n_to_int <byte-offset> <nbytes> -- decodes the big-endian integer at
  # that offset in $RESP (byte-exact via `od`, no `$(<file)` truncation risk
  # since these offsets never straddle a NUL -- length/count headers only).
  be_n_to_int() {
    dd if="$RESP" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -tu1 | tr -s ' \n' ' ' | \
      awk '{s=0; for (i=1;i<=NF;i++) if ($i!="") s=s*256+$i; print s}'
  }

  # -f: see the matching note on the U describe block above.
  It 'replies O + BE32(8) + a sane BE64 estimate, then a tar stream of the seeded dir'
    build_req "$DIR"
    When run command sh -c 'zsh -f "$1" < "$2" > "$3"' _ "$DISPATCH" "$REQ" "$RESP"
    The status should be success

    status_byte=$(head -c1 "$RESP")
    The variable status_byte should equal "O"

    hdr_len=$(be_n_to_int 1 4)
    The variable hdr_len should equal "8"

    # The BE64 is an ESTIMATE with no directional guarantee -- so the honest
    # assertion is a sanity band against the REAL archive byte count (the
    # response tail we actually received), not a fake ceiling. Asserting
    # against a second `du -sk` call would be tautological (comparing du to
    # itself can never fail); asserting `>= real` would pin a ceiling the op
    # does not promise. Band: both > 0, estimate <= 2x real, and real <=
    # 2x estimate + 10240 -- the additive term is bsdtar's fixed blocking-
    # factor padding (every archive is padded to a 10 KiB multiple), which
    # dominates on a deliberately tiny fixture like this one (measured here:
    # du 8192 vs real 20480) but is constant noise at real sizes.
    reported_bytes=$(be_n_to_int 5 8)
    tail -c +14 "$RESP" > "$SHELLSPEC_TMPBASE/a-tar"
    real_bytes=$(wc -c < "$SHELLSPEC_TMPBASE/a-tar" | tr -d ' ')
    in_band=$(awk -v r="$reported_bytes" -v a="$real_bytes" \
      'BEGIN { print (r > 0 && a > 0 && r <= 2*a && a <= 2*r + 10240) ? "yes" : "no" }')
    The variable in_band should equal "yes"

    tar_list=$(tar -tf "$SHELLSPEC_TMPBASE/a-tar" | sort)
    The variable tar_list should include "archive-src/a.txt"
    The variable tar_list should include "archive-src/sub/b.txt"
  End

  # Pre-flight readability: a nested entry tar cannot read would otherwise
  # surface only as a MID-STREAM tar failure -- the O header and partial
  # stream are already out, so the client sees a clean EOF and silently
  # accepts a truncated archive. The op must catch the common trigger
  # (permission-denied entries) UP FRONT, where a real E frame is still
  # possible, before any stream byte.
  It 'errors unreadable-entries BEFORE any stream bytes when a nested file is unreadable'
    chmod 000 "$DIR/sub/b.txt"
    build_req "$DIR"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "E"
    The output should include "unreadable-entries"
    The output should include "$DIR/sub/b.txt"
  End

  It 'errors unreadable-entries when a nested DIRECTORY is untraversable'
    chmod 000 "$DIR/sub"
    build_req "$DIR"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    # Restore before assertions so the next example's setup() can rm -rf it.
    chmod 755 "$DIR/sub"
    The status should be success
    The output should start with "E"
    The output should include "unreadable-entries"
    The output should include "$DIR/sub"
  End

  It 'errors on a nonexistent path'
    build_req "$SHELLSPEC_TMPBASE/does-not-exist-at-all"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End

  It 'errors on a FILE path (not a directory)'
    f="$SHELLSPEC_TMPBASE/a-plain-file.txt"
    printf 'just a file' > "$f"
    build_req "$f"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "not a directory"
  End

  It 'errors on a relative path'
    build_req "relative/dir"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End
End
