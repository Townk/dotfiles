# Tests for pbcopy's file-object mode (files-yazi design §5, spec
# docs/superpowers/specs/2026-07-11-clipboard-phase6-files-yazi-design.md):
# `pbcopy <path>...` puts a real file clip on the pasteboard via bridge op
# `U`, instead of reading stdin. Bridge calls are stubbed by a fake `nc` on
# PATH that logs "<port>:<frame-with-NUL-as-|>" and replies with a status
# frame, so pbcopy's reply-checking branch can be exercised both ways.
Describe 'pbcopy: file-object mode'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbcopy"

  setup() {
    # Force the local (non-SSH) branch regardless of the ambient shell.
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    export PBCOPY_OSC52_SINK="$SHELLSPEC_TMPBASE/osc52"
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    NCLOG="$SHELLSPEC_TMPBASE/nclog"; : > "$NCLOG"
    # Fake nc: capture the raw framed request verbatim to a side file (a
    # shell variable would silently truncate at the first NUL byte, and the
    # U payload is NUL-joined paths), then log "<port>:<frame with NUL ->
    # '|'>" -- safe to compare via shellspec's string matchers. Replies per
    # $NC_REPLY: "ok" (default) -> success frame; "err" -> error frame
    # carrying the message "boom".
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
# Probe form used by the SSH+bridge branch: "nc -z -w1 127.0.0.1 <port>",
# no stdin. \$NC_BRIDGE_UP ("1" default, or "0") controls the exit status;
# never logged -- tests asserting "no frame was sent" only care about real
# frame-carrying invocations below.
if [ "\$1" = "-z" ]; then
  [ "\${NC_BRIDGE_UP:-1}" = "1" ] && exit 0 || exit 1
fi
port=\$3
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
# LC_ALL=C: BSD tr under a UTF-8 locale raises "Illegal byte sequence" on
# arbitrary binary bytes (confirmed empirically -- e.g. byte 0x9b, a length
# byte in the U frame, isn't a valid UTF-8 lead byte) and silently truncates
# its output right there; force byte-oriented translation instead.
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
case "\${NC_REPLY:-ok}" in
  err) printf 'E\\000\\000\\000\\004boom' ;;
  *) printf 'O\\000\\000\\000\\000' ;;
esac
EOF
    chmod +x "$BINDIR/nc"
    export PATH="$BINDIR:$PATH"
  }
  BeforeEach 'setup'

  It 'sends a U frame to :2489 with the NUL-joined absolute paths'
    f1="$SHELLSPEC_TMPBASE/a.txt"; touch "$f1"
    f2="$SHELLSPEC_TMPBASE/b.txt"; touch "$f2"
    # Expected canonical form: pbcopy resolves symlinks (pwd -P), and
    # $SHELLSPEC_TMPBASE itself sits under a symlinked macOS path
    # (/var -> /private/var), so compare against the same canonicalization
    # rather than the raw input paths.
    cf1=$(cd "$(dirname "$f1")" && pwd -P)/$(basename "$f1")
    cf2=$(cd "$(dirname "$f2")" && pwd -P)/$(basename "$f2")
    When run command sh "$SCRIPT" "$f1" "$f2"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2489:U"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "$cf1|$cf2"
  End

  It 'canonicalizes a relative path to an absolute one before sending'
    f1="$SHELLSPEC_TMPBASE/rel.txt"; touch "$f1"
    cf1=$(cd "$(dirname "$f1")" && pwd -P)/$(basename "$f1")
    When run command sh -c 'cd "$1" && sh "$2" rel.txt' _ "$SHELLSPEC_TMPBASE" "$SCRIPT"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "$cf1"
  End

  It 'exits 0 when the bridge replies with an O status'
    f1="$SHELLSPEC_TMPBASE/ok.txt"; touch "$f1"
    NC_REPLY=ok
    When run command sh "$SCRIPT" "$f1"
    The status should be success
  End

  It 'fails loudly (exit 1, message to stderr) when the bridge replies with an E status'
    f1="$SHELLSPEC_TMPBASE/err.txt"; touch "$f1"
    export NC_REPLY=err
    When run command sh "$SCRIPT" "$f1"
    The status should be failure
    The stderr should include "boom"
  End

  It 'exits 1 naming a missing path, without contacting the bridge'
    f1="$SHELLSPEC_TMPBASE/exists.txt"; touch "$f1"
    missing="$SHELLSPEC_TMPBASE/does-not-exist.txt"
    When run command sh "$SCRIPT" "$f1" "$missing"
    The status should be failure
    The stderr should include "$missing"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should equal ""
  End

  # Regression: send_frame's reply-capturing branch used to have no `|| true`,
  # so a hard nc failure (connection refused, or nc missing entirely) tripped
  # `set -e` and killed the script on the spot -- exit 1, but silently, with
  # no message. A failing fake nc (distinct from the reply-frame fakes above,
  # which always succeed as processes and only vary their emitted bytes)
  # reproduces that transport-level failure.
  It 'fails with a message (not a silent set -e death) when nc itself fails'
    f1="$SHELLSPEC_TMPBASE/nc-fails.txt"; touch "$f1"
    cat > "$BINDIR/nc" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$BINDIR/nc"
    When run command sh "$SCRIPT" "$f1"
    The status should be failure
    The stderr should include "bridge"
  End

  # Over SSH + reverse-bridge-up (files-yazi design §5, T11): pbcopy pushes a
  # manifest via op `N` instead of the local `U` -- OSC 52 cannot carry files
  # at all, so this is the only path. Host field: replicate pbcopy's own
  # scutil-then-hostname fallback here rather than stubbing either, so the
  # assertion tracks whatever this machine actually resolves to.
  It 'sends an N frame to :2490 with this host and the NUL-joined absolute paths (bridge up)'
    export SSH_CONNECTION="x 1 y 22"
    expected_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null)
    f1="$SHELLSPEC_TMPBASE/rem-a.txt"; touch "$f1"
    f2="$SHELLSPEC_TMPBASE/rem-b.txt"; touch "$f2"
    cf1=$(cd "$(dirname "$f1")" && pwd -P)/$(basename "$f1")
    cf2=$(cd "$(dirname "$f2")" && pwd -P)/$(basename "$f2")
    export NC_BRIDGE_UP=1
    When run command sh "$SCRIPT" "$f1" "$f2"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:N"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "$expected_host"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "$cf1|$cf2"
  End

  It 'honors CLIPBOARD_BRIDGE_PORT for the SSH+files probe and frame'
    export SSH_CONNECTION="x 1 y 22"
    export CLIPBOARD_BRIDGE_PORT=9999
    export NC_BRIDGE_UP=1
    f1="$SHELLSPEC_TMPBASE/rem-port.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "9999:N"
  End

  It 'exits 0 when the manifest push gets an O reply'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=1
    export NC_REPLY=ok
    f1="$SHELLSPEC_TMPBASE/rem-ok.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
  End

  It 'fails loudly when the manifest push gets an E reply'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=1
    export NC_REPLY=err
    f1="$SHELLSPEC_TMPBASE/rem-err.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be failure
    The stderr should include "boom"
  End

  It 'errors with the reverse-bridge message when no bridge is up, without sending a frame'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=0
    f1="$SHELLSPEC_TMPBASE/rem-nobridge.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be failure
    The stderr should include "pbcopy: file clips need the reverse bridge (OSC 52 cannot carry files)"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should equal ""
  End

  It 'exits 1 naming a missing path over SSH with the bridge up, without sending a frame'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=1
    f1="$SHELLSPEC_TMPBASE/rem-exists.txt"; touch "$f1"
    missing="$SHELLSPEC_TMPBASE/rem-missing.txt"
    When run command sh "$SCRIPT" "$f1" "$missing"
    The status should be failure
    The stderr should include "$missing"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should equal ""
  End

  It 'never touches the bridge when called with no args'
    sentinel="pbcopy-no-arg-sentinel-$$"
    Data "$sentinel"
    When run command sh "$SCRIPT"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should equal ""
  End

  # Confirms the no-arg path still genuinely reaches the real platform tool
  # (not just "didn't touch the bridge"): round-trip through the actual
  # macOS pasteboard via the absolute /usr/bin/pbcopy + /usr/bin/pbpaste
  # (unaffected by our PATH stubbing, which only adds a fake nc).
  It 'still delivers stdin to the real system clipboard when called with no args'
    sentinel="pbcopy-roundtrip-sentinel-$$"
    Data "$sentinel"
    When run command sh -c 'sh "$1" && /usr/bin/pbpaste' _ "$SCRIPT"
    The status should be success
    The output should include "$sentinel"
  End
End
