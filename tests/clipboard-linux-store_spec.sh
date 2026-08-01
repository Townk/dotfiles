# Tests for the Phase 7 linux-headless store backend + the portable core
# helpers (spec 2026-07-14 §2–§3). Everything runs against a temp DB with
# CLIPBOARD_PLATFORM forced, so no test touches the real store or pasteboard.
Describe 'clipboard-store-core: portable helpers'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"
  CORE="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/clipboard-store-core.zsh"

  setup() {
    export CLIPBOARD_BRIDGE_ENDPOINT=trusted
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    export PICK_CLIPBOARD_DB="$SHELLSPEC_TMPBASE/store/history.db"
    mkdir -p "$XDG_STATE_HOME/clipboard" "$SHELLSPEC_TMPBASE/store"
    # local_options nullglob: this setup runs under shellspec's zsh (see
    # .shellspec's --shell zsh), where an unmatched glob is a hard error
    # (NOMATCH) by default -- and on the FIRST run of any test here (or any
    # test before --init-store has created the DB) "$PICK_CLIPBOARD_DB"* has
    # nothing to match yet. nullglob makes a no-match glob expand to nothing
    # instead, scoped to this function only.
    setopt local_options nullglob
    rm -f "$PICK_CLIPBOARD_DB"*
  }
  BeforeEach 'setup'

  # -f skips ~/.zshenv (would clobber the XDG sandbox overrides -- same
  # empirically-confirmed reason as tests/clipboard-bridge_spec.sh).
  It 'clip::sha256 matches shasum -a 256'
    expected=$(printf 'hello' | shasum -a 256 | awk '{print $1}')
    When run command sh -c 'printf hello | zsh -f -c "source \"$1\"; clip::sha256"' _ "$CORE"
    The output should equal "$expected"
  End

  It 'clip::self_host prefers a valid self-name file'
    printf 'cruise-box' > "$XDG_STATE_HOME/clipboard/self-name"
    When run command sh -c 'zsh -f -c "source \"$1\"; clip::self_host"' _ "$CORE"
    The output should equal "cruise-box"
  End

  It 'clip::self_host rejects a garbage self-name first line'
    printf -- '-bad;name\n' > "$XDG_STATE_HOME/clipboard/self-name"
    When run command sh -c 'zsh -f -c "source \"$1\"; clip::self_host"' _ "$CORE"
    The output should not equal "-bad;name"
    The output should not equal ""
  End

  It '--init-store creates the schema'
    When run command sh -c 'CLIPBOARD_PLATFORM=linux-headless zsh -f "$1" --init-store' _ "$DISPATCH"
    The status should be success
    result=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
    The variable result should include "clip_types"
    The variable result should include "clips"
    The variable result should include "file_authorities"
    The variable result should include "file_grants"
  End

  It '--init-store is idempotent'
    When run command sh -c 'CLIPBOARD_PLATFORM=linux-headless zsh -f "$1" --init-store && zsh -f "$1" --init-store' _ "$DISPATCH"
    The status should be success
  End
End

Describe 'clipboard-bridge-dispatch: linux-headless text ops'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export PICK_CLIPBOARD_DB="$SHELLSPEC_TMPBASE/store/history.db"
    mkdir -p "$XDG_STATE_HOME/clipboard" "$SHELLSPEC_TMPBASE/store"
    # local_options nullglob: same NOMATCH gotcha as the portable-helpers
    # Describe above (Task 2) -- on the first run of any example here
    # "$PICK_CLIPBOARD_DB"* has nothing to match yet, which is a hard error
    # (NOMATCH) under this shellspec's zsh by default.
    setopt local_options nullglob
    rm -f "$PICK_CLIPBOARD_DB"*
    printf 'cruise-box' > "$XDG_STATE_HOME/clipboard/self-name"
    REQ="$SHELLSPEC_TMPBASE/req"
  }
  BeforeEach 'setup'

  run_dispatch() {  # request file on stdin, forced Linux platform
    sh -c 'CLIPBOARD_PLATFORM=linux-headless zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
  }

  It 'T set bootstraps the schema lazily and stores the row'
    # 'T' + BE32(6) + regtype 'v' + "hello"
    printf 'T\000\000\000\006vhello' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    row=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT text_plain||'|'||regtype||'|'||type_kind||'|'||source_host FROM clips;")
    The variable row should equal "hello|v|text|cruise-box"
  End

  It 'G returns the latest row text'
    printf 'T\000\000\000\006vhello' > "$REQ"
    run_dispatch >/dev/null
    printf 'G\000\000\000\000' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    The output should include "hello"
  End

  It 'G on an empty store answers an empty O frame'
    printf 'G\000\000\000\000' > "$REQ"
    When run command sh -c 'CLIPBOARD_PLATFORM=linux-headless zsh -f "$1" < "$2" | wc -c | tr -d " "' _ "$DISPATCH" "$REQ"
    The output should equal 5
  End

  It 'R trusts the latest row regtype'
    printf 'T\000\000\000\006bhello' > "$REQ"
    run_dispatch >/dev/null
    printf 'R\000\000\000\000' > "$REQ"
    When run run_dispatch
    The output should include "b"
  End

  It 'R falls back to the trailing-newline heuristic when regtype is NULL'
    printf 'T\000\000\000\006xline\n' > "$REQ"   # regtype 'x' -> stored NULL; payload = 1+5 bytes
    run_dispatch >/dev/null
    printf 'R\000\000\000\000' > "$REQ"
    When run run_dispatch
    The output should include "l"
  End

  It 'S answers the latest last_ts'
    printf 'T\000\000\000\006vhello' > "$REQ"
    run_dispatch >/dev/null
    expected=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT MAX(last_ts) FROM clips;")
    printf 'S\000\000\000\000' > "$REQ"
    When run run_dispatch
    The output should include "$expected"
  End

  It 'legacy bare-connect dumps the latest text unframed'
    printf 'T\000\000\000\006vhello' > "$REQ"
    run_dispatch >/dev/null
    : > "$REQ"   # empty stdin -> immediate EOF -> legacy path
    When run run_dispatch
    The output should equal "hello"
  End

  It 'round-trips multibyte text byte-exactly through T then G'
    # "héllo→" is 9 bytes UTF-8; frame len = 1 (regtype) + 9 = 10
    printf 'T\000\000\000\012vh\303\251llo\342\206\222' > "$REQ"
    run_dispatch >/dev/null
    printf 'G\000\000\000\000' > "$REQ"
    When run run_dispatch
    The output should include "héllo→"
  End

  # Fix 2 (final-review): embedded-NUL byte-safety. Verified empirically
  # (sqlite3 CLI, readfile/writefile) that a NUL byte inside a TEXT column
  # survives SQLite storage byte-exact -- SQL functions like length() use a
  # strlen-style scan and misreport a NUL-containing TEXT value's character
  # count, but the ACTUAL stored bytes (and everything this store reads back
  # through readfile()/writefile(), never length()) are untouched. The two
  # tests below confirm the same holds end to end through T then G. Byte-
  # exact capture never goes through shellspec's own output variable or a
  # $(...) substitution for the reply itself (both are C-string-shaped and
  # would silently truncate at the NUL) -- same file-redirection discipline
  # this codebase already uses everywhere else for byte-safe payloads.
  It 'T stores an embedded NUL byte-exactly (fix 2)'
    # regtype 'v' + "ab\0cd" (5 bytes) = 6-byte payload
    printf 'T\000\000\000\006vab\000cd' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    stored=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT length(CAST(text_plain AS BLOB)) FROM clips;")
    The variable stored should equal 5
  End

  It 'G reply preserves an embedded NUL byte-exactly (fix 2)'
    printf 'T\000\000\000\006vab\000cd' > "$REQ"
    run_dispatch >/dev/null
    printf 'G\000\000\000\000' > "$REQ"
    reply="$SHELLSPEC_TMPBASE/nul-reply.bin"
    When run command sh -c 'CLIPBOARD_PLATFORM=linux-headless zsh -f "$1" < "$2" > "$3"' _ "$DISPATCH" "$REQ" "$reply"
    The status should be success
    size=$(wc -c < "$reply" | tr -d ' ')
    The variable size should equal 10   # 5-byte header + 5-byte payload ("ab\0cd")
    hex=$(od -An -tx1 "$reply" | tr -s ' \n' ' ')
    The variable hex should include "61 62 00 63 64"
  End
End

Describe 'clipboard-bridge-dispatch: linux-headless rich/file ops'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export CLIPBOARD_BRIDGE_ENDPOINT=trusted
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export PICK_CLIPBOARD_DB="$SHELLSPEC_TMPBASE/store/history.db"
    mkdir -p "$XDG_STATE_HOME/clipboard" "$SHELLSPEC_TMPBASE/store"
    setopt local_options nullglob
    rm -f "$PICK_CLIPBOARD_DB"*
    printf 'cruise-box' > "$XDG_STATE_HOME/clipboard/self-name"
    REQ="$SHELLSPEC_TMPBASE/req"
  }
  BeforeEach 'setup'

  run_dispatch() {
    sh -c 'CLIPBOARD_PLATFORM=linux-headless zsh -f "$1" < "$2"' _ "$DISPATCH" "$REQ"
  }

  It 'C persists a text-UTI rich clip with text_plain populated'
    # uti "public.utf8-plain-text" = 22 bytes; blob "rich"; payload = 2+22+4 = 28
    printf 'C\000\000\000\034\000\026public.utf8-plain-textrich' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    row=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT c.type_kind||'|'||c.text_plain||'|'||t.uti FROM clips c JOIN clip_types t ON t.clip_id=c.id;")
    The variable row should equal "text|rich|public.utf8-plain-text"
  End

  It 'C maps public.png to kind image'
    # uti "public.png" = 10 bytes; blob "PNGBYTES"; payload = 2+10+8 = 20
    printf 'C\000\000\000\024\000\012public.pngPNGBYTES' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    kind=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT type_kind FROM clips;")
    The variable kind should equal "image"
  End

  # Fix 1 (final-review): the store-wide single-line-preview invariant
  # (clip::persist_text_row via clip::preview_of, and the Hammerspoon
  # watcher's own equivalent) applies to op_copy's text-UTI branch too --
  # text_preview must collapse to ONE line even though text_plain keeps the
  # full multi-line blob, since pick-clipboard renders text-kind previews raw.
  It 'C collapses a multi-line text-UTI blob to a single-line text_preview'
    # uti "public.utf8-plain-text" = 22 bytes; blob "first\nsecond" = 12
    # bytes (5 + 1 newline + 6); payload = 2 + 22 + 12 = 36
    printf 'C\000\000\000\044\000\026public.utf8-plain-textfirst\nsecond' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    plain=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT text_plain FROM clips;")
    preview=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT text_preview FROM clips;")
    The variable plain should equal "$(printf 'first\nsecond')"
    The variable preview should equal "first second"
  End

  # A blob whose FIRST character is a newline used to store an empty preview
  # (the old ${blob%%$'\n'*}) and render as a blank picker row; the flattening
  # drops the blank line and trims the indented one that follows.
  It 'C flattens a blob that opens with a blank line instead of storing an empty preview'
    # blob "\n  indented\nnext" = 16 bytes; payload = 2 + 22 + 16 = 40 (\050)
    printf 'C\000\000\000\050\000\026public.utf8-plain-text\n  indented\nnext' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    preview=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT text_preview FROM clips;")
    The variable preview should equal "indented next"
  End

  It 'U form A persists a files manifest row stamped with self-name'
    # payload "/tmp/a\0/tmp/b" = 13 bytes
    printf 'U\000\000\000\015/tmp/a\000/tmp/b' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    row=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT type_kind||'|'||source_host FROM clips;")
    The variable row should equal "files|cruise-box"
    authority_count=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT count(*) FROM file_authorities;")
    The variable authority_count should equal "2"
  End

  It 'U form A rejects a relative path'
    printf 'U\000\000\000\010tmp/rel!' > "$REQ"
    When run run_dispatch
    The output should start with "E"
  End

  It 'U form B bumps last_ts of an existing row'
    printf 'U\000\000\000\006/tmp/a' > "$REQ"
    run_dispatch >/dev/null
    sqlite3 "$PICK_CLIPBOARD_DB" "UPDATE clips SET last_ts=1.0;"
    printf 'U\000\000\000\004id:1' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    ts=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT CAST(last_ts AS INTEGER) > 1 FROM clips WHERE id=1;")
    The variable ts should equal 1
  End

  It 'U form B on a missing row answers E'
    printf 'T\000\000\000\006vhello' > "$REQ"
    run_dispatch >/dev/null   # bootstrap the schema first
    printf 'U\000\000\000\005id:99' > "$REQ"
    When run run_dispatch
    The output should start with "E"
  End

  It 'M then L round-trips a manifest through the store'
    # M payload: "cruise-box" US "/tmp/a" = 10+1+6 = 17
    printf 'M\000\000\000\021cruise-box\037/tmp/a' > "$REQ"
    run_dispatch >/dev/null
    printf 'L\000\000\000\000' > "$REQ"
    When run run_dispatch
    The output should start with "O"
    The output should include "files"
    The output should include "cruise-box"
    The output should include "/tmp/a"
  End

  It 'P dedup bumps last_ts instead of inserting a twin'
    # P payload: "otherhost" US "text" US "" US "v" RS "dup" = 9+1+4+1+0+1+1+1+3 = 21
    printf 'P\000\000\000\025otherhost\037text\037\037v\036dup' > "$REQ"
    run_dispatch >/dev/null
    run_dispatch >/dev/null
    count=$(sqlite3 "$PICK_CLIPBOARD_DB" "SELECT COUNT(*) FROM clips;")
    The variable count should equal 1
  End

  It 'H answers the self-name identity'
    printf 'H\000\000\000\000' > "$REQ"
    When run run_dispatch
    The output should include "cruise-box"
  End
End
