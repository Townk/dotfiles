# pick-clipboard Ctrl-S (share) — what the human sees when it cannot share.
# Spec: docs/superpowers/specs/2026-08-18-share-phase3-faces-design.md
#
# Ctrl-S is accept-and-DISMISS: by the time the share helpers run, the tmux
# popup is closing and its stderr dies with it. Mode B (2026-09-29) found a
# text row's refusal vanished — the picker just closed. Every refusal must
# therefore ALSO reach the notify front-end, the same best-effort route Ctrl-Y's
# copy toast takes (PICK_CLIPBOARD_NOTIFY is the seam).

Describe 'pick-clipboard: Ctrl-S feedback'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    SB="$SHELLSPEC_TMPBASE/pick-share"; rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/home"
    DB="$SB/history.db"
    sqlite3 "$DB" "
      CREATE TABLE clips (id INTEGER PRIMARY KEY, type_kind TEXT, text_preview TEXT,
                          source_host TEXT, last_ts REAL);
      CREATE TABLE clip_types (clip_id INTEGER, uti TEXT, blob BLOB);
      INSERT INTO clips VALUES (1, 'text', 'hello', 'mac-mini', 1);
      INSERT INTO clips VALUES (2, 'file', '/nowhere/gone.pdf', 'work-laptop', 2);
      INSERT INTO clip_types VALUES (2, 'x-resolved-path', CAST('/nowhere/gone.pdf' AS BLOB));"
    NOTIFYLOG="$SB/notifylog"; : >"$NOTIFYLOG"
    cat >"$SB/bin/notify" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$NOTIFYLOG"
EOF
    SHARELOG="$SB/sharelog"; : >"$SHARELOG"
    # A share that "fell back to stored": success, empty stdout.
    cat >"$SB/bin/share" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$SHARELOG"
EOF
    chmod +x "$SB/bin/notify" "$SB/bin/share"
    export PICK_CLIPBOARD_NO_RUN=1 PICK_LIB_DIR="$LIB_DIR" PICK_CLIPBOARD_DB="$DB"
    export PICK_CLIPBOARD_NOTIFY="$SB/bin/notify" HOME="$SB/home"
    export SCRIPT_PATH="$SCRIPT" PATH="$SB/bin:$PATH"
  }
  BeforeEach 'setup'

  # Calls a sourced picker function, zsh -f sandboxed; never fails the caller,
  # so an example can assert on output and the notify log together.
  run_fn() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      fn=$1; shift
      "$fn" "$@"
    ' _ "$@" || :
  }

  It 'toasts the refusal for a text row, not just stderr'
    When call run_fn clip::share_by_id 1
    The stdout should equal ''
    The stderr should include 'Ctrl-S shares files — this row is text'
    The contents of file "$NOTIFYLOG" should include 'Ctrl-S shares files — this row is text'
  End

  It 'never runs share for a text row'
    run_fn clip::share_by_id 1 >/dev/null 2>&1
    When call cat "$SHARELOG"
    The output should equal ''
  End

  It 'toasts the refusal for files that are not on this machine, naming Ctrl-Y'
    When call run_fn clip::share_by_id 2
    The stdout should equal ''
    The stderr should include 'press Ctrl-Y first'
    The contents of file "$NOTIFYLOG" should include 'press Ctrl-Y first'
  End

  It 'toasts the stored fallback, since there is no line to inject'
    : >"$SB/here.txt"
    When call run_fn clip::share_paths "$SB/here.txt"
    The stdout should equal ''
    The stderr should include 'the link will arrive in a toast'
    The contents of file "$NOTIFYLOG" should include 'the link will arrive in a toast'
  End

  # The toast is best-effort, like Ctrl-Y's: no front-end is not an error.
  It 'still refuses on stderr when there is no notify front-end'
    export PICK_CLIPBOARD_NOTIFY="$SB/bin/absent"
    When call run_fn clip::share_by_id 1
    The stderr should include 'Ctrl-S shares files — this row is text'
  End
End
