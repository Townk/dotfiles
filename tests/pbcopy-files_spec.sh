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
    # Hermetic self_host() resolution: a fresh sandbox with no clipboard/
    # self-name file, so every example (unless it opts in below) exercises
    # self_host()'s scutil/hostname fallback rather than risking a stray real
    # self-name file on the machine actually running this suite.
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/xdg-state-default"
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    # A prior example may have stubbed `uname` (store-less-platform tests
    # below) -- always start from the real one so unrelated examples keep
    # seeing the ACTUAL platform (Darwin, in this suite's own CI/dev
    # environment).
    rm -f "$BINDIR/uname"
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

  # X2-redo (supersedes X2 below); Fix A (supersedes the N-based peer push
  # described by X2-redo): a file copied over SSH belongs to the machine
  # whose bytes it is -- pbcopy records a LOCAL origin clip as the PRIMARY
  # action, then best-effort pushes a peer manifest so the far side can pull
  # lazily (§12's lazy rule: the peer only gets a manifest POINTER,
  # materialized on Ctrl-Y). Both sends are now op `M` (manifest-persist-
  # local), RECORD-ONLY on both ends: the origin machine is typically
  # locked/headless when reached over SSH, where the Hammerspoon watcher's
  # loginwindow guard skips ALL capture -- so a plain `U` (which only sets
  # the pasteboard, relying on the watcher to capture it) never actually
  # lands a store row there (live-confirmed). Fix A: the peer send used to be
  # op `N` (push-manifest), which ALSO set the PEER's pasteboard to the
  # paths as plain TEXT -- reflected back and shown as a confusing "remote
  # text" twin on the origin's own TUI picker. `M` never touches ANY
  # pasteboard, on either end. Host field: replicate pbcopy's own
  # scutil-then-hostname fallback here rather than stubbing either, so the
  # assertion tracks whatever this machine actually resolves to.
  It 'sends an M frame to BOTH :2489 (local origin record) and :2490 (peer manifest), in that order, and never a U or N frame'
    export SSH_CONNECTION="x 1 y 22"
    expected_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null)
    f1="$SHELLSPEC_TMPBASE/rem-a.txt"; touch "$f1"
    f2="$SHELLSPEC_TMPBASE/rem-b.txt"; touch "$f2"
    cf1=$(cd "$(dirname "$f1")" && pwd -P)/$(basename "$f1")
    cf2=$(cd "$(dirname "$f2")" && pwd -P)/$(basename "$f2")
    export NC_BRIDGE_UP=1
    When run command sh "$SCRIPT" "$f1" "$f2"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2489:M"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2490:M"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "$expected_host"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "$cf1|$cf2"
    # Order matters: the local M (origin record, primary) must precede the
    # peer M (best-effort secondary) in the log.
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should match pattern "*2489:M*2490:M*"
    # The bug this whole rework exists to fix: no `U` frame is sent anymore
    # (it set the pasteboard and relied on a watcher that can't see a
    # locked/headless origin over SSH).
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not include "2489:U"
    # Fix A: no `N` frame is sent anymore either -- it set the PEER's
    # pasteboard to the paths as text, which is exactly the reflected
    # "remote text" twin this fix exists to stop.
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not match pattern "*:N*"
  End

  It 'honors CLIPBOARD_BRIDGE_PORT for the SSH+files probe and frame'
    export SSH_CONNECTION="x 1 y 22"
    export CLIPBOARD_BRIDGE_PORT=9999
    export NC_BRIDGE_UP=1
    f1="$SHELLSPEC_TMPBASE/rem-port.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "9999:M"
  End

  It 'exits 0 when the manifest push gets an O reply'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=1
    export NC_REPLY=ok
    f1="$SHELLSPEC_TMPBASE/rem-ok.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
  End

  # X2-redo: the local M (primary action) already succeeded by the time the
  # peer M is attempted, so a peer-side error is now a WARNING, never a
  # command failure. Needs a port-differentiated fake nc: 2489 (local M) must
  # reply O so the primary action truly succeeds, while 2490 (peer M) replies
  # E -- the shared setup() fake nc can't express that since NC_REPLY isn't
  # port-scoped.
  It 'warns (not fails) when the manifest push gets an E reply -- the local origin record already succeeded'
    export SSH_CONNECTION="x 1 y 22"
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
if [ "\$1" = "-z" ]; then
  exit 0
fi
port=\$3
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
if [ "\$port" = "2489" ]; then
  printf 'O\\000\\000\\000\\000'
else
  printf 'E\\000\\000\\000\\004boom'
fi
EOF
    chmod +x "$BINDIR/nc"
    f1="$SHELLSPEC_TMPBASE/rem-err.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
    The stderr should include "boom"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2489:M"
  End

  # Rework R7 (still true under X2-redo): an "unknown opcode" E-reply on the
  # REMOTE (:2490/peer) send means the OTHER machine's bridge predates file
  # clips -- but that's only a warning, since the local M already recorded
  # the origin clip. Same port-differentiated fake nc as above.
  It 'gives an actionable hint (peer bridge outdated) when the manifest push gets unknown opcode, but still exits 0'
    export SSH_CONNECTION="x 1 y 22"
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
if [ "\$1" = "-z" ]; then
  exit 0
fi
port=\$3
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
if [ "\$port" = "2489" ]; then
  printf 'O\\000\\000\\000\\000'
else
  printf 'E\\000\\000\\000\\016unknown opcode'
fi
EOF
    chmod +x "$BINDIR/nc"
    f1="$SHELLSPEC_TMPBASE/rem-unknown.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
    The stderr should include "peer bridge doesn't support file clips yet"
    The stderr should include "unknown opcode"
    The stderr should include "update chezmoi on the other machine"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2489:M"
  End

  # X2-redo: a down reverse bridge no longer fails the command -- the local
  # origin record (M to 2489) is the primary action and still lands; only
  # the peer notification (N to 2490) is skipped, with a warning naming why.
  It 'still records the local origin clip and warns (exit 0) when the peer bridge (2490) is down'
    export SSH_CONNECTION="x 1 y 22"
    export NC_BRIDGE_UP=0
    f1="$SHELLSPEC_TMPBASE/rem-nobridge.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
    The stderr should include "peer"
    The stderr should include "not notified"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "2489:M"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not include "2490:M"
  End

  # X2-redo: this machine's OWN bridge (2489) is the primary action -- if
  # IT is unreachable, that's a hard error (there is no local-tool fallback
  # for a file clip), regardless of the peer bridge's state.
  It 'hard-errors (exit 1) when this machine'"'"'s own bridge (2489) is unreachable'
    export SSH_CONNECTION="x 1 y 22"
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
if [ "\$1" = "-z" ]; then
  exit 0
fi
port=\$3
if [ "\$port" = "2489" ]; then
  cat > /dev/null
  exit 1
fi
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
printf 'O\\000\\000\\000\\000'
EOF
    chmod +x "$BINDIR/nc"
    f1="$SHELLSPEC_TMPBASE/rem-local-down.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be failure
    The stderr should include "this machine's own clipboard bridge"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should equal ""
  End

  # Phase 7: the store-less interim (peer push promoted to primary on
  # non-Darwin) is retired -- every platform now has its own bridge/store, so
  # an unreachable local M is an unconditional hard fail on Linux exactly
  # like it always was on Darwin, and the peer is never even contacted.
  It 'hard-fails (exit 1) on Linux too when the local bridge is unreachable -- interim retired, no peer push'
    export SSH_CONNECTION="x 1 y 22"
    cat > "$BINDIR/uname" <<'EOF'
#!/bin/sh
echo Linux
EOF
    chmod +x "$BINDIR/uname"
    cat > "$BINDIR/nc" <<EOF
#!/bin/sh
if [ "\$1" = "-z" ]; then
  exit 0
fi
port=\$3
if [ "\$port" = "2489" ]; then
  cat > /dev/null
  exit 1
fi
raw="$SHELLSPEC_TMPBASE/nc-raw.\$\$"
cat > "\$raw"
{ printf '%s:' "\$port"; LC_ALL=C tr '\\0' '|' < "\$raw"; printf '\\n'; } >> "$NCLOG"
rm -f "\$raw"
printf 'O\\000\\000\\000\\000'
EOF
    chmod +x "$BINDIR/nc"
    f1="$SHELLSPEC_TMPBASE/storeless-ok.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be failure
    The stderr should include "this machine's own clipboard bridge is not reachable on 127.0.0.1:2489"
    The stderr should not include "Phase 7 pending"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not include "2490:M"
  End

  # Same Linux platform, peer ALSO unreachable: outcome is identical to the
  # peer-up case above -- the peer is never contacted once the local bridge
  # is confirmed unreachable, so its own state can't change the verdict.
  It 'hard-fails (exit 1) on Linux when both the local bridge and the peer are down, peer still uncontacted'
    export SSH_CONNECTION="x 1 y 22"
    cat > "$BINDIR/uname" <<'EOF'
#!/bin/sh
echo Linux
EOF
    chmod +x "$BINDIR/uname"
    cat > "$BINDIR/nc" <<'EOF'
#!/bin/sh
if [ "$1" = "-z" ]; then
  exit 1
fi
cat > /dev/null
exit 1
EOF
    chmod +x "$BINDIR/nc"
    f1="$SHELLSPEC_TMPBASE/storeless-bothdown.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be failure
    The stderr should include "this machine's own clipboard bridge is not reachable on 127.0.0.1:2489"
    The stderr should not include "no local clipboard store"
    The stderr should not include "reverse bridge down"
  End

  # R-batch Task B amendment: ephemeral-hostname boxes (e.g. this dev-shell's
  # own cloud hostname, which changes daily) can't rely on scutil/hostname -s
  # for a STABLE identity matching the mount key the sit-at machine's
  # peer-hostname front matter expects. ssh-prepare-connection's step_mount
  # pushes a self-name file into $XDG_STATE_HOME/clipboard at connect time;
  # self_host() prefers it when present and safely shaped.
  It 'uses the self-name identity file for the M host field when present and safely shaped'
    export SSH_CONNECTION="x 1 y 22"
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/xdg-state-good"
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf 'stable-devshell' > "$XDG_STATE_HOME/clipboard/self-name"
    f1="$SHELLSPEC_TMPBASE/selfname-a.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "stable-devshell"
  End

  # Defense in depth: this file sits on a shared dev box and could be stale,
  # hand-edited, or malicious -- it becomes both an M-row host field and (on
  # whichever machine reads it back as a peer) a mount-key/ssh target, so an
  # unsafe shape must fall back to the real hostname resolution rather than
  # being trusted verbatim.
  It 'falls back to the real hostname when the self-name file has an unsafe shape'
    export SSH_CONNECTION="x 1 y 22"
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/xdg-state-evil"
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf '* evil' > "$XDG_STATE_HOME/clipboard/self-name"
    expected_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null)
    f1="$SHELLSPEC_TMPBASE/selfname-b.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "$expected_host"
  End

  # Regression (review Critical): the `* evil` fixture above only exercises
  # FIRST-character rejection. In POSIX `case` syntax the naive positive
  # pattern [A-Za-z0-9][A-Za-z0-9.-]* anchors only the first TWO characters
  # (`*` is a wildcard, not zsh's `#` quantifier) -- so a value with a safe
  # prefix and a shell-metacharacter TAIL sailed straight through it.
  # self_host() must reject any disallowed character ANYWHERE in the value.
  It 'falls back to the real hostname when the self-name file smuggles a mid-string injection after a safe prefix'
    export SSH_CONNECTION="x 1 y 22"
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/xdg-state-midevil"
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf 'cruise; rm -rf /tmp' > "$XDG_STATE_HOME/clipboard/self-name"
    expected_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null)
    f1="$SHELLSPEC_TMPBASE/selfname-c.txt"; touch "$f1"
    When run command sh "$SCRIPT" "$f1"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should include "$expected_host"
    The contents of file "$SHELLSPEC_TMPBASE/nclog" should not include "rm -rf"
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

Describe 'pbcopy file mode: Phase 7 -- local M is the unconditional primary'
  PBCOPY="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbcopy"

  setup() {
    STUBS="$SHELLSPEC_TMPBASE/stubs"; mkdir -p "$STUBS"
    export PATH="$STUBS:$PATH"
    export SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"
    touch "$SHELLSPEC_TMPBASE/afile"
    # uname stub: pretend we are the dev-shell
    printf '#!/bin/sh\necho Linux\n' > "$STUBS/uname"; chmod +x "$STUBS/uname"
    # nc stub: EVERY endpoint down (probe -z fails, sends produce no reply)
    printf '#!/bin/sh\nexit 1\n' > "$STUBS/nc"; chmod +x "$STUBS/nc"
    # systemctl stub: record the kick, still report failure to start
    printf '#!/bin/sh\necho "$@" >> "%s/systemctl.log"\nexit 0\n' "$SHELLSPEC_TMPBASE" > "$STUBS/systemctl"
    chmod +x "$STUBS/systemctl"
  }
  BeforeEach 'setup'

  It 'hard-fails on unreachable local bridge even on Linux (interim retired)'
    When run command sh "$PBCOPY" "$SHELLSPEC_TMPBASE/afile"
    The status should equal 1
    The stderr should include "not reachable on 127.0.0.1:2489"
    The stderr should not include "Phase 7 pending"
  End

  It 'kicks the systemd socket before giving up on Linux'
    When run command sh "$PBCOPY" "$SHELLSPEC_TMPBASE/afile"
    The status should equal 1
    The stderr should include "not reachable on 127.0.0.1:2489"
    The contents of file "$SHELLSPEC_TMPBASE/systemctl.log" should include "--user start clipboard-bridge.socket"
  End
End

Describe 'pbcopy local text mode: Phase 7 store fallback'
  PBCOPY="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_pbcopy"

  setup() {
    STUBS="$SHELLSPEC_TMPBASE/stubs"; mkdir -p "$STUBS"
    # Restricted PATH, not prepend: a brew-installed xclip/wl-copy in
    # /opt/homebrew/bin would otherwise win the command -v probes and skip
    # the bridge branch under test.
    export PATH="$STUBS:/usr/bin:/bin"
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    # Defeat the Darwin absolute-path branch on the Mac running this suite
    # (test seam, same class as PBCOPY_OSC52_SINK).
    export PBCOPY_DARWIN_BIN=/nonexistent
    printf '#!/bin/sh\necho Linux\n' > "$STUBS/uname"; chmod +x "$STUBS/uname"
    # nc stub: -z probe up; a framed T send gets an O reply and records the
    # request bytes for inspection.
    cat > "$STUBS/nc" <<EOF
#!/bin/sh
case "\$1" in
  -z) exit 0 ;;
esac
cat > "$SHELLSPEC_TMPBASE/nc-request.bin"
printf 'O\\000\\000\\000\\000'
EOF
    chmod +x "$STUBS/nc"
  }
  BeforeEach 'setup'

  It 'falls back to op T against the local bridge when no display tool exists'
    When run command sh -c 'printf hello | sh "$1"' _ "$PBCOPY"
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/nc-request.bin" should start with "T"
    The contents of file "$SHELLSPEC_TMPBASE/nc-request.bin" should include "vhello"
  End
End
