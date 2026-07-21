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
End
