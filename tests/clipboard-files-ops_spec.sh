# Tests for the clipboard-bridge dispatcher's Phase 6 file ops (spec
# docs/superpowers/specs/2026-07-11-clipboard-phase6-files-yazi-design.md).
Describe 'clipboard-bridge-dispatch: U set-file-urls'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export CLIPBOARD_BRIDGE_ENDPOINT=trusted
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
    The contents of file "$SHELLSPEC_TMPBASE/hs-script" should not include "UntrustedFileURLs"
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

  It 'rejects U on the public endpoint'
    f1="$SHELLSPEC_TMPBASE/public.txt"; touch "$f1"
    len=${#f1}
    { printf 'U'; printf '\000\000\000'; printf "\\$(printf %03o "$len")"; printf '%s' "$f1"; } \
      > "$SHELLSPEC_TMPBASE/req"
    When run command sh -c 'CLIPBOARD_BRIDGE_ENDPOINT=public zsh -f "$1" < "$2"' _ "$DISPATCH" "$SHELLSPEC_TMPBASE/req"
    The output should start with "E"
    The output should include "trusted-endpoint-required"
  End

  It 'rejects a file-reference rich UTI on the public endpoint'
    printf 'C\000\000\000\025\000\017public.file-url/etc' > "$SHELLSPEC_TMPBASE/req"
    When run command sh -c 'CLIPBOARD_BRIDGE_ENDPOINT=public zsh -f "$1" < "$2"' _ "$DISPATCH" "$SHELLSPEC_TMPBASE/req"
    The output should start with "E"
    The output should include "rich type not allowed"
  End

  It 'keeps the supported public.png rich copy on the public endpoint'
    printf 'C\000\000\000\020\000\012public.pngDATA' > "$SHELLSPEC_TMPBASE/req"
    When run command sh -c 'CLIPBOARD_BRIDGE_ENDPOINT=public zsh -f "$1" < "$2"' _ "$DISPATCH" "$SHELLSPEC_TMPBASE/req"
    The output should start with "O"
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
    export CLIPBOARD_BRIDGE_ENDPOINT=public
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

  It 'K issues a 256-bit token for a trusted authority snapshot'
    zsh -f "$DISPATCH" --init-store >/dev/null
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','laptop',500.0); SELECT last_insert_rowid();")
    authorized="$SHELLSPEC_TMPBASE/authorized.txt"
    printf 'authorized\n' > "$authorized"
    pathfile="$SHELLSPEC_TMPBASE/k-path"
    printf '%s' "$authorized" > "$pathfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id,uti,blob) VALUES ($id,'x-resolved-path',readfile('$pathfile'));
      INSERT INTO file_authorities (clip_id,item_index,path) VALUES ($id,1,readfile('$pathfile'));"
    printf 'K\000\000\000\000' > "$REQ"
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    token=$(tail -c +6 "$RESP" | tr '\037' '\n' | sed -n '4p')
    token_len=${#token}
    grant_count=$(sqlite3 "$DB" "SELECT count(*) FROM file_grants WHERE token='$token';")
    When call printf '%s:%s' "$token_len" "$grant_count"
    The output should equal "64:1"
    The status should be success
  End

  It 'K returns no token for a pointer-only manifest'
    zsh -f "$DISPATCH" --init-store >/dev/null
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','peerbox',600.0); SELECT last_insert_rowid();")
    pathfile="$SHELLSPEC_TMPBASE/k-pointer"
    printf '/tmp/pointer.txt' > "$pathfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id,uti,blob) VALUES ($id,'x-file-manifest',readfile('$pathfile'));"
    printf 'K\000\000\000\000' > "$REQ"
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    token=$(tail -c +6 "$RESP" | tr '\037' '\n' | sed -n '4p')
    When call printf '%s' "$token"
    The output should equal "-"
    The status should be success
  End

  It 'keeps an issued snapshot usable after clipboard change and row retention'
    zsh -f "$DISPATCH" --init-store >/dev/null
    sourcefile="$SHELLSPEC_TMPBASE/granted-before-change.txt"
    printf 'snapshot bytes' > "$sourcefile"
    pathfile="$SHELLSPEC_TMPBASE/k-stable-path"
    printf '%s' "$sourcefile" > "$pathfile"
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','laptop',700.0); SELECT last_insert_rowid();")
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id,uti,blob) VALUES ($id,'x-resolved-path',readfile('$pathfile'));
      INSERT INTO file_authorities (clip_id,item_index,path) VALUES ($id,1,readfile('$pathfile'));"
    printf 'K\000\000\000\000' > "$REQ"
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    token=$(tail -c +6 "$RESP" | tr '\037' '\n' | sed -n '4p')
    sqlite3 "$DB" "DELETE FROM file_authorities WHERE clip_id=$id;
      DELETE FROM clip_types WHERE clip_id=$id;
      DELETE FROM clips WHERE id=$id;
      INSERT INTO clips (type_kind,source_host,last_ts,text_plain) VALUES ('text','laptop',800.0,'new clipboard');"
    printf 'f\000\000\000\102%s\0371' "$token" > "$REQ"
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    body=$(tail -c +6 "$RESP")
    When call printf '%s' "$body"
    The output should equal "snapshot bytes"
    The status should be success
  End
End

# M manifest-persist-local (X2-redo; Fix A -- see below): record-only, for
# pbcopy over SSH to persist a files row DIRECTLY to the store -- bypassing
# the Hammerspoon watcher entirely, since the origin machine is typically
# locked/headless when reached over SSH and the watcher's loginwindow guard
# then skips ALL capture (live-confirmed: a plain `U` set the pasteboard but
# no store row ever appeared). Row shape: type_kind='files', x-file-manifest
# blob, text_preview = newline-joined paths. M does ONLY the row-insert -- no
# pasteboard write, no declare-origin.
#
# Fix A: M used to be paired with a `N` push-manifest op that pbcopy sent to
# the PEER bridge -- N did the same row-insert but ALSO declared origin and
# set the peer's pasteboard to the paths as plain TEXT, which got reflected
# back and shown as a confusing "remote text" twin on the origin's own TUI
# picker (files are lazy, §12 -- the peer should only ever get a manifest
# pointer, never a live pasteboard write). N has been retired: pbcopy's SSH
# files branch sends this SAME `M` payload to the trusted local socket and
# public peer port. Endpoint identity now deliberately distinguishes them:
# only the trusted self-host form creates file authority.
Describe 'clipboard-bridge-dispatch: M manifest-persist-local'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export CLIPBOARD_BRIDGE_ENDPOINT=public
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    # clip::mount_enrich (clipboard-mount-enrich_spec.sh) now runs, backgrounded
    # + disowned, after every M reply -- harmless when $HOME/.local/libexec/
    # clipboard-mount is absent (its own guard exits 0 immediately), but on a
    # box where the real helper IS installed, a `check` miss for these fake
    # hosts ("thismac" etc.) would fall through to `ensure`, which shells out to
    # rclone/ssh against a host that doesn't exist -- a real, slow, network-
    # touching side effect this suite must never trigger. Pointing
    # CLIPBOARD_MOUNT_BIN at a path that can't exist makes clip::mount_enrich's
    # very first guard (`[[ -x "$cm" ]] || exit 0`) fire unconditionally,
    # independent of what's installed on the machine running the tests.
    export CLIPBOARD_MOUNT_BIN="$SHELLSPEC_TMPBASE/no-clipboard-mount-here"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_STATE_HOME/clipboard" "$XDG_DATA_HOME/pick-clipboard"
    rm -f "$XDG_STATE_HOME/clipboard/self-name"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
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

    # Fake pbcopy: if M ever invoked op T's pasteboard core, this would
    # capture stdin -- its ABSENCE is exactly how the tests below prove M
    # never touches the pasteboard (see the "does not touch the pasteboard"
    # example).
    export PATH="$SHELLSPEC_TMPBASE/bin:$PATH"
    mkdir -p "$SHELLSPEC_TMPBASE/bin"
    rm -f "$SHELLSPEC_TMPBASE/pbcopy-stdin"
    printf '#!/bin/sh\ncat > "%s"\n' "$SHELLSPEC_TMPBASE/pbcopy-stdin" \
      > "$SHELLSPEC_TMPBASE/bin/pbcopy"
    chmod +x "$SHELLSPEC_TMPBASE/bin/pbcopy"

    # Fake hs: if M ever ran a writeAllData/declare-origin Lua script through
    # Hammerspoon, this would record it -- its ABSENCE proves M never touches
    # the pasteboard via that path either. Same stub shape as the U describe
    # block at the top of this file.
    rm -f "$SHELLSPEC_TMPBASE/hs-script"
    printf '#!/bin/sh\ncat "$1" > "%s"\n' "$SHELLSPEC_TMPBASE/hs-script" \
      > "$SHELLSPEC_TMPBASE/bin/hs"
    chmod +x "$SHELLSPEC_TMPBASE/bin/hs"

    REQ="$SHELLSPEC_TMPBASE/m-req"
    RESP="$SHELLSPEC_TMPBASE/m-resp"
  }
  BeforeEach 'setup'

  # be32 <n> -- mirrors the dispatcher's own int_to_be32.
  be32() {
    n=$1
    printf "\\$(printf %03o $(( (n >> 24) & 255 )))\\$(printf %03o $(( (n >> 16) & 255 )))\\$(printf %03o $(( (n >> 8) & 255 )))\\$(printf %03o $(( n & 255 )))"
  }

  # build_req <host> <path> [<path> ...] -- writes a framed M request to $REQ.
  build_req() {
    _host=$1; shift
    _payfile="$SHELLSPEC_TMPBASE/m-payload"
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
    { printf 'M'; be32 "$_len"; cat "$_payfile"; } > "$REQ"
  }

  # -f: see the matching note on the U describe block above (skips
  # ~/.zshenv, which would clobber the sandbox XDG overrides).
  It 'acks O and inserts a files row + x-file-manifest blob, without touching the pasteboard'
    build_req thismac /tmp/local-a.txt /tmp/local-b.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"

    kind=$(sqlite3 "$DB" "SELECT type_kind FROM clips WHERE source_host='thismac';")
    The variable kind should equal "files"
    host=$(sqlite3 "$DB" "SELECT source_host FROM clips WHERE source_host='thismac';")
    The variable host should equal "thismac"
    preview=$(sqlite3 "$DB" "SELECT text_preview FROM clips WHERE source_host='thismac';")
    The variable preview should equal "$(printf '/tmp/local-a.txt\n/tmp/local-b.txt')"

    manifest_id=$(sqlite3 "$DB" "SELECT id FROM clips WHERE source_host='thismac';")
    manifestfile="$SHELLSPEC_TMPBASE/m-manifest-out"
    sqlite3 "$DB" "SELECT writefile('$manifestfile', blob) FROM clip_types WHERE clip_id=$manifest_id AND uti='x-file-manifest';" >/dev/null
    manifest_paths=$(tr '\000' '|' < "$manifestfile")
    The variable manifest_paths should equal "/tmp/local-a.txt|/tmp/local-b.txt"

    # The negative assertion this whole op exists for: no pasteboard write
    # happened (neither the plain-text pbcopy core nor a writeAllData hs
    # script) -- unlike the retired `N` push-manifest op, which used to do
    # both.
    The path "$SHELLSPEC_TMPBASE/pbcopy-stdin" should not be exist
    The path "$SHELLSPEC_TMPBASE/hs-script" should not be exist
  End

  It 'keeps a public M pointer-only with no file authority'
    build_req peerbox /tmp/public-pointer.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"
    authority_count=$(sqlite3 "$DB" "SELECT count(*) FROM file_authorities;")
    The variable authority_count should equal "0"
  End

  It 'authorizes a self-host M only on the trusted endpoint'
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf 'thismac\n' > "$XDG_STATE_HOME/clipboard/self-name"
    a="$SHELLSPEC_TMPBASE/trusted-a.txt"; printf 'a\n' > "$a"
    b="$SHELLSPEC_TMPBASE/trusted-b.txt"; printf 'b\n' > "$b"
    build_req thismac "$a" "$b"
    When run command sh -c 'CLIPBOARD_BRIDGE_ENDPOINT=trusted zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"
    authority_count=$(sqlite3 "$DB" "SELECT count(*) FROM file_authorities;")
    The variable authority_count should equal "2"
  End

  It 'rejects public M claiming this machine instead of reactivating authority'
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf 'thismac\n' > "$XDG_STATE_HOME/clipboard/self-name"
    p="$SHELLSPEC_TMPBASE/no-reactivate.txt"; printf 'safe\n' > "$p"
    build_req thismac "$p"
    CLIPBOARD_BRIDGE_ENDPOINT=trusted zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    frame_status=$(head -c 1 "$RESP")
    row_count=$(sqlite3 "$DB" "SELECT count(*) FROM clips WHERE source_host='thismac' AND type_kind='files';")
    When call printf '%s:%s' "$frame_status" "$row_count"
    The output should equal "E:1"
    The status should be success
  End

  It 'does not declare an origin file (no O-style provenance write)'
    originfile="$XDG_STATE_HOME/pick-clipboard/current-origin"
    rm -f "$originfile"
    build_req thismac /tmp/local-c.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"
    The path "$originfile" should not be exist
  End

  It 'errors on a malformed payload (missing US separator)'
    { printf 'M\000\000\000\010nohostie'; } > "$REQ"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End

  # DATA-2: a files-manifest row-write SQLite refuses (a read-only DB, or a
  # lock a concurrent BEGIN IMMEDIATE writer holds) used to report success --
  # the M reply was still O while the row, manifest blob, and authority never
  # landed. Bootstrap the full schema in an ISOLATED db (its own path, so
  # leaving it read-only can't contaminate a later example; the file-security
  # tables are created too, so ensure_file_security_schema's own CREATE IF NOT
  # EXISTS needs no write), then make the DB file read-only so the INSERT is
  # refused (rc 8) while reads still succeed; the M op must answer E, not O.
  It 'errors when the store write is refused (DATA-2)'
    RODB="$SHELLSPEC_TMPBASE/ro-manifest.db"
    sh -c 'PICK_CLIPBOARD_DB="$2" zsh -f "$1" --init-store' _ "$DISPATCH" "$RODB" >/dev/null
    chmod a-w "$RODB"
    build_req thismac /tmp/ro-manifest.txt
    When run command sh -c 'PICK_CLIPBOARD_DB="$3" zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ" "$RODB"
    The output should start with "E"
  End

  It 'errors on a malformed payload (empty host)'
    build_req "" /tmp/local-d.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End

  It 'errors on a malformed payload (relative path)'
    build_req thismac relative/path.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End

  It 'rejects an absolute path containing parent traversal'
    build_req thismac /tmp/../../../../etc/passwd
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "unsafe path"
  End

  # Kind-scoped dedup (X1 regression): a repeated M of the same host+paths
  # must not create a second files row.
  It 'dedups a repeated M of the same host+paths to a single files row'
    build_req dupsend /tmp/mdup-a.txt /tmp/mdup-b.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"

    build_req dupsend /tmp/mdup-a.txt /tmp/mdup-b.txt
    zsh -f "$DISPATCH" < "$REQ" > "$RESP" 2>/dev/null
    status2=$(head -c1 "$RESP")
    The variable status2 should equal "O"

    files_count=$(sqlite3 "$DB" "SELECT count(*) FROM clips WHERE source_host='dupsend' AND type_kind='files';")
    The variable files_count should equal "1"
  End

  # Kind-scoped dedup, the collision direction (X1 regression): M's dedup
  # must not bump an unrelated same-hash TEXT row's last_ts.
  It 'inserts a NEW files row (not bumping a same-hash TEXT row) when the joined paths collide with an old text clip'
    joined=$(printf '/tmp/mcollide-a.txt\n/tmp/mcollide-b.txt')
    collide_hash=$(printf '%s' "$joined" | shasum -a 256 | awk '{print $1}')
    text_id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, type_hash, last_ts, text_plain) \
      VALUES ('text','mcollidehost','$collide_hash',50.0,'$joined'); SELECT last_insert_rowid();")

    build_req mcollidehost /tmp/mcollide-a.txt /tmp/mcollide-b.txt
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"

    files_count=$(sqlite3 "$DB" "SELECT count(*) FROM clips WHERE source_host='mcollidehost' AND type_kind='files';")
    The variable files_count should equal "1"

    text_kind=$(sqlite3 "$DB" "SELECT type_kind FROM clips WHERE id=$text_id;")
    The variable text_kind should equal "text"
    text_ts=$(sqlite3 "$DB" "SELECT last_ts FROM clips WHERE id=$text_id;")
    The variable text_ts should equal "50.0"
  End
End

# P persist: the symmetric hazard to M above (X1 regression). op_persist's
# own dedup was keyed on the same (source_host, type_hash) shape with no
# type_kind filter -- a text payload arriving with a hash that happens to
# match an existing FILES row (e.g. an M-persisted manifest) would bump that
# files row's last_ts for what is really an unrelated text paste, instead of
# inserting its own text row. Confirms clip::op_persist's dedup query is
# scoped by type_kind exactly like clip::persist_files_manifest_row's is.
Describe 'clipboard-bridge-dispatch: P persist'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
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
    REQ="$SHELLSPEC_TMPBASE/p-req"
    RESP="$SHELLSPEC_TMPBASE/p-resp"
  }
  BeforeEach 'setup'

  # be32 <n> -- mirrors the dispatcher's own int_to_be32 (see the M describe
  # block above for the identical helper/rationale).
  be32() {
    n=$1
    printf "\\$(printf %03o $(( (n >> 24) & 255 )))\\$(printf %03o $(( (n >> 16) & 255 )))\\$(printf %03o $(( (n >> 8) & 255 )))\\$(printf %03o $(( n & 255 )))"
  }

  # build_req <host> <kind> <app> <regtype> <text> -- writes a framed P
  # request to $REQ. Payload shape (op_persist's header comment):
  #   source_host US kind US app US regtype RS text
  build_req() {
    _host=$1 _kind=$2 _app=$3 _regtype=$4 _text=$5
    _payfile="$SHELLSPEC_TMPBASE/p-payload"
    printf '%s\037%s\037%s\037%s\036%s' "$_host" "$_kind" "$_app" "$_regtype" "$_text" > "$_payfile"
    _len=$(wc -c < "$_payfile" | tr -d ' ')
    { printf 'P'; be32 "$_len"; cat "$_payfile"; } > "$REQ"
  }

  # -f: see the matching note on the U describe block above (skips
  # ~/.zshenv, which would clobber the sandbox XDG overrides).
  It 'inserts a NEW text row (not bumping a same-hash FILES row) when the text collides with an existing manifest hash'
    text="hello from a persisted paste"
    collide_hash=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
    files_id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, type_hash, last_ts) \
      VALUES ('files','pdup','$collide_hash',77.0); SELECT last_insert_rowid();")

    build_req pdup text someapp "" "$text"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"

    text_count=$(sqlite3 "$DB" "SELECT count(*) FROM clips WHERE source_host='pdup' AND type_kind='text';")
    The variable text_count should equal "1"
    text_plain=$(sqlite3 "$DB" "SELECT text_plain FROM clips WHERE source_host='pdup' AND type_kind='text';")
    The variable text_plain should equal "$text"

    files_kind=$(sqlite3 "$DB" "SELECT type_kind FROM clips WHERE id=$files_id;")
    The variable files_kind should equal "files"
    files_ts=$(sqlite3 "$DB" "SELECT last_ts FROM clips WHERE id=$files_id;")
    The variable files_ts should equal "77.0"

    total=$(sqlite3 "$DB" "SELECT count(*) FROM clips WHERE source_host='pdup';")
    The variable total should equal "2"
  End

  It 'rejects a file-kind P before it can reactivate an authoritative row'
    zsh -f "$DISPATCH" --init-store >/dev/null
    text="/tmp/authorized-again.txt"
    collide_hash=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
    files_id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind,source_host,type_hash,last_ts)
      VALUES ('files','pdup','$collide_hash',77.0); SELECT last_insert_rowid();")
    pathfile="$SHELLSPEC_TMPBASE/p-authority-path"
    printf '%s' "$text" > "$pathfile"
    sqlite3 "$DB" "INSERT INTO file_authorities (clip_id,item_index,path)
      VALUES ($files_id,1,readfile('$pathfile'));"
    build_req pdup files someapp "" "$text"
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "cannot persist file kinds"
    files_ts=$(sqlite3 "$DB" "SELECT last_ts FROM clips WHERE id=$files_id;")
    The variable files_ts should equal "77.0"
  End
End

# Capability-bound f/a replace raw-path F/A. f retains F's exact file framing
# and is-directory retry; a retains A's archive stream.
Describe 'clipboard-bridge-dispatch: capability-bound file streams'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"
  TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    rm -f "$DB"
    zsh -f "$DISPATCH" --init-store >/dev/null
    DIR="$SHELLSPEC_TMPBASE/archive-src"
    rm -rf "$DIR"
    mkdir -p "$DIR/sub"
    printf 'hello' > "$DIR/a.txt"
    printf 'world, this is a longer nested file body' > "$DIR/sub/b.txt"
    REQ="$SHELLSPEC_TMPBASE/a-req"
    RESP="$SHELLSPEC_TMPBASE/a-resp"
  }
  BeforeEach 'setup'

  grant_path() {
    _path=$1
    _pathfile="$SHELLSPEC_TMPBASE/grant-path"
    printf '%s' "$_path" > "$_pathfile"
    _now=$(date +%s)
    sqlite3 "$DB" "DELETE FROM file_grants;
      INSERT INTO file_grants
        (token,item_index,path,created_ts,last_used_ts,hard_expires_ts)
      VALUES ('$TOKEN',1,readfile('$_pathfile'),$_now,$_now,9999999999);"
  }

  be32() {
    n=$1
    printf "\\$(printf %03o $(( (n >> 24) & 255 )))\\$(printf %03o $(( (n >> 16) & 255 )))\\$(printf %03o $(( (n >> 8) & 255 )))\\$(printf %03o $(( n & 255 )))"
  }

  build_req() {
    _op=$1
    _index=${2:-1}
    _payload=$(printf '%s\037%s' "$TOKEN" "$_index")
    _len=${#_payload}
    { printf '%s' "$_op"; be32 "$_len"; printf '%s' "$_payload"; } > "$REQ"
  }

  It 'retires uppercase raw-path F and A'
    printf 'F\000\000\000\004/etc' > "$REQ"
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    fmsg=$(tail -c +6 "$RESP")
    printf 'A\000\000\000\004/etc' > "$REQ"
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    amsg=$(tail -c +6 "$RESP")
    When call printf '%s:%s' "$fmsg" "$amsg"
    The output should equal "capability-required; update pbpaste:capability-required; update pbpaste"
    The status should be success
  End

  It 'f errors is-directory for an authorized directory'
    grant_path "$DIR"
    build_req f
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should equal "$(printf 'E\000\000\000\014is-directory')"
  End

  It 'rejects an unknown capability without reading its payload as a path'
    build_req f
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "invalid or expired capability"
  End

  It 'does not follow an authorized top-level file symlink'
    printf 'safe target\n' > "$SHELLSPEC_TMPBASE/symlink-target.txt"
    ln -s "$SHELLSPEC_TMPBASE/symlink-target.txt" "$SHELLSPEC_TMPBASE/file-link"
    grant_path "$SHELLSPEC_TMPBASE/file-link"
    build_req f
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "unsupported-file-type"
  End

  It 'does not archive an authorized top-level directory symlink'
    ln -s "$DIR" "$SHELLSPEC_TMPBASE/dir-link"
    grant_path "$SHELLSPEC_TMPBASE/dir-link"
    build_req a
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "unsupported-file-type"
  End

  It 'rejects a valid token with an item index outside its grant'
    grant_path "$DIR/a.txt"
    build_req f 2
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "invalid or expired capability"
  End

  It 'rejects an idle-expired token'
    grant_path "$DIR/a.txt"
    sqlite3 "$DB" "UPDATE file_grants SET last_used_ts=0;"
    build_req f
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "invalid or expired capability"
  End

  It 'rejects a hard-expired token even when recently used'
    grant_path "$DIR/a.txt"
    sqlite3 "$DB" "UPDATE file_grants SET hard_expires_ts=0;"
    build_req f
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "invalid or expired capability"
  End

  It 'rejects a 4 GiB file instead of wrapping its length to zero'
    big="$SHELLSPEC_TMPBASE/exactly-4g.bin"
    dd if=/dev/null of="$big" bs=1 seek=4294967296 2>/dev/null
    grant_path "$big"
    build_req f
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "file-too-large"
  End

# a archive-stream: capability-authorized directory sibling of f.
# Reply on success: O + BE32 len=8 + BE64 total-byte-count -- a `du -sk`-
# based size ESTIMATE for progress display only, with NO directional
# guarantee (tar header/padding overhead and sparse files can push the real
# stream above OR below it -- empirically, this very fixture reports du 8192
# vs a 20480-byte real archive); see the header comment on
# clip::stream_archive_path.
# Then the raw `tar -cf -` stream of the directory until EOF, no trailing
# frame. Error frames (bad path, unreadable entries) look exactly like any
# other op's E frame and arrive BEFORE any stream bytes.
  # be_n_to_int <byte-offset> <nbytes> -- decodes the big-endian integer at
  # that offset in $RESP (byte-exact via `od`, no `$(<file)` truncation risk
  # since these offsets never straddle a NUL -- length/count headers only).
  be_n_to_int() {
    dd if="$RESP" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -tu1 | tr -s ' \n' ' ' | \
      awk '{s=0; for (i=1;i<=NF;i++) if ($i!="") s=s*256+$i; print s}'
  }

  # -f: see the matching note on the U describe block above.
  It 'replies O + BE32(8) + a sane BE64 estimate, then a tar stream of the seeded dir'
    grant_path "$DIR"
    build_req a
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
    grant_path "$DIR"
    build_req a
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "E"
    The output should include "unreadable-entries"
    The output should include "$DIR/sub/b.txt"
  End

  It 'errors unreadable-entries when a nested DIRECTORY is untraversable'
    chmod 000 "$DIR/sub"
    grant_path "$DIR"
    build_req a
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    # Restore before assertions so the next example's setup() can rm -rf it.
    chmod 755 "$DIR/sub"
    The status should be success
    The output should start with "E"
    The output should include "unreadable-entries"
    The output should include "$DIR/sub"
  End

  It 'errors on a nonexistent path'
    grant_path "$SHELLSPEC_TMPBASE/does-not-exist-at-all"
    build_req a
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End

  It 'errors on a FILE path (not a directory)'
    f="$SHELLSPEC_TMPBASE/a-plain-file.txt"
    printf 'just a file' > "$f"
    grant_path "$f"
    build_req a
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
    The output should include "not a directory"
  End

  It 'errors on a relative path'
    grant_path "relative/dir"
    build_req a
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "E"
  End
End
