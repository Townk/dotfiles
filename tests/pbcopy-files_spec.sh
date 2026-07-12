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
    # carrying the message "boom"; "unknown_opcode" -> an error frame whose
    # payload is EXACTLY "unknown opcode" (rework R7: pbcopy turns that
    # specific payload into an actionable hint instead of relaying it raw).
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
  unknown_opcode) printf 'E\\000\\000\\000\\016unknown opcode' ;;
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

  # Rework R7: an "unknown opcode" E-reply on the LOCAL (:2489) send means
  # THIS machine's own bridge predates file clips -- the bare relayed
  # "pbcopy: unknown opcode" gave no clue that chezmoi needed applying here.
  It 'gives an actionable hint (this machine outdated) when the LOCAL bridge replies unknown opcode'
    f1="$SHELLSPEC_TMPBASE/unknown-local.txt"; touch "$f1"
    export NC_REPLY=unknown_opcode
    When run command sh "$SCRIPT" "$f1"
    The status should be failure
    The stderr should include "this machine's clipboard bridge is outdated"
    The stderr should include "unknown opcode"
    The stderr should include "chezmoi apply"
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

  # Rework R7: an "unknown opcode" E-reply on the REMOTE (:2490/peer) send
  # means the OTHER machine's bridge predates file clips.
  It 'gives an actionable hint (peer bridge outdated) when the manifest push gets unknown opcode'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=1
    export NC_REPLY=unknown_opcode
    f1="$SHELLSPEC_TMPBASE/rem-unknown.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be failure
    The stderr should include "peer bridge doesn't support file clips yet"
    The stderr should include "unknown opcode"
    The stderr should include "update chezmoi on the other machine"
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

# `pbcopy --content <file>` (M3, files-yazi design): puts the file's raw
# BYTES on the clipboard under a detected UTI via bridge op `C` (copy-rich).
# Unlike the U/N tests above (which only ever carry NUL-joined path TEXT and
# so can fold NULs to "|" for readable log assertions), op C's payload is
# itself binary (a 2-byte length + a blob that can hold arbitrary bytes,
# including NULs) -- so this fake `nc` captures the exact, untranslated
# frame to a side file and the tests below parse it byte-for-byte with
# od/head/tail instead of string-matching a translated log.
Describe 'pbcopy: --content rich-UTI mode'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbcopy"
  NCRAW="" # set in setup(), below

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    export PBCOPY_OSC52_SINK="$SHELLSPEC_TMPBASE/osc52"
    BINDIR="$SHELLSPEC_TMPBASE/bin-content"; mkdir -p "$BINDIR"
    NCLOG="$SHELLSPEC_TMPBASE/nclog-content"; : > "$NCLOG"
    NCRAW="$SHELLSPEC_TMPBASE/ncraw-content"; rm -f "$NCRAW"
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
# Probe form (SSH+bridge branch): "nc -z -w1 127.0.0.1 <port>", no stdin.
if [ "\$1" = "-z" ]; then
  [ "\${NC_BRIDGE_UP:-1}" = "1" ] && exit 0 || exit 1
fi
port=\$3
cat > "$NCRAW"
# A separate translated text log, just for the cheap "which port/opcode,
# was a frame sent at all" assertions -- same "\\0 -> |" trick as the
# U/N fake, safe here because only the log (never \$NCRAW) is compared as
# text.
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "$NCRAW"; printf '\\n'; } >> "$NCLOG"
case "\${NC_REPLY:-ok}" in
  err) printf 'E\\000\\000\\000\\004boom' ;;
  unknown_opcode) printf 'E\\000\\000\\000\\016unknown opcode' ;;
  *) printf 'O\\000\\000\\000\\000' ;;
esac
EOF
    chmod +x "$BINDIR/nc"
    export PATH="$BINDIR:$PATH"
  }
  BeforeEach 'setup'

  # od -An -tu1 -j <0-based offset> -N 1 <file> -> decimal value of that byte.
  byte_val() {
    od -An -tu1 -j "$2" -N 1 "$1" | tr -d ' \n'
  }

  # Splits $NCRAW (a raw <opcode><BE32 len><BE16 uti_len><uti><blob> frame)
  # apart and writes the uti to $1-uti and the blob to $1-blob, both as real
  # files -- so callers can assert on them with ordinary shellspec file
  # matchers (uti) or a binary-safe `cmp` (blob), never a shell string that
  # would choke on embedded NULs.
  split_frame() {
    _out=$1
    _b1=$(byte_val "$NCRAW" 5)
    _b2=$(byte_val "$NCRAW" 6)
    _uti_len=$((_b1 * 256 + _b2))
    tail -c +8 "$NCRAW" | head -c "$_uti_len" > "${_out}-uti"
    tail -c +"$((8 + _uti_len))" "$NCRAW" > "${_out}-blob"
  }

  It 'sends a C frame to :2489 carrying the exact uti and byte-identical (NUL-containing) blob'
    fixture="$SHELLSPEC_TMPBASE/blob.png"
    printf 'PNG\000HEADER\000MORE\000DATA' > "$fixture"
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be success
    The contents of file "$NCLOG" should include "2489:C"
    split_frame "$SHELLSPEC_TMPBASE/got"
    The contents of file "$SHELLSPEC_TMPBASE/got-uti" should equal "public.png"
    cmp -s "$SHELLSPEC_TMPBASE/got-blob" "$fixture" && echo same > "$SHELLSPEC_TMPBASE/blobcmp" || echo diff > "$SHELLSPEC_TMPBASE/blobcmp"
    The contents of file "$SHELLSPEC_TMPBASE/blobcmp" should equal "same"
  End

  It 'infers public.png from a .png extension'
    fixture="$SHELLSPEC_TMPBASE/pic.png"; touch "$fixture"
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be success
    split_frame "$SHELLSPEC_TMPBASE/got2"
    The contents of file "$SHELLSPEC_TMPBASE/got2-uti" should equal "public.png"
  End

  It 'infers com.adobe.pdf from a .pdf extension'
    fixture="$SHELLSPEC_TMPBASE/doc.pdf"; touch "$fixture"
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be success
    split_frame "$SHELLSPEC_TMPBASE/got3"
    The contents of file "$SHELLSPEC_TMPBASE/got3-uti" should equal "com.adobe.pdf"
  End

  It 'falls back to `file --mime-type -b` for an extensionless file'
    fixture="$SHELLSPEC_TMPBASE/mimetext"
    printf 'hello world\n' > "$fixture"
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be success
    split_frame "$SHELLSPEC_TMPBASE/got4"
    The contents of file "$SHELLSPEC_TMPBASE/got4-uti" should equal "public.utf8-plain-text"
  End

  It 'errors with the exact "cannot infer UTI" message and exit 1 for an unrecognized type'
    fixture="$SHELLSPEC_TMPBASE/weird.xyz"
    printf '\001\002\003\004' > "$fixture"
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be failure
    The stderr should equal "pbcopy: cannot infer UTI for $fixture"
    The contents of file "$NCLOG" should equal ""
  End

  It 'exits 1 naming a missing file, without contacting the bridge'
    missing="$SHELLSPEC_TMPBASE/does-not-exist-content.png"
    When run command sh "$SCRIPT" --content "$missing"
    The status should be failure
    The stderr should include "$missing"
    The contents of file "$NCLOG" should equal ""
  End

  It 'errors when given zero files'
    When run command sh "$SCRIPT" --content
    The status should be failure
    The stderr should include "--content"
  End

  It 'errors when given more than one file'
    f1="$SHELLSPEC_TMPBASE/multi-a.png"; touch "$f1"
    f2="$SHELLSPEC_TMPBASE/multi-b.png"; touch "$f2"
    When run command sh "$SCRIPT" --content "$f1" "$f2"
    The status should be failure
    The stderr should include "--content"
  End

  It 'fails loudly when the bridge replies with an E status'
    fixture="$SHELLSPEC_TMPBASE/err.png"; touch "$fixture"
    export NC_REPLY=err
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be failure
    The stderr should include "boom"
  End

  # Rework R7: an "unknown opcode" E-reply on --content's LOCAL (:2489)
  # send means THIS machine's own bridge predates rich-type/file clips.
  It 'gives an actionable hint (this machine outdated) when the LOCAL bridge replies unknown opcode'
    fixture="$SHELLSPEC_TMPBASE/unknown-local.png"; touch "$fixture"
    export NC_REPLY=unknown_opcode
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be failure
    The stderr should include "this machine's clipboard bridge is outdated"
    The stderr should include "unknown opcode"
    The stderr should include "chezmoi apply"
  End

  # Over SSH + reverse-bridge-up: same `C` op, but to the reverse-tunneled
  # peer bridge (port 2490 / CLIPBOARD_BRIDGE_PORT) instead of 2489 -- OSC 52
  # is text-only and can't carry rich types any more than it can carry files.
  It 'sends a C frame to :2490 when SSH+bridge-up'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=1
    fixture="$SHELLSPEC_TMPBASE/rem.png"; touch "$fixture"
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be success
    The contents of file "$NCLOG" should include "2490:C"
  End

  It 'honors CLIPBOARD_BRIDGE_PORT for the SSH+content probe and frame'
    export SSH_CONNECTION="x 1 y 22"
    export CLIPBOARD_BRIDGE_PORT=9999
    export NC_BRIDGE_UP=1
    fixture="$SHELLSPEC_TMPBASE/rem-port.png"; touch "$fixture"
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be success
    The contents of file "$NCLOG" should include "9999:C"
  End

  It 'errors with the reverse-bridge message when no bridge is up, without sending a frame'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=0
    fixture="$SHELLSPEC_TMPBASE/rem-nobridge.png"; touch "$fixture"
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be failure
    The stderr should include "pbcopy: --content needs the reverse bridge (OSC 52 cannot carry rich types)"
    The contents of file "$NCLOG" should equal ""
  End

  # Rework R7: an "unknown opcode" E-reply on --content's REMOTE (:2490/peer)
  # send means the OTHER machine's bridge predates rich-type/file clips.
  It 'gives an actionable hint (peer bridge outdated) when the REMOTE bridge replies unknown opcode'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=1
    export NC_REPLY=unknown_opcode
    fixture="$SHELLSPEC_TMPBASE/rem-unknown.png"; touch "$fixture"
    When run command sh "$SCRIPT" --content "$fixture"
    The status should be failure
    The stderr should include "peer bridge doesn't support file clips yet"
    The stderr should include "unknown opcode"
    The stderr should include "update chezmoi on the other machine"
  End
End
