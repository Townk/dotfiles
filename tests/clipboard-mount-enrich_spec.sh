# Dispatcher M-handler mount enrichment (clipboard-mount spec §3.4): after the
# lazy manifest row persists, a healthy mount turns the copy into a live
# pasteboard file-url set (mount-mapped paths), echo-suppressed. The chain is
# backgrounded+disowned, so every example runs the dispatcher THEN polls for
# the artifact the stub chain writes.
Describe 'clipboard-bridge-dispatch: M mount enrichment'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  # build_m_req <host> <path>...: writes the framed M request to $REQ
  build_m_req() {
    _h=$1; shift
    _payload=$(printf '%s\037%s' "$_h" "$1"); shift
    for _p in "$@"; do _payload=$(printf '%s\000%s' "$_payload" "$_p"); done
    _len=${#_payload}
    { printf 'M'; printf '\000\000\000'; printf "\\$(printf %03o "$_len")"; printf '%s' "$_payload"; } > "$REQ"
  }

  # run_and_wait <artifact>: runs the dispatcher, then polls up to 5s for the
  # background chain's artifact so assertions see settled state.
  run_and_wait() {
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    i=0; while [ ! -e "$1" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  }

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    rm -f "$DB"
    sqlite3 "$DB" '
      CREATE TABLE clips (id INTEGER PRIMARY KEY AUTOINCREMENT, text_preview TEXT,
        text_plain TEXT, len INTEGER, first_ts REAL, last_ts REAL, source_app TEXT,
        source_bundle_id TEXT, type_kind TEXT, regtype TEXT, pinned INTEGER DEFAULT 0,
        type_hash TEXT, source_host TEXT);
      CREATE TABLE clip_types (clip_id INTEGER, uti TEXT, blob BLOB, PRIMARY KEY (clip_id, uti));
    '
    STUBS="$SHELLSPEC_TMPBASE/bin"
    export PATH="$STUBS:$PATH"
    mkdir -p "$STUBS"
    rm -f "$SHELLSPEC_TMPBASE"/hs-set-script "$SHELLSPEC_TMPBASE"/cm-calls "$SHELLSPEC_TMPBASE"/cc-value
    # hs stub with two personalities: a changeCount script (contains
    # "changeCount") prints the fixture counter; anything else is a
    # pasteboard-set script -- record it. clip::set_file_urls_core passes
    # the actual paths through a NUL-joined SIDE FILE (never string-
    # interpolated into the Lua literal -- see its header comment), so a
    # real Hammerspoon reads that side file at runtime; this stub mimics
    # that by also appending the side file's content, letting assertions
    # below see the real mapped-path bytes the way `hs` actually would.
    printf '1' > "$SHELLSPEC_TMPBASE/cc-value"
    cat > "$STUBS/hs" <<STUB
#!/bin/sh
if grep -q changeCount "\$1" 2>/dev/null; then
  cat "$SHELLSPEC_TMPBASE/cc-value"
else
  cat "\$1" > "$SHELLSPEC_TMPBASE/hs-set-script"
  pf=\$(sed -n "s/.*io\\.open(\\[\\[\\(.*\\)\\]\\], 'rb').*/\\1/p" "\$1" | head -1)
  if [ -n "\$pf" ] && [ -f "\$pf" ]; then
    printf '\\n--PATHS--\\n' >> "$SHELLSPEC_TMPBASE/hs-set-script"
    tr '\\0' '\\n' < "\$pf" >> "$SHELLSPEC_TMPBASE/hs-set-script"
  fi
fi
STUB
    chmod +x "$STUBS/hs"
    # clipboard-mount stub: healthy by default -- check prints MP; ensure
    # records. MP is a real dir so mapped-path existence checks can pass.
    MP="$SHELLSPEC_TMPBASE/mnt/peer-mini"
    mkdir -p "$MP/Users/thiago"
    touch "$MP/Users/thiago/big.bin"
    export CLIPBOARD_MOUNT_BIN="$STUBS/clipboard-mount"
    cat > "$STUBS/clipboard-mount" <<STUB
#!/bin/sh
echo "\$*" >> "$SHELLSPEC_TMPBASE/cm-calls"
case "\$1" in
  check)  echo "$MP"; exit 0 ;;
  ensure) exit 0 ;;
esac
exit 1
STUB
    chmod +x "$STUBS/clipboard-mount"
    REQ="$SHELLSPEC_TMPBASE/m-req"
    RESP="$SHELLSPEC_TMPBASE/m-resp"
    ORIGIN="$XDG_STATE_HOME/pick-clipboard/current-origin"
    rm -f "$ORIGIN"
  }
  BeforeEach 'setup'

  # Defined BEFORE its first use: shellspec replays this Describe body up to
  # (and including) each targeted `It`, so a helper referenced by `The result
  # of function X` inside an It must be textually defined earlier in the
  # file, or that first example sees it undefined (confirmed empirically --
  # a later example whose textual position is already past this definition
  # sees it fine).
  db_row_count() { sqlite3 "$DB" "SELECT COUNT(*) FROM clips WHERE type_kind='files';"; }

  It 'healthy mount: replies O, persists the manifest row, sets mapped file-urls, arms suppress'
    build_m_req thiago-mac-mini /Users/thiago/big.bin
    When call run_and_wait "$SHELLSPEC_TMPBASE/hs-set-script"
    The contents of file "$RESP" should start with "O"
    The result of function db_row_count should equal 1
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "$MP/Users/thiago/big.bin"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "NSFilenamesPboardType"
    The line 1 of contents of file "$ORIGIN" should equal "thiago-mac-mini"
    The line 2 of contents of file "$ORIGIN" should equal "$(printf '%s' "$MP/Users/thiago/big.bin" | shasum -a 256 | awk '{print $1}')"
    The line 4 of contents of file "$ORIGIN" should equal "suppress-echo"
  End

  It 'maps and sets ALL paths of a multi-file clip, suppress hash over the newline-join'
    touch "$MP/Users/thiago/two.txt"
    build_m_req thiago-mac-mini /Users/thiago/big.bin /Users/thiago/two.txt
    When call run_and_wait "$SHELLSPEC_TMPBASE/hs-set-script"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "$MP/Users/thiago/big.bin"
    The line 2 of contents of file "$ORIGIN" should equal "$(printf '%s\n%s' "$MP/Users/thiago/big.bin" "$MP/Users/thiago/two.txt" | shasum -a 256 | awk '{print $1}')"
  End

  It 'skips enrichment when the first mapped path does not exist on the mount'
    build_m_req thiago-mac-mini /Users/thiago/vanished.bin
    When call run_and_wait "$SHELLSPEC_TMPBASE/cm-calls"
    The contents of file "$RESP" should start with "O"
    The result of function db_row_count should equal 1
    The path "$SHELLSPEC_TMPBASE/hs-set-script" should not be exist
    The path "$ORIGIN" should not be exist
  End

  It 'no CLIPBOARD_MOUNT_BIN executable: byte-identical legacy behavior'
    export CLIPBOARD_MOUNT_BIN="$SHELLSPEC_TMPBASE/nonexistent"
    build_m_req thiago-mac-mini /Users/thiago/big.bin
    When call run_and_wait "$SHELLSPEC_TMPBASE/never-appears"
    The contents of file "$RESP" should start with "O"
    The result of function db_row_count should equal 1
    The path "$SHELLSPEC_TMPBASE/hs-set-script" should not be exist
  End
End

# Second half of clipboard-mount spec §3.4 coverage: the self-heal branch
# (unhealthy check -> ensure -> re-check -> retroactive set) and the
# changeCount guard (a set that lands in the copy/paste gap must never
# clobber whatever the user's pasteboard now holds). shellspec Describe
# blocks don't share function scope, so build_m_req/run_and_wait/setup are
# copied verbatim from the previous Describe (see its header comments for
# the stub-fidelity rationale).
Describe 'clipboard-bridge-dispatch: M self-heal + changeCount guard'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  # build_m_req <host> <path>...: writes the framed M request to $REQ
  build_m_req() {
    _h=$1; shift
    _payload=$(printf '%s\037%s' "$_h" "$1"); shift
    for _p in "$@"; do _payload=$(printf '%s\000%s' "$_payload" "$_p"); done
    _len=${#_payload}
    { printf 'M'; printf '\000\000\000'; printf "\\$(printf %03o "$_len")"; printf '%s' "$_payload"; } > "$REQ"
  }

  # run_and_wait <artifact>: runs the dispatcher, then polls up to 5s for the
  # background chain's artifact so assertions see settled state.
  run_and_wait() {
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    i=0; while [ ! -e "$1" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  }

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    rm -f "$DB"
    sqlite3 "$DB" '
      CREATE TABLE clips (id INTEGER PRIMARY KEY AUTOINCREMENT, text_preview TEXT,
        text_plain TEXT, len INTEGER, first_ts REAL, last_ts REAL, source_app TEXT,
        source_bundle_id TEXT, type_kind TEXT, regtype TEXT, pinned INTEGER DEFAULT 0,
        type_hash TEXT, source_host TEXT);
      CREATE TABLE clip_types (clip_id INTEGER, uti TEXT, blob BLOB, PRIMARY KEY (clip_id, uti));
    '
    STUBS="$SHELLSPEC_TMPBASE/bin"
    export PATH="$STUBS:$PATH"
    mkdir -p "$STUBS"
    rm -f "$SHELLSPEC_TMPBASE"/hs-set-script "$SHELLSPEC_TMPBASE"/cm-calls "$SHELLSPEC_TMPBASE"/cc-value "$SHELLSPEC_TMPBASE"/mounted
    # hs stub with two personalities: a changeCount script (contains
    # "changeCount") prints the fixture counter; anything else is a
    # pasteboard-set script -- record it. clip::set_file_urls_core passes
    # the actual paths through a NUL-joined SIDE FILE (never string-
    # interpolated into the Lua literal -- see its header comment), so a
    # real Hammerspoon reads that side file at runtime; this stub mimics
    # that by also appending the side file's content, letting assertions
    # below see the real mapped-path bytes the way `hs` actually would.
    printf '1' > "$SHELLSPEC_TMPBASE/cc-value"
    cat > "$STUBS/hs" <<STUB
#!/bin/sh
if grep -q changeCount "\$1" 2>/dev/null; then
  cat "$SHELLSPEC_TMPBASE/cc-value"
else
  cat "\$1" > "$SHELLSPEC_TMPBASE/hs-set-script"
  pf=\$(sed -n "s/.*io\\.open(\\[\\[\\(.*\\)\\]\\], 'rb').*/\\1/p" "\$1" | head -1)
  if [ -n "\$pf" ] && [ -f "\$pf" ]; then
    printf '\\n--PATHS--\\n' >> "$SHELLSPEC_TMPBASE/hs-set-script"
    tr '\\0' '\\n' < "\$pf" >> "$SHELLSPEC_TMPBASE/hs-set-script"
  fi
fi
STUB
    chmod +x "$STUBS/hs"
    # clipboard-mount stub: healthy by default -- check prints MP; ensure
    # records. MP is a real dir so mapped-path existence checks can pass.
    MP="$SHELLSPEC_TMPBASE/mnt/peer-mini"
    mkdir -p "$MP/Users/thiago"
    touch "$MP/Users/thiago/big.bin"
    export CLIPBOARD_MOUNT_BIN="$STUBS/clipboard-mount"
    cat > "$STUBS/clipboard-mount" <<STUB
#!/bin/sh
echo "\$*" >> "$SHELLSPEC_TMPBASE/cm-calls"
case "\$1" in
  check)  echo "$MP"; exit 0 ;;
  ensure) exit 0 ;;
esac
exit 1
STUB
    chmod +x "$STUBS/clipboard-mount"
    REQ="$SHELLSPEC_TMPBASE/m-req"
    RESP="$SHELLSPEC_TMPBASE/m-resp"
    ORIGIN="$XDG_STATE_HOME/pick-clipboard/current-origin"
    rm -f "$ORIGIN"
  }
  BeforeEach 'setup'

  # Defined BEFORE the first It that uses it -- see the previous Describe's
  # identical comment; shellspec replays this Describe body up to the
  # targeted `It`, so a helper referenced via `The result of function X` must
  # be textually above every It that names it.
  db_row_count() { sqlite3 "$DB" "SELECT COUNT(*) FROM clips WHERE type_kind='files';"; }

  It 'unhealthy mount: ensure is called, then re-check, then the set lands (retroactive enrichment)'
    # check fails until ensure has run (marker file flips the stub healthy)
    cat > "$STUBS/clipboard-mount" <<STUB
#!/bin/sh
echo "\$*" >> "$SHELLSPEC_TMPBASE/cm-calls"
case "\$1" in
  check)  [ -e "$SHELLSPEC_TMPBASE/mounted" ] && { echo "$MP"; exit 0; } || exit 1 ;;
  ensure) touch "$SHELLSPEC_TMPBASE/mounted"; exit 0 ;;
esac
exit 1
STUB
    chmod +x "$STUBS/clipboard-mount"
    build_m_req thiago-mac-mini /Users/thiago/big.bin
    When call run_and_wait "$SHELLSPEC_TMPBASE/hs-set-script"
    The contents of file "$RESP" should start with "O"
    The contents of file "$SHELLSPEC_TMPBASE/cm-calls" should include "ensure thiago-mac-mini"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "$MP/Users/thiago/big.bin"
  End

  It 'remount fails: clip stays lazy, no pasteboard set, no suppress armed'
    cat > "$STUBS/clipboard-mount" <<STUB
#!/bin/sh
echo "\$*" >> "$SHELLSPEC_TMPBASE/cm-calls"
exit 1
STUB
    chmod +x "$STUBS/clipboard-mount"
    build_m_req thiago-mac-mini /Users/thiago/big.bin
    When call run_and_wait "$SHELLSPEC_TMPBASE/cm-calls"
    The contents of file "$RESP" should start with "O"
    The result of function db_row_count should equal 1
    The path "$SHELLSPEC_TMPBASE/hs-set-script" should not be exist
    The path "$ORIGIN" should not be exist
  End

  It 'changeCount moved during the heal gap: the retroactive set is skipped'
    # hs changeCount personality increments per call: snapshot=1, re-read=2
    cat > "$STUBS/hs" <<STUB
#!/bin/sh
if grep -q changeCount "\$1" 2>/dev/null; then
  n=\$(cat "$SHELLSPEC_TMPBASE/cc-value"); echo "\$n"; echo \$((n+1)) > "$SHELLSPEC_TMPBASE/cc-value"
else
  cat "\$1" > "$SHELLSPEC_TMPBASE/hs-set-script"
  pf=\$(sed -n "s/.*io\\.open(\\[\\[\\(.*\\)\\]\\], 'rb').*/\\1/p" "\$1" | head -1)
  if [ -n "\$pf" ] && [ -f "\$pf" ]; then
    printf '\\n--PATHS--\\n' >> "$SHELLSPEC_TMPBASE/hs-set-script"
    tr '\\0' '\\n' < "\$pf" >> "$SHELLSPEC_TMPBASE/hs-set-script"
  fi
fi
STUB
    chmod +x "$STUBS/hs"
    build_m_req thiago-mac-mini /Users/thiago/big.bin
    When call run_and_wait "$SHELLSPEC_TMPBASE/cm-calls"
    The contents of file "$RESP" should start with "O"
    The path "$SHELLSPEC_TMPBASE/hs-set-script" should not be exist
    The path "$ORIGIN" should not be exist
  End
End
