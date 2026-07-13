# Tests for the clipboard-bridge dispatcher's O (declare-origin) op, spec §23:
# writes a hash-keyed current-origin state file the HS watcher consults.
Describe 'clipboard-bridge-dispatch: O declare-origin'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard"
    ORIGINFILE="$XDG_STATE_HOME/pick-clipboard/current-origin"
    REQ="$SHELLSPEC_TMPBASE/req"
    # frame: 'O' + BE32(len) + "TESTHOST\x1fhello"; payload len = 8+1+5 = 14 = 0x0e
    printf 'O\000\000\000\016TESTHOST\037hello' > "$REQ"
  }
  BeforeEach 'setup'

  # -f: skip ~/.zshenv et al. Without it, this repo's ~/.zshenv unconditionally
  # re-exports XDG_STATE_HOME (~/.config/zsh/environment.sh, no ${VAR:-default}
  # guard) and clobbers the sandbox override above before the dispatcher ever
  # sees it -- confirmed empirically: the unguarded invocation silently wrote
  # to the real $HOME/.local/state/pick-clipboard/current-origin instead of
  # the test tmpdir. The dispatcher itself is self-contained (own zmodload/
  # setopt), so -f changes nothing it depends on.
  It 'acknowledges with an O status byte'
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The status should be success
    The output should start with "O"
  End

  It 'writes the origin host as line 1'
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "O"
    The contents of file "$ORIGINFILE" should include "TESTHOST"
  End

  It 'writes sha256(text) as line 2'
    expected=$(printf 'hello' | shasum -a 256 | awk '{print $1}')
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "O"
    The contents of file "$ORIGINFILE" should include "$expected"
  End

  # A plain O must NOT set the one-shot suppress-echo flag (origin-file
  # line 4, files-yazi T11): text flows (nvim / pbcopy) NEED the watcher's
  # capture. Historically only the now-retired `N` push-manifest op (Fix A)
  # set it, because N inserted its own authoritative store row. Exactly 3
  # lines = the pre-existing format, nothing extra.
  It 'does not write the suppress-echo flag (exactly 3 lines)'
    When run command sh -c 'zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
    The output should start with "O"
    The contents of file "$ORIGINFILE" should not include "suppress-echo"
    lines=$(wc -l < "$ORIGINFILE" | tr -d ' ')
    The variable lines should equal 3
  End
End

# Tests for the S (get-current-ts) op, X9: the CURRENT clipboard's copy-time,
# so a consumer surfacing a peer's live clipboard as a synthetic row
# (pick-clipboard §22 live row) can sort it chronologically instead of always
# pinning it to the top. Seeds a temp SQLite store with the same schema
# clipboard-history.lua creates (same convention as
# tests/clipboard-files-ops_spec.sh's "L list-files" Describe) and stubs
# `pbpaste` on PATH (clip::op_get_ts reads the current clipboard the exact
# same way op_get does -- a bare `pbpaste`) so these tests never touch the
# real system pasteboard.
#
# Resolution is by TEXT CONTENT (the picker's §22.5 dedup query: rtrim
# char(10) on both sides, byte-safe via readfile), NOT by any hash -- so it
# matches a row the Hammerspoon watcher captured on the HOME machine, whose
# type_hash is computed over the sorted uti=blob SET (a different formula
# than op_persist's shasum) and would never hash-match. The
# 'watcher-captured row' test below is the case that a hash-based S got
# wrong (the whole reason for this rework).
#
# NOT exercised here: whether the OS pasteboard content a real `pbpaste`
# would return actually reflects a genuine user copy. That would require
# either mutating the real macOS pasteboard (intrusive -- this machine's
# actual clipboard is a shared resource the user cares about, and these
# tests run outside any sandbox for it) or a running Hammerspoon instance,
# neither appropriate for a headless spec run. Stubbing `pbpaste` instead
# exercises the exact same code path op_get_ts runs in production (shelling
# out to `pbpaste`, nothing pasteboard-API-specific) -- so the content-match
# resolution and both fallback tiers below are fully covered; only "does
# pbpaste's own output genuinely reflect the live pasteboard" is deferred/
# untested, and that's op_get's own well-established behavior, not new
# surface this op adds.
Describe 'clipboard-bridge-dispatch: S get-current-ts'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    # SHELLSPEC_TMPBASE is shared across every It in this file (not reset per-
    # example) -- same gotcha noted in tests/clipboard-files-ops_spec.sh, so
    # a stale db from a previous example must be cleared before CREATE TABLE.
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

    # Stub pbpaste: point it at a controlled fixture file instead of the real
    # pasteboard. PBPASTE_FIXTURE starts empty ("nothing on the clipboard"/
    # non-text current pasteboard); individual examples overwrite it.
    export PATH="$SHELLSPEC_TMPBASE/bin:$PATH"
    mkdir -p "$SHELLSPEC_TMPBASE/bin"
    PBPASTE_FIXTURE="$SHELLSPEC_TMPBASE/pbpaste-fixture"
    : > "$PBPASTE_FIXTURE"
    cat > "$SHELLSPEC_TMPBASE/bin/pbpaste" <<EOF
#!/bin/sh
cat "$PBPASTE_FIXTURE"
EOF
    chmod +x "$SHELLSPEC_TMPBASE/bin/pbpaste"

    REQ="$SHELLSPEC_TMPBASE/req"
    RESP="$SHELLSPEC_TMPBASE/resp"
    # S: opcode + BE32(0) + no payload (op_get_ts takes no request payload).
    printf 'S\000\000\000\000' > "$REQ"
  }
  BeforeEach 'setup'

  # -f: same ~/.zshenv guard noted above (skips it entirely, so the sandbox
  # XDG_STATE_HOME/XDG_DATA_HOME overrides and the stubbed PATH survive).
  # Response is a framed byte stream (1 status byte + BE32 length + payload);
  # the payload here is plain ASCII decimal digits, so a straight byte-offset
  # read (head -c1 / tail -c +6) is enough -- no US/NUL field decoding needed
  # (contrast tests/clipboard-files-ops_spec.sh's run_l, whose L payload has
  # embedded NULs and needs that extra care).
  run_s() {
    zsh -f "$DISPATCH" < "$REQ" > "$RESP" 2>/dev/null
    printf 'STATUS:%s\n' "$(head -c1 "$RESP")"
    tail -c +6 "$RESP"
  }

  # THE case a hash-based S got wrong: a row the HS watcher captured on the
  # HOME machine has its text in text_plain but a type_hash computed over the
  # sorted uti=blob SET -- deliberately NOT equal to shasum(text_plain). The
  # old S hashed the current clipboard with shasum and looked up type_hash,
  # so it never matched this row and fell through to MAX(last_ts) (~now,
  # inflated by an unrelated recent push) -- floating an old clip to the top.
  # Content match returns ITS real last_ts instead.
  It "returns a watcher-captured row's last_ts via content match (type_hash is an unrelated uti-set hash, never shasum(text))"
    printf '%s' 'hello world' > "$PBPASTE_FIXTURE"
    # A newer, unrelated row (an M-push, say) is what MAX(last_ts) would
    # wrongly return if the content match failed -- pin it far in the future.
    sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts, text_plain, type_hash) VALUES ('text', 999.9, 'something else entirely', 'unrelated-recent');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts, text_plain, type_hash) VALUES ('text', 111.5, 'hello world', 'uti-set-hash-not-shasum');"

    When call run_s
    The status should be success
    The output should include "STATUS:O"
    The output should include "111.5"
    The output should not include "999.9"
  End

  # Trailing-newline insensitivity (rtrim char(10) on both sides): op_get
  # (pbpaste) strips the trailing newline a stored copy keeps, so the current
  # clipboard text can differ from text_plain only by that newline and must
  # still match.
  It 'matches trailing-newline-insensitively (stored text_plain keeps a newline op_get stripped)'
    printf '%s' 'line one' > "$PBPASTE_FIXTURE"   # no trailing newline (as pbpaste returns)
    sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts, text_plain, type_hash) VALUES ('text', 123.5, 'line one' || char(10), 'x');"

    When call run_s
    The status should be success
    The output should include "STATUS:O"
    The output should include "123.5"
  End

  It 'returns the MOST RECENT last_ts when several rows share the current clipboard text'
    printf '%s' 'hello world' > "$PBPASTE_FIXTURE"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts, text_plain, type_hash) VALUES ('text', 111.5, 'hello world', 'a');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts, text_plain, type_hash) VALUES ('text', 222.75, 'hello world', 'b');"

    When call run_s
    The status should be success
    The output should include "STATUS:O"
    The output should include "222.75"
    The output should not include "111.5"
  End

  # Fallback tier 1 (dispatcher comment step 3): no stored row's text matches
  # the current clipboard (a just-copied text that hasn't round-tripped into
  # the store yet, or -- as here -- simply nothing matching) -- fall back to
  # the store's most-recent last_ts.
  It "falls back to the store's most recent last_ts when nothing matches the current clipboard's text"
    printf '%s' 'not in the store' > "$PBPASTE_FIXTURE"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts, text_plain, type_hash) VALUES ('text', 50, 'row a', 'deadbeef');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts, text_plain, type_hash) VALUES ('text', 300.25, 'row b', 'cafebabe');"

    When call run_s
    The status should be success
    The output should include "STATUS:O"
    The output should include "300.25"
  End

  # Fallback tier 2 (dispatcher comment step 5): store is completely empty --
  # nothing to fall back to at all, reply payload is empty (still status O).
  It 'returns empty when the store has no rows at all'
    printf '%s' 'anything' > "$PBPASTE_FIXTURE"

    When call run_s
    The status should be success
    expected=$(printf 'STATUS:O\n')
    The output should equal "$expected"
  End
End
