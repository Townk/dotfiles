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
      INSERT INTO clip_types VALUES (2, 'x-resolved-path', CAST('/nowhere/gone.pdf' AS BLOB));
      INSERT INTO clips VALUES (3, 'file', 'gone.pdf', NULL, 3);
      INSERT INTO clip_types VALUES (3, 'x-resolved-path', CAST('/nowhere/gone.pdf' AS BLOB));"
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
  # MY_HOST is pinned AFTER sourcing: the script derives it at load time from
  # the real machine, and origin decisions key on it.
  run_fn() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      MY_HOST=mac-mini
      [[ -n "${TEST_LIVEF_HOST-}" ]] && { LIVEF_HOST=$TEST_LIVEF_HOST; LIVEF_PATHS_FILE=$TEST_LIVEF_PATHS; }
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

  # Mode B (2026-09-29): the old advice, "press Ctrl-Y first to bring them
  # local", led nowhere — since clipboard phase 6b Ctrl-Y puts a reverse-mount
  # POINTER on the clipboard, never a local copy, so the row stays remote and
  # Ctrl-S refused again. Files from another machine are shared from THAT
  # machine: the human is sitting at it, and the mount's files are untrusted
  # here (org.chezmoi.clipboard.UntrustedFileURLs), so relaying them onward
  # would cross the boundary the clipboard design enforces.
  It 'refuses a row from another machine, saying where to share it from'
    When call run_fn clip::share_by_id 2
    The stdout should equal ''
    The stderr should include 'gone.pdf is on work-laptop — share it from there'
    The contents of file "$NOTIFYLOG" should include 'gone.pdf is on work-laptop — share it from there'
    The contents of file "$NOTIFYLOG" should not include 'Ctrl-Y'
  End

  # Origin, not path existence, decides. Machines sharing a username share
  # path shapes, so a remote row can name a path that ALSO exists here — a
  # different file, which must never be sent in its place.
  It 'refuses a remote row even when the same path exists on this machine'
    : >"$SB/collide.txt"
    sqlite3 "$DB" "INSERT INTO clips VALUES (4, 'file', 'collide.txt', 'work-laptop', 4);
                   INSERT INTO clip_types VALUES (4, 'x-resolved-path', CAST('$SB/collide.txt' AS BLOB));"
    run_fn clip::share_by_id 4 >/dev/null 2>&1
    When call cat "$SHARELOG"
    The output should equal ''
  End

  It 'names the file count for a multi-file remote row'
    # Hex, not '||' concatenation: a NUL inside SQL text is not reliable.
    local hex; hex="$(printf '/x/a.pdf\0/x/b.pdf' | xxd -p | tr -d '\n')"
    sqlite3 "$DB" "INSERT INTO clips VALUES (5, 'files', 'a b', 'work-laptop', 5);
                   INSERT INTO clip_types VALUES (5, 'x-file-manifest', X'$hex');"
    When call run_fn clip::share_by_id 5
    The stderr should include '2 files are on work-laptop — share them from there'
  End

  It 'refuses the live files row, which is always the peer machine'
    printf '/x/live.pdf' >"$SB/livef"
    export TEST_LIVEF_HOST=work-laptop TEST_LIVEF_PATHS="$SB/livef"
    When call run_fn clip::share_live_files
    The stdout should equal ''
    The stderr should include 'live.pdf is on work-laptop — share it from there'
  End

  # A LOCAL row (NULL host = legacy local) whose file has since gone.
  It 'says a local file is gone, without the old Ctrl-Y advice'
    When call run_fn clip::share_by_id 3
    The stderr should include 'no longer on this machine'
    The stderr should not include 'Ctrl-Y'
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

  It 'names the other machine by its learned alias'
    printf 'work-laptop peer-laptop\n' >"$SB/host-aliases"
    export HOST_ALIASES_FILE="$SB/host-aliases"
    When call run_fn clip::share_by_id 2
    The stderr should include 'gone.pdf is on peer-laptop — share it from there'
  End
End
