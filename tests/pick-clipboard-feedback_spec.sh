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

  Describe 'clip::toast_spec (§6 variant selection, pure)'
    It 'remote text row -> text glyph + Copied from <host>'
      When call run_fn clip::toast_spec text work-laptop
      The output should equal "glyph:nf-md-text_box$(printf '\x1f')Copied from work-laptop"
    End

    It 'remote files row -> file_multiple glyph'
      When call run_fn clip::toast_spec files work-laptop
      The output should equal "glyph:nf-md-file_multiple$(printf '\x1f')Copied from work-laptop"
    End

    It 'remote image/file/directory rows -> their kind glyphs'
      When call run_fn clip::toast_spec image work-laptop
      The output should equal "glyph:nf-md-image$(printf '\x1f')Copied from work-laptop"
    End

    It 'unknown kind falls back to the text glyph'
      When call run_fn clip::toast_spec url work-laptop
      The output should equal "glyph:nf-md-text_box$(printf '\x1f')Copied from work-laptop"
    End

    It 'own-host row -> local acknowledgment variant'
      When call run_fn clip::toast_spec text mac-mini
      The output should equal "glyph:fa-clipboard-list$(printf '\x1f')Clipboard moved to top"
    End

    It 'empty host (legacy row) reads as local'
      When call run_fn clip::toast_spec files ''
      The output should equal "glyph:fa-clipboard-list$(printf '\x1f')Clipboard moved to top"
    End
  End
End
