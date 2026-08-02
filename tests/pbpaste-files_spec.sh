# Tests for pbpaste's file-manifest mode (files-yazi design §5, spec
# docs/superpowers/specs/2026-07-11-clipboard-phase6-files-yazi-design.md):
# `pbpaste --manifest` prints the current clipboard entry's file manifest
# (bridge op `L`, T2) instead of the clipboard text. Bridge calls are stubbed
# by a fake `nc` on PATH that logs "<port>:<frame-with-NUL-as-|>" (same
# convention as pbcopy-files_spec.sh) and replies with a canned frame built
# from $REPLY_FRAME, a file this spec constructs per example.
Describe 'pbpaste: --manifest'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbpaste"

  # build_frame <status> <payload> <outfile> -- writes a wire-exact
  # <status><BE32 len><payload> frame. $payload may contain embedded NULs
  # (path separators): it MUST be passed via a file, not a shell scalar
  # (command substitution truncates at the first NUL), so callers write the
  # payload to a temp file first and pass that path here instead.
  build_frame() {
    st=$1 payload_file=$2 outfile=$3
    len=$(wc -c < "$payload_file" | tr -d ' ')
    {
      printf '%s' "$st"
      printf "\\$(printf %03o $(((len>>24)&255)))\\$(printf %03o $(((len>>16)&255)))\\$(printf %03o $(((len>>8)&255)))\\$(printf %03o $((len&255)))"
      cat "$payload_file"
    } > "$outfile"
  }

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    rm -f "$BINDIR/du" "$BINDIR/wc"
    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
    rm -f "$SHELLSPEC_TMPBASE/cm-calls" "$SHELLSPEC_TMPBASE/check-count"
    REPLY_FRAME="$SHELLSPEC_TMPBASE/reply.frame"
    export REPLY_FRAME
    # Fake nc: capture the raw framed request to a side file (a shell
    # variable would truncate at NUL, irrelevant here since the L request
    # payload is empty, but kept byte-safe for consistency with
    # pbcopy-files_spec.sh), log "<port>:<frame with NUL -> '|'>", then reply
    # with whatever is currently at $REPLY_FRAME. Grabs the port as the LAST
    # positional arg so it doesn't care whether the caller wrote `-w 2` or
    # `-w2` before the host/port.
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
argc=\$#
eval "port=\\\${\$argc}"
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
cat "$REPLY_FRAME"
EOF
    chmod +x "$BINDIR/nc"
    export PATH="$BINDIR:$PATH"
  }
  BeforeEach 'setup'

  It 'prints kind/host/ts/path lines and exits 0 for a single-file clip'
    pf="$SHELLSPEC_TMPBASE/payload"
    printf 'file\037mac-mini\0371752200000.123456\037/tmp/a.txt' > "$pf"
    build_frame O "$pf" "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be success
    The line 1 of output should equal "$(printf 'kind\tfile')"
    The line 2 of output should equal "$(printf 'host\tmac-mini')"
    The line 3 of output should equal "$(printf 'ts\t1752200000.123456')"
    The line 4 of output should equal "$(printf 'path\t/tmp/a.txt')"
    The lines of output should equal 4
  End

  It 'prints one path line per path for a multi-file clip, paths with spaces'
    pf="$SHELLSPEC_TMPBASE/payload"
    printf 'files\037mac-mini\0371752200000.5\037/tmp/a b.txt\000/tmp/c.txt' > "$pf"
    build_frame O "$pf" "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be success
    The line 1 of output should equal "$(printf 'kind\tfiles')"
    The line 4 of output should equal "$(printf 'path\t/tmp/a b.txt')"
    The line 5 of output should equal "$(printf 'path\t/tmp/c.txt')"
    The lines of output should equal 5
  End

  It 'preserves the row type_kind verbatim (directory)'
    pf="$SHELLSPEC_TMPBASE/payload"
    printf 'directory\037mac-mini\0371752200000.9\037/tmp/adir' > "$pf"
    build_frame O "$pf" "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be success
    The line 1 of output should equal "$(printf 'kind\tdirectory')"
  End

  It 'sends the L frame to :2489 locally'
    pf="$SHELLSPEC_TMPBASE/payload"
    printf 'file\037mac-mini\0371752200000.1\037/tmp/a.txt' > "$pf"
    build_frame O "$pf" "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be success
    The line 1 of output should equal "$(printf 'kind\tfile')"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2489:L"
  End

  It 'sends the L frame to the default :2490 over SSH'
    export SSH_CONNECTION="x 1 y 22"
    pf="$SHELLSPEC_TMPBASE/payload"
    printf 'file\037mac-mini\0371752200000.1\037/tmp/a.txt' > "$pf"
    build_frame O "$pf" "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be success
    The line 1 of output should equal "$(printf 'kind\tfile')"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:L"
  End

  It 'honors CLIPBOARD_BRIDGE_PORT over SSH'
    export SSH_CONNECTION="x 1 y 22"
    export CLIPBOARD_BRIDGE_PORT=9999
    pf="$SHELLSPEC_TMPBASE/payload"
    printf 'file\037mac-mini\0371752200000.1\037/tmp/a.txt' > "$pf"
    build_frame O "$pf" "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be success
    The line 1 of output should equal "$(printf 'kind\tfile')"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "9999:L"
  End

  It 'exits 1 with nothing on stdout and a reason on stderr for a non-files clip'
    pf="$SHELLSPEC_TMPBASE/payload"
    printf 'not-files' > "$pf"
    build_frame E "$pf" "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be failure
    The stderr should include "not-files"
    The output should equal ""
  End

  It 'exits 1 with nothing on stdout and a reason on stderr for an empty store'
    pf="$SHELLSPEC_TMPBASE/payload"
    printf 'empty-store' > "$pf"
    build_frame E "$pf" "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be failure
    The stderr should include "empty-store"
    The output should equal ""
  End

  It 'exits 1 with nothing on stdout when the bridge is unreachable'
    cat > "$BINDIR/nc" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$BINDIR/nc"
    When run command sh "$SCRIPT" --manifest
    The status should be failure
    The output should equal ""
    The stderr should include "bridge"
  End

  It 'rejects a truncated O frame instead of reporting an empty manifest success'
    printf 'O' > "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be failure
    The output should equal ""
    The stderr should include "truncated frame"
  End

  It 'rejects a frame whose declared payload is longer than the bytes received'
    printf 'O\000\000\000\012short' > "$REPLY_FRAME"
    When run command sh "$SCRIPT" --manifest
    The status should be failure
    The output should equal ""
    The stderr should include "malformed frame"
  End

  It 'documents every supported file-materialization route'
    When run command sh "$SCRIPT" --help
    The status should be success
    The output should include "SSH clients stream authorized files"
    The output should include "healthy peer mount"
    The output should not include "later milestone"
  End

  It 'never touches the bridge and stays byte-identical for a plain paste (no flags)'
    sentinel="pbpaste-manifest-untouched-sentinel-$$"
    printf '%s' "$sentinel" | /usr/bin/pbcopy
    When run command sh "$SCRIPT"
    The status should be success
    The output should equal "$sentinel"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should equal ""
  End
End

# Tests for pbpaste's local file-materialization engine (files-yazi design
# §5/§8, T5): `pbpaste --files [--force] [--quiet|--progress|--porcelain]
# [dir]`. Same fake-`nc`-with-a-canned-`L`-reply convention as the
# `--manifest` Describe above, but every manifest here points at REAL temp
# files/dirs on disk (this Describe's own SRC), since the whole point is to
# exercise the actual copy engine and assert on real bytes landing in TARGET.
Describe 'pbpaste: --files (local materialization)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbpaste"
  TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

  # build_frame <status> <payload_file> <outfile> -- same wire-exact
  # <status><BE32 len><payload> framing helper as the --manifest Describe
  # above (each files-yazi spec file keeps its own copy -- see
  # pbcopy-files_spec.sh for the convention).
  build_frame() {
    st=$1 payload_file=$2 outfile=$3
    len=$(wc -c < "$payload_file" | tr -d ' ')
    {
      printf '%s' "$st"
      printf "\\$(printf %03o $(((len>>24)&255)))\\$(printf %03o $(((len>>16)&255)))\\$(printf %03o $(((len>>8)&255)))\\$(printf %03o $((len&255)))"
      cat "$payload_file"
    } > "$outfile"
  }

  # build_manifest <outfile> <kind> <host> <ts> <path>... -- writes the raw
  # `K`-reply payload manifest_parse expects: kind US host US ts US "-" US path NUL
  # path NUL path ...
  build_manifest() {
    outfile=$1 kind=$2 host=$3 ts=$4
    shift 4
    {
      printf '%s\037%s\037%s\037%s\037' "$kind" "$host" "$ts" "$TOKEN"
      first=1
      for p in "$@"; do
        if [ "$first" -eq 1 ]; then
          printf '%s' "$p"
          first=0
        else
          printf '\000%s' "$p"
        fi
      done
    } > "$outfile"
  }

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    rm -f "$BINDIR/du" "$BINDIR/wc"
    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
    rm -f "$SHELLSPEC_TMPBASE/cm-calls" "$SHELLSPEC_TMPBASE/check-count" "$SHELLSPEC_TMPBASE/du-count"
    REPLY_FRAME="$SHELLSPEC_TMPBASE/reply.frame"
    export REPLY_FRAME
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
argc=\$#
eval "port=\\\${\$argc}"
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
cat "$REPLY_FRAME"
EOF
    chmod +x "$BINDIR/nc"
    # Fake scutil: pins THIS host's name for the local/remote manifest-host
    # comparison (pbpaste_files uses the same `scutil --get LocalHostName`
    # || `hostname -s` fallback as pbcopy), so the suite never depends on
    # the real machine's name.
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
    # Hermetic self_host() resolution (R-batch Task B): PF_HOST now prefers
    # $XDG_STATE_HOME/clipboard/self-name over the fake scutil above, so pin
    # a fresh sandbox with no such file -- otherwise a real self-name file on
    # the machine running this suite would override the pinned "mac-mini".
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/xdg-state-local"

    SRC="$SHELLSPEC_TMPBASE/src"; mkdir -p "$SRC"
    TARGET="$SHELLSPEC_TMPBASE/target"; mkdir -p "$TARGET"
  }
  BeforeEach 'setup'

  It 'materializes a file and a directory into the target dir, contents identical to the source'
    printf 'hello world\n' > "$SRC/a.txt"
    mkdir -p "$SRC/adir/nested"
    printf 'nested content\n' > "$SRC/adir/nested/b.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" files mac-mini 1752200000.1 "$SRC/a.txt" "$SRC/adir"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh -c '
      sh "$1" --files "$2" >/dev/null 2>"$3" || exit 1
      diff -r "$4/a.txt" "$2/a.txt" || exit 2
      diff -r "$4/adir" "$2/adir" || exit 3
    ' _ "$SCRIPT" "$TARGET" "$SHELLSPEC_TMPBASE/err" "$SRC"
    The status should be success
  End

  It 'refuses a local self-host manifest that has no authority token'
    TOKEN=-
    printf 'untrusted local\n' > "$SRC/untrusted-local.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752200000.11 "$SRC/untrusted-local.txt"
    build_frame O "$pf" "$REPLY_FRAME"
    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "did not authorize"
    The file "$TARGET/untrusted-local.txt" should not be exist
  End

  It 'preserves a literal US byte in a path instead of splitting a new item'
    When run command sh -c '
      us=$(printf "\037")
      name="unit${us}separator.txt"
      src="$3/$name"
      printf "control-byte path\n" > "$src"
      payload="$4/us-payload"
      printf "file\037mac-mini\0371752200000.15\037%s\037%s" "$6" "$src" > "$payload"
      len=$(wc -c < "$payload" | tr -d " ")
      {
        printf O
        printf "\\$(printf %03o $(((len>>24)&255)))\\$(printf %03o $(((len>>16)&255)))\\$(printf %03o $(((len>>8)&255)))\\$(printf %03o $((len&255)))"
        cat "$payload"
      } > "$5"
      sh "$1" --files "$2" >/dev/null &&
      cmp "$src" "$2/$name"
    ' _ "$SCRIPT" "$TARGET" "$SRC" "$SHELLSPEC_TMPBASE" "$REPLY_FRAME" "$TOKEN"
    The status should be success
  End

  It 'refuses to overwrite an existing name and lists it on stderr'
    printf 'new\n' > "$SRC/dup.txt"
    printf 'old\n' > "$TARGET/dup.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752200000.2 "$SRC/dup.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "dup.txt"
    The contents of file "$TARGET/dup.txt" should equal "old"
  End

  It '--force overwrites the conflicting target'
    printf 'new\n' > "$SRC/dup2.txt"
    printf 'old\n' > "$TARGET/dup2.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752200000.3 "$SRC/dup2.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files --force "$TARGET"
    The status should be success
    The contents of file "$TARGET/dup2.txt" should equal "new"
  End

  # --force over a DIRECTORY must replace it wholesale via rename-aside
  # (old tree renamed into staging, new tree renamed into place -- both
  # atomic), never delete-then-move: `rm -rf` of a directory target is a
  # recursive non-atomic delete, and a kill inside it would leave a
  # half-shredded old tree in the destination. Assert full replacement
  # (stale entry gone, new tree identical) and no staging residue.
  It '--force replaces an existing directory target wholesale, leaving no staging dir'
    mkdir -p "$SRC/rdir/sub"
    printf 'new\n' > "$SRC/rdir/sub/new.txt"
    mkdir -p "$TARGET/rdir"
    printf 'old\n' > "$TARGET/rdir/stale.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" directory mac-mini 1752200000.37 "$SRC/rdir"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh -c '
      sh "$1" --files --force "$2" || exit 1
      [ ! -e "$2/rdir/stale.txt" ] || exit 9
      diff -r "$3/rdir" "$2/rdir" || exit 8
      if ls -d "$2"/.pbpaste-staging.* >/dev/null 2>&1; then exit 7; fi
      exit 0
    ' _ "$SCRIPT" "$TARGET" "$SRC"
    The status should be success
  End

  # Two manifest entries sharing one basename (multi-dir selection) cannot
  # both land in one flat target dir -- the second would silently clobber
  # the first, so this is refused even with --force (which only waives
  # PRE-EXISTING targets, not intra-clip collisions).
  It 'refuses a clip whose entries share a basename, even with --force'
    mkdir -p "$SRC/d1" "$SRC/d2"
    printf 'first\n' > "$SRC/d1/same.txt"
    printf 'second\n' > "$SRC/d2/same.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" files mac-mini 1752200000.35 "$SRC/d1/same.txt" "$SRC/d2/same.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files --force "$TARGET"
    The status should be failure
    The stderr should include "same.txt"
    The file "$TARGET/same.txt" should not be exist
  End

  # Porcelain is a CONTRACT (design §8): every line must be exactly 4
  # tab-separated fields, every progress line's done/total bytes must be
  # equal (these tiers are instant), and the stream must end with a `done`
  # line. Asserted with awk, not string-matching, per the task brief.
  It 'porcelain: every line has exactly 4 tab fields, progress done==total, ends with a done line'
    printf 'abc\n' > "$SRC/p1.txt"
    printf 'defgh\n' > "$SRC/p2.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" files mac-mini 1752200000.4 "$SRC/p1.txt" "$SRC/p2.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh -c '
      sh "$1" --files --porcelain "$2" > "$3" || exit 1
      awk -F"\t" "{ if (NF != 4) exit 9 }" "$3" || exit 9
      awk -F"\t" "\$1 == \"progress\" && \$3 != \$4 { exit 6 }" "$3" || exit 6
      last=$(tail -n 1 "$3")
      case "$last" in
        done*) : ;;
        *) exit 8 ;;
      esac
      sed "\$d" "$3" | awk -F"\t" "\$1 != \"progress\" { exit 7 }" || exit 7
    ' _ "$SCRIPT" "$TARGET" "$SHELLSPEC_TMPBASE/porcelain.out"
    The status should be success
  End

  It 'prints nothing to stdout by default when not attached to a TTY'
    printf 'quiet content\n' > "$SRC/q.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752200000.5 "$SRC/q.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be success
    The output should equal ""
  End

  It 'reports the picker fallback when a remote manifest mount is unavailable'
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.6 "/remote/missing.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "mount is unavailable"
    The stderr should include "pick-clipboard Ctrl-Y"
  End

  It 'materializes Yazi-style --porcelain remote paste through a healthy peer mount'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT/remote/dir with space"
    printf 'mounted file\n' > "$MOUNT/remote/file with space.txt"
    printf 'mounted nested\n' > "$MOUNT/remote/dir with space/nested.txt"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
echo "\$*" >> "$SHELLSPEC_TMPBASE/cm-calls"
case "\$1" in
  check) [ "\$2" = some-other-mac ] && { printf '%s\\n' "$MOUNT"; exit 0; } ;;
  map)   [ "\$2" = some-other-mac ] && { printf '%s%s\\n' "$MOUNT" "\$3"; exit 0; } ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" files some-other-mac 1752200000.61 \
      "/remote/file with space.txt" "/remote/dir with space"
    build_frame O "$pf" "$REPLY_FRAME"
    printf 'old file\n' > "$TARGET/file with space.txt"
    mkdir -p "$TARGET/dir with space"
    printf 'stale\n' > "$TARGET/dir with space/stale.txt"

    When run command sh -c '
      sh "$1" --files --force --porcelain "$2" >"$3" || exit 9
      [ "$(cat "$2/file with space.txt")" = "mounted file" ] || exit 8
      [ "$(cat "$2/dir with space/nested.txt")" = "mounted nested" ] || exit 7
      [ ! -e "$2/dir with space/stale.txt" ] || exit 6
      grep -q "^done" "$3" || exit 5
      lines=$(wc -l < "$5" | tr -d " ")
      [ "$lines" -eq 1 ] || { echo "nclog lines=$lines" >&2; exit 4; }
    ' _ "$SCRIPT" "$TARGET" "$SHELLSPEC_TMPBASE/out61" "$SHELLSPEC_TMPBASE/unused" "$NCLOG"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/cm-calls" should include "check some-other-mac"
    The contents of file "$SHELLSPEC_TMPBASE/cm-calls" should include "map some-other-mac /remote/file with space.txt"
  End

  It 'keeps internal size metadata separate from an item named .sizes'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT/remote"
    printf 'literal sizes file\n' > "$MOUNT/remote/.sizes"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check) printf '%s\\n' "$MOUNT"; exit 0 ;;
  map) printf '%s%s\\n' "$MOUNT" "\$3"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.611 "/remote/.sizes"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be success
    The contents of file "$TARGET/.sizes" should equal "literal sizes file"
  End

  It 'uses an existing picker-localized remote row without remapping it'
    export PICK_CLIPBOARD_CACHE_ROOT="$SHELLSPEC_TMPBASE/cache/files"
    cached="$PICK_CLIPBOARD_CACHE_ROOT/42/1/cached.txt"
    mkdir -p "$(dirname "$cached")"
    printf 'already local\n' > "$cached"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
echo "\$*" >> "$SHELLSPEC_TMPBASE/cm-calls"
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.612 "$cached"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be success
    The contents of file "$TARGET/cached.txt" should equal "already local"
    The path "$SHELLSPEC_TMPBASE/cm-calls" should not be exist
  End

  It 'does not trust a cache-shaped remote row without a capability'
    export PICK_CLIPBOARD_CACHE_ROOT="$SHELLSPEC_TMPBASE/cache/files"
    cached="$PICK_CLIPBOARD_CACHE_ROOT/43/1/untrusted.txt"
    mkdir -p "$(dirname "$cached")"
    printf 'stale local\n' > "$cached"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
echo "\$*" >> "$SHELLSPEC_TMPBASE/cm-calls"
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.6125 "$cached"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "mount is unavailable"
    The file "$TARGET/untrusted.txt" should not be exist
    The contents of file "$SHELLSPEC_TMPBASE/cm-calls" should include "check some-other-mac"
  End

  It 'enforces CLIP_FILE_MAX for mounted cross-machine copies'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT/remote"
    printf 'small\n' > "$MOUNT/remote/small.txt"
    printf '0123456789012345678901234567890123456789' > "$MOUNT/remote/large.txt"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check) printf '%s\\n' "$MOUNT"; exit 0 ;;
  map) printf '%s%s\\n' "$MOUNT" "\$3"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" files some-other-mac 1752200000.613 \
      "/remote/small.txt" "/remote/large.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command env CLIP_FILE_MAX=10 sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "exceeds size cap"
    The stderr should include "CLIP_FILE_MAX=10"
    The file "$TARGET/small.txt" should not be exist
    The file "$TARGET/large.txt" should not be exist
  End

  It 'rechecks staged mounted sizes before placing any item'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT/remote/growing-dir"
    printf 'small\n' > "$MOUNT/remote/small-first.txt"
    printf 'initial\n' > "$MOUNT/remote/growing-dir/a.txt"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check) printf '%s\\n' "$MOUNT"; exit 0 ;;
  map) printf '%s%s\\n' "$MOUNT" "\$3"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    cat > "$BINDIR/du" <<EOF
#!/bin/sh
n=0
[ -f "$SHELLSPEC_TMPBASE/du-count" ] && n=\$(cat "$SHELLSPEC_TMPBASE/du-count")
n=\$((n + 1))
printf '%s\\n' "\$n" > "$SHELLSPEC_TMPBASE/du-count"
if [ "\$n" -le 2 ]; then echo "1 \$2"; else echo "2 \$2"; fi
EOF
    chmod +x "$BINDIR/du"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" files some-other-mac 1752200000.6135 \
      "/remote/small-first.txt" "/remote/growing-dir"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command env CLIP_FILE_MAX=1500 sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "exceeds size cap"
    The file "$TARGET/small-first.txt" should not be exist
    The path "$TARGET/growing-dir" should not be exist
  End

  It 'fails closed when a mounted source size cannot be measured'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT/remote"
    printf 'unreadable\n' > "$MOUNT/remote/unreadable.txt"
    chmod 000 "$MOUNT/remote/unreadable.txt"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check) printf '%s\\n' "$MOUNT"; exit 0 ;;
  map) printf '%s%s\\n' "$MOUNT" "\$3"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.614 "/remote/unreadable.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    chmod 600 "$MOUNT/remote/unreadable.txt"
    The status should be failure
    The stderr should include "could not determine source size"
    The file "$TARGET/unreadable.txt" should not be exist
  End

  It 'does not follow a top-level symlink from the peer mount'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT/remote"
    printf 'local target\n' > "$SHELLSPEC_TMPBASE/local-target.txt"
    ln -s "$SHELLSPEC_TMPBASE/local-target.txt" "$MOUNT/remote/link.txt"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check) printf '%s\\n' "$MOUNT"; exit 0 ;;
  map) printf '%s%s\\n' "$MOUNT" "\$3"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.6141 "/remote/link.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "could not determine source size"
    The file "$TARGET/link.txt" should not be exist
  End

  It 'rejects a partial directory size when du exits nonzero'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT/remote/partial-dir"
    printf 'partial\n' > "$MOUNT/remote/partial-dir/a.txt"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check) printf '%s\\n' "$MOUNT"; exit 0 ;;
  map) printf '%s%s\\n' "$MOUNT" "\$3"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    cat > "$BINDIR/du" <<'EOF'
#!/bin/sh
echo "123 partial"
exit 1
EOF
    chmod +x "$BINDIR/du"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" directory some-other-mac 1752200000.6145 "/remote/partial-dir"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "could not determine source size"
    The file "$TARGET/partial-dir" should not be exist
  End

  It 'reports the picker fallback when the mount dies during size measurement'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT/remote"
    printf 'raced\n' > "$MOUNT/remote/raced.txt"
    chmod 000 "$MOUNT/remote/raced.txt"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check)
    n=0
    [ -f "$SHELLSPEC_TMPBASE/check-count" ] && n=\$(cat "$SHELLSPEC_TMPBASE/check-count")
    n=\$((n + 1))
    printf '%s\\n' "\$n" > "$SHELLSPEC_TMPBASE/check-count"
    [ "\$n" -eq 1 ] && { printf '%s\\n' "$MOUNT"; exit 0; }
    exit 1
    ;;
  map) printf '%s%s\\n' "$MOUNT" "\$3"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.6146 "/remote/raced.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    chmod 600 "$MOUNT/remote/raced.txt"
    The status should be failure
    The stderr should include "mount is unavailable"
    The stderr should not include "could not determine source size"
  End

  It 'fails closed when a remote mount path cannot be mapped'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check) printf '%s\\n' "$MOUNT"; exit 0 ;;
  map) exit 1 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.615 "/remote/unsafe.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "cannot map remote clipboard path"
    The file "$TARGET/unsafe.txt" should not be exist
  End

  It 'reports the picker fallback when the mount dies after the health check'
    MOUNT="$SHELLSPEC_TMPBASE/mnt/some-other-mac"
    mkdir -p "$MOUNT"
    export CLIPBOARD_MOUNT_BIN="$BINDIR/clipboard-mount"
    cat > "$CLIPBOARD_MOUNT_BIN" <<EOF
#!/bin/sh
case "\$1" in
  check)
    n=0
    [ -f "$SHELLSPEC_TMPBASE/check-count" ] && n=\$(cat "$SHELLSPEC_TMPBASE/check-count")
    n=\$((n + 1))
    printf '%s\\n' "\$n" > "$SHELLSPEC_TMPBASE/check-count"
    [ "\$n" -eq 1 ] && { printf '%s\\n' "$MOUNT"; exit 0; }
    exit 1
    ;;
  map) printf '%s%s\\n' "$MOUNT" "\$3"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$CLIPBOARD_MOUNT_BIN"
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.616 "/remote/vanished.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "mount is unavailable"
    The stderr should include "pick-clipboard Ctrl-Y"
    The stderr should not include "source no longer exists"
  End

  # R-batch Task B amendment: PF_HOST resolves via self_host(), which prefers
  # the pushed $XDG_STATE_HOME/clipboard/self-name identity over
  # scutil/hostname. On an ephemeral-hostname dev-shell, pbcopy stamps
  # manifest rows with that stable self-name -- if pbpaste --files kept
  # resolving the raw (fake-scutil "mac-mini") hostname here, this row would
  # misclassify as REMOTE and, with no SSH env in this Describe, require a
  # peer mount instead of materializing. Success + real bytes in
  # the target + no second nc call (only the one K fetch) proves the row took
  # the LOCAL path.
  It 'routes a manifest matching the self-name identity to the LOCAL materialization path'
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/xdg-state-selfname"
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf 'stable-devshell' > "$XDG_STATE_HOME/clipboard/self-name"
    printf 'self-name routed\n' > "$SRC/selfname.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file stable-devshell 1752200000.62 "$SRC/selfname.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh -c '
      sh "$1" --files "$2" >/dev/null 2>"$3" || { cat "$3" >&2; exit 1; }
      diff "$4/selfname.txt" "$2/selfname.txt" || exit 2
      lines=$(wc -l < "$5" | tr -d " ")
      [ "$lines" -eq 1 ] || { echo "nclog lines=$lines" >&2; exit 3; }
    ' _ "$SCRIPT" "$TARGET" "$SHELLSPEC_TMPBASE/err62" "$SRC" "$NCLOG"
    The status should be success
  End

  It 'errors pointing at plain pbpaste when the clipboard entry is not a files clip'
    pf="$SHELLSPEC_TMPBASE/payload"
    printf 'not-files' > "$pf"
    build_frame E "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "pbpaste"
  End
End

# Interrupt-safety: killing pbpaste --files mid-copy must never leave a
# partial entry in the target, and a leftover staging dir from an
# untrappable SIGKILL must be swept by the next invocation. APFS clonefile
# (tier 1) is near-instant regardless of size -- copying even a many-GB file
# within the SAME container completes in milliseconds, which would make
# "kill mid-copy" untestable via timing. This Describe forces a genuine,
# timeable byte-for-byte copy by putting the source on its OWN APFS
# container (a throwaway sparse disk image): per `man cp`, `-c` degrades to
# a normal copy across containers -- still tier 1 code, but no longer
# instant -- without needing to fake/skip any real binary.
Describe 'pbpaste: --files interrupt safety'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbpaste"
  TOKEN=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

  build_frame() {
    st=$1 payload_file=$2 outfile=$3
    len=$(wc -c < "$payload_file" | tr -d ' ')
    {
      printf '%s' "$st"
      printf "\\$(printf %03o $(((len>>24)&255)))\\$(printf %03o $(((len>>16)&255)))\\$(printf %03o $(((len>>8)&255)))\\$(printf %03o $((len&255)))"
      cat "$payload_file"
    } > "$outfile"
  }

  build_manifest() {
    outfile=$1 kind=$2 host=$3 ts=$4
    shift 4
    {
      printf '%s\037%s\037%s\037%s\037' "$kind" "$host" "$ts" "$TOKEN"
      first=1
      for p in "$@"; do
        if [ "$first" -eq 1 ]; then
          printf '%s' "$p"
          first=0
        else
          printf '\000%s' "$p"
        fi
      done
    } > "$outfile"
  }

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
    REPLY_FRAME="$SHELLSPEC_TMPBASE/reply.frame"
    export REPLY_FRAME
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
argc=\$#
eval "port=\\\${\$argc}"
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
cat "$REPLY_FRAME"
EOF
    chmod +x "$BINDIR/nc"
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
    # Hermetic self_host(): see the local-materialization Describe's setup.
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/xdg-state-interrupt"

    TARGET="$SHELLSPEC_TMPBASE/target"; mkdir -p "$TARGET"

    DMG="$SHELLSPEC_TMPBASE/xvol.sparseimage"
    hdiutil create -size 5g -fs APFS -volname PbpasteFilesTest -type SPARSE "$DMG" >/dev/null
    ATTACH_OUT=$(hdiutil attach "$DMG" -nobrowse)
    MNT=$(printf '%s\n' "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
    export MNT
    # Real (non-sparse) zero-fill: a genuinely dense, cross-container source
    # so tier 1's fallback copy has real bytes to move (see Describe header).
    dd if=/dev/zero of="$MNT/big.bin" bs=4m count=1024 >/dev/null 2>&1
  }
  BeforeEach 'setup'

  cleanup() {
    if [ -n "${MNT:-}" ]; then
      hdiutil detach "$MNT" -force >/dev/null 2>&1
    fi
    rm -f "$SHELLSPEC_TMPBASE/xvol.sparseimage"
  }
  AfterEach 'cleanup'

  It 'leaves no partial entry in the target when killed mid-copy, and sweeps staging on the next run'
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752200000.7 "$MNT/big.bin"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh -c '
      sh "$1" --files "$2" >/dev/null 2>&1 &
      pid=$!
      sleep 0.2
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      if [ -e "$2/big.bin" ]; then exit 9; fi
      sh "$1" --files "$2" >/dev/null 2>&1 || exit 1
      if ls -d "$2"/.pbpaste-staging.* >/dev/null 2>&1; then exit 8; fi
      if [ ! -e "$2/big.bin" ]; then exit 7; fi
      cmp -s "$2/big.bin" "$MNT/big.bin" || exit 6
    ' _ "$SCRIPT" "$TARGET"
    The status should be success
  End
End

# Forced-replacement crash recovery (bug #2). `--force` replaces an existing
# destination by renaming it ASIDE (mv final -> backup) and only THEN renaming
# the staged replacement into place (mv stage -> final). A signal/kill landing
# BETWEEN those two renames leaves the destination momentarily absent with the
# only copy of the original in the backup -- so the backup MUST live somewhere
# the cleanup path restores rather than blindly deletes, and the sweep of a
# SIGKILLed run must restore it too.
#
# These probes are DETERMINISTIC: a fake `mv` on PATH fires exactly one signal
# at a chosen seam in pbpaste_files_place's rename pair (guarded by a one-shot
# marker so the recovery/restore renames that follow run for real). It keys the
# seam off the destination path -- a backup destination (inside the staging or
# recovery dir) is the FIRST rename (the displace), the target destination is
# the SECOND (the place) -- so it works unchanged against both the old
# backup-in-staging layout and the fixed recovery-dir layout. `between`/`sweep`
# reproduce the data-loss window; `before`/`after` are guards that the original
# (resp. the new content) survives the adjacent windows.
Describe 'pbpaste: --files forced-replacement crash recovery'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbpaste"
  TOKEN=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

  build_frame() {
    st=$1 payload_file=$2 outfile=$3
    len=$(wc -c < "$payload_file" | tr -d ' ')
    {
      printf '%s' "$st"
      printf "\\$(printf %03o $(((len>>24)&255)))\\$(printf %03o $(((len>>16)&255)))\\$(printf %03o $(((len>>8)&255)))\\$(printf %03o $((len&255)))"
      cat "$payload_file"
    } > "$outfile"
  }

  build_manifest() {
    outfile=$1 kind=$2 host=$3 ts=$4
    shift 4
    {
      printf '%s\037%s\037%s\037%s\037' "$kind" "$host" "$ts" "$TOKEN"
      first=1
      for p in "$@"; do
        if [ "$first" -eq 1 ]; then
          printf '%s' "$p"
          first=0
        else
          printf '\000%s' "$p"
        fi
      done
    } > "$outfile"
  }

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
    REPLY_FRAME="$SHELLSPEC_TMPBASE/reply.frame"
    export REPLY_FRAME
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
argc=\$#
eval "port=\\\${\$argc}"
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
cat "$REPLY_FRAME"
EOF
    chmod +x "$BINDIR/nc"
    cat > "$BINDIR/scutil" <<'EOF'
#!/bin/sh
if [ "$1" = "--get" ] && [ "$2" = "LocalHostName" ]; then
  echo mac-mini
  exit 0
fi
exit 1
EOF
    chmod +x "$BINDIR/scutil"

    # One-shot interrupt harness for pbpaste_files_place's rename pair. Reads
    # PBPASTE_MV_MODE (before|between|after|sweep) and PBPASTE_MV_MARKER from
    # the environment pbpaste passes down. place() always calls `mv -- SRC DST`,
    # so $3 is the destination: a staging/recovery/.replaced destination is the
    # displacing FIRST rename, anything else is the placing SECOND rename.
    cat > "$BINDIR/mv" <<EOF
#!/bin/sh
real=/bin/mv
[ -x "\$real" ] || real=/usr/bin/mv
dst=\$3
case "\$dst" in
  *.pbpaste-recovery.*|*.pbpaste-staging.*|*.replaced.*) displace=1 ;;
  *) displace=0 ;;
esac
if [ -n "\${PBPASTE_MV_MODE:-}" ] && [ ! -f "\${PBPASTE_MV_MARKER:-/nonexistent}" ]; then
  fire=0
  case "\$PBPASTE_MV_MODE" in
    before) [ "\$displace" = 1 ] && fire=1 ;;
    between|after|sweep) [ "\$displace" = 0 ] && fire=1 ;;
  esac
  if [ "\$fire" = 1 ]; then
    : > "\$PBPASTE_MV_MARKER"
    [ "\$PBPASTE_MV_MODE" = after ] && "\$real" "\$@"
    case "\$PBPASTE_MV_MODE" in
      sweep) kill -KILL \$PPID ;;
      *) kill -TERM \$PPID ;;
    esac
    exit 0
  fi
fi
exec "\$real" "\$@"
EOF
    chmod +x "$BINDIR/mv"
    export PATH="$BINDIR:$PATH"
    # Hermetic self_host(): see the local-materialization Describe's setup.
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/xdg-state-recover"
    MVMARKER="$SHELLSPEC_TMPBASE/mv-marker"; rm -f "$MVMARKER"

    SRC="$SHELLSPEC_TMPBASE/src-recover"; mkdir -p "$SRC"
    TARGET="$SHELLSPEC_TMPBASE/target-recover"; rm -rf "$TARGET"; mkdir -p "$TARGET"
    printf 'NEWCONTENT\n' > "$SRC/keep.txt"
    printf 'ORIGINAL\n' > "$TARGET/keep.txt"
    pf="$SHELLSPEC_TMPBASE/payload-recover"
    build_manifest "$pf" file mac-mini 1752400000.1 "$SRC/keep.txt"
    build_frame O "$pf" "$REPLY_FRAME"
  }
  BeforeEach 'setup'

  # Guard window: a signal immediately BEFORE the first rename never displaced
  # anything, so the original is untouched at its destination.
  It 'keeps the original when interrupted immediately before the first rename'
    When run command env PBPASTE_MV_MODE=before PBPASTE_MV_MARKER="$MVMARKER" sh -c '
      sh "$1" --files --force "$2" >/dev/null 2>&1
      [ "$(cat "$2/keep.txt" 2>/dev/null)" = "ORIGINAL" ] || exit 6
      ls -d "$2"/.pbpaste-recovery.* >/dev/null 2>&1 && exit 5
      ls -d "$2"/.pbpaste-staging.* >/dev/null 2>&1 && exit 4
      exit 0
    ' _ "$SCRIPT" "$TARGET"
    The status should be success
  End

  # THE BUG: a signal BETWEEN the two renames -- the original has been displaced
  # into the backup and the replacement has not landed yet. The trap must
  # RESTORE the displaced original (destination missing), not delete it with the
  # staging dir. Red on the old backup-in-staging layout (original lost), green
  # once the backup lives in a recovery dir the trap restores from.
  It 'restores the displaced original when interrupted between the two renames'
    When run command env PBPASTE_MV_MODE=between PBPASTE_MV_MARKER="$MVMARKER" sh -c '
      sh "$1" --files --force "$2" >/dev/null 2>&1
      [ -e "$2/keep.txt" ] || exit 7
      [ "$(cat "$2/keep.txt")" = "ORIGINAL" ] || exit 6
      ls -d "$2"/.pbpaste-recovery.* >/dev/null 2>&1 && exit 5
      ls -d "$2"/.pbpaste-staging.* >/dev/null 2>&1 && exit 4
      exit 0
    ' _ "$SCRIPT" "$TARGET"
    The status should be success
  End

  # Guard window: a signal immediately AFTER the replacement landed must keep
  # the NEW content (never "restore" the stale original over it) and leave no
  # residue.
  It 'keeps the new content when interrupted immediately after the replacement'
    When run command env PBPASTE_MV_MODE=after PBPASTE_MV_MARKER="$MVMARKER" sh -c '
      sh "$1" --files --force "$2" >/dev/null 2>&1
      [ "$(cat "$2/keep.txt" 2>/dev/null)" = "NEWCONTENT" ] || exit 6
      ls -d "$2"/.pbpaste-recovery.* >/dev/null 2>&1 && exit 5
      ls -d "$2"/.pbpaste-staging.* >/dev/null 2>&1 && exit 4
      exit 0
    ' _ "$SCRIPT" "$TARGET"
    The status should be success
  End

  # SIGKILL (untrappable) between the two renames leaves the displaced original
  # only in the on-disk recovery dir. The NEXT run's stale-sweep must restore it
  # (destination missing) BEFORE anything else -- here the plain follow-up paste
  # then refuses the now-present conflict, leaving the restored original intact.
  It 'restores a SIGKILLed run''s displaced original on the next run''s stale-sweep'
    When run command sh -c '
      # Background + wait so the shell reaps the SIGKILLed run silently (the
      # same pattern the mid-copy interrupt test uses) -- a foreground kill
      # would print a "Killed: 9" job notice to stderr, which shellspec flags.
      PBPASTE_MV_MODE=sweep PBPASTE_MV_MARKER="$3" sh "$1" --files --force "$2" >/dev/null 2>&1 &
      wait "$!" 2>/dev/null
      [ ! -e "$2/keep.txt" ] || exit 9
      ls -d "$2"/.pbpaste-recovery.* >/dev/null 2>&1 || exit 8
      sh "$1" --files "$2" >/dev/null 2>&1
      [ -e "$2/keep.txt" ] || exit 7
      [ "$(cat "$2/keep.txt")" = "ORIGINAL" ] || exit 6
      ls -d "$2"/.pbpaste-recovery.* >/dev/null 2>&1 && exit 5
      ls -d "$2"/.pbpaste-staging.* >/dev/null 2>&1 && exit 4
      exit 0
    ' _ "$SCRIPT" "$TARGET" "$MVMARKER"
    The status should be success
  End
End

# Tests for pbpaste's REMOTE file-materialization engine (T13, design
# §5/§8): manifest host != this host -> stream each item over F (files) /
# A (directories, via the dispatcher's `E is-directory` retry) instead of
# the local tiered engine. The fake `nc` here is opcode-aware (peeks the
# first request byte) so it can serve a DIFFERENT canned reply per opcode --
# unlike the single-`$REPLY_FRAME` convention above, which only ever needs
# to answer one `L` request per invocation. Fake `scutil` reports THIS
# host as "dev-shell"; manifest host "mac-mini" is therefore a DIFFERENT
# machine, exercising the remote branch (a manifest host of "dev-shell"
# itself, reused from the Describes above, would take the LOCAL branch
# instead -- see the explicit host-comparison this task added).
Describe 'pbpaste: --files (remote engine)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbpaste"
  TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  build_frame() {
    st=$1 payload_file=$2 outfile=$3
    len=$(wc -c < "$payload_file" | tr -d ' ')
    {
      printf '%s' "$st"
      printf "\\$(printf %03o $(((len>>24)&255)))\\$(printf %03o $(((len>>16)&255)))\\$(printf %03o $(((len>>8)&255)))\\$(printf %03o $((len&255)))"
      cat "$payload_file"
    } > "$outfile"
  }

  build_manifest() {
    outfile=$1 kind=$2 host=$3 ts=$4
    shift 4
    {
      printf '%s\037%s\037%s\037%s\037' "$kind" "$host" "$ts" "$TOKEN"
      first=1
      for p in "$@"; do
        if [ "$first" -eq 1 ]; then
          printf '%s' "$p"
          first=0
        else
          printf '\000%s' "$p"
        fi
      done
    } > "$outfile"
  }

  # build_a_frame <est_bytes> <tar_body_file> <outfile> -- an A-reply frame:
  # O + BE32(8) + BE64(est_bytes), then <tar_body_file>'s bytes RAW (no
  # further framing -- stream_archive_path's contract: read to EOF).
  build_a_frame() {
    est=$1 body=$2 outfile=$3
    {
      printf 'O'
      len=8
      printf "\\$(printf %03o $(((len>>24)&255)))\\$(printf %03o $(((len>>16)&255)))\\$(printf %03o $(((len>>8)&255)))\\$(printf %03o $((len&255)))"
      b8=$(( est & 255 )); b7=$(( (est>>8)&255 )); b6=$(( (est>>16)&255 )); b5=$(( (est>>24)&255 ))
      b4=$(( (est>>32)&255 )); b3=$(( (est>>40)&255 )); b2=$(( (est>>48)&255 )); b1=$(( (est>>56)&255 ))
      printf "\\$(printf %03o $b1)\\$(printf %03o $b2)\\$(printf %03o $b3)\\$(printf %03o $b4)\\$(printf %03o $b5)\\$(printf %03o $b6)\\$(printf %03o $b7)\\$(printf %03o $b8)"
      cat "$body"
    } > "$outfile"
  }

  setup() {
    export SSH_CONNECTION="x 1 y 22"
    unset SSH_CLIENT SSH_TTY
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
    REPLY_L="$SHELLSPEC_TMPBASE/reply.L"; : > "$REPLY_L"
    REPLY_F="$SHELLSPEC_TMPBASE/reply.F"; : > "$REPLY_F"
    REPLY_A="$SHELLSPEC_TMPBASE/reply.A"; : > "$REPLY_A"
    export REPLY_L REPLY_F REPLY_A

    # Opcode-aware fake nc: peeks the request's first byte (the opcode) and
    # replies from the matching canned file. Logs "<port>:<op>:<frame, NUL
    # -> '|'>" so tests can assert both port selection (requirement 4) and
    # which opcode each call actually sent.
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
argc=\$#
eval "port=\\\${\$argc}"
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
op=\$(dd bs=1 count=1 2>/dev/null < "\$raw")
{ printf '%s:%s:' "\$port" "\$op"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
case "\$op" in
  K) cat "$REPLY_L" ;;
  f) cat "$REPLY_F" ;;
  a) cat "$REPLY_A" ;;
esac
EOF
    chmod +x "$BINDIR/nc"

    cat > "$BINDIR/scutil" <<'EOF'
#!/bin/sh
if [ "$1" = "--get" ] && [ "$2" = "LocalHostName" ]; then
  echo dev-shell
  exit 0
fi
exit 1
EOF
    chmod +x "$BINDIR/scutil"
    export PATH="$BINDIR:$PATH"
    # Hermetic self_host(): see the local-materialization Describe's setup.
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/xdg-state-remote"

    # A dedicated target subdir, NOT the "$SHELLSPEC_TMPBASE/target" the
    # Describes above use: $SHELLSPEC_TMPBASE is shared for the whole spec
    # run (not reset per Example), so reusing that path here would collide
    # with files an earlier Describe already materialized under the exact
    # same item names (e.g. "a.txt").
    TARGET="$SHELLSPEC_TMPBASE/target-remote"; mkdir -p "$TARGET"
  }
  BeforeEach 'setup'

  It 'fails closed with an upgrade hint when the origin does not support K'
    errf="$SHELLSPEC_TMPBASE/k-unknown"
    printf 'unknown opcode' > "$errf"
    build_frame E "$errf" "$REPLY_L"
    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "origin clipboard bridge is outdated"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not include ":f:"
  End

  It 'refuses a remote pointer-only manifest instead of falling back to raw paths'
    TOKEN=-
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752300000.0 "/remote/not-authorized.txt"
    build_frame O "$pf" "$REPLY_L"
    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "did not authorize"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not include ":f:"
  End

  It 'materializes a regular file via F, byte-identical to the source bytes'
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752300000.1 "/remote/a.txt"
    build_frame O "$pf" "$REPLY_L"

    body="$SHELLSPEC_TMPBASE/filebody"
    printf 'hello from the remote Mac\n' > "$body"
    build_frame O "$body" "$REPLY_F"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be success
    The contents of file "$TARGET/a.txt" should equal "hello from the remote Mac"
  End

  It 'sends F to the reverse-tunneled :2490 port (requirement 4)'
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752300000.2 "/remote/b.txt"
    build_frame O "$pf" "$REPLY_L"
    body="$SHELLSPEC_TMPBASE/filebody"
    printf 'port check\n' > "$body"
    build_frame O "$body" "$REPLY_F"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:K:"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:f:"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "$TOKEN"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not include "/remote/b.txt"
  End

  It 'refuses to overwrite an existing target name without --force (same conflict semantics as local)'
    printf 'old\n' > "$TARGET/dup.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752300000.3 "/remote/dup.txt"
    build_frame O "$pf" "$REPLY_L"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should include "dup.txt"
    The contents of file "$TARGET/dup.txt" should equal "old"
    # The conflict check runs BEFORE any transfer -- only the manifest's own
    # `K` fetch happened, never an `f`/`a` call for the conflicting item.
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:K:"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not include ":f:"
  End

  It "retries as A on the dispatcher's exact is-directory error, extracting the directory correctly"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" directory mac-mini 1752300000.4 "/remote/adir"
    build_frame O "$pf" "$REPLY_L"

    errf="$SHELLSPEC_TMPBASE/is-directory-msg"
    printf 'is-directory' > "$errf"
    build_frame E "$errf" "$REPLY_F"

    # The real dispatcher's `tar -cf - -C <parent> <basename>` roots the
    # archive's entries at the manifest path's OWN basename ("adir", from
    # "/remote/adir" above) -- this fixture's source dir must be named
    # identically so the tar body is byte-shaped like the real thing, or
    # the extraction below would land at PF_STAGING/src-adir while
    # pbpaste_files_place expects PF_STAGING/adir (the manifest's basename).
    src="$SHELLSPEC_TMPBASE/adir"
    mkdir -p "$src/nested"
    printf 'top level\n' > "$src/top.txt"
    printf 'nested content\n' > "$src/nested/deep.txt"
    tarfile="$SHELLSPEC_TMPBASE/adir.tar"
    tar -cf "$tarfile" -C "$SHELLSPEC_TMPBASE" "$(basename "$src")"
    kb=$(du -sk "$src" | awk '{print $1}')
    est=$(( kb * 1024 ))
    build_a_frame "$est" "$tarfile" "$REPLY_A"

    When run command sh -c '
      sh "$1" --files "$2" || exit 1
      diff -r "$3" "$2/adir" || exit 2
    ' _ "$SCRIPT" "$TARGET" "$src"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include ":f:"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include ":a:"
  End

  # Integrity check per T13/design §4: a mid-stream I/O error on the far end
  # has no error frame left to send once the A stream's O header is out, so
  # the client's own tar EXTRACTION failing is the only truncation signal.
  # A genuinely truncated archive (real random bytes, cut well past any
  # header so tar has committed to extracting a file it can't finish) must
  # fail the item AND leave no partial directory in the target.
  It 'fails a genuinely truncated A stream, leaving no partial directory in the target'
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" directory mac-mini 1752300000.5 "/remote/bigdir"
    build_frame O "$pf" "$REPLY_L"

    errf="$SHELLSPEC_TMPBASE/is-directory-msg2"
    printf 'is-directory' > "$errf"
    build_frame E "$errf" "$REPLY_F"

    # Same basename requirement as the "retries as A" test above: the
    # manifest path's basename ("bigdir") must be the tar's rooted entry
    # name, or a would-be-successful extraction lands under the wrong name
    # regardless of truncation.
    src="$SHELLSPEC_TMPBASE/bigdir"
    mkdir -p "$src"
    head -c 200000 /dev/urandom > "$src/big.bin" 2>/dev/null || dd if=/dev/urandom of="$src/big.bin" bs=1000 count=200 2>/dev/null
    fulltar="$SHELLSPEC_TMPBASE/bigdir-full.tar"
    tar -cf "$fulltar" -C "$SHELLSPEC_TMPBASE" "$(basename "$src")"
    fullsize=$(wc -c < "$fulltar" | tr -d ' ')
    cutsize=$(( fullsize * 60 / 100 ))
    cutbody="$SHELLSPEC_TMPBASE/bigdir-cut.tar"
    head -c "$cutsize" "$fulltar" > "$cutbody"
    kb=$(du -sk "$src" | awk '{print $1}')
    est=$(( kb * 1024 ))
    build_a_frame "$est" "$cutbody" "$REPLY_A"

    When run command sh -c '
      sh "$1" --files "$2" >/dev/null 2>&1
      rc=$?
      if [ "$rc" -eq 0 ]; then exit 9; fi
      if [ -e "$2/bigdir" ]; then exit 8; fi
      if ls -d "$2"/.pbpaste-staging.* >/dev/null 2>&1; then exit 7; fi
      exit 0
    ' _ "$SCRIPT" "$TARGET"
    The status should be success
  End

  # Porcelain contract from the remote path (reusing the local Describe's
  # assertion pattern): every line exactly 4 tab fields, stream ends with a
  # `done` line. Unlike the local engine's single instant tier, an in-flight
  # remote item's `progress` lines are NOT required to have done==total
  # (see pbpaste_progress_tick) -- only the FINAL line pbpaste_files_place
  # emits per item is (done==total==the real transferred size).
  It 'porcelain: every line has exactly 4 tab fields and the stream ends with a done line'
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752300000.6 "/remote/p.txt"
    build_frame O "$pf" "$REPLY_L"
    body="$SHELLSPEC_TMPBASE/filebody-porcelain"
    printf 'porcelain payload contents\n' > "$body"
    build_frame O "$body" "$REPLY_F"

    When run command sh -c '
      sh "$1" --files --porcelain "$2" > "$3" || exit 1
      awk -F"\t" "{ if (NF != 4) exit 9 }" "$3" || exit 9
      last=$(tail -n 1 "$3")
      case "$last" in
        done*) : ;;
        *) exit 8 ;;
      esac
      final=$(awk -F"\t" "\$1 == \"progress\" { line = \$0 } END { print line }" "$3")
      case "$final" in
        *"$2/p.txt"*) : ;;
        *) exit 7 ;;
      esac
    ' _ "$SCRIPT" "$TARGET" "$SHELLSPEC_TMPBASE/porcelain.out"
    The status should be success
  End

  # Design §11: per-item size cap, F engine. Declared total comes straight
  # from F's own BE32 length header, known before any body byte is pulled.
  #
  # Both examples below exercise ONLY the non-interactive refusal branch of
  # pbpaste_files_cap_check (no usable /dev/tty in this harness -- `tty`
  # reports "not a tty" for the whole shellspec sandbox, and a scripted PTY
  # via `script -q /dev/null` was tried and confirmed unworkable here: the
  # wrapped child's `read </dev/tty` came back empty even when fed input
  # through script's own stdin, because the harness process itself has no
  # controlling terminal for `script` to relay through). The interactive
  # ACCEPT path (`[ -t 1 ] && [ -r /dev/tty ]` true, gum/`read` answers "y")
  # is exercised only by hand against a live terminal -- see the Mode B UX
  # validation session, not covered by an automated example here.
  It 'fails naming the cap and the item when CLIP_FILE_MAX is exceeded (F, non-interactive)'
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file mac-mini 1752300000.7 "/remote/toobig.txt"
    build_frame O "$pf" "$REPLY_L"
    body="$SHELLSPEC_TMPBASE/filebody-toobig"
    printf '0123456789012345678901234567890123456789' > "$body"
    build_frame O "$body" "$REPLY_F"

    When run command env CLIP_FILE_MAX=10 sh "$SCRIPT" --files "$TARGET" </dev/null
    The status should be failure
    The stderr should include "CLIP_FILE_MAX"
    The stderr should include "toobig.txt"
    # W1: the refusal is actionable and doesn't imply a terminal is needed --
    # smart-paste.yazi's remote path parses everything up through "--
    # refusing" (see parse_cap_refusal); this pins that the fixed shape
    # survived the reword and that the free-form suggestion text is present.
    The stderr should include "-- refusing (no interactive confirm available"
    The stderr should include "set CLIP_FILE_MAX=40 or higher to allow"
    The file "$TARGET/toobig.txt" should not be exist
  End

  # Same cap, A engine: declared total is the BE64 estimate, known before
  # the tar pipeline even starts.
  It 'fails naming the cap and the item when CLIP_FILE_MAX is exceeded (A, non-interactive)'
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" directory mac-mini 1752300000.8 "/remote/toobigdir"
    build_frame O "$pf" "$REPLY_L"
    errf="$SHELLSPEC_TMPBASE/is-directory-msg3"
    printf 'is-directory' > "$errf"
    build_frame E "$errf" "$REPLY_F"
    src="$SHELLSPEC_TMPBASE/toobigdir-src"
    mkdir -p "$src"
    printf 'small\n' > "$src/small.txt"
    tarfile="$SHELLSPEC_TMPBASE/toobigdir.tar"
    tar -cf "$tarfile" -C "$SHELLSPEC_TMPBASE" "$(basename "$src")"
    build_a_frame 999999999 "$tarfile" "$REPLY_A"

    When run command env CLIP_FILE_MAX=10 sh "$SCRIPT" --files "$TARGET" </dev/null
    The status should be failure
    The stderr should include "CLIP_FILE_MAX"
    The stderr should include "toobigdir"
    The stderr should include "-- refusing (no interactive confirm available"
    The stderr should include "set CLIP_FILE_MAX=999999999 or higher to allow"
    The file "$TARGET/toobigdir" should not be exist
  End

  # The byte counter must NEVER derive from dd's stderr summary: its wording
  # is dialect-specific (BSD dd prints "bytes transferred", GNU dd "bytes
  # copied"), and the primary consumer of the remote branch is a Linux dev
  # shell -- parsing one dialect zeroes out every read on the other,
  # producing instant spurious "connection closed/truncated" failures. The
  # canned-stream fixtures above can't switch dd flavors, so this pins the
  # MECHANISM instead: every chunked dd read in the shim must discard its
  # stderr (2>/dev/null), proving the counts come from artifact files
  # (`wc -c`) -- which the functional examples above then exercise for
  # correctness, on any platform's dd.
  It 'never captures dd stderr for byte counting (BSD/GNU dd summaries differ)'
    When run command sh -c 'grep -E "dd bs=.*count=1" "$1" | grep -v "^ *#" | grep -v "2>/dev/null"' _ "$SCRIPT"
    The status should be failure
    The output should equal ""
  End

  # Multi-item failure semantics: items are placed into the target one at a
  # time, atomically, as each completes -- a later item's failure ABORTS the
  # run (exit 1) but does NOT roll back items already placed (per-item
  # placement + abort-on-failure, not all-or-nothing; inherited from the
  # local engine's own loop shape). Pin exactly that: item 1's file IS in
  # the target with full content, item 2 left nothing behind, and the
  # staging dir is gone (EXIT trap).
  It 'keeps an already-placed item when a later item truncates, aborting with a clean staging dir'
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" files mac-mini 1752300000.9 "/remote/ok.txt" "/remote/trunc.txt"
    build_frame O "$pf" "$REPLY_L"

    okbody="$SHELLSPEC_TMPBASE/okbody"
    printf 'first item, completes fine\n' > "$okbody"
    build_frame O "$okbody" "$SHELLSPEC_TMPBASE/reply.F-ok"

    # Truncated F reply: header declares 100 body bytes, only 40 follow
    # (1 status + 4 len + 40 body = 45) -- pbpaste_stream_file_body's
    # EOF-before-total check must fail the item.
    truncbody="$SHELLSPEC_TMPBASE/truncbody"
    head -c 100 /dev/zero > "$truncbody"
    fullframe="$SHELLSPEC_TMPBASE/reply.F-full"
    build_frame O "$truncbody" "$fullframe"
    head -c 45 "$fullframe" > "$SHELLSPEC_TMPBASE/reply.F-trunc"

    # Per-item f replies: this test's own nc picks the canned reply by
    # reading the request's final decimal item index -- the
    # setup-provided nc serves ONE canned file per opcode, which can't
    # distinguish the two F calls this run makes.
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
argc=\$#
eval "port=\\\${\$argc}"
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
op=\$(dd bs=1 count=1 2>/dev/null < "\$raw")
{ printf '%s:%s:' "\$port" "\$op"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
case "\$op" in
  K) cat "$SHELLSPEC_TMPBASE/reply.L" ;;
  f)
    index=\$(tail -c 1 "\$raw")
    if [ "\$index" = "2" ]; then
      cat "$SHELLSPEC_TMPBASE/reply.F-trunc"
    else
      cat "$SHELLSPEC_TMPBASE/reply.F-ok"
    fi
    ;;
esac
rm -f "\$raw"
EOF
    chmod +x "$BINDIR/nc"

    When run command sh -c '
      sh "$1" --files "$2" >/dev/null 2>"$3"
      rc=$?
      if [ "$rc" -eq 0 ]; then exit 9; fi
      [ -e "$2/ok.txt" ] || exit 8
      grep -q "first item, completes fine" "$2/ok.txt" || exit 8
      if [ -e "$2/trunc.txt" ]; then exit 7; fi
      if ls -d "$2"/.pbpaste-staging.* >/dev/null 2>&1; then exit 6; fi
      grep -q "truncated stream" "$3" || exit 5
      exit 0
    ' _ "$SCRIPT" "$TARGET" "$SHELLSPEC_TMPBASE/two-item-err"
    The status should be success
  End
End

# pbpaste_cap_theme (rework R6): resolves the size-cap gum confirm's colors
# from the generated JSON palette (THEME_PALETTE_JSON, same file the zsh-only
# C_HEX_* vars come from -- see the function's own header comment). The gum
# dialog itself is untestable here (no usable /dev/tty in this harness, same
# limitation noted above pbpaste_files_cap_check's other examples), but the
# helper is a plain function with no tty/gum dependency, so it's exercised
# directly by sourcing the script with PBPASTE_TEST_SOURCE_ONLY=1 (stops
# right after the function definitions, before the real dispatch/exec logic
# would run).
Describe 'pbpaste: pbpaste_cap_theme (size-cap dialog palette)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbpaste"

  It 'reads dialog_warning/crust/subtext0/surface0 from a fixture palette JSON'
    fixture="$SHELLSPEC_TMPBASE/palette.json"
    cat > "$fixture" <<'EOF'
{
  "palette": {"crust": "#000001", "subtext0": "#000002", "surface0": "#000003"},
  "extended": {"dialog": {"warning": "#000004"}}
}
EOF
    When run command env PBPASTE_TEST_SOURCE_ONLY=1 THEME_PALETTE_JSON="$fixture" sh -c '
      . "$1"
      printf "warn=%s crust=%s subtext0=%s surface0=%s\n" \
        "$(pbpaste_cap_theme dialog_warning)" \
        "$(pbpaste_cap_theme crust)" \
        "$(pbpaste_cap_theme subtext0)" \
        "$(pbpaste_cap_theme surface0)"
    ' _ "$SCRIPT"
    The status should be success
    The output should equal "warn=#000004 crust=#000001 subtext0=#000002 surface0=#000003"
  End

  It 'falls back to the hardcoded Catppuccin Mocha literals when the palette file is missing'
    When run command env PBPASTE_TEST_SOURCE_ONLY=1 THEME_PALETTE_JSON="$SHELLSPEC_TMPBASE/does-not-exist.json" sh -c '
      . "$1"
      printf "warn=%s crust=%s subtext0=%s surface0=%s\n" \
        "$(pbpaste_cap_theme dialog_warning)" \
        "$(pbpaste_cap_theme crust)" \
        "$(pbpaste_cap_theme subtext0)" \
        "$(pbpaste_cap_theme surface0)"
    ' _ "$SCRIPT"
    The status should be success
    The output should equal "warn=#e5bf7b crust=#11111b subtext0=#a6adc8 surface0=#313244"
  End

  # C2: pbpaste is POSIX /bin/sh and cannot source theme-common, but its inline
  # resolution now honours the SAME order as theme::json_path -- with
  # $THEME_PALETTE_JSON unset it reads the effective cache copy
  # ($XDG_CACHE_HOME/theme/chezmoi-system.json), the SSH-tinted file the shell
  # exports, so the size-cap dialog agrees with the status bar and dialogs.
  It 'reads the effective cache copy when the override is unset (theme::json_path order)'
    cachedir="$SHELLSPEC_TMPBASE/xdgcache/theme"
    mkdir -p "$cachedir"
    cat > "$cachedir/chezmoi-system.json" <<'EOF'
{
  "palette": {"crust": "#0c0c0c", "subtext0": "#0d0d0d", "surface0": "#0e0e0e"},
  "extended": {"dialog": {"warning": "#0f0f0f"}}
}
EOF
    When run command env PBPASTE_TEST_SOURCE_ONLY=1 THEME_PALETTE_JSON= \
      XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/xdgcache" sh -c '
      . "$1"
      printf "warn=%s crust=%s subtext0=%s surface0=%s\n" \
        "$(pbpaste_cap_theme dialog_warning)" \
        "$(pbpaste_cap_theme crust)" \
        "$(pbpaste_cap_theme subtext0)" \
        "$(pbpaste_cap_theme surface0)"
    ' _ "$SCRIPT"
    The status should be success
    The output should equal "warn=#0f0f0f crust=#0c0c0c subtext0=#0d0d0d surface0=#0e0e0e"
  End
End

Describe 'pbpaste local mode: Phase 7 store fallback'
  PBPASTE="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbpaste"

  setup() {
    STUBS="$SHELLSPEC_TMPBASE/stubs"; mkdir -p "$STUBS"
    # Restricted PATH -- see Task 7's local-text Describe: a brew-installed
    # wl-paste/xclip must not win the command -v probes.
    export PATH="$STUBS:/usr/bin:/bin"
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    # Defeat the `-x /usr/bin/pbpaste` Darwin branch on the Mac running this
    # suite (test seam, mirrors Task 7's PBCOPY_DARWIN_BIN).
    export PBPASTE_DARWIN_BIN=/nonexistent
    printf '#!/bin/sh\necho Linux\n' > "$STUBS/uname"; chmod +x "$STUBS/uname"
    # nc stub: -z probe succeeds; a G request gets a framed "O" + "hi" reply
    cat > "$STUBS/nc" <<'EOF'
#!/bin/sh
case "$1" in
  -z) exit 0 ;;
esac
# framed response: O + BE32(2) + "hi"
printf 'O\000\000\000\002hi'
EOF
    chmod +x "$STUBS/nc"
    # No wl-paste/xclip stubs and /usr/bin/pbpaste absent-by-uname -> falls
    # through to the bridge branch.
  }
  BeforeEach 'setup'

  It 'falls back to bridge G when no local clipboard tool exists'
    When run command sh "$PBPASTE"
    The status should be success
    The output should equal "hi"
  End

  It 'distinguishes a reachable bridge answering E from an unreachable one (fix 5b)'
    # Overrides the shared setup()'s nc stub: -z probe still succeeds (the
    # bridge IS reachable), but the G request now gets an E reply carrying a
    # real error message instead of O.
    cat > "$STUBS/nc" <<'EOF'
#!/bin/sh
case "$1" in
  -z) exit 0 ;;
esac
printf 'E\000\000\000\012store down'
EOF
    chmod +x "$STUBS/nc"
    When run command sh "$PBPASTE"
    The status should equal 1
    The stderr should include "answered with an error"
    The stderr should include "store down"
    The stderr should not include "is not reachable"
  End

  It 'keeps the combined not-reachable message when the bridge never answers the probe'
    # -z probe itself fails (and, since uname says Linux, there is no
    # systemctl stub either, so the self-heal kick is a no-op) -- this is
    # the genuinely-unreachable case, which must keep the ORIGINAL combined
    # wording, not the new "answered with an error" branch.
    printf '#!/bin/sh\nexit 1\n' > "$STUBS/nc"
    chmod +x "$STUBS/nc"
    When run command sh "$PBPASTE"
    The status should equal 1
    The stderr should include "clipboard bridge is not reachable on 127.0.0.1:2489"
  End
End
