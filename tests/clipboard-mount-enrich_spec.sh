# Dispatcher M-handler mount enrichment (clipboard-mount spec §3.4): after the
# lazy manifest row persists, a healthy mount turns the copy into a live
# pasteboard file-url set (mount-mapped paths), carrying a change-bound
# untrusted marker so the watcher never turns a public pointer into authority.
# backgrounded+disowned, so every example runs the dispatcher THEN polls for
# the artifact the stub chain writes.
Describe 'clipboard-bridge-dispatch: M mount enrichment'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"
  HISTORY="$SHELLSPEC_PROJECT_ROOT/home/dot_config/hammerspoon/modules/apps/clipboard-history.lua"

  # build_m_req <host> <path>...: writes the framed M request to $REQ
  build_m_req() {
    _h=$1; shift
    _payload=$(printf '%s\037%s' "$_h" "$1"); shift
    for _p in "$@"; do _payload=$(printf '%s\000%s' "$_payload" "$_p"); done
    _len=${#_payload}
    { printf 'M'; printf '\000\000\000'; printf "\\$(printf %03o "$_len")"; printf '%s' "$_payload"; } > "$REQ"
  }

  # run_and_wait <artifact> [budget]: runs the dispatcher, then polls (budget
  # x 0.1s; default 150 = 15s -- suite-wide process churn can stretch the
  # disowned chain well past 5s, seen flaking once under full-suite load) for
  # the background chain's artifact so assertions see settled state. Costs
  # nothing when green: the poll exits as soon as the artifact appears.
  run_and_wait() {
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    i=0; while [ ! -e "$1" ] && [ $i -lt "${2:-150}" ]; do sleep 0.1; i=$((i+1)); done
  }

  setup() {
    export CLIPBOARD_BRIDGE_ENDPOINT=public
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
    # self-name file reset every example -- NOT just removed by the one
    # example that writes it. $SHELLSPEC_TMPBASE (and so $XDG_STATE_HOME,
    # which is a fixed subpath of it) is reused across every example in this
    # run, not recreated per example (confirmed against shellspec's own
    # dsl.sh: only $SHELLSPEC_WORKDIR is per-example). Left in place, a
    # self-name written by one example would leak into every later example's
    # mount_enrich call and silently flip its self-host guard whenever that
    # later example's fixture host happens to match -- CRITICAL to clear
    # here, not just at the point of use.
    rm -f "$XDG_STATE_HOME/clipboard/self-name"
    # scutil stub: pinned to a fixed non-fixture hostname by DEFAULT, reset
    # every example -- NOT simply removed. mount_enrich's self-host guard
    # falls back to the real `scutil`/`hostname -s` when no stub is present,
    # and this file's fixture host ("thiago-mac-mini") is empirically a real
    # developer machine's actual LocalHostName -- confirmed live, it made
    # every M-enrichment example here false-negative (self-host guard firing
    # for real) on that box. Pinning a stub host that can never collide with
    # any fixture used in this file keeps the suite hostname-independent; the
    # self-host example below overrides this stub with its own.
    cat > "$STUBS/scutil" <<STUB
#!/bin/sh
echo test-suite-nonself
STUB
    chmod +x "$STUBS/scutil"
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
if grep -q '^print(hs\.pasteboard\.changeCount())$' "\$1" 2>/dev/null; then
  cat "$SHELLSPEC_TMPBASE/cc-value"
else
  # Write ATOMICALLY (temp + mv): run_and_wait polls for this file's
  # EXISTENCE, and a two-step write let assertions read a half-written
  # artifact under load (observed live: multi-file paths missing). mv within
  # the same directory is a rename -- pollers see nothing or everything.
  tmp="$SHELLSPEC_TMPBASE/hs-set-script.tmp.\$\$"
  cat "\$1" > "\$tmp"
  pf=\$(sed -n "s/.*io\\.open(\\[\\[\\(.*\\)\\]\\], 'rb').*/\\1/p" "\$1" | head -1)
  if [ -n "\$pf" ] && [ -f "\$pf" ]; then
    printf '\\n--PATHS--\\n' >> "\$tmp"
    tr '\\0' '\\n' < "\$pf" >> "\$tmp"
  fi
  mv "\$tmp" "$SHELLSPEC_TMPBASE/hs-set-script"
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

  It 'healthy mount: persists the row and marks the mapped file-url change untrusted'
    build_m_req thiago-mac-mini /Users/thiago/big.bin
    When call run_and_wait "$SHELLSPEC_TMPBASE/hs-set-script"
    The contents of file "$RESP" should start with "O"
    The result of function db_row_count should equal 1
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "$MP/Users/thiago/big.bin"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "NSFilenamesPboardType"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "org.chezmoi.clipboard.UntrustedFileURLs"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "if hs.pasteboard.changeCount() ~= 1 then return end"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "if not hs.pasteboard.writeAllData(data)"
    The contents of file "$HISTORY" should include '["org.chezmoi.clipboard.UntrustedFileURLs"] = true'
    The path "$ORIGIN" should not be exist
  End

  It 'maps and marks ALL paths of a multi-file clip'
    touch "$MP/Users/thiago/two.txt"
    build_m_req thiago-mac-mini /Users/thiago/big.bin /Users/thiago/two.txt
    When call run_and_wait "$SHELLSPEC_TMPBASE/hs-set-script"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "$MP/Users/thiago/big.bin"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "$MP/Users/thiago/two.txt"
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "org.chezmoi.clipboard.UntrustedFileURLs"
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
    # 3s budget: this artifact never appears by design (absence is
    # probabilistic anyway); the default 15s would just add suite latency.
    When call run_and_wait "$SHELLSPEC_TMPBASE/never-appears" 30
    The contents of file "$RESP" should start with "O"
    The result of function db_row_count should equal 1
    The path "$SHELLSPEC_TMPBASE/hs-set-script" should not be exist
  End

  It 'self-host record: M payload host IS this machine -- record-only, no mount attempt at all'
    export CLIPBOARD_BRIDGE_ENDPOINT=trusted
    # scutil stubbed to answer the SAME host the M payload carries, so
    # mount_enrich's self-host guard fires as the very first thing inside the
    # backgrounded subshell -- before it even execs $cm. Row still persists
    # (op_manifest_persist_local's insert runs before mount_enrich is called
    # at all); no cm-calls (clipboard-mount never invoked), no hs-set-script,
    # no origin file.
    cat > "$STUBS/scutil" <<STUB
#!/bin/sh
echo thiago-test-self
STUB
    chmod +x "$STUBS/scutil"
    self_file="$SHELLSPEC_TMPBASE/self-local.bin"; printf 'self\n' > "$self_file"
    build_m_req thiago-test-self "$self_file"
    # 3s budget: none of these artifacts appear by design.
    When call run_and_wait "$SHELLSPEC_TMPBASE/never-appears" 30
    The contents of file "$RESP" should start with "O"
    The result of function db_row_count should equal 1
    The path "$SHELLSPEC_TMPBASE/cm-calls" should not be exist
    The path "$SHELLSPEC_TMPBASE/hs-set-script" should not be exist
    The path "$ORIGIN" should not be exist
  End

  It 'self-host record via self-name file: pushed identity wins over a DIFFERING live scutil answer'
    export CLIPBOARD_BRIDGE_ENDPOINT=trusted
    # This is the drift scenario the self-name file exists for (pbcopy's
    # self_host(), executable_pbcopy near abspath()): the identity a machine
    # STAMPS on its own outgoing M rows is whatever self_host() resolved at
    # send time, which prefers the pushed self-name file over scutil --
    # ssh-prepare-connection's step_mount pushes it precisely because
    # LocalHostName can drift (hand-edited fragment, or macOS's own
    # auto-rename on a hostname collision, e.g. thiago-mac-mini ->
    # thiago-mac-mini-2). The guard here must resolve identity the SAME way,
    # or a self-stamped row stops being recognized as self the moment the
    # two diverge. scutil is left at setup()'s default stub
    # ("test-suite-nonself") -- deliberately a DIFFERENT answer than the
    # self-name file below, so this only goes green if the guard actually
    # prefers the self-name file (pre-fix, scutil-only, it would not: see
    # the red-verify note above the commit).
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf 'self-name-target' > "$XDG_STATE_HOME/clipboard/self-name"
    self_file="$SHELLSPEC_TMPBASE/self-name-local.bin"; printf 'self\n' > "$self_file"
    build_m_req self-name-target "$self_file"
    # 3s budget: none of these artifacts appear by design.
    When call run_and_wait "$SHELLSPEC_TMPBASE/never-appears" 30
    The contents of file "$RESP" should start with "O"
    The result of function db_row_count should equal 1
    The path "$SHELLSPEC_TMPBASE/cm-calls" should not be exist
    The path "$SHELLSPEC_TMPBASE/hs-set-script" should not be exist
    The path "$ORIGIN" should not be exist
  End
End

# Second half of clipboard-mount spec §3.4 coverage: the self-heal branch
# (unhealthy check -> ensure -> re-check -> retroactive set) and the
# changeCount guard (a set that lands in the copy/paste gap must never
# clobber whatever the user's pasteboard now holds). shellspec Describe
# blocks don't share function scope, so build_m_req/run_and_wait/setup are
# copied from the previous Describe (see its header comments for the
# stub-fidelity rationale), with one divergence: this setup() has an extra
# "$SHELLSPEC_TMPBASE"/mounted reset (the self-heal stub's own artifact).
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

  # run_and_wait <artifact> [budget]: runs the dispatcher, then polls (budget
  # x 0.1s; default 150 = 15s -- suite-wide process churn can stretch the
  # disowned chain well past 5s, seen flaking once under full-suite load) for
  # the background chain's artifact so assertions see settled state. Costs
  # nothing when green: the poll exits as soon as the artifact appears.
  run_and_wait() {
    zsh -f "$DISPATCH" < "$REQ" > "$RESP"
    i=0; while [ ! -e "$1" ] && [ $i -lt "${2:-150}" ]; do sleep 0.1; i=$((i+1)); done
  }

  setup() {
    export CLIPBOARD_BRIDGE_ENDPOINT=public
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
    # self-name file reset every example -- $SHELLSPEC_TMPBASE (and so this
    # $XDG_STATE_HOME subpath) is shared across BOTH Describes' examples, so
    # the previous Describe's self-name example would otherwise leak its
    # file into every example here. See the matching comment in the previous
    # Describe's setup() for the full rationale.
    rm -f "$XDG_STATE_HOME/clipboard/self-name"
    # scutil stub pinned to a fixed non-fixture hostname -- see the matching
    # comment in the previous Describe's setup() for why this can't just be
    # removed (this file's fixture host collides with a real dev machine's
    # actual LocalHostName, confirmed live).
    cat > "$STUBS/scutil" <<STUB
#!/bin/sh
echo test-suite-nonself
STUB
    chmod +x "$STUBS/scutil"
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
if grep -q '^print(hs\.pasteboard\.changeCount())$' "\$1" 2>/dev/null; then
  cat "$SHELLSPEC_TMPBASE/cc-value"
else
  # Write ATOMICALLY (temp + mv): run_and_wait polls for this file's
  # EXISTENCE, and a two-step write let assertions read a half-written
  # artifact under load (observed live: multi-file paths missing). mv within
  # the same directory is a rename -- pollers see nothing or everything.
  tmp="$SHELLSPEC_TMPBASE/hs-set-script.tmp.\$\$"
  cat "\$1" > "\$tmp"
  pf=\$(sed -n "s/.*io\\.open(\\[\\[\\(.*\\)\\]\\], 'rb').*/\\1/p" "\$1" | head -1)
  if [ -n "\$pf" ] && [ -f "\$pf" ]; then
    printf '\\n--PATHS--\\n' >> "\$tmp"
    tr '\\0' '\\n' < "\$pf" >> "\$tmp"
  fi
  mv "\$tmp" "$SHELLSPEC_TMPBASE/hs-set-script"
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
    The contents of file "$SHELLSPEC_TMPBASE/hs-set-script" should include "org.chezmoi.clipboard.UntrustedFileURLs"
  End

  It 'remount fails: clip stays lazy with no untrusted pasteboard set'
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
    # The first hs call snapshots 1 and advances the simulated pasteboard to
    # 2. The second script must carry and enforce expected changeCount 1.
    cat > "$STUBS/hs" <<STUB
#!/bin/sh
if grep -q '^print(hs\.pasteboard\.changeCount())$' "\$1" 2>/dev/null; then
  n=\$(cat "$SHELLSPEC_TMPBASE/cc-value"); echo "\$n"; echo \$((n+1)) > "$SHELLSPEC_TMPBASE/cc-value"
else
  expected=\$(sed -n 's/.*changeCount() ~= \([0-9][0-9]*\).*/\1/p' "\$1")
  current=\$(cat "$SHELLSPEC_TMPBASE/cc-value")
  if [ -n "\$expected" ] && [ "\$current" != "\$expected" ]; then exit 0; fi
  # Write ATOMICALLY (temp + mv): run_and_wait polls for this file's
  # EXISTENCE, and a two-step write let assertions read a half-written
  # artifact under load (observed live: multi-file paths missing). mv within
  # the same directory is a rename -- pollers see nothing or everything.
  tmp="$SHELLSPEC_TMPBASE/hs-set-script.tmp.\$\$"
  cat "\$1" > "\$tmp"
  pf=\$(sed -n "s/.*io\\.open(\\[\\[\\(.*\\)\\]\\], 'rb').*/\\1/p" "\$1" | head -1)
  if [ -n "\$pf" ] && [ -f "\$pf" ]; then
    printf '\\n--PATHS--\\n' >> "\$tmp"
    tr '\\0' '\\n' < "\$pf" >> "\$tmp"
  fi
  mv "\$tmp" "$SHELLSPEC_TMPBASE/hs-set-script"
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
