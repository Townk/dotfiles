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
# pull is captured by a fake `rsync` wired in via PICK_CLIPBOARD_RSYNC (the
# picker pins /opt/homebrew/bin/rsync in production, same as pbpaste -- the
# env var is the test-only override documented in clip::copy_files_by_id).
#
# Remote manifest paths in these tests live under /pick-clipboard-remote-src/
# -- a root that never exists on the test machine. The localized-row guard is
# restricted to the picker's own cache root, so a real local path could no
# longer short-circuit the rsync branch, but keeping remote paths obviously
# nonexistent stays the honest fixture shape (they ARE remote paths).
Describe 'pick-clipboard: Ctrl-Y files branch (clip::copy_by_id)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
  REMOTE_SRC="/pick-clipboard-remote-src"

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
    # A dedicated TMPDIR (spec R3): the rsync-failure test below globs for the
    # stderr-capture temp file clip::copy_files_by_id leaves behind on a
    # failed pull, which needs a clean, known directory rather than whatever
    # this machine's ambient TMPDIR happens to already contain.
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
    # Test-only override (documented in clip::copy_files_by_id): production
    # pins /opt/homebrew/bin/rsync exactly like pbpaste's tier 2 -- an
    # absolute-path invocation can't be shadowed via PATH, so the fake is
    # wired in through this env var instead.
    export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync"
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

  # Runs the SCRIPT directly (not sourced, no PICK_CLIPBOARD_NO_RUN escape
  # hatch) with --restore-id <id> as real argv (spec R4's headless CLI mode).
  # clipboard-picker.lua's hs.task call now wraps this same argv in
  # `/bin/zsh -lc` for an environment-faithful login shell (W3); the CLI's
  # own contract -- and what this helper exercises -- is unchanged. -f: same
  # ~/.zshenv guard as run_copy above.
  run_restore_id() {
    zsh -f "$SCRIPT" --restore-id "$1"
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

  # X2-redo gap fix: an M-persisted row (op M, manifest-persist-local --
  # pbcopy over SSH persisting DIRECTLY to this machine's OWN store, since a
  # locked/headless origin's Hammerspoon watcher can never capture the
  # pasteboard) has source_host==self, same as a genuine local capture, but
  # carries ONLY an x-file-manifest blob -- no NSFilenamesPboardType/
  # public.file-url, since no real pasteboard write ever happened. A genuine
  # Hammerspoon capture never writes x-file-manifest at all (only N's
  # cross-machine push and the picker's own localization step do, neither of
  # which is source_host==self) -- so `srcuti == x-file-manifest` reliably
  # picks out this shape. restore_by_id's blind writeAllData over just that
  # private UTI would silently paste nothing in Finder; this must route
  # through form A with the manifest's own (already-local, no cache-root
  # check needed) paths instead of the id:<n> form.
  It 'local M-persisted row (source_host=self, only an x-file-manifest blob): sends U with the raw paths, not id:'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','mac-mini',150); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/local-manifest.bin"
    printf '%s/local-a.txt\000%s/local-b.txt' "$HOME" "$HOME" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$NCLOG" should include "2489:U"
    The contents of file "$NCLOG" should include "$HOME/local-a.txt|$HOME/local-b.txt"
    The contents of file "$NCLOG" should not include "id:$id"
    The contents of file "$RSYNCLOG" should equal ""
  End

  It 'remote manifest row: rsyncs each manifest path into its per-position cache subdir'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',200); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt\000%s/remote-b.txt' "$REMOTE_SRC" "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should include "devbox:$REMOTE_SRC/remote-a.txt"
    The contents of file "$RSYNCLOG" should include "devbox:$REMOTE_SRC/remote-b.txt"
    The contents of file "$RSYNCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/1/"
    The contents of file "$RSYNCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/2/"
    The path "$HOME/.cache/pick-clipboard/files/$id/1/remote-a.txt" should be exist
    The path "$HOME/.cache/pick-clipboard/files/$id/2/remote-b.txt" should be exist
  End

  It 'remote manifest row: sends U with the localized NUL-joined paths (not id:)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',201); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt\000%s/remote-b.txt' "$REMOTE_SRC" "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$NCLOG" should include "2489:U"
    The contents of file "$NCLOG" should not include "id:$id"
    The contents of file "$NCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/1/remote-a.txt"
    The contents of file "$NCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/2/remote-b.txt"
  End

  # Reviewer finding 1 (critical): two manifest entries sharing a basename
  # used to collide on one flat cache path -- only ONE rsync ran and the U
  # payload carried the same localized path twice, silently losing a file.
  # The per-position <idx>/ namespacing must keep them distinct end to end:
  # two rsync invocations, two distinct paths in the U payload AND in the
  # localized row's recorded blob.
  It 'remote manifest row: two paths sharing a basename stay distinct (per-position namespacing)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',210); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/dirA/README.md\000%s/dirB/README.md' "$REMOTE_SRC" "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should include "devbox:$REMOTE_SRC/dirA/README.md"
    The contents of file "$RSYNCLOG" should include "devbox:$REMOTE_SRC/dirB/README.md"
    The contents of file "$NCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/1/README.md"
    The contents of file "$NCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/2/README.md"
    # The localized row's own blob must record two DISTINCT paths. Extracted
    # via writefile: the sqlite3 CLI truncates direct blob output at the
    # first embedded NUL (verified empirically), so a `SELECT blob` pipe
    # would only ever show the first path. tr the NUL joints to newlines
    # BEFORE the $(...) capture; grep -c counts the de-duplicated survivors
    # -- 1 would mean the old collision.
    locblob="$SHELLSPEC_TMPBASE/localized-blob"
    sqlite3 "$DB" "SELECT writefile('$locblob', blob) FROM clip_types WHERE clip_id=(SELECT MAX(id) FROM clips) AND uti='x-file-manifest';" >/dev/null
    distinct=$(tr '\000' '\n' < "$locblob" | sort -u | grep -c 'README.md')
    The variable distinct should equal 2
  End

  It 'remote manifest row: records a localized clip (new row, source_host stays the origin host)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',202); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt\000%s/remote-b.txt' "$REMOTE_SRC" "$REMOTE_SRC" > "$mf"
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
    printf '%s/remote-a.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    run_copy "$id" >/dev/null 2>&1
    : > "$RSYNCLOG"
    When call run_copy "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should equal ""
  End

  # Reviewer finding 2 (important): re-picking a row the picker itself
  # localized earlier. Two shapes, both previously broken:
  #   single-path -> only a synthetic x-resolved-path blob; the old code sent
  #     `U id:<n>` and restore_by_id wrote the blob under the literal
  #     'x-resolved-path' UTI -- nothing pasteable, false success.
  #   multi-path -> x-file-manifest with LOCAL cache paths but
  #     source_host=origin; the old code tried `rsync origin:<local-path>`.
  # Fix under test: when a remote-origin row's recorded paths ALL live under
  # the picker's own cache root (~/.cache/pick-clipboard/files/ -- the only
  # place localization ever records) AND exist on disk, send U with those
  # paths directly (form A) -- no id:, no rsync.
  It 'localized single-path row (x-resolved-path cache path, remote origin, file on disk): sends U with the path, no id:, no rsync'
    locdir="$HOME/.cache/pick-clipboard/files/77/1"; mkdir -p "$locdir"
    printf 'already local\n' > "$locdir/doc.txt"
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','devbox',220); SELECT last_insert_rowid();")
    pathfile="$SHELLSPEC_TMPBASE/resolved-path"
    printf '%s' "$locdir/doc.txt" > "$pathfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-resolved-path', readfile('$pathfile'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$NCLOG" should include "2489:U"
    The contents of file "$NCLOG" should include "$locdir/doc.txt"
    The contents of file "$NCLOG" should not include "id:$id"
    The contents of file "$RSYNCLOG" should equal ""
  End

  It 'localized multi-path row (x-file-manifest of cache paths, remote origin): sends U with the paths, no rsync'
    locdir="$HOME/.cache/pick-clipboard/files/78"; mkdir -p "$locdir/1" "$locdir/2"
    printf 'a\n' > "$locdir/1/a.txt"
    printf 'b\n' > "$locdir/2/b.txt"
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',221); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/1/a.txt\000%s/2/b.txt' "$locdir" "$locdir" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$NCLOG" should include "2489:U"
    The contents of file "$NCLOG" should include "$locdir/1/a.txt"
    The contents of file "$NCLOG" should include "$locdir/2/b.txt"
    The contents of file "$NCLOG" should not include "id:$id"
    The contents of file "$RSYNCLOG" should equal ""
  End

  # Re-review follow-up 1: the guard must be RESTRICTED to the cache root.
  # A remote manifest whose path strings happen to exist locally too (the
  # Mac-to-Mac mirror case: /Users/<me>/... exists on both machines) must
  # NOT short-circuit to the possibly-stale local copies -- it takes the
  # rsync branch like any other remote manifest.
  It 'remote manifest of locally-existing NON-cache paths: takes the rsync branch, not the guard'
    coincdir="$SHELLSPEC_TMPBASE/coincident"; rm -rf "$coincdir"; mkdir -p "$coincdir"
    printf 'stale local twin\n' > "$coincdir/doc.txt"
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','devbox',222); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/doc.txt' "$coincdir" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should include "devbox:$coincdir/doc.txt"
    The contents of file "$NCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/1/doc.txt"
    The contents of file "$NCLOG" should not include "$coincdir/doc.txt"
  End

  # Re-review follow-up 2: a fully-cached re-pick pulls nothing, so it must
  # not insert another bookkeeping row (type_hash is NULL on these rows, so
  # nothing would ever dedup the pile-up).
  It 'two consecutive picks of the same remote row record exactly one localized row'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',223); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt\000%s/remote-b.txt' "$REMOTE_SRC" "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    run_copy "$id" >/dev/null 2>&1
    When call run_copy "$id"
    The status should be success
    localized_rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM clips WHERE id != $id AND source_host = 'devbox';")
    The variable localized_rows should equal 1
  End

  # Reviewer finding 3 (important): the pull must use the pinned
  # /opt/homebrew/bin/rsync (stock /usr/bin/rsync is openrsync without
  # --info=progress2 -- the exact reason pbpaste pins it), never a PATH
  # lookup. With the test override unset, the PATH-shadowing fake must NOT
  # be consulted (empty rsynclog) even though it sits first on PATH; the
  # real pinned binary then fails to reach the bogus .invalid host
  # (sandboxed HOME = no ssh config) and the text fallback kicks in.
  It 'pins /opt/homebrew/bin/rsync: the PATH-shadowing fake is never consulted without the override'
    unset PICK_CLIPBOARD_RSYNC
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('files','no-such-host.invalid',230,'$REMOTE_SRC/x.txt'); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/x.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The stderr should include "rsync"
    The contents of file "$RSYNCLOG" should equal ""
    The contents of file "$NCLOG" should include "2489:T"
    The contents of file "$NCLOG" should not include "2489:U"
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

  # NOTE: the in-place overwrite of $BINDIR/rsync below is intentionally
  # coupled to setup()'s `PICK_CLIPBOARD_RSYNC=$BINDIR/rsync` -- the picker
  # invokes whatever that override points at (never a PATH lookup, see the
  # pinning test above), so swapping the file's CONTENT is how this test
  # turns the fake into a failing rsync without touching the env wiring.
  It 'a failed rsync falls back to the current text-copy behavior (T set, not U)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('files','devbox',301,'a b'); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt\000%s/remote-b.txt' "$REMOTE_SRC" "$REMOTE_SRC" > "$mf"
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

  # --- spec R3: readable pull failures + warning suppression -----------------
  It 'rsync -e string clears the clipboard bridge forward (spec R3): kills the redundant reverse-forward attempt and its warning at the source'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',400); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should include "ClearAllForwardings=yes"
  End

  # Fake rsync writes real noise to ITS OWN stderr (standing in for the
  # "Warning: remote port forwarding failed..." ssh line the live session
  # showed) and fails. The picker must surface a single readable line on its
  # OWN stderr -- never the raw noise -- while the noise itself survives on
  # disk for follow-up (the detail file the message points at).
  It 'a failed pull captures rsync/ssh stderr to a temp file instead of forwarding raw noise onto the picker'\''s own stderr (spec R3)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('files','devbox',401,'a b'); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"
    cat > "$BINDIR/rsync" <<'EOF'
#!/bin/sh
echo "FAKE-SSH-NOISE: Warning: remote port forwarding failed for listen port 2490" >&2
exit 1
EOF
    chmod +x "$BINDIR/rsync"

    When call run_copy "$id"
    The status should be success
    The stderr should include "rsync failed pulling"
    The stderr should include "details:"
    The stderr should not include "FAKE-SSH-NOISE"
    detail_file=$(ls "$TMPDIR"/pick-clipboard-rsync-err.* 2>/dev/null | head -1)
    The path "$detail_file" should be exist
    The contents of file "$detail_file" should include "FAKE-SSH-NOISE"
  End

  # --- spec R5b: localized bookkeeping rows get a real text_preview ----------
  # Integration: the localized row is no longer anonymous (row 983's live-
  # session bug -- a NULL text_preview renders as "[files]" in both pickers'
  # IFNULL fallback). Doesn't assert on the exact preview text: under
  # shellspec's own deeply-nested sandbox HOME the localized cache path alone
  # can run past clip::localized_preview's ~100-char budget (an environment
  # artifact, not a real-world path length) -- the shape of the truncation is
  # covered as a pure-function unit test below instead.
  It 'localized bookkeeping row gets a non-empty text_preview (not the anonymous NULL/[files] fallback), spec R5b'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',402); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt\000%s/remote-b.txt' "$REMOTE_SRC" "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    preview=$(sqlite3 "$DB" "SELECT IFNULL(text_preview,'') FROM clips WHERE id=(SELECT MAX(id) FROM clips);")
    The variable preview should not equal ""
  End

  # Unit test (pure function, short synthetic paths -- no HOME/cache-root
  # dependency): newline-joined paths that fit the ~100-char budget are kept
  # whole; the localized cache path this function actually receives at the
  # real call site is always well under that in production (a normal
  # $HOME, unlike the sandbox's own deeply-nested tmp HOME above).
  It 'clip::localized_preview joins short paths whole (spec R5b, pure-function unit test)'
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::localized_preview "/tmp/a/1/one.txt" "/tmp/a/2/two.txt"
    ' 2>&1)"
    expected=$'/tmp/a/1/one.txt\n/tmp/a/2/two.txt'
    When call test "$result" = "$expected"
    The status should be success
  End

  # Unit test: paths that blow the budget fall back to "first path
  # truncated + K more", never a silent empty/anonymous preview.
  It 'clip::localized_preview summarizes when paths exceed the ~100-char budget (spec R5b, pure-function unit test)'
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::localized_preview "/this/is/a/very/long/synthetic/path/that/alone/blows/right/past/the/one/hundred/character/budget/one.txt" "/another/long/path/two.txt"
    ' 2>&1)"
    When call test -n "$result"
    The status should be success
    The variable result should include "more"
  End

  # --- X4/X3: --preview pane detail body shows the path, not a "[kind]" badge -
  # for a files/file/directory row whose text_plain is NULL. The watcher and
  # N-op never populate text_plain for these kinds (only text_preview holds
  # the path(s)) -- before this fix the detail pane's body expression
  # (COALESCE(text_plain,'['||type_kind||']')) fell straight through to the
  # anonymous badge whenever text_plain was NULL, so the LIST row showed the
  # real path (text_preview, fixed separately) but the right-hand detail pane
  # still showed "[file]"/"[directory]"/"[files]". Exercises the generated
  # preview_script directly -- PICK_CLIPBOARD_NO_RUN writes it to a temp file
  # (and the SQL/vars it closes over) before the script returns.
  It 'the --preview pane detail body shows the path, not a "[file]" badge, for a single-file row with no text_plain'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, source_host, last_ts) VALUES ('file','/tmp/some/report.pdf','mac-mini',600); SELECT last_insert_rowid();")
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      bash "$preview_script" "$1"
    ' _ "$id" 2>&1)"
    When call test -n "$result"
    The status should be success
    The variable result should include "/tmp/some/report.pdf"
    The variable result should not include "[file]"
  End

  It 'the --preview pane detail body shows joined paths, not "[files]", for a multi-file row with no text_plain'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, source_host, last_ts) VALUES ('files','/tmp/a.txt
/tmp/b.txt','mac-mini',601); SELECT last_insert_rowid();")
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      bash "$preview_script" "$1"
    ' _ "$id" 2>&1)"
    When call test -n "$result"
    The status should be success
    The variable result should include "/tmp/a.txt"
    The variable result should include "/tmp/b.txt"
    The variable result should not include "[files]"
  End

  # --- spec R5c: bump-on-use ---------------------------------------------------
  It 'local files row restore bumps the original row'\''s last_ts (spec R5c)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','mac-mini',100); SELECT last_insert_rowid();")

    When call run_copy "$id"
    The status should be success
    bumped=$(sqlite3 "$DB" "SELECT last_ts > 100 FROM clips WHERE id=$id;")
    The variable bumped should equal "1"
  End

  It 'localized (already-cached) row restore bumps the original row'\''s last_ts (spec R5c, case 2)'
    locdir="$HOME/.cache/pick-clipboard/files/79/1"; mkdir -p "$locdir"
    printf 'already local\n' > "$locdir/doc.txt"
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','devbox',404); SELECT last_insert_rowid();")
    pathfile="$SHELLSPEC_TMPBASE/resolved-path"
    printf '%s' "$locdir/doc.txt" > "$pathfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-resolved-path', readfile('$pathfile'));"

    When call run_copy "$id"
    The status should be success
    bumped=$(sqlite3 "$DB" "SELECT last_ts > 404 FROM clips WHERE id=$id;")
    The variable bumped should equal "1"
  End

  It 'remote-pull files row restore bumps the ORIGINAL row'\''s last_ts, not just the new localized bookkeeping row (spec R5c, case 3)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',403); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    bumped=$(sqlite3 "$DB" "SELECT last_ts > 403 FROM clips WHERE id=$id;")
    The variable bumped should equal "1"
  End

  # --- spec R4: headless --restore-id CLI mode --------------------------------
  It '--restore-id <n> works headless for a local row (spec R4): sends U with the id: form, exit 0'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','mac-mini',500); SELECT last_insert_rowid();")

    When call run_restore_id "$id"
    The status should be success
    The contents of file "$NCLOG" should include "2489:U"
    The contents of file "$NCLOG" should include "id:$id"
  End

  It '--restore-id <n> works headless for a remote manifest row (spec R4): rsync-pulls then sends U with the localized paths, exit 0'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',501); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_restore_id "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should include "devbox:$REMOTE_SRC/remote-a.txt"
    The contents of file "$NCLOG" should include "2489:U"
    The contents of file "$NCLOG" should include "$HOME/.cache/pick-clipboard/files/$id/1/remote-a.txt"
  End

  It '--restore-id rejects a non-numeric id, exit 1 (spec R4)'
    When call zsh -f "$SCRIPT" --restore-id notanumber
    The status should be failure
    The stderr should include "numeric clip id"
  End

  It '--restore-id exits 1 when the underlying restore genuinely fails (spec R4)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','mac-mini',502); SELECT last_insert_rowid();")
    cat > "$BINDIR/nc" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$BINDIR/nc"

    When call run_restore_id "$id"
    The status should be failure
    The stderr should include "local files restore"
  End

  # --- W2: restore-failure messages must not vanish with the picker ----------
  # The interactive tail of the script (after fzf's accept-dispatch case) can
  # hold the floating pane open on a Ctrl-Y files-restore failure so the
  # one-line reason is readable instead of flashing past as the pane closes
  # (validated live twice). That hold must NEVER apply to the --restore-id
  # headless mode: clipboard-picker.lua's hs.task shells out to exactly this
  # invocation and can't answer a `read -k1 -s` prompt, so a hold there would
  # wedge the GUI picker's restore call forever. --restore-id already exits
  # (at the top of the script, long before the interactive tail) on both
  # success and failure, so this is really a structural guarantee -- this
  # timeout-guarded example is the regression net: if a future change ever
  # routed --restore-id through the interactive tail, this would hang and
  # timeout instead of silently passing.
  It '--restore-id failure exits promptly (never holds) even though the same reason reaches stderr (spec R4 + W2)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','mac-mini',503); SELECT last_insert_rowid();")
    cat > "$BINDIR/nc" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$BINDIR/nc"

    When call timeout 5 zsh -f "$SCRIPT" --restore-id "$id" < /dev/null
    The status should be failure
    The status should not equal 124
    The stderr should include "local files restore"
  End

  # clip::should_hold_on_restore_failure is the pure decision the interactive
  # tail gates on; exercised directly (via PICK_CLIPBOARD_NO_RUN) so it's
  # covered without ever touching fzf or a floating pane. The TRUE "hold"
  # case (a live controlling terminal actually reachable) is intentionally
  # NOT exercised here -- there is no way to fake a real controlling tty
  # inside this shellspec harness, and clip::has_live_tty's whole point is to
  # tell the difference (see its own comment in the script). What IS covered
  # is every reason the decision must come back "no": no reason to show, the
  # headless/hs.task mode, and -- the case this harness always hits -- no
  # live terminal attached.
  run_should_hold() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      clip::should_hold_on_restore_failure "$1" "$2"
    ' _ "$1" "$2"
  }

  It 'clip::should_hold_on_restore_failure: no reason to show -> never hold'
    When call run_should_hold "" 0
    The status should be failure
  End

  It 'clip::should_hold_on_restore_failure: headless mode -> never hold, even with a reason'
    When call run_should_hold "pick-clipboard: rsync failed pulling devbox:/x" 1
    The status should be failure
  End

  It 'clip::should_hold_on_restore_failure: interactive but no live controlling terminal (this harness) -> never hold'
    When call run_should_hold "pick-clipboard: rsync failed pulling devbox:/x" 0
    The status should be failure
  End

  # clip::restore_fail is what every failure exit inside clip::copy_files_by_id
  # now goes through (W2): it must keep printing the EXACT same stderr text
  # existing callers already assert on (see the rsync/local-restore-failure
  # tests above) while ALSO capturing it into CLIP_RESTORE_FAILURE for the
  # interactive tail to render+hold on later.
  It 'clip::restore_fail prints the reason to stderr AND stashes it in CLIP_RESTORE_FAILURE'
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::restore_fail "rsync failed pulling devbox:/x/y (details: /tmp/z)"
      print -r -- "$CLIP_RESTORE_FAILURE"
    ' 2>"$SHELLSPEC_TMPBASE/restore-fail-stderr")"
    The variable result should equal "pick-clipboard: rsync failed pulling devbox:/x/y (details: /tmp/z)"
    The contents of file "$SHELLSPEC_TMPBASE/restore-fail-stderr" should include "rsync failed pulling devbox:/x/y"
  End

  # W2 reviewer Minor: by the time the hold screen shows, the plain-text
  # fallback (the T set after a failed files restore) usually already put
  # the clip's path text on the clipboard -- an error-only hold misreads as
  # "nothing was copied". clip::copy_by_id marks that success in
  # CLIP_RESTORE_FALLBACK_OK so the hold can append a note line. The marker
  # must be set on the failed-files-restore-then-successful-text-fallback
  # path, and NEVER on an ordinary copy that hit no failure.
  It 'a failed files restore whose text fallback succeeds sets CLIP_RESTORE_FALLBACK_OK (W2 note line)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('files','devbox',600,'/x/a.txt'); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"
    cat > "$BINDIR/rsync" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$BINDIR/rsync"

    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::copy_by_id "$1"
      print -r -- "fallback_ok=${CLIP_RESTORE_FALLBACK_OK}"
    ' _ "$id" 2>/dev/null)"
    When call test "$result" = "fallback_ok=1"
    The status should be success
  End

  It 'an ordinary text-row copy (no files failure) leaves CLIP_RESTORE_FALLBACK_OK empty -- the note can never appear without its error'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',601,'hello'); SELECT last_insert_rowid();")

    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::copy_by_id "$1"
      print -r -- "fallback_ok=${CLIP_RESTORE_FALLBACK_OK}"
    ' _ "$id" 2>/dev/null)"
    When call test "$result" = "fallback_ok="
    The status should be success
  End
End

# Tests for X9: the synthetic live-peer row (spec §22) must sort
# chronologically by when the PEER's clipboard was copied (fetched via the
# new S get-current-ts op), not always float to the top above every local
# row.
#
# bridge_up (top of executable_pick-clipboard) requires an SSH env var AND a
# real connect-probe success (`nc -z -w 1 host port`), so the fake `nc` here
# is a different, more capable shape than the shared one in the Describe
# above (which never sets an SSH env var, so bridge_up -- and this fake --
# never engage there): it answers the `-z` probe unconditionally, and
# dispatches the framed G/H/S reads (the picker's live-row fetch at open) to
# fixed canned replies. It does NOT attempt the `-z` probe's real filehandle
# behavior (no listener, no timeout) -- just "yes, reachable".
Describe 'pick-clipboard: live-peer row ordering (X9)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  # be32_esc <n> -- prints a literal `\NNN\NNN\NNN\NNN` (backslash + 3-digit
  # octal, 4x) BE32-length escape sequence as TEXT, for baking into a
  # generated shell script's own `printf 'FORMAT'` call (mirrors the
  # dispatcher's own int_to_be32; see its comment for why printf's \NNN
  # octal escapes are the reliable way to emit raw framing bytes).
  be32_esc() {
    local n=$1
    printf '\\%03o\\%03o\\%03o\\%03o' $(( (n>>24)&255 )) $(( (n>>16)&255 )) $(( (n>>8)&255 )) $(( n&255 ))
  }

  setup() {
    unset SSH_CLIENT SSH_TTY
    export SSH_CONNECTION="10.0.0.1 1234 10.0.0.2 22"   # bridge_up precondition 1/2
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    export HOME="$SHELLSPEC_TMPBASE/home"; rm -rf "$HOME"; mkdir -p "$HOME"
    export TMPDIR="$SHELLSPEC_TMPBASE/tmp"; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"; mkdir -p "$XDG_DATA_HOME/pick-clipboard"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    export PICK_CLIPBOARD_DB="$DB"
    # The budget test below exports PICK_CLIPBOARD_LIMIT; shellspec shares one
    # shell across a Describe's examples, so clear it here so every other
    # example runs at the default cap (500) rather than inheriting a stale
    # tiny limit from a previous It.
    unset PICK_CLIPBOARD_LIMIT
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

    # Peer fixtures: text distinct from every seeded local row's text_plain
    # (so the §22.5 dedup check never suppresses the live row out from under
    # these ordering tests) and a peer hostname. LIVE_TS is set per-It below
    # (each example wires its own G_LEN/H_LEN/S_LEN + fake nc).
    LIVE_TEXT="peer clipboard text, distinct from every local row"
    LIVE_HOST="peer-host"

    # Fake scutil: pins THIS host's name (mac-mini), same convention as the
    # Describe above -- source_host==self / remote comparisons need it.
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

  # write_fake_nc <live_ts> -- the picker's live-row fetch at open (spec §22)
  # sends G (peer text), H (peer host), then S (X9, peer copy-time) over the
  # reverse-tunnel loopback port; bridge_up itself first probes with
  # `nc -z -w 1`. This fake answers all four shapes: `-z` -> immediate
  # success (no stdin read -- a real probe sends none either); G/H/S -> the
  # canned LIVE_TEXT/LIVE_HOST/<live_ts> reply; anything else (T/P from the
  # accept-time materialize path, not exercised by these ordering-only
  # tests) -> a bare O + empty body.
  write_fake_nc() {
    local live_ts=$1
    local g_hdr h_hdr s_hdr
    g_hdr=$(be32_esc ${#LIVE_TEXT})
    h_hdr=$(be32_esc ${#LIVE_HOST})
    s_hdr=$(be32_esc ${#live_ts})
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
if [ "\$1" = "-z" ]; then
  exit 0
fi
raw="\$(mktemp "$SHELLSPEC_TMPBASE/nc-raw.XXXXXX")"
cat > "\$raw"
opcode=\$(dd if="\$raw" bs=1 count=1 2>/dev/null)
rm -f "\$raw"
case "\$opcode" in
  G) printf 'O'; printf '$g_hdr'; printf '%s' '$LIVE_TEXT' ;;
  H) printf 'O'; printf '$h_hdr'; printf '%s' '$LIVE_HOST' ;;
  S) printf 'O'; printf '$s_hdr'; printf '%s' '$live_ts' ;;
  *) printf 'O\\000\\000\\000\\000' ;;
esac
EOF
    chmod +x "$BINDIR/nc"
  }

  # run_emit -- sources the picker under PICK_CLIPBOARD_NO_RUN (same escape
  # hatch/convention as run_copy in the Describe above) then calls emit_rows
  # directly, printing just the tail id of each emitted row ("LIVE" for the
  # synthetic row) one per line, in emission order -- exactly the ordering
  # this fix is about, with none of the ANSI/preview-width noise around it.
  run_emit() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      emit_rows | while IFS= read -r line; do
        tail=${line##*$'"'"'\x1f'"'"'}
        id=${tail%%$'"'"'\x1e'"'"'*}
        print -r -- "$id"
      done
    '
  }

  It 'interleaves the live row by copy-time between newer and older local rows'
    id_old=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',100,'old local'); SELECT last_insert_rowid();")
    id_new=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',300,'new local'); SELECT last_insert_rowid();")
    write_fake_nc 200

    When call run_emit
    The status should be success
    expected=$(printf '%s\nLIVE\n%s' "$id_new" "$id_old")
    The output should equal "$expected"
  End

  It 'places the live row at the very top when its copy-time is newer than every local row'
    id_a=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',100,'a'); SELECT last_insert_rowid();")
    id_b=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',200,'b'); SELECT last_insert_rowid();")
    write_fake_nc 999

    When call run_emit
    The status should be success
    expected=$(printf 'LIVE\n%s\n%s' "$id_b" "$id_a")
    The output should equal "$expected"
  End

  It 'places the live row at the very bottom when its copy-time is older than every local row'
    id_a=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',100,'a'); SELECT last_insert_rowid();")
    id_b=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',200,'b'); SELECT last_insert_rowid();")
    write_fake_nc 1

    When call run_emit
    The status should be success
    expected=$(printf '%s\n%s\nLIVE' "$id_b" "$id_a")
    The output should equal "$expected"
  End

  # Pinned local rows sort above the live row regardless of ts (the live row
  # is never pinned) -- spec X9 requirement 3's explicit invariant.
  It 'keeps a pinned local row above the live row even when the pinned row is chronologically older'
    id_pinned=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain, pinned) VALUES ('text','mac-mini',10,'pinned-old',1); SELECT last_insert_rowid();")
    id_unpinned=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',50,'unpinned-old'); SELECT last_insert_rowid();")
    write_fake_nc 200

    When call run_emit
    The status should be success
    expected=$(printf '%s\nLIVE\n%s' "$id_pinned" "$id_unpinned")
    The output should equal "$expected"
  End

  # Tie: an UNPINNED local row whose last_ts EQUALS the live row's copy-time.
  # The split is ABOVE = (last_ts > threshold), BELOW = (last_ts <= threshold),
  # so a tie is `<=` -> it lands in BELOW, i.e. just UNDER the live row. This
  # is the deterministic, documented placement (ties sort below the live row).
  It 'places a local row tied with the live copy-time just below the live row'
    id_tie=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',200,'tie'); SELECT last_insert_rowid();")
    id_above=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',300,'above'); SELECT last_insert_rowid();")
    write_fake_nc 200

    When call run_emit
    The status should be success
    expected=$(printf '%s\nLIVE\n%s' "$id_above" "$id_tie")
    The output should equal "$expected"
  End

  # X9 shared budget: pre-fix, ABOVE and BELOW each carried the full
  # PICK_CLIPBOARD_LIMIT, so with a live row present the picker could emit
  # ~2x the cap. The two halves must share ONE budget: total emitted rows
  # (ABOVE + live + BELOW) <= PICK_CLIPBOARD_LIMIT. Tiny limit + a live row +
  # more local rows than the cap -> the count must never exceed the limit.
  It 'never emits more than PICK_CLIPBOARD_LIMIT rows total, live row included'
    export PICK_CLIPBOARD_LIMIT=2
    # Four local rows straddling the live copy-time (200): two above, two
    # below -- so a naive per-half full-limit would emit 2 (above) + 1 (live)
    # + 2 (below) = 5, well over the cap of 2.
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',100,'a');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',150,'b');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',250,'c');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',350,'d');"
    write_fake_nc 200

    n=$(run_emit | grep -c .)
    When call test "$n" -le 2
    The status should be success
  End

  # Same budget, without any live row: the split degrades to a single
  # LIMIT-capped ABOVE query (LIVE_COUNT=0, ABOVE_LIMIT=limit), matching the
  # pre-X9 single-global-LIMIT behavior exactly -- exactly `limit` rows.
  It 'caps at exactly PICK_CLIPBOARD_LIMIT rows when there is no live row (no bridge)'
    unset SSH_CONNECTION   # no bridge -> no live row at all
    export PICK_CLIPBOARD_LIMIT=2
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',100,'a');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',200,'b');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',300,'c');"

    n=$(run_emit | grep -c .)
    When call test "$n" -eq 2
    The status should be success
  End
End
