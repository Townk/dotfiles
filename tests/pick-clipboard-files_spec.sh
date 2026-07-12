# Tests for pick-clipboard's Ctrl-Y files branch (files-yazi design §9,
# docs/superpowers/specs/2026-07-11-clipboard-phase6-files-yazi-design.md,
# task 10 / M2): `clip::copy_by_id` no longer degrades a files/file/directory
# row to path text.
#
# The picker (`executable_pick-clipboard`) is a zsh script that ends by
# running an interactive fzf session unconditionally -- PICK_CLIPBOARD_NO_RUN
# is a test-only escape hatch this task adds (see the "run" section near the
# bottom of the script) that sources the file's functions and returns before
# that session ever starts, so a test can call clip::copy_by_id directly
# against a seeded store + faked bridge/rsync.
#
# Seeds a temp SQLite store with the same schema clipboard-history.lua
# creates (CREATE TABLE statements at ~clipboard-history.lua:275-295) -- same
# convention as tests/clipboard-files-ops_spec.sh's "L list-files" Describe.
# Bridge sends are captured by a fake `nc` on PATH (same log convention as
# tests/pbpaste-files_spec.sh: "<port>:<frame-with-NUL-as-|>"); the remote
# pull is captured by a fake `rsync` on PATH (clip::copy_files_by_id resolves
# rsync via $PATH, not pbpaste's pinned /opt/homebrew/bin/rsync, specifically
# so a test can shadow it this way).
Describe 'pick-clipboard: Ctrl-Y files branch (clip::copy_by_id)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    # SHELLSPEC_TMPBASE is shared across every It in this file (same
    # convention noted in tests/clipboard-files-ops_spec.sh), and the DB's
    # AUTOINCREMENT restarts at 1 each time it's dropped+recreated below --
    # so two different Its can end up localizing the SAME clip id. Without
    # wiping ~/.cache here, a later It would find an earlier It's cached
    # files already sitting under files/<id>/ and (correctly, per the
    # no-re-fetch behavior under test) skip rsync -- a false pass/fail
    # bleeding across examples. Fresh HOME dir per It avoids it.
    export HOME="$SHELLSPEC_TMPBASE/home"; rm -rf "$HOME"; mkdir -p "$HOME"
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

    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
    # Fake nc: logs "<port>:<raw frame, NUL -> '|'>" (pbpaste-files_spec.sh's
    # convention) then always answers a bare 'O' status + zero-length body --
    # good enough for clipbridge::send, which only inspects the status byte.
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

    # Fake scutil: pins THIS host's name (mac-mini) for the
    # source_host==this-host / remote comparison -- same convention as
    # tests/pbpaste-files_spec.sh.
    cat > "$BINDIR/scutil" <<'EOF'
#!/bin/sh
if [ "$1" = "--get" ] && [ "$2" = "LocalHostName" ]; then
  echo mac-mini
  exit 0
fi
exit 1
EOF
    chmod +x "$BINDIR/scutil"

    RSYNCLOG="$SHELLSPEC_TMPBASE/rsynclog"; : > "$RSYNCLOG"
    # Fake rsync: logs its full argv, then fabricates the "pulled" file at the
    # destination (last two args: "host:/remote/path" source, "dir/" dest) so
    # the localization step has real bytes to find. $RSYNCLOG is baked in at
    # WRITE time (unquoted heredoc); argv/dst/base are computed at RUN time
    # (escaped so the heredoc leaves them literal).
    cat > "$BINDIR/rsync" <<EOF
#!/bin/sh
echo "\$*" >> "$RSYNCLOG"
argc=\$#
eval "src=\\\${\$((argc - 1))}"
eval "dst=\\\${\$argc}"
name="\${src##*:}"
base="\${name##*/}"
mkdir -p "\$dst"
printf 'pulled:%s' "\$base" > "\$dst/\$base"
EOF
    chmod +x "$BINDIR/rsync"

    export PATH="$BINDIR:$PATH"
    export PICK_COMMON_LIB="$LIB_DIR/pick-common.zsh"
    export PICK_BRIDGE_CLIENT_LIB="$LIB_DIR/clipboard-bridge-client.zsh"
    export PICK_CLIPBOARD_NO_RUN=1
    export SCRIPT_PATH="$SCRIPT"
  }
  BeforeEach 'setup'

  # Runs `clip::copy_by_id <id>` in a fresh zsh -f (no ~/.zshenv --
  # clipboard-files-ops_spec.sh's own note applies here too: an unguarded
  # invocation would let this repo's ~/.zshenv clobber the sandboxed
  # XDG_DATA_HOME/HOME before the script ever sees them) that sources the
  # picker under PICK_CLIPBOARD_NO_RUN, then calls the function directly.
  run_copy() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      clip::copy_by_id "$1"
    ' _ "$1"
  }

  It 'local files row: sends U with the id:<n> form to the local bridge port'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','mac-mini',100); SELECT last_insert_rowid();")

    When call run_copy "$id"
    The status should be success
    The contents of file "$NCLOG" should include "2489:U"
    The contents of file "$NCLOG" should include "id:$id"
    The contents of file "$RSYNCLOG" should equal ""
  End

  It 'local files row (NULL source_host, legacy capture): still uses the id:<n> form'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts) VALUES ('directory',100); SELECT last_insert_rowid();")

    When call run_copy "$id"
    The status should be success
    The contents of file "$NCLOG" should include "2489:U"
    The contents of file "$NCLOG" should include "id:$id"
  End

  It 'remote manifest row: rsyncs each manifest path into the per-clip cache dir'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',200); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '/tmp/remote-a.txt\000/tmp/remote-b.txt' > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should include "devbox:/tmp/remote-a.txt"
    The contents of file "$RSYNCLOG" should include "devbox:/tmp/remote-b.txt"
    The contents of file "$RSYNCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/"
    The path "$HOME/.cache/pick-clipboard/files/$id/remote-a.txt" should be exist
    The path "$HOME/.cache/pick-clipboard/files/$id/remote-b.txt" should be exist
  End

  It 'remote manifest row: sends U with the localized NUL-joined paths (not id:)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',201); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '/tmp/remote-a.txt\000/tmp/remote-b.txt' > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$NCLOG" should include "2489:U"
    The contents of file "$NCLOG" should not include "id:$id"
    The contents of file "$NCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/remote-a.txt"
    The contents of file "$NCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/remote-b.txt"
  End

  It 'remote manifest row: records a localized clip (new row, source_host stays the origin host)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',202); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '/tmp/remote-a.txt\000/tmp/remote-b.txt' > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    row_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM clips WHERE id != $id AND source_host = 'devbox' AND type_kind = 'files';")
    The variable row_count should equal 1
    blob_uti=$(sqlite3 "$DB" "SELECT uti FROM clip_types WHERE clip_id = (SELECT MAX(id) FROM clips) AND uti IN ('x-file-manifest','x-resolved-path');")
    The variable blob_uti should equal "x-file-manifest"
  End

  It 'remote manifest row: a second Ctrl-Y on the same row does not re-rsync an already-cached path'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','devbox',203); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '/tmp/remote-a.txt' > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    run_copy "$id" >/dev/null 2>&1
    : > "$RSYNCLOG"
    When call run_copy "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should equal ""
  End

  It 'local restore failure falls back to the current text-copy behavior'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('file','mac-mini',300,'/tmp/a.txt'); SELECT last_insert_rowid();")
    cat > "$BINDIR/nc" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$BINDIR/nc"

    When call run_copy "$id"
    The status should be success
    The stderr should include "files restore"
  End

  It 'a failed rsync falls back to the current text-copy behavior (T set, not U)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('files','devbox',301,'/tmp/a.txt /tmp/b.txt'); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '/tmp/remote-a.txt\000/tmp/remote-b.txt' > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"
    cat > "$BINDIR/rsync" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$BINDIR/rsync"

    When call run_copy "$id"
    The status should be success
    The stderr should include "rsync failed"
    The contents of file "$NCLOG" should include "2489:T"
    The contents of file "$NCLOG" should not include "2489:U"
  End
End
