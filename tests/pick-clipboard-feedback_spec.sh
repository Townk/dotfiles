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
    # Fake hs CLI: logs the -c payload, one line per call.
    cat > "$BINDIR/hs" <<EOF
#!/bin/sh
[ "\$1" = "-c" ] && echo "\$2" >> "$HSLOG"
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
      The line 1 of contents of file "$HSLOG" should equal 'require("osd").progress("glyph:nf-md-download", 10, "work-laptop")'
      The contents of file "$HSLOG" should include 'require("osd").progress("glyph:nf-md-download", 10, "work-laptop", true)'
      The contents of file "$HSLOG" should end_with 'require("osd").progress("glyph:nf-md-download", 50, "work-laptop")'
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

  Describe 'cancellation + partial-cache cleanup (§4.4)'
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

    It 'TERM mid-pull runs the cancel path: exit 130, partial removed, quiet toast'
      id=$(seed_remote_manifest_row)
      cat > "$BINDIR/rsync-slow" <<EOF
#!/bin/sh
argc=\$#
eval "dst=\\\${\$argc}"
mkdir -p "\$dst/partial-dir"
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
      The path "$HOME/.cache/pick-clipboard/files/$id/1" should not be exist
      The contents of file "$NOTIFYLOG" should include "--icon glyph:nf-md-close Transfer cancelled"
      The contents of file "$NOTIFYLOG" should not include "Copied from"
    End
  End
End
