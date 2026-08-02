# Tests for the Ctrl-Y copy-feedback layer (copy-feedback design,
# docs/superpowers/specs/2026-07-20-clipboard-copy-feedback-design.md):
# toast variant selection (§6), materialization progress throttling (§4.2),
# and their wiring into clip::copy_by_id / --restore-id.
#
# Same harness shape as tests/pick-clipboard-files_spec.sh: the picker is
# sourced under PICK_CLIPBOARD_NO_RUN in a zsh -f (no ~/.zshenv), against a
# sandboxed HOME + seeded store; notify/hs/rsync are captured by fake
# executables wired in via the PICK_CLIPBOARD_* test overrides.
Describe 'pick-clipboard: copy feedback'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    export HOME="$SHELLSPEC_TMPBASE/home"; rm -rf "$HOME"; mkdir -p "$HOME"
    export XDG_STATE_HOME="$HOME/.local/state"
    export TMPDIR="$SHELLSPEC_TMPBASE/tmp"; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"; mkdir -p "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    export PICK_CLIPBOARD_DB="$DB"
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
      CREATE TABLE file_authorities (
        clip_id INTEGER,
        item_index INTEGER,
        path BLOB,
        PRIMARY KEY (clip_id, item_index)
      );
    '

    # Fake scutil pins THIS host to mac-mini (same convention as
    # tests/pick-clipboard-files_spec.sh) so local/remote comparisons are
    # deterministic.
    cat > "$BINDIR/scutil" <<'EOF'
#!/bin/sh
if [ "$1" = "--get" ] && [ "$2" = "LocalHostName" ]; then
  echo mac-mini
  exit 0
fi
exit 1
EOF
    chmod +x "$BINDIR/scutil"

    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
    # Fake nc: logs "<port>:<raw frame, NUL -> '|'>" then answers a bare 'O'
    # status -- verbatim from tests/pick-clipboard-files_spec.sh.
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
argc=\$#
eval "port=\\\${\$argc}"
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
printf 'O\\000\\000\\000\\000'
EOF
    chmod +x "$BINDIR/nc"

    NOTIFYLOG="$SHELLSPEC_TMPBASE/notifylog"; : > "$NOTIFYLOG"
    # Fake notify front-end: logs its argv, one line per call.
    cat > "$BINDIR/notify" <<EOF
#!/bin/sh
echo "\$*" >> "$NOTIFYLOG"
EOF
    chmod +x "$BINDIR/notify"
    export PICK_CLIPBOARD_NOTIFY="$BINDIR/notify"

    HSLOG="$SHELLSPEC_TMPBASE/hslog"; : > "$HSLOG"
    # Fake hs CLI: accepts only the production `-q -c` shape with stdin
    # redirected from /dev/null, so every payload assertion regression-tests
    # both isolation requirements. Hammerspoon 1.1.1's console mirror can
    # recursively flood warnings from an unrelated print during a request,
    # blocking its event taps; -q bypasses that mirror. The real CLI also
    # reads stdin, which otherwise steals records from rsync's progress pipe.
    # printf '%s\n', not echo: /bin/sh's echo builtin is XSI-compliant on this box (verified:
    # `sh -c 'x="a\\\\b"; echo "$x"'` prints a single backslash) and would
    # silently collapse the label-escaping test's literal backslash pairs
    # before they ever reach the log -- printf never reinterprets its
    # argument, so the log holds the exact -c payload byte-for-byte, same as
    # what real Hammerspoon's `hs -q -c` would receive.
    cat > "$BINDIR/hs" <<EOF
#!/bin/sh
[ -c /dev/fd/0 ] && [ "\$1" = "-q" ] && [ "\$2" = "-c" ] && printf '%s\n' "\$3" >> "$HSLOG"
EOF
    chmod +x "$BINDIR/hs"
    export PICK_CLIPBOARD_HS="$BINDIR/hs"

    RSYNCLOG="$SHELLSPEC_TMPBASE/rsynclog"; : > "$RSYNCLOG"
    # Fake rsync: logs argv, emits three CR-separated progress2-style
    # updates on stdout (like the real --info=progress2), then fabricates
    # the pulled file -- same dst/base extraction as
    # tests/pick-clipboard-files_spec.sh's fake.
    cat > "$BINDIR/rsync" <<EOF
#!/bin/sh
echo "\$*" >> "$RSYNCLOG"
printf '     1,000  10%%    1.00MB/s    0:00:09\\r'
printf '     5,000  50%%    1.00MB/s    0:00:05\\r'
printf '    10,000 100%%    1.00MB/s    0:00:00\\r'
argc=\$#
eval "src=\\\${\$((argc - 1))}"
eval "dst=\\\${\$argc}"
name="\${src##*:}"
base="\${name##*/}"
mkdir -p "\$dst"
printf 'pulled:%s' "\$base" > "\$dst/\$base"
EOF
    chmod +x "$BINDIR/rsync"
    export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync"

    export PATH="$BINDIR:$PATH"
    export PICK_COMMON_LIB="$LIB_DIR/pick-common.zsh"
    export PICK_BRIDGE_CLIENT_LIB="$LIB_DIR/clipboard-bridge-client.zsh"
    export PICK_CLIPBOARD_CORE_LIB="$LIB_DIR/clipboard-store-core.zsh"
    export PICK_CLIPBOARD_NO_RUN=1
    export SCRIPT_PATH="$SCRIPT"
  }
  BeforeEach 'setup'

  # Calls a sourced picker function with the given argv, zsh -f sandboxed.
  run_fn() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      fn=$1; shift
      "$fn" "$@"
    ' _ "$@"
  }

  run_restore_id() {
    zsh -f "$SCRIPT" --restore-id "$1"
  }

  # Seeds a remote files row with a single-path x-file-manifest.
  seed_remote_manifest_row() {
    _id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','work-laptop',100); SELECT last_insert_rowid();")
    printf '/pick-clipboard-remote-src/big.bin' > "$SHELLSPEC_TMPBASE/manifest-blob"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($_id, 'x-file-manifest', readfile('$SHELLSPEC_TMPBASE/manifest-blob'));"
    printf '%s' "$_id"
  }

  # Exact-match checker for clip::toast_spec output: the expected string
  # contains a raw US (0x1f) separator, which must never appear inside a
  # shellspec DSL argument (it collides with shellspec's own internal
  # field separator and corrupts the assertion). Comparison happens
  # entirely in-shell instead.
  check_toast_spec() {  # <kind> <host> <expected-icon> <expected-message>
    local out
    out=$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::toast_spec "$1" "$2"
    ' _ "$1" "$2")
    [ "$out" = "$3$(printf '\x1f')$4" ]
  }

  Describe 'clip::toast_spec (§6 variant selection, pure)'
    It 'remote text row -> text glyph + Copied from <host>'
      When call check_toast_spec text work-laptop glyph:nf-md-text_box "Copied from work-laptop"
      The status should be success
    End

    It 'remote files row -> file_multiple glyph'
      When call check_toast_spec files work-laptop glyph:nf-md-file_multiple "Copied from work-laptop"
      The status should be success
    End

    It 'remote image/file/directory rows -> their kind glyphs'
      When call check_toast_spec image work-laptop glyph:nf-md-image "Copied from work-laptop"
      The status should be success
    End

    It 'unknown kind falls back to the text glyph'
      When call check_toast_spec url work-laptop glyph:nf-md-text_box "Copied from work-laptop"
      The status should be success
    End

    It 'own-host row -> local acknowledgment variant'
      When call check_toast_spec text mac-mini glyph:fa-clipboard-list "Clipboard moved to top"
      The status should be success
    End

    It 'empty host (legacy row) reads as local'
      When call check_toast_spec files '' glyph:fa-clipboard-list "Clipboard moved to top"
      The status should be success
    End
  End

  Describe 'clip::copy_by_id toast wiring (§6)'
    It 'remote text row: bridge copy succeeds and toasts Copied from <host>'
      id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, source_host, last_ts) VALUES ('text','hello','work-laptop',100); SELECT last_insert_rowid();")
      When call run_fn clip::copy_by_id "$id"
      The status should be success
      The contents of file "$NOTIFYLOG" should include "--icon glyph:nf-md-text_box --sound Frog Copied from work-laptop"
    End

    It 'local text row: toasts the moved-to-top acknowledgment'
      id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, source_host, last_ts) VALUES ('text','hello','mac-mini',100); SELECT last_insert_rowid();")
      When call run_fn clip::copy_by_id "$id"
      The status should be success
      The contents of file "$NOTIFYLOG" should include "--icon glyph:fa-clipboard-list --sound Frog Clipboard moved to top"
    End

    It 'missing notify binary is a silent no-op, copy still succeeds'
      rm -f "$BINDIR/notify"
      id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, source_host, last_ts) VALUES ('text','hello','work-laptop',100); SELECT last_insert_rowid();")
      When call run_fn clip::copy_by_id "$id"
      The status should be success
      The contents of file "$NOTIFYLOG" should equal ""
    End

    It 'files-restore failure with text fallback does NOT toast (W2 hold owns that)'
      # files kind + no recorded paths -> clip::copy_files_by_id fails fast,
      # copy_by_id falls through to the text fallback (bridge copy succeeds
      # via fake nc) -- CLIP_RESTORE_FAILURE is set, so no toast.
      id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, source_host, last_ts) VALUES ('files','/tmp/x','work-laptop',100); SELECT last_insert_rowid();")
      When call run_fn clip::copy_by_id "$id"
      The stderr should include 'no file paths recorded'
      The contents of file "$NOTIFYLOG" should equal ""
    End
  End

  Describe 'clip::progress_pct (§4.2 aggregate, pure)'
    It 'single path mirrors the current transfer percent'
      When call run_fn clip::progress_pct 0 1 45
      The output should equal 45
    End

    It 'aggregates completed paths over an N-path manifest'
      # 2 of 4 paths done, current one at 50% -> (200+50)/4 = 62
      When call run_fn clip::progress_pct 2 4 50
      The output should equal 62
    End

    It 'zero total degrades to 0, not a division error'
      When call run_fn clip::progress_pct 0 0 50
      The output should equal 0
    End
  End

  Describe 'clip::progress_decide (§4.2 throttle, pure)'
    It 'suppresses everything inside the 500ms grace window'
      When call run_fn clip::progress_decide 100.4 100.0 100.0 -100 45
      The output should equal ""
    End

    It 'first post-grace tick emits (spacing satisfied since start)'
      When call run_fn clip::progress_decide 100.6 100.0 100.0 -100 45
      The output should equal 1
    End

    It 'suppresses a tick inside the 300ms spacing window'
      When call run_fn clip::progress_decide 100.8 100.0 100.6 45 60
      The output should equal ""
    End

    It 'suppresses a sub-1-point delta even after the spacing window'
      When call run_fn clip::progress_decide 101.2 100.0 100.6 45 45
      The output should equal ""
    End

    It 'emits on >=1pt delta past the spacing window'
      When call run_fn clip::progress_decide 101.0 100.0 100.6 45 46
      The output should equal 1
    End

    It 'keep-alive: emits with NO delta after 1.5s of silence'
      When call run_fn clip::progress_decide 102.2 100.0 100.6 45 45
      The output should equal 1
    End
  End

  Describe 'clip::progress_stream (§4.2 headless sink)'
    It 'fast canned stream emits exactly one HUD update (throttle) once past grace'
      # progress_begin stamps start=now; forcing CLIP_PROGRESS_START back
      # to 0 puts every tick past the grace window deterministically. The
      # three ticks arrive within 300ms, so only the first can emit.
      When call zsh -f -c '
        source "$SCRIPT_PATH"
        clip::progress_begin
        CLIP_PROGRESS_START=0
        CLIP_PROGRESS_LAST_EMIT=0
        printf "  1,000  10%%\r  5,000  50%%\r 10,000 100%%\r" | clip::progress_stream 0 1 work-laptop
      '
      The status should be success
      # Emits are now supervised background spawns (§4.2b): the fake hs
      # writes its line asynchronously, so give it a moment to land before
      # reading HSLOG (this example was observed flaky without the pause).
      sleep 0.5
      The contents of file "$HSLOG" should equal 'require("osd").progress("glyph:nf-md-download", 10, "work-laptop")'
    End

    It 'aggregates over a multi-path manifest (path 3 of 4 at 50% -> 62)'
      When call zsh -f -c '
        source "$SCRIPT_PATH"
        clip::progress_begin
        CLIP_PROGRESS_START=0
        CLIP_PROGRESS_LAST_EMIT=0
        printf "  5,000  50%%\r" | clip::progress_stream 2 4 work-laptop
      '
      The status should be success
      # §4.2b: background spawn -- give the fake hs a moment to write
      # (observed flaky without the pause).
      sleep 0.2
      The contents of file "$HSLOG" should equal 'require("osd").progress("glyph:nf-md-download", 62, "work-laptop")'
    End

    It 'missing hs binary: sink drains stdin as a no-op'
      rm -f "$BINDIR/hs"
      When call zsh -f -c '
        source "$SCRIPT_PATH"
        clip::progress_begin
        CLIP_PROGRESS_START=0
        printf "  5,000  50%%\r" | clip::progress_stream 0 1 work-laptop
      '
      The status should be success
      The contents of file "$HSLOG" should equal ""
    End

    It 'pre-first-record wait is bright preparing state, then first chunk switches to copying'
      When call zsh -f -c '
        export PICK_CLIPBOARD_STALL_SECS=0.3
        source "$SCRIPT_PATH"
        clip::progress_begin
        CLIP_PROGRESS_START=0
        CLIP_PROGRESS_LAST_EMIT=0
        { sleep 0.8; printf "  1,000  10%%\r"; } | clip::progress_stream 0 1 "Copying report.zip from peer…"
      '
      The status should be success
      sleep 0.2
      The line 1 of contents of file "$HSLOG" should equal 'require("osd").progress("glyph:nf-md-download", 0, "Preparing to copy report.zip from peer…", "preparing")'
      The contents of file "$HSLOG" should end_with 'require("osd").progress("glyph:nf-md-download", 10, "Copying report.zip from peer…")'
    End

    It 'stall: quiet gap emits a stalled repaint, next chunk snaps back past the throttle (§4.3)'
      # STALL_SECS=0.3 keeps the test fast; the 0.8s quiet gap comfortably
      # exceeds it (>=1 stall tick guaranteed, timing-tolerant). START=0
      # puts every tick past the grace window.
      When call zsh -f -c '
        export PICK_CLIPBOARD_STALL_SECS=0.3
        source "$SCRIPT_PATH"
        clip::progress_begin
        CLIP_PROGRESS_START=0
        CLIP_PROGRESS_LAST_EMIT=0
        { printf "  1,000  10%%\r"; sleep 0.8; printf "  5,000  50%%\r"; } | clip::progress_stream 0 1 work-laptop
      '
      The status should be success
      # First emit: normal 10%. At least one stalled repaint carrying the
      # last known pct. Final emit: the post-stall 50% arrives while the
      # 300ms spacing window is still open -- only the stall bypass can
      # let it through, so this line IS the bypass assertion.
      # This shellspec (0.28.1) supports `The line N of contents of file`
      # but not a `last`/negative-index line modifier ("Unknown word 'last'
      # after contents modifier" / "parameter #1 of line modifier is not a
      # number" -- verified empirically), so the final property below uses
      # `should end_with` on the whole contents instead -- confirmed to
      # discriminate (fails when the file doesn't actually end with this
      # line, per a throwaway probe run before committing).
      # §4.2b: the final (post-stall) emit is a background spawn with no
      # subsequent progress_end in this example to synchronize on -- give
      # it a moment to land (observed flaky without the pause).
      sleep 0.2
      The line 1 of contents of file "$HSLOG" should equal 'require("osd").progress("glyph:nf-md-download", 10, "work-laptop")'
      The contents of file "$HSLOG" should include 'require("osd").progress("glyph:nf-md-download", 10, "work-laptop", true)'
      The contents of file "$HSLOG" should end_with 'require("osd").progress("glyph:nf-md-download", 50, "work-laptop")'
    End

    It 'a hung hs emit never blocks the sink; teardown reaps the straggler (§4.2b)'
      # Fake hs that logs its payload then hangs forever: with synchronous
      # emits this example would wedge until the shellspec timeout; with
      # supervised background emits the whole pipeline finishes in ~1s.
      cat > "$BINDIR/hs-hang" <<EOF
#!/bin/sh
[ -c /dev/fd/0 ] && [ "\$1" = "-q" ] && [ "\$2" = "-c" ] && printf '%s\n' "\$3" >> "$HSLOG"
sleep 300
EOF
      chmod +x "$BINDIR/hs-hang"
      export PICK_CLIPBOARD_HS="$BINDIR/hs-hang"
      When call zsh -f -c '
        source "$SCRIPT_PATH"
        clip::progress_begin
        CLIP_PROGRESS_START=0
        CLIP_PROGRESS_LAST_EMIT=0
        { printf "  1,000  10%%\r"; sleep 0.4; printf "  5,000  50%%\r"; sleep 0.4; printf "  9,000  90%%\r"; } | clip::progress_stream 0 1 hang-probe
        clip::progress_end
        # Teardown killed the last emitter: its pid must be gone.
        if [[ -n "${CLIP_PROGRESS_EMIT_PID:-}" ]] && kill -0 "$CLIP_PROGRESS_EMIT_PID" 2>/dev/null; then
          print -u2 -- "straggler-still-alive"
          exit 90
        fi
      '
      The status should be success
      # progress_end launches hide fire-and-forget; allow its fake to log.
      sleep 0.2
      The contents of file "$HSLOG" should include 'require("osd").progress("glyph:nf-md-download", 10, "hang-probe")'
      The contents of file "$HSLOG" should include 'require("osd").progress("glyph:nf-md-download", 50, "hang-probe")'
      The contents of file "$HSLOG" should include 'require("osd").progress("glyph:nf-md-download", 90, "hang-probe")'
      The contents of file "$HSLOG" should include 'require("osd").progressHide()'
    End
  End

  Describe '--restore-id headless pull with progress plumbing (§4.2)'
    It 'pull succeeds; sub-grace transfer emits no HUD calls; toast still fires'
      id=$(seed_remote_manifest_row)
      When call run_restore_id "$id"
      The status should be success
      # The fake rsync finishes instantly -- inside the 500ms grace window,
      # so the HUD must never flash (and progressHide is skipped: nothing
      # was shown).
      The contents of file "$HSLOG" should equal ""
      The contents of file "$NOTIFYLOG" should include "--icon glyph:nf-md-file_multiple --sound Frog Copied from work-laptop"
    End
  End

  Describe 'cancellation + resumable staging lifecycle (§4.4)'
    It 'rsync failure removes the partial cache dir'
      id=$(seed_remote_manifest_row)
      cat > "$BINDIR/rsync-fail" <<EOF
#!/bin/sh
argc=\$#
eval "dst=\\\${\$argc}"
mkdir -p "\$dst/partial-dir"
printf partial > "\$dst/partial-dir/chunk"
exit 23
EOF
      chmod +x "$BINDIR/rsync-fail"
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync-fail"
      When call run_restore_id "$id"
      The status should equal 1
      The stderr should include 'rsync failed pulling'
      The path "$HOME/.cache/pick-clipboard/files/$id/1" should not be exist
      The contents of file "$NOTIFYLOG" should equal ""
    End

    It 'a failed pull does not poison the cache: the next pick re-pulls and succeeds'
      id=$(seed_remote_manifest_row)
      cat > "$BINDIR/rsync-fail" <<EOF
#!/bin/sh
argc=\$#
eval "dst=\\\${\$argc}"
mkdir -p "\$dst/partial-dir"
exit 23
EOF
      chmod +x "$BINDIR/rsync-fail"
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync-fail"
      run_restore_id "$id" 2>/dev/null || true
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync"
      When call run_restore_id "$id"
      The status should be success
      The contents of file "$NOTIFYLOG" should include "Copied from work-laptop"
    End

    It 'TERM mid-pull runs the cancel path: exit 130, partial retained, quiet toast'
      id=$(seed_remote_manifest_row)
      cat > "$BINDIR/rsync-slow" <<EOF
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in --partial-dir=*) partial=\${arg#*=} ;; esac
done
mkdir -p "\$partial"
printf partial > "\$partial/chunk"
sleep 1
exit 0
EOF
      chmod +x "$BINDIR/rsync-slow"
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync-slow"
      run_cancelled_restore() {
        zsh -f "$SCRIPT" --restore-id "$1" &
        _pid=$!
        sleep 0.4
        kill -TERM "$_pid" 2>/dev/null
        wait "$_pid"
      }
      When call run_cancelled_restore "$id"
      The status should equal 130
      The path "$HOME/.cache/pick-clipboard/files/$id/.partial/1" should be exist
      The path "$HOME/.cache/pick-clipboard/files/$id/.partial-data/1/chunk" should be exist
      The contents of file "$NOTIFYLOG" should include "--icon glyph:nf-md-close Transfer cancelled"
      The contents of file "$NOTIFYLOG" should not include "Copied from"
    End

    It 'the next pull reuses a retained partial and clears its staging marker'
      id=$(seed_remote_manifest_row)
      sub="$HOME/.cache/pick-clipboard/files/$id/1"
      partial="$HOME/.cache/pick-clipboard/files/$id/.partial-data/1"
      marker="$HOME/.cache/pick-clipboard/files/$id/.partial/1"
      mkdir -p "$sub" "$partial" "${marker:h}"
      printf partial > "$partial/chunk"
      : > "$marker"
      cat > "$BINDIR/rsync-resume" <<EOF
#!/bin/sh
partial=""
for arg in "\$@"; do
  case "\$arg" in --partial-dir=*) partial=\${arg#*=} ;; esac
done
[ "\$partial" = "$partial" ] || exit 98
argc=\$#
eval "src=\\\${\$((argc - 1))}"
eval "dst=\\\${\$argc}"
[ -f "\$partial/chunk" ] || exit 97
base="\${src##*/}"
printf resumed > "\$dst/\$base"
rm -f "\$partial/chunk"
EOF
      chmod +x "$BINDIR/rsync-resume"
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync-resume"
      When call run_restore_id "$id"
      The status should be success
      The path "$sub/big.bin" should be exist
      The path "$marker" should not be exist
      The path "$partial" should not be exist
      The contents of file "$NOTIFYLOG" should include "Copied from"
    End

    It '24-hour sweep removes expired bytes and their un-restorable localized row'
      sub="$HOME/.cache/pick-clipboard/files/77/1"
      iddir="${sub:h}"
      mkdir -p "$sub" "$iddir/.authorized" "$iddir/.partial" "$iddir/.partial-data/1"
      printf staged > "$sub/report.bin"
      : > "$iddir/.authorized/1"
      : > "$iddir/.partial/1"
      printf partial > "$iddir/.partial-data/1/chunk"
      printf '%s' "$sub/report.bin" > "$SHELLSPEC_TMPBASE/localized-blob"
      localized_id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','peer',100); SELECT last_insert_rowid();")
      sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($localized_id, 'x-resolved-path', readfile('$SHELLSPEC_TMPBASE/localized-blob'));"
      touch -t 202001010000 "$sub"
      export PICK_CLIPBOARD_CACHE_TTL=1
      export LOCALIZED_ID="$localized_id"
      When call zsh -f -c '
        source "$SCRIPT_PATH"
        clip::cache_sweep
        sqlite3 "$DB_FILE" "SELECT count(*) FROM clips WHERE id=$LOCALIZED_ID;"
      '
      The status should be success
      The output should equal "0"
      The path "$sub" should not be exist
      The path "$iddir" should not be exist
    End
  End

  Describe 'clip::progress_label (§4.2a, pure)'
    It 'single path -> Copying <basename> from <host>…'
      When call run_fn clip::progress_label 1 work-laptop /remote/src/big-clip.bin
      The output should equal 'Copying big-clip.bin from work-laptop…'
    End

    It 'multi path -> Copying N files from <host>…'
      When call run_fn clip::progress_label 3 work-laptop /remote/src/first.txt
      The output should equal 'Copying 3 files from work-laptop…'
    End
  End

  Describe 'clip::progress_emit label escaping (§4.2a)'
    # Expected value has ONE escaped backslash (\\) ahead of "name": the
    # label's single literal backslash is doubled once by clip::progress_emit
    # for Lua-string embedding (a real `hs -c` evaluates the -c argument as
    # Lua source, where "\\" decodes back to one literal backslash) -- this
    # is the literal -c argument text, not a further-escaped rendering of it.
    # Discrimination-verified: reverting the backslash-escape line in
    # clip::progress_emit (so the label's `\` passes through unescaped)
    # makes this assertion fail (the log then holds a single unescaped `\`
    # ahead of "name" instead of the doubled `\\`).
    It 'escapes backslash and double quote; CR/LF become spaces'
      When call zsh -f -c '
        source "$SCRIPT_PATH"
        clip::progress_begin
        clip::progress_emit 40 "we\"ird\\name"
      '
      The status should be success
      # §4.2b: background spawn -- give the fake hs a moment to write
      # (observed flaky without the pause).
      sleep 0.2
      The contents of file "$HSLOG" should include 'require("osd").progress("glyph:nf-md-download", 40, "we\"ird\\name")'
    End

    It 'CR and LF in a label become spaces (a filename could carry either)'
      When call zsh -f -c '
        source "$SCRIPT_PATH"
        clip::progress_begin
        clip::progress_emit 40 $'"'"'weird\rna\nme'"'"'
      '
      The status should be success
      # §4.2b: background spawn -- give the fake hs a moment to write
      # (observed flaky without the pause).
      sleep 0.2
      The contents of file "$HSLOG" should include 'require("osd").progress("glyph:nf-md-download", 40, "weird na me")'
    End
  End

  # Wave 2 consolidation: the restore-failure box routes its gum styling through
  # the shared theme::gum_style_env (danger role) instead of an inline GUM_STYLE_*
  # env. The gum call itself writes to /dev/tty (untestable headless, same as
  # pbpaste's size-cap dialog), but the SHARED ENV it exports is what matters:
  # run the real function (gum stubbed, its /dev/tty write allowed to fail and be
  # swallowed) and assert the GUM_STYLE_* it exported equals the canonical danger
  # accent (C_HEX_DIALOG_DANGER) — i.e. the caller renders with the shared env.
  Describe 'clip::render_restore_failure (Wave 2: shared gum_style env)'
    # Returns 0 iff the GUM_STYLE_* the function exported both equal the
    # canonical danger accent (C_HEX_DIALOG_DANGER). The gum stub's /dev/tty
    # write is expected to fail headless and is swallowed — the export happens
    # first, which is the point of the assertion.
    render_uses_shared_env() {
      printf '#!/bin/sh\nexit 0\n' > "$BINDIR/gum"; chmod +x "$BINDIR/gum"
      local out fg rest border canon
      out=$(zsh -f -c '
        source "$SCRIPT_PATH"
        clip::render_restore_failure "boom" 2>/dev/null || true
        print -r -- "$GUM_STYLE_FOREGROUND|$GUM_STYLE_BORDER_FOREGROUND|$C_HEX_DIALOG_DANGER"
      ')
      fg=${out%%|*}; rest=${out#*|}; border=${rest%%|*}; canon=${rest#*|}
      [ -n "$canon" ] && [ "$fg" = "$canon" ] && [ "$border" = "$canon" ]
    }
    It 'exports GUM_STYLE_* set to the canonical danger accent'
      When call render_uses_shared_env
      The status should be success
    End
  End
End
