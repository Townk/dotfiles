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
