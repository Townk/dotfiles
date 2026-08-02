# pick-clipboard: the borderless front-end flag (shared-lib Wave 2, group C5,
# Decision 1). pick-clipboard now accepts --no-border on the command line —
# matching pick-glyph / pick-gitmoji — so all four zellij picker adapters can
# drive the borderless look through the flag form instead of an env var. The
# parsed `no_border` is what gates `pick_args+=(--no-border)` fed into
# pick::start (the fzf --no-border / pick_ui[no_border] the floating pane wants).
#
# Harness: source the picker under PICK_CLIPBOARD_NO_RUN (its test-only escape
# hatch, which returns before the interactive fzf session) in a zsh -f sandbox,
# then read back the resolved `no_border`. The env var PICK_CLIPBOARD_NO_BORDER
# is still honored as harmless back-compat.
Describe 'pick-clipboard: --no-border front-end'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    export HOME="$SHELLSPEC_TMPBASE/home"; rm -rf "$HOME"; mkdir -p "$HOME"
    export TMPDIR="$SHELLSPEC_TMPBASE/tmp"; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"; mkdir -p "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    export PICK_CLIPBOARD_DB="$DB"
    rm -f "$DB"
    # A minimal store: sourcing only needs the file to exist (no clips query
    # runs before the NO_RUN return on the non-bridge path), but seed the
    # schema so the source is realistic.
    sqlite3 "$DB" 'CREATE TABLE clips (id INTEGER PRIMARY KEY, text_plain TEXT, source_host TEXT);'
    export PICK_COMMON_LIB="$LIB_DIR/pick-common.zsh"
    export PICK_BRIDGE_CLIENT_LIB="$LIB_DIR/clipboard-bridge-client.zsh"
    export PICK_CLIPBOARD_CORE_LIB="$LIB_DIR/clipboard-store-core.zsh"
    export SCRIPT_PATH="$SCRIPT"
  }
  BeforeEach 'setup'

  # Source the picker under NO_RUN with the given argv and echo the resolved
  # no_border. `shift` then `source "$s" "$@"` passes an EXPLICIT (possibly
  # empty) positional list, so the sourced script never inherits this runner's
  # own $@.
  resolve_no_border() {
    PICK_CLIPBOARD_NO_RUN=1 zsh -f -c '
      s="$1"; shift
      source "$s" "$@"
      print -r -- "$no_border"
    ' _ "$SCRIPT_PATH" "$@"
  }

  It 'defaults to no_border=0 with no flag and no env'
    When call resolve_no_border
    The status should be success
    The output should equal "0"
  End

  It 'sets no_border=1 from the --no-border CLI flag'
    When call resolve_no_border --no-border
    The status should be success
    The output should equal "1"
  End

  It 'still honors PICK_CLIPBOARD_NO_BORDER (back-compat) with no flag'
    export PICK_CLIPBOARD_NO_BORDER=1
    When call resolve_no_border
    The status should be success
    The output should equal "1"
  End
End
