# Tests for the paste client's file modes — `system-clip paste --manifest` and
# `system-clip paste --files` — against the REAL listener in recording mode
# (spec §11.1) rather than a fake `nc` with a canned frame.
#
# WHAT THE CONVERSION CHANGED, beyond the transport.
#
#   * The manifest is no longer a US-separated payload this file has to build by
#     hand. `files.list` and `files.grant` answer with named fields, so the
#     examples below put a real ROW in front of the daemon's own resolver
#     (`seed_clip`) and let it produce the reply. That is strictly stronger than
#     a canned frame: the kind, the paths, the `-` a pointer row answers with
#     and the 64-hex capability a trusted row mints are all the daemon's own.
#   * `files.fetch` declares `kind`, so the `is-directory` retry — and the
#     second connection it cost — is gone. The remote examples assert exactly
#     ONE fetch per item.
#   * §6.4's explicit empty `D` makes truncation a protocol fact. The recorder's
#     `close` directive produces it, so "the stream ended early" is now
#     assertable without hand-cutting a tar.
#   * Error strings became §10 codes. Assertions that used to grep a
#     dispatcher's message text now key on what the client renders from the
#     code.
#
# WHAT MUST NOT CHANGE, because other programs parse it:
#
#   * the porcelain stream — `progress\t<path>\t<done>\t<total>` per item and a
#     terminal `done\t<files>\t<bytes>\t<seconds>`;
#   * the size-cap refusal line, matched by
#     `home/dot_config/yazi/plugins/smart-paste.yazi/main.lua` as
#     `^pbpaste: (.-) exceeds size cap %(CLIP_FILE_MAX=(%d+) bytes, item is
#     (%d+) bytes%) %-%- refusing`. Everything up through `-- refusing` is
#     load-bearing and is asserted here by exact equality, not by substring.
#
# The messages still say `pbpaste:` on purpose: that is the shim name the user
# invoked, and the binary's own name never appears in its output.
#
# ASSERTION SHAPE. Every example that reads the recorder drives the client AND
# prints what it wants to assert from inside ONE function, and asserts on that
# function's output. Two honest reasons: the client's exit status is then
# carried alongside the wire assertions instead of being asserted separately,
# and a run that got several fields wrong reports all of them in one message.
#
# Two harness facts worth not rediscovering. `When run command <path>` cannot
# run an absolute path — shellspec resolves that word through PATH only and
# aborts 127 — so the client is driven with a bare `When run "$CLIP"`. And an
# unmatched glob is a hard error under zsh, so "no staging residue" is probed
# with `find` (see `has_staging`) rather than with `ls -d ...*`.

# --- the store the daemon answers from ---------------------------------------
#
# The schema is frozen (§16, and `store.rs` carries it statement for statement
# from the Lua writer), so restating it here cannot drift out from under the
# daemon; `CREATE TABLE IF NOT EXISTS` means the daemon's own `ensure_schema`
# still runs over the same shape.
seed_reset() {
  SEED_DB="$XDG_DATA_HOME/pick-clipboard/history.db"
  export SEED_DB
  mkdir -p "$XDG_DATA_HOME/pick-clipboard"
  rm -f "$SEED_DB" "$SEED_DB-wal" "$SEED_DB-shm"
  sqlite3 "$SEED_DB" "
CREATE TABLE IF NOT EXISTS clips (
    id INTEGER PRIMARY KEY AUTOINCREMENT, text_preview TEXT, text_plain TEXT,
    len INTEGER, first_ts REAL, last_ts REAL, source_app TEXT,
    source_bundle_id TEXT, type_kind TEXT, regtype TEXT, pinned INTEGER DEFAULT 0,
    type_hash TEXT, source_host TEXT);
CREATE TABLE IF NOT EXISTS clip_types (
    clip_id INTEGER, uti TEXT, blob BLOB, PRIMARY KEY (clip_id, uti));
CREATE TABLE IF NOT EXISTS file_authorities (
    clip_id INTEGER NOT NULL, item_index INTEGER NOT NULL, path BLOB NOT NULL,
    PRIMARY KEY (clip_id, item_index));
CREATE TABLE IF NOT EXISTS file_grants (
    token TEXT NOT NULL, item_index INTEGER NOT NULL, path BLOB NOT NULL,
    created_ts REAL NOT NULL, last_used_ts REAL NOT NULL,
    hard_expires_ts REAL NOT NULL, PRIMARY KEY (token, item_index));"
}

seed_hex() { printf '%s' "$1" | xxd -p | tr -d '\n'; }

# The NUL-joined `x-file-manifest` blob, byte-exact: a path may legally carry
# any byte but NUL and /, so it goes through hex rather than through a shell
# scalar.
seed_paths_hex() {
  {
    _seed_first=1
    for _seed_path in "$@"; do
      [ "$_seed_first" -eq 1 ] || printf '\000'
      printf '%s' "$_seed_path"
      _seed_first=0
    done
  } | xxd -p | tr -d '\n'
}

# seed_clip <kind> <host> <ts> <auth|pointer> <path>... — the newest row, which
# is the one `files.list`/`files.grant` resolve. `auth` writes the immutable
# authority snapshot that makes the grant mint a real 64-hex capability;
# `pointer` leaves it out, which is what a row with no local authority is and
# what makes `files.grant` answer `-`.
seed_clip() {
  _seed_kind=$1 _seed_host=$2 _seed_ts=$3 _seed_auth=$4
  shift 4
  sqlite3 "$SEED_DB" "
DELETE FROM clips; DELETE FROM clip_types; DELETE FROM file_authorities;
DELETE FROM file_grants;
INSERT INTO clips (text_preview,len,first_ts,last_ts,type_kind,pinned,type_hash,source_host)
  VALUES ('seeded',6,$_seed_ts,$_seed_ts,'$_seed_kind',0,'seedhash','$_seed_host');
INSERT INTO clip_types (clip_id,uti,blob)
  VALUES (last_insert_rowid(),'x-file-manifest',X'$(seed_paths_hex "$@")');"
  [ "$_seed_auth" = auth ] || return 0
  _seed_index=0
  for _seed_path in "$@"; do
    _seed_index=$((_seed_index + 1))
    sqlite3 "$SEED_DB" "INSERT INTO file_authorities (clip_id,item_index,path)
      VALUES ((SELECT MAX(id) FROM clips),$_seed_index,X'$(seed_hex "$_seed_path")');"
  done
}

# A text row, for the "this is not a files clip" refusals.
seed_text_clip() {
  sqlite3 "$SEED_DB" "
DELETE FROM clips; DELETE FROM clip_types; DELETE FROM file_authorities;
INSERT INTO clips (text_preview,text_plain,len,first_ts,last_ts,type_kind,regtype,pinned,type_hash,source_host)
  VALUES ('plain text','plain text',10,1752200000.4,1752200000.4,'text','v',0,'texthash','$RECOB_SELF_NAME');"
}

# Residue probes for the staging and recovery dirs. `find` rather than a glob:
# an unmatched glob is a hard error under zsh, which would turn "there is no
# residue" — the passing case — into noise on stderr.
_residue() { find "$1" -maxdepth 1 -name "$2" -print -quit 2>/dev/null; }
has_staging() { [ -n "$(_residue "$1" '.pbpaste-staging.*')" ]; }
has_recovery() { [ -n "$(_residue "$1" '.pbpaste-recovery.*')" ]; }

# A capability shaped like the real thing (64 hex) for the examples whose reply
# is scripted rather than resolved. `files.fetch`'s own grant check lives in the
# handler, and a scripted reply is served before the handler runs, so the value
# only has to satisfy the client's `has_capability`.
SEED_FAKE_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

Describe 'paste --manifest'
  Include tests/recob_helper.sh

  setup() {
    # The suite runs on a machine that may itself be reached over SSH; a shell
    # variable left in the ambient environment would silently route every
    # example down the public endpoint.
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    recob_start
    seed_reset
    export CLIP="$(recob_client_bin)"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  It 'prints kind/host/ts/path lines and exits 0 for a single-file clip'
    seed_clip file mac-mini 1752200000.123456 pointer /tmp/a.txt
    When run "$CLIP" paste --manifest
    The status should be success
    The line 1 of output should equal "$(printf 'kind\tfile')"
    The line 2 of output should equal "$(printf 'host\tmac-mini')"
    The line 3 of output should equal "$(printf 'ts\t1752200000.123456')"
    The line 4 of output should equal "$(printf 'path\t/tmp/a.txt')"
    The lines of output should equal 4
  End

  It 'prints one path line per path for a multi-file clip, paths with spaces'
    seed_clip files mac-mini 1752200000.5 pointer '/tmp/a b.txt' /tmp/c.txt
    When run "$CLIP" paste --manifest
    The status should be success
    The line 1 of output should equal "$(printf 'kind\tfiles')"
    The line 4 of output should equal "$(printf 'path\t/tmp/a b.txt')"
    The line 5 of output should equal "$(printf 'path\t/tmp/c.txt')"
    The lines of output should equal 5
  End

  It 'preserves the row type_kind verbatim (directory)'
    seed_clip directory mac-mini 1752200000.9 pointer /tmp/adir
    When run "$CLIP" paste --manifest
    The status should be success
    The line 1 of output should equal "$(printf 'kind\tdirectory')"
  End

  It 'asks files.list on the trusted socket when this shell is not over SSH'
    # The public port is pointed at a closed one for the length of the run: if
    # the client reached for it at all the example fails, which is what the old
    # ":2489 vs :2490" log assertion was really pinning.
    seed_clip file mac-mini 1752200000.1 pointer /tmp/a.txt
    local_route() {
      CLIPBOARD_BRIDGE_PORT=1 "$CLIP" paste --manifest >/dev/null || return 1
      printf '%s|%s|%s' "$(recob_op 1)" "$(recob_endpoint 1)" "$(recob_count)"
    }
    When call local_route
    The output should equal 'files.list|trusted|1'
  End

  It 'asks files.list on the reverse-tunneled public endpoint over SSH'
    # Same proof in the other direction: the trusted socket path is bogus, so
    # the credentialed TCP endpoint is the only way this could have answered.
    seed_clip file mac-mini 1752200000.1 pointer /tmp/a.txt
    ssh_route() {
      SSH_CONNECTION="x 1 y 22" CLIPBOARD_BRIDGE_LOCAL_SOCKET="$RECOB_DIR/absent.sock" \
        "$CLIP" paste --manifest >/dev/null || return 1
      printf '%s|%s|%s' "$(recob_op 1)" "$(recob_endpoint 1)" "$(recob_count)"
    }
    When call ssh_route
    The output should equal 'files.list|public|1'
  End

  It 'honors CLIPBOARD_BRIDGE_PORT over SSH'
    seed_clip file mac-mini 1752200000.1 pointer /tmp/a.txt
    When run env SSH_CONNECTION="x 1 y 22" CLIPBOARD_BRIDGE_PORT=1 "$CLIP" paste --manifest
    The status should be failure
    The output should equal ""
    The stderr should include "127.0.0.1:1"
  End

  It 'exits 1 with nothing on stdout and a reason on stderr for a non-files clip'
    seed_text_clip
    When run "$CLIP" paste --manifest
    The status should be failure
    The output should equal ""
    The stderr should include "not a files clip"
  End

  It 'exits 1 with nothing on stdout and a reason on stderr for an empty store'
    When run "$CLIP" paste --manifest
    The status should be failure
    The output should equal ""
    The stderr should include "the store holds no rows"
  End

  It 'exits 1 with nothing on stdout when the bridge is unreachable'
    unreachable() { recob_stop; "$CLIP" paste --manifest; }
    When call unreachable
    The status should be failure
    The output should equal ""
    The stderr should include "not reachable"
  End

  It 'rejects a stream that ends mid-frame instead of reporting an empty manifest'
    # §6.4/§11.1: `close` writes a header that declares a body and then hangs
    # up. Every old "truncated frame"/"malformed frame" case collapses into
    # this one, because the length prefix is now the daemon's own encoder's.
    seed_clip file mac-mini 1752200000.1 pointer /tmp/a.txt
    recob_script 'close'
    When run "$CLIP" paste --manifest
    The status should be failure
    The output should equal ""
    The stderr should equal "pbpaste: protocol error: truncated frame"
  End

  It 'documents every supported file-materialization route'
    When run "$CLIP" paste --help
    The status should be success
    The output should include "SSH clients stream authorized files"
    The output should include "healthy peer mount"
    The output should not include "later milestone"
  End

  It 'never touches the bridge for a plain paste (no flags)'
    # The platform tool is stubbed rather than driven: a spec must never read or
    # write the human's real pasteboard, and the point here is only that the
    # bytes pass through untouched and no exchange happens.
    stubdir="$RECOB_DIR/bin"; mkdir -p "$stubdir"
    printf '#!/bin/sh\nprintf %%s "untouched-sentinel"\n' > "$stubdir/pbpaste"
    chmod +x "$stubdir/pbpaste"
    plain() {
      PBPASTE_DARWIN_BIN="$RECOB_DIR/bin/pbpaste" "$CLIP" paste || return 1
      printf '|%s' "$(recob_count)"
    }
    When call plain
    The output should equal 'untouched-sentinel|0'
  End
End

# The local materialization engine: `paste --files [--force]
# [--quiet|--progress|--porcelain] [dir]` over a manifest this machine owns.
# Every manifest here points at REAL files and directories, because the whole
# point is the copy engine and the bytes that land in the target.
Describe 'paste --files (local materialization)'
  Include tests/recob_helper.sh

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    recob_start
    seed_reset
    export CLIP="$(recob_client_bin)"
    export SRC="$RECOB_DIR/src"; mkdir -p "$SRC"
    export TARGET="$RECOB_DIR/target"; mkdir -p "$TARGET"
    export BINDIR="$RECOB_DIR/bin"; mkdir -p "$BINDIR"
    export PATH="$BINDIR:$PATH"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  It 'materializes a file and a directory into the target dir, contents identical to the source'
    printf 'hello world\n' > "$SRC/a.txt"
    mkdir -p "$SRC/adir/nested"
    printf 'nested content\n' > "$SRC/adir/nested/b.txt"
    seed_clip files "$RECOB_SELF_NAME" 1752200000.1 auth "$SRC/a.txt" "$SRC/adir"
    materialize() {
      "$CLIP" paste --files "$TARGET" >/dev/null || return 1
      diff "$SRC/a.txt" "$TARGET/a.txt" >/dev/null || return 2
      diff -r "$SRC/adir" "$TARGET/adir" >/dev/null || return 3
      # A same-host clip is copied here, never streamed: one exchange, the
      # manifest's own, and no `files.fetch` at all.
      printf '%s' "$(recob_ops | tr '\n' ',')"
    }
    When call materialize
    The output should equal 'files.grant,'
  End

  It 'routes a manifest stamped with the pushed self-name identity to the LOCAL path'
    # The identity comes from $XDG_STATE_HOME/clipboard/self-name, which
    # ssh-prepare-connection writes and which deliberately differs from this
    # machine's own hostname. If the client resolved the hostname instead, this
    # row would misclassify as remote and — with no SSH env here — demand a peer
    # mount rather than copying.
    printf 'self-name routed\n' > "$SRC/selfname.txt"
    seed_clip file "$RECOB_SELF_NAME" 1752200000.62 auth "$SRC/selfname.txt"
    When run "$CLIP" paste --files "$TARGET"
    The status should be success
    The contents of file "$TARGET/selfname.txt" should equal "self-name routed"
  End

  It 'refuses a local self-host manifest that has no authority token'
    # A pointer row is a row whose paths carry no local authority — the shape a
    # peer-mount-enriched pasteboard produces. Materializing one copies bytes
    # the origin never authorized this machine to take.
    printf 'untrusted local\n' > "$SRC/untrusted-local.txt"
    seed_clip file "$RECOB_SELF_NAME" 1752200000.11 pointer "$SRC/untrusted-local.txt"
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "did not authorize"
    The file "$TARGET/untrusted-local.txt" should not be exist
  End

  It 'preserves a literal US byte in a path instead of splitting a new item'
    # The US byte was the old wire's field separator. It is an ordinary path
    # byte now, and the manifest is length-prefixed — but a path is still bytes,
    # and this pins that nothing along the way re-splits on one.
    us_name="unit$(printf '\037')separator.txt"
    printf 'control-byte path\n' > "$SRC/$us_name"
    seed_clip file "$RECOB_SELF_NAME" 1752200000.15 auth "$SRC/$us_name"
    us_path() {
      "$CLIP" paste --files "$TARGET" >/dev/null || return 1
      cmp "$SRC/$us_name" "$TARGET/$us_name" || return 2
    }
    When call us_path
    The status should be success
  End

  It 'refuses to overwrite an existing name and lists it on stderr'
    printf 'new\n' > "$SRC/dup.txt"
    printf 'old\n' > "$TARGET/dup.txt"
    seed_clip file "$RECOB_SELF_NAME" 1752200000.2 auth "$SRC/dup.txt"
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "refusing to overwrite existing items (use --force)"
    The stderr should include "dup.txt"
    The contents of file "$TARGET/dup.txt" should equal "old"
  End

  It '--force overwrites the conflicting target'
    printf 'new\n' > "$SRC/dup2.txt"
    printf 'old\n' > "$TARGET/dup2.txt"
    seed_clip file "$RECOB_SELF_NAME" 1752200000.3 auth "$SRC/dup2.txt"
    When run "$CLIP" paste --files --force "$TARGET"
    The status should be success
    The contents of file "$TARGET/dup2.txt" should equal "new"
  End

  # --force over a DIRECTORY replaces it wholesale by rename-aside (the old tree
  # renamed into the recovery dir, the new tree renamed into place — both
  # atomic), never delete-then-move: `rm -rf` of a directory target is a
  # recursive non-atomic delete, and a kill inside it would leave a half-shredded
  # old tree in the destination.
  It '--force replaces an existing directory target wholesale, leaving no staging dir'
    mkdir -p "$SRC/rdir/sub"
    printf 'new\n' > "$SRC/rdir/sub/new.txt"
    mkdir -p "$TARGET/rdir"
    printf 'old\n' > "$TARGET/rdir/stale.txt"
    seed_clip directory "$RECOB_SELF_NAME" 1752200000.37 auth "$SRC/rdir"
    replace_dir() {
      "$CLIP" paste --files --force "$TARGET" >/dev/null || return 1
      [ ! -e "$TARGET/rdir/stale.txt" ] || return 9
      diff -r "$SRC/rdir" "$TARGET/rdir" >/dev/null || return 8
      has_staging "$TARGET" && return 7
      has_recovery "$TARGET" && return 6
      return 0
    }
    When call replace_dir
    The status should be success
  End

  # Two manifest entries sharing one basename cannot both land in one flat
  # target — the second would silently clobber the first — so this is refused
  # even with --force, which only ever waives PRE-EXISTING targets.
  It 'refuses a clip whose entries share a basename, even with --force'
    mkdir -p "$SRC/d1" "$SRC/d2"
    printf 'first\n' > "$SRC/d1/same.txt"
    printf 'second\n' > "$SRC/d2/same.txt"
    seed_clip files "$RECOB_SELF_NAME" 1752200000.35 auth "$SRC/d1/same.txt" "$SRC/d2/same.txt"
    When run "$CLIP" paste --files --force "$TARGET"
    The status should be failure
    The stderr should include "multiple items with the same name"
    The stderr should include "same.txt"
    The file "$TARGET/same.txt" should not be exist
  End

  # Porcelain is a CONTRACT: every line exactly 4 tab-separated fields, every
  # local progress line's done/total equal (these tiers are instant), and the
  # stream ends with a `done` line. Asserted with awk, not string matching.
  It 'porcelain: every line has exactly 4 tab fields, progress done==total, ends with a done line'
    printf 'abc\n' > "$SRC/p1.txt"
    printf 'defgh\n' > "$SRC/p2.txt"
    seed_clip files "$RECOB_SELF_NAME" 1752200000.4 auth "$SRC/p1.txt" "$SRC/p2.txt"
    porcelain() {
      out="$RECOB_DIR/porcelain.out"
      "$CLIP" paste --files --porcelain "$TARGET" > "$out" || return 1
      awk -F'\t' '{ if (NF != 4) exit 9 }' "$out" || return 9
      awk -F'\t' '$1 == "progress" && $3 != $4 { exit 6 }' "$out" || return 6
      case "$(tail -n 1 "$out")" in
        done*) : ;;
        *) return 8 ;;
      esac
      sed '$d' "$out" | awk -F'\t' '$1 != "progress" { exit 7 }' || return 7
      return 0
    }
    When call porcelain
    The status should be success
  End

  It 'prints nothing to stdout by default when not attached to a TTY'
    printf 'quiet content\n' > "$SRC/q.txt"
    seed_clip file "$RECOB_SELF_NAME" 1752200000.5 auth "$SRC/q.txt"
    When run "$CLIP" paste --files "$TARGET"
    The status should be success
    The output should equal ""
  End

  It 'fails closed when a source named by the manifest is gone by the time it is read'
    # Against a real daemon a vanished source never reaches the engine: grant-
    # time re-validation demotes the row to a pointer one and the authority
    # refusal above fires first, exactly as the shim's did. The engine's own
    # existence check guards the window AFTER the grant — the daemon validated,
    # then the file vanished — which only a scripted reply can hold open.
    recob_script \
      "ok kind=$(seed_hex file) host=$(seed_hex "$RECOB_SELF_NAME") timestamp=$(seed_hex 1752200000.51) token=$(seed_hex "$SEED_FAKE_TOKEN") paths=$(seed_paths_hex "$SRC/gone.txt")"
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "source no longer exists"
    The file "$TARGET/gone.txt" should not be exist
  End

  It 'refuses a row whose authority a symlink swap invalidated'
    printf 'local target\n' > "$RECOB_DIR/link-target.txt"
    ln -s "$RECOB_DIR/link-target.txt" "$SRC/link.txt"
    # The daemon re-validates the authority snapshot at grant time and a
    # symlink fails it, so even a row SEEDED with authority answers `-` — and
    # a self-host pointer row is refused outright, exactly as the shim's
    # PF_REQUIRE_CAP refused it. (The engine's own symlink size refusal is
    # pinned on the peer-mount route below, the one route that reaches it.)
    seed_clip file "$RECOB_SELF_NAME" 1752200000.52 auth "$SRC/link.txt"
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "did not authorize"
    The file "$TARGET/link.txt" should not be exist
  End

  # §11's per-item cap was scoped to transfers that cross a machine boundary:
  # the shim tested it under `[ "$PF_MOUNT_REMOTE" -eq 1 ]` at every call site,
  # so a same-host copy — a local `cp` of the user's own file — was never
  # capped. Capping it means `pbpaste --files` refuses a 4 GB local paste at
  # the 200 MB default, which is not what the cap is for. The refusal LINE
  # itself is pinned by exact equality in the remote Describe below, where both
  # designs agree that the cap applies.
  It 'does not apply the cross-machine size cap to a same-host local copy'
    Pending 'client: cap_check runs on the local path too; the shim capped only mounted cross-machine transfers'
    printf '0123456789012345678901234567890123456789' > "$SRC/toobig.bin"
    seed_clip file "$RECOB_SELF_NAME" 1752200000.53 auth "$SRC/toobig.bin"
    local_cap() {
      CLIP_FILE_MAX=10 "$CLIP" paste --files "$TARGET" >/dev/null 2>&1 || return 1
      cmp -s "$SRC/toobig.bin" "$TARGET/toobig.bin"
    }
    When call local_cap
    The status should be success
  End

  It 'errors pointing at plain pbpaste when the clipboard entry is not a files clip'
    seed_text_clip
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "not a files clip"
    The stderr should include "use plain pbpaste"
  End

  It 'refuses a directory argument that does not exist before touching the bridge'
    seed_clip file "$RECOB_SELF_NAME" 1752200000.54 auth /tmp
    no_dir() {
      "$CLIP" paste --files "$RECOB_DIR/no-such-dir" 2>"$RECOB_DIR/err" && return 9
      grep -q 'no such directory' "$RECOB_DIR/err" || return 8
      # Argument errors cost no connection: the refusal is decided before the
      # client dials anything.
      printf '%s' "$(recob_count)"
    }
    When call no_dir
    The output should equal '0'
  End
End

# A manifest owned by another machine, read while sitting AT the Mac: the peer's
# endpoint is not forwarded back here, so the bytes must come from an
# already-localized picker cache row or through the healthy read-only peer
# mount, and anything else fails closed pointing at pick-clipboard.
Describe 'paste --files (peer mount)'
  Include tests/recob_helper.sh

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    recob_start
    seed_reset
    export CLIP="$(recob_client_bin)"
    export TARGET="$RECOB_DIR/target"; mkdir -p "$TARGET"
    export BINDIR="$RECOB_DIR/bin"; mkdir -p "$BINDIR"
    export PATH="$BINDIR:$PATH"
    export MOUNT="$RECOB_DIR/mnt/some-other-mac"
    export CM_CALLS="$RECOB_DIR/cm-calls"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # A stand-in for the rclone mount helper. `check` answers with the mount
  # point, `map` rewrites a peer path into it; every call is logged so an
  # example can assert what was asked as well as what happened.
  mount_helper() {
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
echo "\$*" >> "$CM_CALLS"
case "\$1" in
  check) printf '%s\n' "$MOUNT"; exit 0 ;;
  map)   printf '%s%s\n' "$MOUNT" "\$3"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
  }

  mount_helper_down() {
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
echo "\$*" >> "$CM_CALLS"
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
  }

  It 'reports the picker fallback when a remote manifest mount is unavailable'
    mount_helper_down
    seed_clip file some-other-mac 1752200000.6 pointer /remote/missing.txt
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "mount is unavailable"
    The stderr should include "pick-clipboard Ctrl-Y"
  End

  It 'materializes a Yazi-style --porcelain remote paste through a healthy peer mount'
    mkdir -p "$MOUNT/remote/dir with space"
    printf 'mounted file\n' > "$MOUNT/remote/file with space.txt"
    printf 'mounted nested\n' > "$MOUNT/remote/dir with space/nested.txt"
    mount_helper
    printf 'old file\n' > "$TARGET/file with space.txt"
    mkdir -p "$TARGET/dir with space"
    printf 'stale\n' > "$TARGET/dir with space/stale.txt"
    seed_clip files some-other-mac 1752200000.61 pointer \
      '/remote/file with space.txt' '/remote/dir with space'
    mounted() {
      out="$RECOB_DIR/out61"
      "$CLIP" paste --files --force --porcelain "$TARGET" > "$out" || return 9
      [ "$(cat "$TARGET/file with space.txt")" = "mounted file" ] || return 8
      [ "$(cat "$TARGET/dir with space/nested.txt")" = "mounted nested" ] || return 7
      [ ! -e "$TARGET/dir with space/stale.txt" ] || return 6
      grep -q '^done' "$out" || return 5
      # The bytes came off the mount, not off the wire: the manifest is the
      # only exchange this run makes.
      printf '%s' "$(recob_ops | tr '\n' ',')"
    }
    When call mounted
    The output should equal 'files.grant,'
    The contents of file "$CM_CALLS" should include "check some-other-mac"
    The contents of file "$CM_CALLS" should include "map some-other-mac /remote/file with space.txt"
  End

  It 'treats an item literally named .sizes as an ordinary item'
    mkdir -p "$MOUNT/remote"
    printf 'literal sizes file\n' > "$MOUNT/remote/.sizes"
    mount_helper
    seed_clip file some-other-mac 1752200000.611 pointer /remote/.sizes
    When run "$CLIP" paste --files "$TARGET"
    The status should be success
    The contents of file "$TARGET/.sizes" should equal "literal sizes file"
  End

  It 'uses an existing picker-localized remote row without remapping it'
    export PICK_CLIPBOARD_CACHE_ROOT="$RECOB_DIR/cache/files"
    cached="$PICK_CLIPBOARD_CACHE_ROOT/42/1/cached.txt"
    mkdir -p "$(dirname "$cached")"
    printf 'already local\n' > "$cached"
    mount_helper_down
    # A localized row still carries its capability; that is what distinguishes
    # it from a path that merely looks like a cache entry.
    seed_clip file some-other-mac 1752200000.612 auth "$cached"
    When run "$CLIP" paste --files "$TARGET"
    The status should be success
    The contents of file "$TARGET/cached.txt" should equal "already local"
    The path "$CM_CALLS" should not be exist
  End

  It 'does not trust a cache-shaped remote row without a capability'
    export PICK_CLIPBOARD_CACHE_ROOT="$RECOB_DIR/cache/files"
    cached="$PICK_CLIPBOARD_CACHE_ROOT/43/1/untrusted.txt"
    mkdir -p "$(dirname "$cached")"
    printf 'stale local\n' > "$cached"
    mount_helper_down
    seed_clip file some-other-mac 1752200000.6125 pointer "$cached"
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "mount is unavailable"
    The file "$TARGET/untrusted.txt" should not be exist
    The contents of file "$CM_CALLS" should include "check some-other-mac"
  End

  It 'enforces CLIP_FILE_MAX against the staged copy rather than the mount'
    # Sizes on this path are deliberately taken from the staged copy: the mount
    # can vanish mid-run, and a size read from it afterwards would be a lie.
    # The stub reports a tiny directory the first time (the mount source) and a
    # huge one the second (the staged copy), so only a run that re-measures
    # after staging refuses.
    mkdir -p "$MOUNT/remote/growing-dir"
    printf 'initial\n' > "$MOUNT/remote/growing-dir/a.txt"
    mount_helper
    cat > "$BINDIR/du" <<EOF
#!/bin/sh
n=0
[ -f "$RECOB_DIR/du-count" ] && n=\$(cat "$RECOB_DIR/du-count")
n=\$((n + 1))
printf '%s\n' "\$n" > "$RECOB_DIR/du-count"
if [ "\$n" -le 1 ]; then echo "1 \$2"; else echo "9999 \$2"; fi
EOF
    chmod +x "$BINDIR/du"
    seed_clip directory some-other-mac 1752200000.6135 pointer /remote/growing-dir
    When run env CLIP_FILE_MAX=1500 "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "exceeds size cap"
    The path "$TARGET/growing-dir" should not be exist
  End

  It 'names the cap and the offending item for a mounted cross-machine copy'
    mkdir -p "$MOUNT/remote"
    printf 'small\n' > "$MOUNT/remote/small.txt"
    printf '0123456789012345678901234567890123456789' > "$MOUNT/remote/large.txt"
    mount_helper
    seed_clip files some-other-mac 1752200000.613 pointer /remote/small.txt /remote/large.txt
    When run env CLIP_FILE_MAX=10 "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "exceeds size cap"
    The stderr should include "CLIP_FILE_MAX=10"
    The file "$TARGET/large.txt" should not be exist
  End

  # The sizes on this path can only be known after staging, so the shim ran the
  # re-measure and the cap check over EVERY staged item before placing any of
  # them (`PF_SIZE_LIST`, then a second loop that places). One refusal therefore
  # meant the target was untouched, which is what makes a refusal safe to retry
  # with a higher cap.
  It 'places no item at all when a later one exceeds the cap'
    Pending 'client: with deferred (mount) sizes the cap check is interleaved with placement, so an earlier item lands before the refusal'
    mkdir -p "$MOUNT/remote"
    printf 'small\n' > "$MOUNT/remote/small.txt"
    printf '0123456789012345678901234567890123456789' > "$MOUNT/remote/large.txt"
    mount_helper
    seed_clip files some-other-mac 1752200000.6131 pointer /remote/small.txt /remote/large.txt
    nothing_placed() {
      CLIP_FILE_MAX=10 "$CLIP" paste --files "$TARGET" >/dev/null 2>&1 && return 9
      [ -e "$TARGET/small.txt" ] && return 8
      [ -e "$TARGET/large.txt" ] && return 7
      return 0
    }
    When call nothing_placed
    The status should be success
  End

  It 'fails closed when a mounted source cannot be read'
    mkdir -p "$MOUNT/remote"
    printf 'unreadable\n' > "$MOUNT/remote/unreadable.txt"
    chmod 000 "$MOUNT/remote/unreadable.txt"
    mount_helper
    seed_clip file some-other-mac 1752200000.614 pointer /remote/unreadable.txt
    unreadable() {
      "$CLIP" paste --files "$TARGET"
      rc=$?
      chmod 600 "$MOUNT/remote/unreadable.txt"
      return "$rc"
    }
    When call unreadable
    The status should be failure
    The stderr should not equal ''
    The file "$TARGET/unreadable.txt" should not be exist
  End

  It 'does not follow a top-level symlink from the peer mount'
    mkdir -p "$MOUNT/remote"
    printf 'local target\n' > "$RECOB_DIR/local-target.txt"
    ln -s "$RECOB_DIR/local-target.txt" "$MOUNT/remote/link.txt"
    mount_helper
    seed_clip file some-other-mac 1752200000.6141 pointer /remote/link.txt
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "could not determine source size"
    The file "$TARGET/link.txt" should not be exist
  End

  It 'rejects a partial directory size when du exits nonzero'
    mkdir -p "$MOUNT/remote/partial-dir"
    printf 'partial\n' > "$MOUNT/remote/partial-dir/a.txt"
    mount_helper
    printf '#!/bin/sh\necho "123 partial"\nexit 1\n' > "$BINDIR/du"
    chmod +x "$BINDIR/du"
    seed_clip directory some-other-mac 1752200000.6145 pointer /remote/partial-dir
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "could not determine source size"
    The path "$TARGET/partial-dir" should not be exist
  End

  It 'fails closed when a remote mount path cannot be mapped'
    mkdir -p "$MOUNT"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check) printf '%s\n' "$MOUNT"; exit 0 ;;
  map) exit 1 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    seed_clip file some-other-mac 1752200000.615 pointer /remote/unsafe.txt
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "cannot map remote clipboard path"
    The file "$TARGET/unsafe.txt" should not be exist
  End

  It 'fails closed when the mount dies after the health check'
    # The helper answers `check` and `map`, but nothing is actually mounted, so
    # the mapped paths do not exist. The old shim re-checked the mount's health
    # and reported the picker fallback; the compiled engine reports the missing
    # source instead. Either way nothing may land in the target.
    mkdir -p "$MOUNT"
    mount_helper
    seed_clip file some-other-mac 1752200000.616 pointer /remote/vanished.txt
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "source no longer exists"
    The file "$TARGET/vanished.txt" should not be exist
  End
End

# Interrupt safety: killing a `--files` run mid-copy must never leave a partial
# entry in the target, and the staging dir an untrappable SIGKILL leaves behind
# must be swept by the next invocation.
#
# APFS clonefile is near-instant regardless of size — copying even a many-GB
# file inside ONE container completes in milliseconds, which would make "kill
# mid-copy" untestable by timing. So the source goes on its own APFS container
# (a throwaway sparse image): per `man cp`, `-c` degrades to a real copy across
# containers — still tier 1 code, but no longer instant — without faking any
# binary.
Describe 'paste --files interrupt safety'
  Include tests/recob_helper.sh

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    recob_start
    seed_reset
    export CLIP="$(recob_client_bin)"
    export TARGET="$RECOB_DIR/target"; mkdir -p "$TARGET"
    # The item under test is deliberately larger than the 200 MB default cap —
    # a copy has to be big enough to still be running 0.2 s in. What is under
    # test here is the interruption, not the cap, so the cap is lifted.
    export CLIP_FILE_MAX=17179869184

    DMG="$RECOB_DIR/xvol.sparseimage"
    hdiutil create -size 5g -fs APFS -volname PbpasteFilesTest -type SPARSE "$DMG" >/dev/null
    ATTACH_OUT=$(hdiutil attach "$DMG" -nobrowse)
    MNT=$(printf '%s\n' "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
    export MNT
    # A genuinely dense, cross-container source, so tier 1's degraded copy has
    # real bytes to move.
    dd if=/dev/zero of="$MNT/big.bin" bs=4m count=1024 >/dev/null 2>&1
    seed_clip file "$RECOB_SELF_NAME" 1752200000.7 auth "$MNT/big.bin"
  }
  BeforeEach 'setup'

  cleanup() {
    [ -n "${MNT:-}" ] && hdiutil detach "$MNT" -force >/dev/null 2>&1
    recob_stop
  }
  AfterEach 'cleanup'

  It 'leaves no partial entry in the target when killed mid-copy, and sweeps staging on the next run'
    killed_mid_copy() {
      "$CLIP" paste --files "$TARGET" >/dev/null 2>&1 &
      pid=$!
      sleep 0.2
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      # Nothing half-copied is ever visible under the item's own name: the
      # copy happens in the staging dir and only a rename publishes it.
      [ -e "$TARGET/big.bin" ] && return 9
      "$CLIP" paste --files "$TARGET" >/dev/null 2>&1 || return 1
      has_staging "$TARGET" && return 8
      [ -e "$TARGET/big.bin" ] || return 7
      cmp -s "$TARGET/big.bin" "$MNT/big.bin" || return 6
      return 0
    }
    When call killed_mid_copy
    The status should be success
  End
End

# Forced-replacement crash recovery. `--force` replaces an existing destination
# by renaming it ASIDE (destination -> recovery dir, with a sidecar naming where
# it came from) and only THEN renaming the staged replacement into place. A kill
# landing BETWEEN those two renames leaves the destination momentarily absent
# with the only copy of the original in the recovery dir — so that dir must be
# somewhere a later run RESTORES from rather than blindly deletes.
#
# The old probes forced that window with a fake `mv` on PATH. The engine renames
# in-process now (`std::fs::rename`), so the window is no longer reachable from
# outside; what IS reachable — and is the part that protects the user's data —
# is the state such a crash leaves on disk and what the next run does with it.
# Each example below builds that state under a pid that is certainly dead and
# runs the real client over it. The in-process halves (recover_dir, the landed
# replacement, the live-pid guard) are covered by paste_files.rs's own tests.
Describe 'paste --files forced-replacement crash recovery'
  Include tests/recob_helper.sh

  # A pid high enough to be unallocated, matching the engine's own test.
  DEAD_PID=999999

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    recob_start
    seed_reset
    export CLIP="$(recob_client_bin)"
    export SRC="$RECOB_DIR/src"; mkdir -p "$SRC"
    export TARGET="$RECOB_DIR/target"; mkdir -p "$TARGET"
    printf 'NEWCONTENT\n' > "$SRC/keep.txt"
    seed_clip file "$RECOB_SELF_NAME" 1752400000.1 auth "$SRC/keep.txt"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # The on-disk state a run killed between the two renames leaves: the original
  # displaced into a recovery dir, with the sidecar naming the destination it
  # was displaced from.
  displaced() {
    rec="$TARGET/.pbpaste-recovery.$DEAD_PID"
    mkdir -p "$rec"
    printf 'ORIGINAL\n' > "$rec/bak.1"
    printf '%s' "$TARGET/keep.txt" > "$rec/final.1"
  }

  It 'restores the displaced original left by a killed run before doing anything else'
    displaced
    recovered() {
      # The destination is absent — the replacement never landed. The sweep
      # restores it, and this run then refuses the conflict it just restored,
      # which is exactly the "your file is still there" outcome.
      "$CLIP" paste --files "$TARGET" >/dev/null 2>&1
      [ -e "$TARGET/keep.txt" ] || return 7
      [ "$(cat "$TARGET/keep.txt")" = "ORIGINAL" ] || return 6
      has_recovery "$TARGET" && return 5
      has_staging "$TARGET" && return 4
      return 0
    }
    When call recovered
    The status should be success
  End

  It 'never restores a displaced original over a replacement that landed'
    printf 'REPLACEMENT\n' > "$TARGET/keep.txt"
    displaced
    not_clobbered() {
      "$CLIP" paste --files "$TARGET" >/dev/null 2>&1
      [ "$(cat "$TARGET/keep.txt")" = "REPLACEMENT" ] || return 6
      has_recovery "$TARGET" && return 5
      return 0
    }
    When call not_clobbered
    The status should be success
  End

  It 'sweeps a dead run''s staging dir and spares a live one''s'
    mkdir -p "$TARGET/.pbpaste-staging.$DEAD_PID" "$TARGET/.pbpaste-staging.$$"
    swept() {
      "$CLIP" paste --files "$TARGET" >/dev/null 2>&1 || return 1
      [ -d "$TARGET/.pbpaste-staging.$DEAD_PID" ] && return 9
      # A genuinely concurrent run's directories belong to it: the sweep is
      # pid-gated, never a blind wildcard.
      [ -d "$TARGET/.pbpaste-staging.$$" ] || return 8
      return 0
    }
    When call swept
    The status should be success
  End

  It 'leaves no recovery or staging residue when a forced replacement succeeds'
    printf 'ORIGINAL\n' > "$TARGET/keep.txt"
    clean_force() {
      "$CLIP" paste --files --force "$TARGET" >/dev/null || return 1
      [ "$(cat "$TARGET/keep.txt")" = "NEWCONTENT" ] || return 6
      has_recovery "$TARGET" && return 5
      has_staging "$TARGET" && return 4
      return 0
    }
    When call clean_force
    The status should be success
  End
End

# The REMOTE engine: manifest host != this host and this shell IS over SSH, so
# every item streams over `files.fetch` from the endpoint that answered the
# manifest. The daemon serves those streams from real paths, so the bytes that
# land in the target came through the wire.
Describe 'paste --files (remote engine)'
  Include tests/recob_helper.sh

  setup() {
    export SSH_CONNECTION="x 1 y 22"
    unset SSH_CLIENT SSH_TTY
    recob_start
    seed_reset
    export CLIP="$(recob_client_bin)"
    export ORIGIN="$RECOB_DIR/origin"; mkdir -p "$ORIGIN"
    export TARGET="$RECOB_DIR/target"; mkdir -p "$TARGET"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  It 'refuses a remote pointer-only manifest instead of falling back to raw paths'
    printf 'not authorized\n' > "$ORIGIN/not-authorized.txt"
    seed_clip file mac-mini 1752300000.0 pointer "$ORIGIN/not-authorized.txt"
    pointer_only() {
      "$CLIP" paste --files "$TARGET" 2>"$RECOB_DIR/err"
      rc=$?
      grep -q 'did not authorize' "$RECOB_DIR/err" || return 9
      [ "$rc" -ne 0 ] || return 8
      # Refused before any transfer: the manifest is the only exchange.
      printf '%s' "$(recob_ops | tr '\n' ',')"
    }
    When call pointer_only
    The output should equal 'files.grant,'
    The file "$TARGET/not-authorized.txt" should not be exist
  End

  It 'materializes a regular file over files.fetch, byte-identical to the source'
    printf 'hello from the remote Mac\n' > "$ORIGIN/a.txt"
    seed_clip file mac-mini 1752300000.1 auth "$ORIGIN/a.txt"
    When run "$CLIP" paste --files "$TARGET"
    The status should be success
    The contents of file "$TARGET/a.txt" should equal "hello from the remote Mac"
  End

  It 'spends the manifest capability by index and never names the path on the wire'
    printf 'port check\n' > "$ORIGIN/b.txt"
    seed_clip file mac-mini 1752300000.2 auth "$ORIGIN/b.txt"
    fetch_shape() {
      "$CLIP" paste --files "$TARGET" >/dev/null || return 1
      printf '%s|%s|%s|%s|%s' \
        "$(recob_op 1)" "$(recob_op 2)" "$(recob_endpoint 2)" \
        "$(recob_field 2 index)" \
        "$(recob_raw | grep -c "$ORIGIN/b.txt")"
    }
    When call fetch_shape
    # The trailing 0 is the count of times the origin's path appears anywhere
    # in the recorded stream: an item is named by INDEX into the grant, so a
    # peer never learns the origin's layout from a fetch. (The token is
    # asserted by value in the next example.)
    The output should equal 'files.grant|files.fetch|public|1|0'
  End

  It 'spends the very capability the origin minted for this manifest'
    # Read back from the daemon's own store rather than from the reply: the
    # recorder logs REQUESTS, so the token the grant answered with is only
    # observable where the daemon put it.
    printf 'token check\n' > "$ORIGIN/c.txt"
    seed_clip file mac-mini 1752300000.21 auth "$ORIGIN/c.txt"
    token_match() {
      "$CLIP" paste --files "$TARGET" >/dev/null || return 1
      minted=$(sqlite3 "$SEED_DB" "SELECT token FROM file_grants LIMIT 1;")
      [ ${#minted} -eq 64 ] || return 2
      [ "$(recob_field 2 token)" = "$minted" ] && printf 'spent-the-minted-grant'
    }
    When call token_match
    The output should equal 'spent-the-minted-grant'
  End

  It 'refuses to overwrite an existing target name without --force, before any transfer'
    printf 'old\n' > "$TARGET/dup.txt"
    printf 'new\n' > "$ORIGIN/dup.txt"
    seed_clip file mac-mini 1752300000.3 auth "$ORIGIN/dup.txt"
    conflict_first() {
      "$CLIP" paste --files "$TARGET" 2>/dev/null && return 9
      printf '%s' "$(recob_ops | tr '\n' ',')"
    }
    When call conflict_first
    The output should equal 'files.grant,'
    The contents of file "$TARGET/dup.txt" should equal "old"
  End

  It 'extracts a directory from the kind-declared stream in a single fetch'
    # §6.2: the head declares `kind`, so the `is-directory` error — and the
    # second connection its retry cost — are gone.
    mkdir -p "$ORIGIN/adir/nested"
    printf 'top level\n' > "$ORIGIN/adir/top.txt"
    printf 'nested content\n' > "$ORIGIN/adir/nested/deep.txt"
    seed_clip directory mac-mini 1752300000.4 auth "$ORIGIN/adir"
    remote_dir() {
      "$CLIP" paste --files "$TARGET" >/dev/null || return 1
      diff -r "$ORIGIN/adir" "$TARGET/adir" >/dev/null || return 2
      printf '%s' "$(recob_ops | tr '\n' ',')"
    }
    When call remote_dir
    The output should equal 'files.grant,files.fetch,'
  End

  It 'fails an item whose stream ends without §6.4''s terminator, leaving nothing behind'
    # The recorder's `close` hangs up mid-frame. Before §6.4 the only truncation
    # signal was tar's own opinion of what it received; now the missing empty
    # `D` fails the item by protocol.
    recob_script \
      "ok kind=$(seed_hex file) host=$(seed_hex mac-mini) timestamp=$(seed_hex 1752300000.5) token=$(seed_hex "$SEED_FAKE_TOKEN") paths=$(seed_paths_hex /remote/trunc.txt)" \
      'close'
    truncated() {
      "$CLIP" paste --files "$TARGET" 2>/dev/null
      rc=$?
      [ "$rc" -ne 0 ] || return 9
      [ -e "$TARGET/trunc.txt" ] && return 8
      has_staging "$TARGET" && return 7
      return 0
    }
    When call truncated
    The status should be success
  End

  It 'places nothing at all when a later item truncates'
    # A change from the shim, and a strengthening: items are staged whole and
    # only then published, so a failure anywhere means the target is untouched
    # rather than half-populated.
    printf 'first item, completes fine\n' > "$RECOB_DIR/okbody"
    recob_script \
      "ok kind=$(seed_hex files) host=$(seed_hex mac-mini) timestamp=$(seed_hex 1752300000.9) token=$(seed_hex "$SEED_FAKE_TOKEN") paths=$(seed_paths_hex /remote/ok.txt /remote/trunc.txt)" \
      "stream $RECOB_DIR/okbody" \
      'close'
    partial() {
      "$CLIP" paste --files "$TARGET" 2>/dev/null
      [ $? -ne 0 ] || return 9
      [ -e "$TARGET/trunc.txt" ] && return 8
      [ -e "$TARGET/ok.txt" ] && return 7
      has_staging "$TARGET" && return 6
      return 0
    }
    When call partial
    The status should be success
  End

  It 'porcelain: every line has exactly 4 tab fields and the stream ends with a done line'
    # Unlike the local engine's instant tiers, an in-flight remote item's
    # progress lines are NOT required to have done==total — only that the last
    # one names the destination it is reporting on.
    printf 'porcelain payload contents\n' > "$ORIGIN/p.txt"
    seed_clip file mac-mini 1752300000.6 auth "$ORIGIN/p.txt"
    porcelain() {
      out="$RECOB_DIR/porcelain.out"
      "$CLIP" paste --files --porcelain "$TARGET" > "$out" || return 1
      awk -F'\t' '{ if (NF != 4) exit 9 }' "$out" || return 9
      case "$(tail -n 1 "$out")" in
        done*) : ;;
        *) return 8 ;;
      esac
      final=$(awk -F'\t' '$1 == "progress" { line = $0 } END { print line }' "$out")
      case "$final" in
        *"$TARGET/p.txt"*) : ;;
        *) return 7 ;;
      esac
      return 0
    }
    When call porcelain
    The status should be success
  End

  # §11's per-item cap, remote file engine: the declared total comes from the
  # `R` head, before a single body byte is pulled. Only the non-interactive
  # refusal branch is reachable here — see the local Describe's note.
  It 'refuses an over-cap streamed file with the exact line the yazi plugin parses'
    printf '0123456789012345678901234567890123456789' > "$ORIGIN/toobig.txt"
    seed_clip file mac-mini 1752300000.7 auth "$ORIGIN/toobig.txt"
    When run env CLIP_FILE_MAX=10 "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should equal "pbpaste: $TARGET/toobig.txt exceeds size cap (CLIP_FILE_MAX=10 bytes, item is 40 bytes) -- refusing (no interactive confirm available; set CLIP_FILE_MAX=40 or higher to allow)"
    The file "$TARGET/toobig.txt" should not be exist
  End

  It 'refuses an over-cap streamed directory before extracting anything'
    # The directory's declared total is the origin's own `du -sk` estimate, so
    # the byte count is asserted by shape rather than by value.
    mkdir -p "$ORIGIN/toobigdir"
    printf 'small\n' > "$ORIGIN/toobigdir/small.txt"
    seed_clip directory mac-mini 1752300000.8 auth "$ORIGIN/toobigdir"
    When run env CLIP_FILE_MAX=10 "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "pbpaste: $TARGET/toobigdir exceeds size cap (CLIP_FILE_MAX=10 bytes, item is "
    The stderr should include "-- refusing (no interactive confirm available"
    The path "$TARGET/toobigdir" should not be exist
  End

  It 'reports the code the origin answered with when the clip is not a files clip'
    seed_text_clip
    When run "$CLIP" paste --files "$TARGET"
    The status should be failure
    The stderr should include "not a files clip"
  End

  It 'fails loudly when the reverse tunnel is down'
    tunnel_down() { recob_stop; "$CLIP" paste --files "$TARGET"; }
    When call tunnel_down
    The status should be failure
    The stderr should include "reverse SSH tunnel down"
  End
End

# Plain `paste` on a host with no local clipboard tool: the store IS the
# clipboard there, reached over the trusted socket. (The Darwin tool is stubbed
# away rather than removed, so the example runs the same on either platform.)
Describe 'paste text: the store fallback'
  Include tests/recob_helper.sh

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    recob_start
    export CLIP="$(recob_client_bin)"
    # A restricted PATH so a brew-installed wl-paste/xclip cannot win the
    # availability probes, and no Darwin tool at all.
    export PATH="$RECOB_DIR/stubs:/usr/bin:/bin"
    export PBPASTE_DARWIN_BIN=/nonexistent
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  It 'asks the bridge for the clip text when no local clipboard tool exists'
    recob_script "ok text=$(seed_hex hi)"
    store_text() {
      "$CLIP" paste || return 1
      printf '|%s|%s' "$(recob_op 1)" "$(recob_endpoint 1)"
    }
    When call store_text
    The output should equal 'hi|clip.get|trusted'
  End

  It 'distinguishes a reachable bridge answering with an error from an unreachable one'
    recob_script 'err internal store down'
    When run "$CLIP" paste
    The status should equal 1
    The stderr should include "internal"
    The stderr should include "store down"
    The stderr should not include "not reachable"
  End

  It 'keeps the not-reachable message when nothing is listening'
    down() { recob_stop; "$CLIP" paste; }
    When call down
    The status should equal 1
    The stderr should include "trusted clipboard bridge is not reachable"
  End
End

# THREE OF THE SHIM'S DESCRIBES HAVE NO EQUIVALENT HERE, deliberately:
#
#   * `pbpaste_cap_theme` — the size-cap dialog's palette. It was reachable by
#     sourcing the shim with PBPASTE_TEST_SOURCE_ONLY=1; a compiled client has
#     no such seam, and the function it became is only called from inside the
#     gum dialog, which needs a controlling terminal this harness does not
#     have. `paste_files.rs` unit-tests the extractor, but NOT the resolution
#     ORDER (THEME_PALETTE_JSON → the effective cache copy → the config copy)
#     that the C2 fix put there — that gap belongs in a Rust unit test over
#     `palette_json()`, and is reported with this conversion rather than
#     silently dropped.
#   * "never captures dd stderr for byte counting" — it grepped the shim's own
#     source for a `dd` invocation. There is no `dd`, and the byte counter is
#     the stream sink's own accumulator.
#   * "fails closed with an upgrade hint when the origin does not support K" —
#     the client has no version-skew diagnostic to test: `Session::supports()`
#     exists and no client calls it, so §8 rule 7 is unimplemented rather than
#     untested. Reported, not asserted, because an example here could only pin
#     the absence.
