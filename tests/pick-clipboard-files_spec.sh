# Tests for pick-clipboard's Ctrl-Y files branch (files-yazi design §9,
# docs/superpowers/specs/2026-07-11-clipboard-phase6-files-yazi-design.md,
# task 10 / M2): `clip::copy_by_id` no longer degrades a files/file/directory
# row to path text.
#
# The picker (`executable_pick-clipboard`) is a zsh script that ends by
# running an interactive fzf session unconditionally -- PICK_CLIPBOARD_NO_RUN
# is a test-only escape hatch (see the "run" section near the bottom of the
# script) that sources the file's functions and returns before that session
# ever starts, so a test can call clip::copy_by_id directly against a seeded
# store + a recording bridge + a faked rsync.
#
# CONVERTED TO THE RECOB HARNESS (tests/recob_helper.sh): the transport is a
# REAL `recobd --record` per example, and the picker reaches it through the
# spec suite's own `system-bridge` build (recob_start exports
# SYSTEM_BRIDGE_BIN). What the old fake `nc` asserted as raw frames
# ("cb.sock:U...id:<n>") is asserted as decoded operations now:
#
#   U with `id:<rowid>`        -> clip.set.files{clip_id}, the BARE decimal
#   U with NUL-joined paths    -> clip.set.files{paths}
#   T fallback to :2489        -> clip.set on the `trusted` endpoint
#
# Two consequences of the recorder being the real daemon, called out where
# they bite:
#
#   * A by-rowid restore replays the row's stored clip_types, so (unlike the
#     always-'O' fake) a local row must be seeded with a real pasteboard BLOB
#     -- see seed_file_url_blob. The blob must be X'hex', never a TEXT
#     literal: sqlite stores the literal with TEXT affinity and the daemon's
#     blob read refuses it.
#   * A successful clip.set / clip.set.files writes the daemon's own
#     post-write snapshot row (source_host = this host) into the SHARED
#     store, so "the localized bookkeeping row" is selected by
#     source_host + id, never by bare MAX(id).
#
# The remote pull is still captured by a fake `rsync` wired in via
# PICK_CLIPBOARD_RSYNC (the picker pins /opt/homebrew/bin/rsync in
# production, same as pbpaste -- the env var is the test-only override
# documented in clip::copy_files_by_id).
#
# Remote manifest paths in these tests live under /pick-clipboard-remote-src/
# -- a root that never exists on the test machine. The localized-row guard is
# restricted to the picker's own cache root, so a real local path could no
# longer short-circuit the rsync branch, but keeping remote paths obviously
# nonexistent stays the honest fixture shape (they ARE remote paths).

# Byte-exact fixtures/expectations ride as hex (the recorder's own log
# encoding), so NUL-joined path lists are assertable without ever putting a
# NUL through a shell comparison.
spec_hex() { printf '%s' "$1" | xxd -p | tr -d '\n'; }
spec_paths_hex() {
  {
    _sp_first=1
    for _sp_path in "$@"; do
      [ "$_sp_first" -eq 1 ] || printf '\000'
      printf '%s' "$_sp_path"
      _sp_first=0
    done
  } | xxd -p | tr -d '\n'
}

Describe 'pick-clipboard: Ctrl-Y files branch (clip::copy_by_id)'
  Include tests/recob_helper.sh

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
    # The recorder is a real daemon with a real identity; pin it to the same
    # mac-mini the fixtures always used. Phase 7's self-name file (which
    # recob_start writes into ITS sandboxed XDG_STATE_HOME) outranks scutil
    # in clip::self_host, so MY_HOST is deterministic with no scutil fake.
    RECOB_SELF_NAME=mac-mini
    recob_start
    # ONE store, shared by the picker and the daemon: recob_start's
    # XDG_DATA_HOME. clip.set.files{clip_id} is resolved by the daemon's own
    # restore engine, which must find the very row the example seeded.
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    export PICK_CLIPBOARD_DB="$DB"
    mkdir -p "$XDG_DATA_HOME/pick-clipboard"
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

    PBCOPYLOG="$SHELLSPEC_TMPBASE/pbcopylog"; : > "$PBCOPYLOG"
    # Fake pbcopy: clip::copy_by_id's last-resort fallback pipes the clip
    # text into `pbcopy`, and a spec must NEVER touch the human's real
    # pasteboard -- the daemon's writes are already sandboxed onto a private
    # pasteboard by recob_start, this covers the one write that bypasses the
    # daemon. Logs the bytes so the bridge-down fallback is assertable.
    cat > "$BINDIR/pbcopy" <<EOF
#!/bin/sh
cat >> "$PBCOPYLOG"
EOF
    chmod +x "$BINDIR/pbcopy"

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
    export PICK_CLIPBOARD_CORE_LIB="$LIB_DIR/clipboard-store-core.zsh"
    export PICK_CLIPBOARD_NO_RUN=1
    # Test-only override (documented in clip::copy_files_by_id): production
    # pins /opt/homebrew/bin/rsync exactly like pbpaste's tier 2 -- an
    # absolute-path invocation can't be shadowed via PATH, so the fake is
    # wired in through this env var instead.
    export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync"
    export SCRIPT_PATH="$SCRIPT"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # A genuine local capture carries a real pasteboard blob. The recorder is
  # the real daemon: clip.set.files{clip_id} replays the row's stored
  # clip_types, so a row with nothing to replay is honestly refused
  # (not-found) where the old fake nc answered 'O' regardless. X'hex' on
  # purpose: a plain SQL string literal stores with TEXT affinity, which the
  # daemon's blob read rejects (`Invalid column type Text`).
  seed_file_url_blob() {  # <clip-id> <path>
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob)
      VALUES ($1, 'public.file-url', X'$(spec_hex "file://$2")');"
  }

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

  It 'local files row: one clip.set.files{clip_id} exchange on the trusted socket (bare rowid, no paths, no id: prefix)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','mac-mini',100); SELECT last_insert_rowid();")
    seed_file_url_blob "$id" /tmp/a.txt

    When call run_copy "$id"
    The status should be success
    # clip_id is the BARE decimal rowid (§6.1 -- the id: prefix died with the
    # positional payload), asserted by exact hex so a stray prefix byte fails.
    wire="$(recob_op 1)|$(recob_endpoint 1)|clip_id=$(recob_field_hex 1 clip_id)|paths=$(recob_field_hex 1 paths)|$(recob_count)"
    The variable wire should equal "clip.set.files|trusted|clip_id=$(spec_hex "$id")|paths=|1"
    The contents of file "$RSYNCLOG" should equal ""
  End

  It 'local files row (NULL source_host, legacy capture): still uses the clip_id form'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts) VALUES ('directory',100); SELECT last_insert_rowid();")
    seed_file_url_blob "$id" /tmp/adir

    When call run_copy "$id"
    The status should be success
    wire="$(recob_op 1)|$(recob_endpoint 1)|clip_id=$(recob_field_hex 1 clip_id)"
    The variable wire should equal "clip.set.files|trusted|clip_id=$(spec_hex "$id")"
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
  It 'local M-persisted row (source_host=self, only an x-file-manifest blob): sends clip.set.files{paths}, not clip_id'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','mac-mini',150); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/local-manifest.bin"
    printf '%s/local-a.txt\000%s/local-b.txt' "$HOME" "$HOME" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"
    p1="$SHELLSPEC_TMPBASE/local-authority-1"; printf '%s/local-a.txt' "$HOME" > "$p1"
    p2="$SHELLSPEC_TMPBASE/local-authority-2"; printf '%s/local-b.txt' "$HOME" > "$p2"
    sqlite3 "$DB" "INSERT INTO file_authorities (clip_id,item_index,path) VALUES
      ($id,1,readfile('$p1')),($id,2,readfile('$p2'));"

    When call run_copy "$id"
    The status should be success
    wire="$(recob_op 1)|$(recob_endpoint 1)|clip_id=$(recob_field_hex 1 clip_id)"
    The variable wire should equal "clip.set.files|trusted|clip_id="
    got_paths="$(recob_field_hex 1 paths)"
    The variable got_paths should equal "$(spec_paths_hex "$HOME/local-a.txt" "$HOME/local-b.txt")"
    The contents of file "$RSYNCLOG" should equal ""
  End

  It 'does not trust a self-host x-file-manifest row without authority'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','mac-mini',151); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/untrusted-local-manifest.bin"
    printf '%s/sensitive.txt' "$HOME" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    ops="$(recob_ops | tr '\n' ',')"
    The variable ops should not include "clip.set.files"
    # The path must not cross the wire AT ALL -- the log holds every decoded
    # field hex-encoded, so its absence there is absence everywhere.
    The contents of file "$RECOB_RECORD_LOG" should not include "$(spec_hex "$HOME/sensitive.txt")"
    The stderr should include "not authorized"
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

  It 'remote manifest row: sends clip.set.files{paths} with the localized NUL-joined paths (not clip_id)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',201); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt\000%s/remote-b.txt' "$REMOTE_SRC" "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    wire="$(recob_op 1)|$(recob_endpoint 1)|clip_id=$(recob_field_hex 1 clip_id)"
    The variable wire should equal "clip.set.files|trusted|clip_id="
    got_paths="$(recob_field_hex 1 paths)"
    The variable got_paths should equal "$(spec_paths_hex \
      "$HOME/.cache/pick-clipboard/files/$id/1/remote-a.txt" \
      "$HOME/.cache/pick-clipboard/files/$id/2/remote-b.txt")"
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
    got_paths="$(recob_field_hex 1 paths)"
    The variable got_paths should equal "$(spec_paths_hex \
      "$HOME/.cache/pick-clipboard/files/$id/1/README.md" \
      "$HOME/.cache/pick-clipboard/files/$id/2/README.md")"
    # The localized row's own blob must record two DISTINCT paths. Selected
    # by source_host + id, not MAX(id): the daemon's own post-write snapshot
    # row (source_host = this host) lands after the bookkeeping row.
    # Extracted via writefile: the sqlite3 CLI truncates direct blob output
    # at the first embedded NUL (verified empirically), so a `SELECT blob`
    # pipe would only ever show the first path. tr the NUL joints to
    # newlines BEFORE the $(...) capture; grep -c counts the de-duplicated
    # survivors -- 1 would mean the old collision.
    locblob="$SHELLSPEC_TMPBASE/localized-blob"
    sqlite3 "$DB" "SELECT writefile('$locblob', blob) FROM clip_types WHERE clip_id=(SELECT MAX(id) FROM clips WHERE source_host='devbox' AND id != $id) AND uti='x-file-manifest';" >/dev/null
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
    # The localized bookkeeping row keeps source_host = origin; the daemon's
    # own post-write snapshot row (source_host = this host, from the
    # clip.set.files it served) is newer, so MAX(id) alone would name the
    # wrong row.
    blob_uti=$(sqlite3 "$DB" "SELECT uti FROM clip_types WHERE clip_id = (SELECT MAX(id) FROM clips WHERE source_host='devbox' AND id != $id) AND uti IN ('x-file-manifest','x-resolved-path');")
    The variable blob_uti should equal "x-file-manifest"
    authority_count=$(sqlite3 "$DB" "SELECT count(*) FROM file_authorities WHERE clip_id=(SELECT MAX(id) FROM clips WHERE source_host='devbox' AND id != $id);")
    The variable authority_count should equal 2
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
    The file "$HOME/.cache/pick-clipboard/files/$id/.authorized/1" should be exist
  End

  It 're-pulls cache bytes left without an authority marker'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','devbox',203.5); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/interrupted-manifest.bin"
    printf '%s/remote-a.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"
    sub="$HOME/.cache/pick-clipboard/files/$id/1"
    mkdir -p "$sub"
    printf 'interrupted stale bytes\n' > "$sub/remote-a.txt"

    When call run_copy "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should include "devbox:$REMOTE_SRC/remote-a.txt"
    The contents of file "$sub/remote-a.txt" should equal "pulled:remote-a.txt"
    The file "$HOME/.cache/pick-clipboard/files/$id/.authorized/1" should be exist
  End

  It 'keeps authorization metadata separate from an identically named item'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','devbox',203.6); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/marker-name-manifest.bin"
    printf '%s/.pick-clipboard-authorized' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    item="$HOME/.cache/pick-clipboard/files/$id/1/.pick-clipboard-authorized"
    The contents of file "$item" should equal "pulled:.pick-clipboard-authorized"
    The file "$HOME/.cache/pick-clipboard/files/$id/.authorized/1" should be exist
  End

  It 'keeps partial-state metadata separate from an identically named item'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','devbox',203.7); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/partial-name-manifest.bin"
    printf '%s/.pick-clipboard-partial' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_copy "$id"
    The status should be success
    item="$HOME/.cache/pick-clipboard/files/$id/1/.pick-clipboard-partial"
    The contents of file "$item" should equal "pulled:.pick-clipboard-partial"
    The file "$HOME/.cache/pick-clipboard/files/$id/.authorized/1" should be exist
    The path "$HOME/.cache/pick-clipboard/files/$id/.partial" should not be exist
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
  # place localization ever records), exist on disk, AND carry trusted
  # file_authorities, send U with those paths directly (form A) -- no id:,
  # no rsync.
  It 'localized single-path row (x-resolved-path cache path, remote origin, file on disk): sends clip.set.files{paths} with the path, no clip_id, no rsync'
    locdir="$HOME/.cache/pick-clipboard/files/77/1"; mkdir -p "$locdir"
    printf 'already local\n' > "$locdir/doc.txt"
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','devbox',220); SELECT last_insert_rowid();")
    pathfile="$SHELLSPEC_TMPBASE/resolved-path"
    printf '%s' "$locdir/doc.txt" > "$pathfile"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-resolved-path', readfile('$pathfile'));
      INSERT INTO file_authorities (clip_id,item_index,path) VALUES ($id,1,readfile('$pathfile'));"

    When call run_copy "$id"
    The status should be success
    wire="$(recob_op 1)|$(recob_endpoint 1)|clip_id=$(recob_field_hex 1 clip_id)"
    The variable wire should equal "clip.set.files|trusted|clip_id="
    got_paths="$(recob_field_hex 1 paths)"
    The variable got_paths should equal "$(spec_hex "$locdir/doc.txt")"
    The contents of file "$RSYNCLOG" should equal ""
  End

  It 'localized multi-path row (x-file-manifest of cache paths, remote origin): sends clip.set.files{paths} with the paths, no rsync'
    locdir="$HOME/.cache/pick-clipboard/files/78"; mkdir -p "$locdir/1" "$locdir/2"
    printf 'a\n' > "$locdir/1/a.txt"
    printf 'b\n' > "$locdir/2/b.txt"
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',221); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/1/a.txt\000%s/2/b.txt' "$locdir" "$locdir" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"
    p1="$SHELLSPEC_TMPBASE/localized-authority-1"; printf '%s/1/a.txt' "$locdir" > "$p1"
    p2="$SHELLSPEC_TMPBASE/localized-authority-2"; printf '%s/2/b.txt' "$locdir" > "$p2"
    sqlite3 "$DB" "INSERT INTO file_authorities (clip_id,item_index,path) VALUES
      ($id,1,readfile('$p1')),($id,2,readfile('$p2'));"

    When call run_copy "$id"
    The status should be success
    wire="$(recob_op 1)|$(recob_endpoint 1)|clip_id=$(recob_field_hex 1 clip_id)"
    The variable wire should equal "clip.set.files|trusted|clip_id="
    got_paths="$(recob_field_hex 1 paths)"
    The variable got_paths should equal "$(spec_paths_hex "$locdir/1/a.txt" "$locdir/2/b.txt")"
    The contents of file "$RSYNCLOG" should equal ""
  End

  It 'does not trust a cache-shaped remote row without authority'
    locdir="$HOME/.cache/pick-clipboard/files/79/1"; mkdir -p "$locdir"
    printf 'stale local\n' > "$locdir/stale.txt"
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('file','devbox',221.5,'fallback'); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/untrusted-cache-manifest.bin"
    printf '%s/stale.txt' "$locdir" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"
    cat > "$BINDIR/rsync" <<EOF
#!/bin/sh
echo "\$*" >> "$RSYNCLOG"
exit 1
EOF
    chmod +x "$BINDIR/rsync"

    When call run_copy "$id"
    The contents of file "$RSYNCLOG" should include "devbox:$locdir/stale.txt"
    ops="$(recob_ops | tr '\n' ',')"
    The variable ops should not include "clip.set.files"
    The stderr should include "rsync failed"
  End

  It 'rejects a top-level symlink localized from a remote manifest'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('file','devbox',221.6,'fallback'); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/remote-symlink-manifest.bin"
    printf '%s/link.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"
    cat > "$BINDIR/rsync" <<EOF
#!/bin/sh
argc=\$#
eval "dst=\\\${\$argc}"
mkdir -p "\$dst"
ln -s "$HOME/.ssh/id_rsa" "\$dst/link.txt"
EOF
    chmod +x "$BINDIR/rsync"

    When call run_copy "$id"
    ops="$(recob_ops | tr '\n' ',')"
    The variable ops should not include "clip.set.files"
    authority_count=$(sqlite3 "$DB" "SELECT count(*) FROM file_authorities;")
    The variable authority_count should equal 0
    The stderr should include "unsupported localized file type"
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
    # Exact equality on the whole paths field: the cache path is the ONLY
    # path sent, so the stale coincident local twin provably never rode along.
    got_paths="$(recob_field_hex 1 paths)"
    The variable got_paths should equal "$(spec_hex "$HOME/.cache/pick-clipboard/files/$id/1/doc.txt")"
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
    # The fallback is a clip.set on this machine's own bridge -- the trusted
    # socket now, where the old wire dialed loopback :2489.
    fallback="$(recob_op 1)|$(recob_endpoint 1)"
    The variable fallback should equal "clip.set|trusted"
    ops="$(recob_ops | tr '\n' ',')"
    The variable ops should not include "clip.set.files"
  End

  It 'local restore failure (bridge down) falls back to the current text-copy behavior'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('file','mac-mini',300,'/tmp/a.txt'); SELECT last_insert_rowid();")
    seed_file_url_blob "$id" /tmp/a.txt
    # The whole bridge is down (the old fake made `nc` fail; killing the
    # recorder is the same condition, honestly), so the by-rowid restore AND
    # the trusted-socket clip.set both fail -- the pbcopy shim is the
    # fallback that must still land the text.
    bridge_down_copy() { recob_stop; run_copy "$1"; }

    When call bridge_down_copy "$id"
    The status should be success
    The stderr should include "files restore"
    The contents of file "$PBCOPYLOG" should include "/tmp/a.txt"
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
    fallback="$(recob_op 1)|$(recob_endpoint 1)"
    The variable fallback should equal "clip.set|trusted"
    ops="$(recob_ops | tr '\n' ',')"
    The variable ops should not include "clip.set.files"
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
    seed_file_url_blob "$id" /tmp/a.txt

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
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-resolved-path', readfile('$pathfile'));
      INSERT INTO file_authorities (clip_id,item_index,path) VALUES ($id,1,readfile('$pathfile'));"

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
  It '--restore-id <n> works headless for a local row (spec R4): one clip.set.files{clip_id} exchange, exit 0'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','mac-mini',500); SELECT last_insert_rowid();")
    seed_file_url_blob "$id" /tmp/a.txt

    When call run_restore_id "$id"
    The status should be success
    wire="$(recob_op 1)|$(recob_endpoint 1)|clip_id=$(recob_field_hex 1 clip_id)"
    The variable wire should equal "clip.set.files|trusted|clip_id=$(spec_hex "$id")"
  End

  It '--restore-id <n> works headless for a remote manifest row (spec R4): rsync-pulls then sends clip.set.files{paths} with the localized paths, exit 0'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','devbox',501); SELECT last_insert_rowid();")
    mf="$SHELLSPEC_TMPBASE/manifest.bin"
    printf '%s/remote-a.txt' "$REMOTE_SRC" > "$mf"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($id, 'x-file-manifest', readfile('$mf'));"

    When call run_restore_id "$id"
    The status should be success
    The contents of file "$RSYNCLOG" should include "devbox:$REMOTE_SRC/remote-a.txt"
    wire="$(recob_op 1)|$(recob_endpoint 1)"
    The variable wire should equal "clip.set.files|trusted"
    got_paths="$(recob_field_hex 1 paths)"
    The variable got_paths should equal "$(spec_hex "$HOME/.cache/pick-clipboard/files/$id/1/remote-a.txt")"
  End

  It '--restore-id rejects a non-numeric id, exit 1 (spec R4)'
    When call zsh -f "$SCRIPT" --restore-id notanumber
    The status should be failure
    The stderr should include "numeric clip id"
  End

  It '--restore-id exits 1 when the underlying restore genuinely fails (spec R4)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','mac-mini',502); SELECT last_insert_rowid();")
    seed_file_url_blob "$id" /tmp/a.txt
    bridge_down_restore() { recob_stop; run_restore_id "$1"; }

    When call bridge_down_restore "$id"
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
    seed_file_url_blob "$id" /tmp/a.txt
    bridge_down_restore_prompt() {
      recob_stop
      timeout 5 zsh -f "$SCRIPT" --restore-id "$1" < /dev/null
    }

    When call bridge_down_restore_prompt "$id"
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
# chronologically by when the PEER's clipboard was copied (clip.get's
# timestamp field), not always float to the top above every local row.
#
# bridge_up (top of executable_pick-clipboard) requires an SSH env var AND a
# real connect-probe success. Under the RECOB harness both come for free: the
# recorder's TCP listener answers the probe (recob_start exported
# CLIPBOARD_BRIDGE_PORT, which the picker's own BRIDGE_PORT resolution
# mirrors), and the live-row fetch is three real, authenticated `clip.get`
# exchanges over the --peer route whose reply is scripted per example
# (live_reply). The script is re-read from the start on every connection, so
# ONE `ok` directive serves the text, host and timestamp reads identically.
Describe 'pick-clipboard: live-peer row ordering (X9)'
  Include tests/recob_helper.sh

  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    unset SSH_CLIENT SSH_TTY
    export SSH_CONNECTION="10.0.0.1 1234 10.0.0.2 22"   # bridge_up precondition 1/2
    export HOME="$SHELLSPEC_TMPBASE/home"; rm -rf "$HOME"; mkdir -p "$HOME"
    export TMPDIR="$SHELLSPEC_TMPBASE/tmp"; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    # Same identity pinning as the Ctrl-Y Describe: the recorder's sandboxed
    # self-name file (which outranks scutil in clip::self_host) makes
    # MY_HOST deterministically mac-mini.
    RECOB_SELF_NAME=mac-mini
    recob_start
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    export PICK_CLIPBOARD_DB="$DB"
    mkdir -p "$XDG_DATA_HOME/pick-clipboard"
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
    # (each example scripts its own clip.get reply via live_reply).
    LIVE_TEXT="peer clipboard text, distinct from every local row"
    LIVE_HOST="peer-host"

    export PICK_COMMON_LIB="$LIB_DIR/pick-common.zsh"
    export PICK_BRIDGE_CLIENT_LIB="$LIB_DIR/clipboard-bridge-client.zsh"
    export PICK_CLIPBOARD_NO_RUN=1
    export SCRIPT_PATH="$SCRIPT"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # live_reply <live_ts> -- script the recorder's answer for the picker's
  # live-row fetch at open (spec §22, 6b: via clipbridge::peer_snapshot's
  # clip.get exchange): one §6.1 reply carrying text/regtype/timestamp/host.
  # Every connection re-reads the script from the start, so this single
  # directive serves both the clip.get and files.list exchanges alike (the
  # latter just finds none of the fields it looks for).
  live_reply() {
    recob_script "ok text=$(spec_hex "$LIVE_TEXT") regtype=$(spec_hex v) timestamp=$(spec_hex "$1") host=$(spec_hex "$LIVE_HOST")"
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
    live_reply 200

    When call run_emit
    The status should be success
    expected=$(printf '%s\nLIVE\n%s' "$id_new" "$id_old")
    The output should equal "$expected"
  End

  It 'places the live row at the very top when its copy-time is newer than every local row'
    id_a=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',100,'a'); SELECT last_insert_rowid();")
    id_b=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',200,'b'); SELECT last_insert_rowid();")
    live_reply 999

    When call run_emit
    The status should be success
    expected=$(printf 'LIVE\n%s\n%s' "$id_b" "$id_a")
    The output should equal "$expected"
  End

  It 'places the live row at the very bottom when its copy-time is older than every local row'
    id_a=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',100,'a'); SELECT last_insert_rowid();")
    id_b=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',200,'b'); SELECT last_insert_rowid();")
    live_reply 1

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
    live_reply 200

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
    live_reply 200

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
    live_reply 200

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

  # Task 2 (6b): the open-time live-row fetch now goes through
  # clipbridge::peer_snapshot -- ONE clip.get + ONE files.list exchange --
  # instead of three separate clip_get_raw(text)/clip_get_raw(host)/
  # clip_get_raw(timestamp) round-trips (each a full connection+handshake).
  # LIVE_REGTYPE is captured here too (from the snapshot's text candidate),
  # so clip::copy_live/materialize_live never need a fourth fetch at accept
  # time.
  run_live_state() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      printf "regtype=%s|host=%s" "$LIVE_REGTYPE" "$LIVE_HOST"
    '
  }

  It 'fetches the live entry with one clip.get and one files.list -- never per-field'
    live_reply 200

    When call run_live_state
    The status should be success
    The output should equal "regtype=v|host=peer-host"
    ops="$(recob_ops | tr '\n' ',')"
    The variable ops should equal "clip.get,files.list,"
  End

  # clip::copy_live/materialize_live must reuse LIVE_REGTYPE captured at
  # open -- no extra clip.get for the regtype field at accept time.
  # >/dev/null: clip::copy_live's own clip.set exchange prints the scripted
  # reply's fields (this Describe's canned recob directive answers every
  # exchange identically, clip.set included) -- irrelevant noise here, since
  # the assertion below is about the recorded OP SEQUENCE, not this stdout.
  run_copy_live() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      clip::copy_live
    ' >/dev/null
  }

  It 'clip::copy_live reuses the open-time regtype -- no extra clip.get'
    live_reply 200

    When call run_copy_live
    The status should be success
    ops="$(recob_ops | tr '\n' ',')"
    The variable ops should equal "clip.get,files.list,clip.set,"
  End

  run_materialize_live() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      clip::materialize_live
    ' >/dev/null
  }

  It 'clip::materialize_live reuses the open-time regtype -- no extra clip.get'
    live_reply 200

    When call run_materialize_live
    The status should be success
    ops="$(recob_ops | tr '\n' ',')"
    The variable ops should equal "clip.get,files.list,store.persist.text,"
  End
End

# Task 3 (6b): the live FILES row -- the sitting machine's file clip appears
# in the picker and pulls on accept. A plain fake SYSTEM_BRIDGE_BIN dispatcher
# (Task 1's clipboard-bridge-client_spec.sh convention: branch on the op name
# in argv), not the recob_helper.sh recorder: the recorder reloads its script
# fresh on every CONNECTION and clip.get/files.list are two SEPARATE
# connections, so a single recob_script queue cannot give them two different
# scripted replies -- exactly why Task 1 used the same op-dispatching fake for
# clipbridge::peer_snapshot's own spec.
Describe 'pick-clipboard: live FILES row (6b, Task 3)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    unset SSH_CLIENT SSH_TTY
    export SSH_CONNECTION="10.0.0.1 1234 10.0.0.2 22"   # bridge_up precondition 1/2
    export HOME="$SHELLSPEC_TMPBASE/homelivef"; rm -rf "$HOME"; mkdir -p "$HOME"
    export TMPDIR="$SHELLSPEC_TMPBASE/tmplivef"; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    # Deterministic MY_HOST without a real daemon: clip::self_host's own
    # self-name-file precedence (Phase 7), same fixture recob_start installs.
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/statelivef"
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf 'mac-mini\n' > "$XDG_STATE_HOME/clipboard/self-name"

    DB="$SHELLSPEC_TMPBASE/history-livef.db"
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

    BINDIR="$SHELLSPEC_TMPBASE/binlivef"; mkdir -p "$BINDIR"
    export PATH="$BINDIR:$PATH"
    export PICK_COMMON_LIB="$LIB_DIR/pick-common.zsh"
    export PICK_BRIDGE_CLIENT_LIB="$LIB_DIR/clipboard-bridge-client.zsh"
    export PICK_CLIPBOARD_NO_RUN=1
    export SCRIPT_PATH="$SCRIPT"
    unset PICK_CLIPBOARD_LIMIT
  }
  BeforeEach 'setup'

  # write_fake_bridge <clip.get behavior> <files.list behavior> -- Task 1's
  # write_fake shape (clipboard-bridge-client_spec.sh), extended with
  # store.persist.files (logs its argv + saves stdin, the same FAKE_BRIDGE_LOG/
  # FAKE_BRIDGE_STDIN contract Task 1's persist_files spec uses) and probe
  # (always succeeds -- these examples all need bridge_up=1).
  write_fake_bridge() {
    cat > "$BINDIR/fake-bridge" <<FAKE
#!/bin/sh
op=""
for a in "\$@"; do case "\$a" in
  clip.get|files.list|store.persist.files|probe) op="\$a" ;;
esac; done
case "\$op" in
  probe) exit 0 ;;
  clip.get)  $1 ;;
  files.list) $2 ;;
  store.persist.files)
    printf '%s\n' "\$*" >> "\${FAKE_BRIDGE_LOG:?}"
    cat > "\${FAKE_BRIDGE_STDIN:-/dev/null}"
    ;;
esac
FAKE
    chmod +x "$BINDIR/fake-bridge"
    export SYSTEM_BRIDGE_BIN="$BINDIR/fake-bridge"
  }

  # run_live_files_state -- sources the picker under PICK_CLIPBOARD_NO_RUN in a
  # FRESH subprocess (same escape hatch/convention as run_live_state in the X9
  # Describe above) and prints LIVEF_HOST plus the NUL-joined
  # LIVEF_PATHS_FILE contents (newline-joined for a readable assertion). A
  # subprocess, not a direct `source` in this example's own shell: the
  # picker's own cleanup trap covers EXIT INT TERM, and shellspec's `When
  # call` delivers one of those signals to the calling context right after
  # the call returns -- confirmed empirically (a bare EXIT-only trap survives
  # to the next assertion line, but adding INT/TERM makes the trap fire
  # immediately, before the very next line runs). A subprocess sidesteps that
  # entirely: everything worth asserting is read and printed BEFORE the
  # subprocess's own exit ever fires its copy of the trap.
  run_live_files_state() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      print -r -- "host=$LIVEF_HOST"
      if [[ -n "$LIVEF_PATHS_FILE" && -s "$LIVEF_PATHS_FILE" ]]; then
        print -r -- "paths=$(tr "\0" "\n" < "$LIVEF_PATHS_FILE")"
      else
        print -r -- "paths="
      fi
    '
  }

  # files_reply <host> <timestamp> <path>... -- builds the SHELL CODE (not its
  # executed output) for the files.list arm of write_fake_bridge: a `printf`
  # invocation of hex-encoded fields, Task 1's write_fake shape
  # (clipboard-bridge-client_spec.sh). The path arguments are individually
  # NUL-free (a NUL cannot survive a shell positional parameter), and
  # spec_paths_hex (top of this file) does the NUL-joining itself, entirely in
  # its own output stream -- never threading a NUL through an argv slot.
  files_reply() {
    local host=$1 ts=$2; shift 2
    print -r -- "printf 'kind=%s\\nhost=%s\\ntimestamp=%s\\npaths=%s\\n' '$(spec_hex files)' '$(spec_hex "$host")' '$(spec_hex "$ts")' '$(spec_paths_hex "$@")'"
  }

  It 'builds a live FILES row from the snapshot files candidate'
    write_fake_bridge "exit 1" "$(files_reply laptop 1755551300.1 /a/b /c)"

    When call run_live_files_state
    The status should be success
    The line 1 of output should eq 'host=laptop'
    The line 2 of output should eq 'paths=/a/b'
    The line 3 of output should eq '/c'
  End

  It 'suppresses the live FILES row when an equal manifest row is stored'
    write_fake_bridge "exit 1" "$(files_reply laptop 1755551300.1 /a/b /c)"
    mf="$SHELLSPEC_TMPBASE/seed-manifest.bin"
    printf '/a/b\000/c' > "$mf"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','laptop',50);
      INSERT INTO clip_types (clip_id, uti, blob) VALUES (last_insert_rowid(), 'x-file-manifest', readfile('$mf'));"

    When call run_live_files_state
    The status should be success
    The line 2 of output should eq 'paths='
  End

  run_pull_live_files() {
    source "$SCRIPT_PATH"
    clip::copy_files_by_id() { COPY_CALLED_WITH="$1"; }
    clip::pull_live_files laptop "$PULL_PATHS_FILE"
  }

  It "clip::pull_live_files persists then restores by the resolved id"
    write_fake_bridge "exit 1" "exit 1"
    PULL_PATHS_FILE="$SHELLSPEC_TMPBASE/pull-paths.bin"
    printf '/x/y' > "$PULL_PATHS_FILE"
    FAKE_BRIDGE_LOG="$SHELLSPEC_TMPBASE/fake-bridge-log"; : > "$FAKE_BRIDGE_LOG"
    export FAKE_BRIDGE_LOG
    export FAKE_BRIDGE_STDIN="$SHELLSPEC_TMPBASE/fake-bridge-stdin"
    SEEDED_ROW_ID=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','laptop',999); SELECT last_insert_rowid();")

    When call run_pull_live_files
    The status should be success
    The contents of file "$FAKE_BRIDGE_LOG" should include 'store.persist.files'
    The contents of file "$FAKE_BRIDGE_LOG" should include 'host=laptop'
    The variable COPY_CALLED_WITH should eq "$SEEDED_ROW_ID"
  End

  emit_rows_with_two_live() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      emit_rows
    '
  }

  # DB rows at ts 100, 300, 500; text candidate ts=400, files ts=200 -> emit
  # order: 500, text-live, 300, files-live, 100 (ABOVE = last_ts>400, MID =
  # 400>=last_ts>200, BELOW = last_ts<=200).
  It 'interleaves two live rows each by its own timestamp'
    write_fake_bridge \
      "printf 'text=%s\nregtype=%s\ntimestamp=%s\nhost=%s\n' '$(spec_hex "peer text, distinct from every local row")' '$(spec_hex v)' '$(spec_hex 400)' '$(spec_hex peer-host)'" \
      "$(files_reply peer-host 200 /a/b /c)"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',100,'row-100 text');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',300,'row-300 text');"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts, text_plain) VALUES ('text','mac-mini',500,'row-500 text');"

    When call emit_rows_with_two_live
    The status should be success
    The line 1 of output should include 'row-500'
    The line 2 of output should include $'\x1f''LIVE'$'\x1e'
    The line 3 of output should include 'row-300'
    The line 4 of output should include $'\x1f''LIVEF'$'\x1e'
    The line 5 of output should include 'row-100'
  End
End

# X8: a files/file/directory row's path was right-truncated
# (substr(...,1,CW-1)||'…') exactly like a text row, which chops off the
# BASENAME -- the part that matters. clip::shorten_path (list rows) and the
# preview_script's fold-based wrap (preview pane) fix that; see the X8
# comment block above EMIT_ROW_BODY in the picker script for the full
# design (why a zsh/bash-portable helper + a \x02-marker splice in
# emit_rows/emit_script, rather than doing tail-truncation in pure SQL).
Describe 'pick-clipboard: file-path rendering keeps the basename (X8)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    # No SSH_CONNECTION -> bridge_up is false -> no live row, so emit_rows'
    # output below is exactly the seeded DB rows, nothing synthetic mixed in.
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    export HOME="$SHELLSPEC_TMPBASE/home"; rm -rf "$HOME"; mkdir -p "$HOME"
    # Phase 7: sandbox self_host's self-name lookup too (see the matching
    # comment in the Ctrl-Y files branch Describe's setup() above) so this
    # machine's own self-name file, if any, can never leak into MY_HOST here.
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
    export PICK_COMMON_LIB="$LIB_DIR/pick-common.zsh"
    export PICK_BRIDGE_CLIENT_LIB="$LIB_DIR/clipboard-bridge-client.zsh"
    export PICK_CLIPBOARD_NO_RUN=1
    export SCRIPT_PATH="$SCRIPT"
  }
  BeforeEach 'setup'

  # run_list_content -- sources the picker under PICK_CLIPBOARD_NO_RUN, calls
  # emit_rows, and for each row prints just the visible content column
  # (everything before the first \x1f tail field), with ANSI color codes
  # stripped -- the padded/truncated text this fix is about, with none of
  # the glyph/color noise around it.
  run_list_content() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      emit_rows | while IFS= read -r line; do
        vis=${line%%$'"'"'\x1f'"'"'*}
        print -r -- "$vis"
      done | sed -E $'"'"'s/\x1b\[[0-9;]*m//g'"'"'
    '
  }

  It 'a long single-file path in a narrow CW: list content keeps the basename, elides the head with a leading …/'
    export PICK_CLIPBOARD_CONTENT_WIDTH=20
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, source_host, last_ts) VALUES ('file','/Users/thiago/.local/share/chezmoi/Makefile','mac-mini',100);"

    When call run_list_content
    The status should be success
    The output should include "…/chezmoi/Makefile"
    The output should not include ".local/share/chezmoi/Makefile"
  End

  It 'a multi-file row: list content shows the first file'"'"'s tail + a (+N) suffix for the rest'
    export PICK_CLIPBOARD_CONTENT_WIDTH=30
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, source_host, last_ts) VALUES ('files','/tmp/one.txt
/tmp/two.txt
/tmp/three.txt','mac-mini',100);"

    When call run_list_content
    The status should be success
    The output should include "/tmp/one.txt (+2)"
  End

  # Non-file kinds are untouched: same substr(...,1,CW-1)||'…' right-truncate
  # as before X8 (requirement 3).
  It 'a text row still gets the plain right-truncate (unchanged by X8)'
    export PICK_CLIPBOARD_CONTENT_WIDTH=10
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, text_preview, source_host, last_ts) VALUES ('text','a rather long line of text','a rather long line of text','mac-mini',100);"

    When call run_list_content
    The status should be success
    The output should include "a rather …"
    The output should not include "…/"
  End

  It 'the preview pane for a files row wraps a long path across multiple lines, dropping no characters'
    long_path="/Users/thiago/.local/share/chezmoi/home/dot_local/libexec/executable_pick-clipboard-with-an-unusually-long-name.sh"
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, source_host, last_ts) VALUES ('file','$long_path','mac-mini',100); SELECT last_insert_rowid();")

    outfile="$SHELLSPEC_TMPBASE/preview-out-$id"
    zsh -f -c '
      source "$SCRIPT_PATH"
      FZF_PREVIEW_COLUMNS=20 bash "$preview_script" "$1" > "$2"
    ' _ "$id" "$outfile"
    first_line=$(head -1 "$outfile")
    flat=$(tr -d '\n' < "$outfile")

    When call test "${#first_line}" -le 20
    The status should be success
    The variable flat should include "$long_path"
  End

  It 'the preview pane for a multi-file row still shows every path (unwrapped, since each fits the pane)'
    id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, source_host, last_ts) VALUES ('files','/tmp/a.txt
/tmp/b.txt','mac-mini',100); SELECT last_insert_rowid();")
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      bash "$preview_script" "$1"
    ' _ "$id" 2>&1)"
    When call test -n "$result"
    The status should be success
    The variable result should include "/tmp/a.txt"
    The variable result should include "/tmp/b.txt"
  End

  # --- clip::shorten_path (pure-function unit tests) --------------------------
  It 'clip::shorten_path: a path that already fits the width is returned whole'
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::shorten_path "/tmp/a.txt" 20
    ')"
    When call test -n "$result"
    The status should be success
    The variable result should equal "/tmp/a.txt"
  End

  It 'clip::shorten_path: a path over budget is tail-truncated, keeping the basename + as many trailing segments as fit'
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::shorten_path "/Users/thiago/.local/share/chezmoi/Makefile" 18
    ')"
    When call test -n "$result"
    The status should be success
    The variable result should equal "…/chezmoi/Makefile"
  End

  # X8 review (Minor): an over-long bare basename still keeps a leading '…'
  # elision marker (was a bare trailing substring, which read like an
  # un-truncated short name) -- '…atall.txt', not 'satall.txt'.
  It 'clip::shorten_path: a single segment longer than the width falls back to a … marker + ITS OWN trailing chars'
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::shorten_path "areallylongfilenamewithoutanyslashesatall.txt" 10
    ')"
    When call test -n "$result"
    The status should be success
    The variable result should equal "…atall.txt"
    The variable result should not include "/"
  End

  # X8 review (Critical): the base case ('…/'+basename, no fitted segments)
  # must be budget-checked like the loop candidates are -- pre-fix a basename
  # of length width-1 returned an 11-char string for width 10 ('…/Makefile1'),
  # overflowing the fixed content column and misaligning it against text
  # rows. Assert the result is <= width at the exact boundary (basename ==
  # width-1, width, width+1). Runs under LC_ALL=C to also exercise the
  # byte-vs-char length fix below on plain ASCII (char==byte here, so this
  # isolates the off-by-one).
  It 'clip::shorten_path: result length never exceeds width at the basename==width-1/width/width+1 boundaries'
    out="$(LC_ALL=C zsh -f -c '
      source "$SCRIPT_PATH"
      for p in /x/Makefil /x/Makefile /x/Makefilee; do
        r=$(clip::shorten_path "$p" 8)
        # measure in CHARACTERS (utf-8), matching the columns math
        LC_ALL= LC_CTYPE=en_US.UTF-8
        print -r -- "${#r}"
      done
    ')"
    # basenames are Makefil(7)=width-1, Makefile(8)=width, Makefilee(9)=width+1
    When call test "$out" = "$(printf '8\n8\n8')"
    The status should be success
  End

  # X8 review (Important): the fit/pad math must count CHARACTERS, not bytes,
  # so an accented path aligns with a text row's CW even under LC_ALL=C (where
  # bare ${#var} counts bytes). Cross-kind parity: render a multibyte file row
  # AND an ASCII text row at the same CW, strip ANSI, and assert the visible
  # content columns have equal character width.
  It 'file-row content aligns to the same char width as a text-row at the same CW, even under LC_ALL=C (multibyte)'
    export PICK_CLIPBOARD_CONTENT_WIDTH=14
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, source_host, last_ts) VALUES ('file','/tmp/café/résumé.txt','mac-mini',100);"
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, text_preview, source_host, last_ts) VALUES ('text','ABCDEFGHIJKLMNOP','ABCDEFGHIJKLMNOP','mac-mini',90);"

    out="$(LC_ALL=C zsh -f -c '
      source "$SCRIPT_PATH"
      emit_rows | while IFS= read -r line; do
        vis=${line%%$'"'"'\x1f'"'"'*}
        stripped=$(print -r -- "$vis" | sed -E $'"'"'s/\x1b\[[0-9;]*m//g'"'"')
        LC_ALL= LC_CTYPE=en_US.UTF-8
        print -r -- "${#stripped}"
      done
    ')"
    # two rows, both the same visible char width -> aligned
    file_w=$(printf '%s\n' "$out" | sed -n 1p)
    text_w=$(printf '%s\n' "$out" | sed -n 2p)
    When call test "$file_w" = "$text_w"
    The status should be success
  End
End

Describe 'pick-clipboard: MY_HOST portability (Phase 7)'
  PICKER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  CORE="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/clipboard-store-core.zsh"

  It 'resolves MY_HOST from the self-name file before scutil'
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf 'cruise-box' > "$XDG_STATE_HOME/clipboard/self-name"
    When run command sh -c 'zsh -f -c "source \"$1\"; clip::self_host"' _ "$CORE"
    The output should equal "cruise-box"
  End

  # clip::self_host already has direct coverage above (it predates this task
  # -- Tasks 1-2). What's new here is the WIRING: does the picker's own
  # MY_HOST actually pick up the self-name file, through the subshell-
  # isolated `source` this task adds (see the header comment at MY_HOST's
  # assignment site). Sources the picker under PICK_CLIPBOARD_NO_RUN (same
  # escape hatch every other Describe in this file uses) and echoes $MY_HOST
  # directly -- a real store file must exist for the picker to get past its
  # own `[[ -f "$DB_FILE" ]] || die` guard, so an empty DB is created first.
  It 'wires MY_HOST from the self-name file through the picker itself'
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    export HOME="$SHELLSPEC_TMPBASE/myhost-home"; rm -rf "$HOME"; mkdir -p "$HOME"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/myhost-data"; mkdir -p "$XDG_DATA_HOME/pick-clipboard"
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/myhost-state"
    mkdir -p "$XDG_STATE_HOME/clipboard" "$XDG_STATE_HOME/pick-clipboard"
    printf 'cruise-box' > "$XDG_STATE_HOME/clipboard/self-name"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    sqlite3 "$DB" 'CREATE TABLE clips (id INTEGER PRIMARY KEY AUTOINCREMENT, source_host TEXT);'
    export PICK_CLIPBOARD_DB="$DB"
    LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export PICK_COMMON_LIB="$LIB_DIR/pick-common.zsh"
    export PICK_BRIDGE_CLIENT_LIB="$LIB_DIR/clipboard-bridge-client.zsh"
    export PICK_CLIPBOARD_NO_RUN=1
    export SCRIPT_PATH="$PICKER"

    When run command zsh -f -c '
      source "$SCRIPT_PATH"
      print -r -- "$MY_HOST"
    '
    The output should equal "cruise-box"
  End
End

# The content column used to render the stored text_preview raw, so a row
# whose preview was captured before the writers learned to flatten showed
# whatever whitespace happened to be there: a clip that OPENS with a blank
# line stored an EMPTY preview (${text%%$'\n'*}) and rendered as a blank row
# with nothing to identify it by, and an indented first line rendered pushed
# off its column. clip::sql_flatten/$SNIPPET_EXPR repair those rows at render
# time, the way clipboard-picker.lua's query_items does for the GUI picker.
Describe 'pick-clipboard: the content column trims and flattens its snippet'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    # No SSH_CONNECTION -> no live row, so the output is exactly the seeded rows.
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    export HOME="$SHELLSPEC_TMPBASE/snippet-home"; rm -rf "$HOME"; mkdir -p "$HOME"
    export XDG_STATE_HOME="$HOME/.local/state"
    export TMPDIR="$SHELLSPEC_TMPBASE/snippet-tmp"; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/snippet-data"; mkdir -p "$XDG_DATA_HOME/pick-clipboard"
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
      CREATE TABLE clip_types (clip_id INTEGER, uti TEXT, blob BLOB, PRIMARY KEY (clip_id, uti));
    '
    export PICK_COMMON_LIB="$LIB_DIR/pick-common.zsh"
    export PICK_BRIDGE_CLIENT_LIB="$LIB_DIR/clipboard-bridge-client.zsh"
    export PICK_CLIPBOARD_NO_RUN=1
    export SCRIPT_PATH="$SCRIPT"
    export PICK_CLIPBOARD_CONTENT_WIDTH=40
  }
  BeforeEach 'setup'

  # Same harness as the X8 Describe above: the visible content column of every
  # emitted row (everything before the first \x1f tail field), ANSI stripped.
  run_list_content() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      emit_rows | while IFS= read -r line; do
        vis=${line%%$'"'"'\x1f'"'"'*}
        print -r -- "$vis"
      done | sed -E $'"'"'s/\x1b\[[0-9;]*m//g'"'"'
    '
  }

  It 'a legacy row whose preview opens with a blank line gets a real snippet from text_plain'
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, text_plain, source_host, last_ts) VALUES ('text','','

    function foo() {
        return 1
    }','mac-mini',100);"

    When call run_list_content
    The status should be success
    The output should include "function foo() { return 1 }"
  End

  It 'a legacy preview with leading/trailing whitespace renders trimmed'
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, text_plain, source_host, last_ts) VALUES ('text','   indented legacy   ','   indented legacy   ','mac-mini',100);"

    When call run_list_content
    The status should be success
    # The column is left-padded only by the icon+separator, so a leading space
    # in the snippet would show up as a 3-space run ahead of the text.
    The output should include "  indented legacy"
    The output should not include "   indented legacy"
  End

  It 'a row with no usable preview and no plain text falls back to the [kind] badge'
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, text_plain, source_host, last_ts) VALUES ('text','','  ','mac-mini',100);"

    When call run_list_content
    The status should be success
    The output should include "[text]"
  End

  # The files/file/directory branch reaches the badge through its own
  # expression (the paths stay raw there for X8's tail truncation), and an
  # EMPTY preview has to hit it too -- IFNULL alone only caught NULL.
  It 'a files row with an empty preview falls back to the [files] badge'
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, source_host, last_ts) VALUES ('files','','mac-mini',100);"

    When call run_list_content
    The status should be success
    The output should include "[files]"
  End

  # The row SQL is duplicated into the --reload-cmd script (fzf reloads with a
  # fresh shell after a delete/pin), so the repair has to be in that copy too
  # -- otherwise the first Ctrl-P/Ctrl-D would bring the blank rows back.
  It 'the reload script renders the same repaired snippet as the initial stream'
    sqlite3 "$DB" "INSERT INTO clips (type_kind, text_preview, text_plain, source_host, last_ts) VALUES ('text','','
   reloaded snippet','mac-mini',100);"

    # Only the visible content column: the row's \x1f-prefixed tail fields
    # carry control bytes that have no business in a shellspec assertion.
    result="$(zsh -f -c '
      source "$SCRIPT_PATH"
      FZF_COLUMNS=100 bash "$emit_script" | while IFS= read -r line; do
        print -r -- "${line%%$'"'"'\x1f'"'"'*}"
      done | sed -E $'"'"'s/\x1b\[[0-9;]*m//g'"'"'
    ')"
    When call test -n "$result"
    The status should be success
    The variable result should include "reloaded snippet"
  End
End
