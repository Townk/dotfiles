# Tests for the pbcopy shim's over-SSH provenance behavior (spec §23): declare
# origin (O) before delivering OSC 52, and record a local row (P). Bridge calls
# are stubbed by a fake `nc` on PATH that logs opcode + payload.
Describe 'pbcopy: over-SSH provenance'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbcopy"

  setup() {
    export SSH_CONNECTION="x 1 y 22"           # force the over-SSH branch
    export PBCOPY_OSC52_SINK="$SHELLSPEC_TMPBASE/osc52"
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
    # fake nc: record "<port>:<first-byte-opcode>:<payload-tail>" and consume stdin
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
port=\$3
data=\$(cat)
printf '%s:%s\n' "\$port" "\$data" >> "$NCLOG"
EOF
    chmod +x "$BINDIR/nc"
    export PATH="$BINDIR:$PATH"
  }
  BeforeEach 'setup'

  It 'writes the OSC 52 payload to the sink'
    Data 'hello'
    When run command sh "$SCRIPT"
    The status should be success
    The contents of file "$PBCOPY_OSC52_SINK" should include "]52;c;"
  End

  It 'declares origin via an O frame to :2490'
    Data 'hello'
    When run command sh "$SCRIPT"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:O"
  End

  It 'records a local row via a P frame to :2489'
    Data 'hello'
    When run command sh "$SCRIPT"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2489:P"
  End

  # Best-effort/no-hang invariant: if the O/P temp files can't be created, the
  # copy must still deliver OSC 52 and exit success (a local FS failure must not
  # be worse than a down bridge). Stub mktemp to fail ONLY the secondary O/P
  # templates while delegating the primary stdin buffer, so we isolate the guard
  # (pointing TMPDIR at a read-only dir instead would also break the primary
  # buffer, which legitimately must abort since stdin can't be buffered at all).
  It 'still delivers OSC 52 when the O/P temp files cannot be created'
    BINDIR="$SHELLSPEC_TMPBASE/bin"
    cat > "$BINDIR/mktemp" <<'MKEOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *pbcopy-o.*|*pbcopy-p.*) exit 1 ;;
  esac
done
exec /usr/bin/mktemp "$@"
MKEOF
    chmod +x "$BINDIR/mktemp"
    Data 'hello'
    When run command sh "$SCRIPT"
    The status should be success
    The contents of file "$PBCOPY_OSC52_SINK" should include "]52;c;"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should equal ""
  End
End
