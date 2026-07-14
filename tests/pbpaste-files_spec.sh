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
    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
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
  # `L`-reply payload manifest_parse expects: kind US host US ts US path NUL
  # path NUL path ...
  build_manifest() {
    outfile=$1 kind=$2 host=$3 ts=$4
    shift 4
    {
      printf '%s\037%s\037%s\037' "$kind" "$host" "$ts"
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

  # A manifest from a DIFFERENT host used to hit T5's "later milestone"
  # error here; T13 replaces that with a real remote engine (its own
  # dedicated "pbpaste: --files (remote engine)" Describe below, with an
  # opcode-aware fake `nc` that can actually answer F/A). This Describe's
  # fake `nc` only ever answers the `L` manifest fetch, so the one thing
  # worth asserting HERE is the negative: the OLD milestone string is gone.
  # It's since ALSO become a same-shape case of the Mac-side-no-SSH refusal
  # (see the dedicated regression test right below this one) -- still
  # failure, but for the NEW reason, never the old milestone message.
  It 'no longer refuses a manifest from a different host with the old milestone message'
    printf 'x\n' > "$SRC/r.txt"
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.6 "$SRC/r.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh "$SCRIPT" --files "$TARGET"
    The status should be failure
    The stderr should not include "later milestone"
  End

  # Regression: sitting at the Mac (no SSH_* env at all -- this Describe's
  # setup() unsets them) with a manifest whose source_host differs from this
  # machine's own (fake scutil says "mac-mini"; manifest says
  # "some-other-mac") used to fall through to PF_REMOTE's F/A engine anyway
  # -- talking to THIS Mac's own bridge (port 2489) for paths that live on a
  # DIFFERENT host. This Describe's fake `nc` only ever answers the `L`
  # manifest fetch (never F/A), so the old behavior would have produced a
  # per-item bridge/connection failure instead of a clean refusal -- and on
  # a real machine, whenever the remote path happens to also exist locally
  # (the Mac-to-Mac mirror case), it would silently materialize that STALE
  # LOCAL TWIN instead. Assert the exact refusal message, exit 1, and that
  # no SECOND `nc` call (an F/A frame) was ever made -- only the initial `L`
  # manifest fetch appears in the log.
  It 'refuses --files on a remote manifest when sitting at the Mac (no SSH): exact error, exit 1, no F/A frames sent'
    pf="$SHELLSPEC_TMPBASE/payload"
    build_manifest "$pf" file some-other-mac 1752200000.61 "/remote/mirror.txt"
    build_frame O "$pf" "$REPLY_FRAME"

    When run command sh -c '
      sh "$1" --files "$2" >"$3" 2>"$4"
      rc=$?
      [ "$rc" -eq 1 ] || { echo "rc=$rc" >&2; exit 9; }
      exp="pbpaste: manifest lives on some-other-mac -- use pick-clipboard Ctrl-Y to localize it on this Mac"
      got=$(cat "$4")
      [ "$got" = "$exp" ] || { echo "stderr=[$got]" >&2; exit 8; }
      [ -s "$3" ] && { echo "unexpected stdout" >&2; exit 7; }
      lines=$(wc -l < "$5" | tr -d " ")
      [ "$lines" -eq 1 ] || { echo "nclog lines=$lines" >&2; exit 6; }
    ' _ "$SCRIPT" "$TARGET" "$SHELLSPEC_TMPBASE/out61" "$SHELLSPEC_TMPBASE/err61" "$NCLOG"
    The status should be success
  End

  # R-batch Task B amendment: PF_HOST resolves via self_host(), which prefers
  # the pushed $XDG_STATE_HOME/clipboard/self-name identity over
  # scutil/hostname. On an ephemeral-hostname dev-shell, pbcopy stamps
  # manifest rows with that stable self-name -- if pbpaste --files kept
  # resolving the raw (fake-scutil "mac-mini") hostname here, this row would
  # misclassify as REMOTE and, with no SSH env in this Describe, die on the
  # Mac-side refusal above instead of materializing. Success + real bytes in
  # the target + no second nc call (only the one L fetch) proves the row took
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
      printf '%s\037%s\037%s\037' "$kind" "$host" "$ts"
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
      printf '%s\037%s\037%s\037' "$kind" "$host" "$ts"
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
  # further framing -- op_archive_stream's contract: read to EOF).
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
  L) cat "$REPLY_L" ;;
  F) cat "$REPLY_F" ;;
  A) cat "$REPLY_A" ;;
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
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:L:"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:F:"
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
    # `L` fetch happened, never an `F`/`A` call for the conflicting item.
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:L:"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not include ":F:"
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
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include ":F:"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include ":A:"
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

    # Per-path F replies: this test's own nc picks the canned reply by
    # grepping the request payload for the item's basename -- the
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
  L) cat "$SHELLSPEC_TMPBASE/reply.L" ;;
  F)
    if LC_ALL=C grep -q "trunc.txt" "\$raw"; then
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
End
