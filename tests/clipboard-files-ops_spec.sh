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
