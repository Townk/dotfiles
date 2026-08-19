# Tests for the copy client's file-object and rich-type modes, against the REAL
# listener in recording mode (spec §11.1) rather than a fake `nc`.
#
# `pbcopy <path>...` and `pbcopy --content <file>` are now `system-clip copy`
# with the same flags. What the conversion changed, beyond the transport:
#
#   * The single-letter opcodes are gone (§6.1). `U` is `clip.set.files`, `M` is
#     `store.persist.files`, `C` is `clip.set.rich`; `N` and the declare-origin
#     `O` were already retired, and §6.2 explains why provenance stopped needing
#     a frame of its own.
#   * Errors are codes, not strings a client greps (§8 rule 3, §10). The old
#     `unknown opcode` reply became `unknown-op`, and with it went the client's
#     "this machine's bridge is outdated / run chezmoi apply" hints: branching on
#     message text is exactly what §8 rule 3 forbids, so the code is surfaced and
#     the operator reads it. The examples below assert the code reaches stderr.
#   * `nc` failing is now the client's own connect failing, which reports the
#     socket it could not reach instead of dying silently under `set -e`.
#
# The exit-code contract for file mode over SSH is unchanged and is the reason
# this file exists: the LOCAL record is the primary action and fails loudly, the
# peer push is a courtesy that only ever warns.
#
# ASSERTION SHAPE. Every example runs the client and prints what it wants to
# check from inside one function, then asserts on that function's output. Two
# reasons, both practical: the client's own exit status has to be printed INTO
# that output (the assertion function's status is its last command's, not the
# client's), and one combined subject reports every wrong field in a single
# message instead of one per run. The helper's accessors index operations and
# skip the per-connection `hello` line, so `recob_op 1` is the first real
# operation however many connections the client opened.

Describe 'copy: file mode at the machine'
  Include tests/recob_helper.sh

  setup() {
    # The ambient shell may itself be an SSH session; the local branch is only
    # reachable with all three variables clear.
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    recob_start
    CLIENT="$(recob_client_bin)"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  It 'sends clip.set.files over the trusted socket with NUL-joined absolute paths'
    f1="$SHELLSPEC_TMPBASE/a.txt"; touch "$f1"
    f2="$SHELLSPEC_TMPBASE/b.txt"; touch "$f2"
    # The client resolves the parent and keeps the leaf as named, and
    # $SHELLSPEC_TMPBASE sits under a symlinked macOS path (/var -> /private/var),
    # so the expectation is canonicalized the same way rather than taken raw.
    cf1=$(cd "$(dirname "$f1")" && pwd -P)/$(basename "$f1")
    cf2=$(cd "$(dirname "$f2")" && pwd -P)/$(basename "$f2")
    files_frame() {
      "$CLIENT" copy "$f1" "$f2"
      printf 'exit=%s|%s|%s|' "$?" "$(recob_op 1)" "$(recob_endpoint 1)"
      # The separator is a real NUL on the wire; folding it late keeps the
      # payload byte-exact right up to the comparison.
      recob_field 1 paths | tr '\0' '@'
    }
    When call files_frame
    The output should equal "exit=0|clip.set.files|trusted|$cf1@$cf2"
  End

  It 'canonicalizes a relative path to an absolute one before sending'
    f1="$SHELLSPEC_TMPBASE/rel.txt"; touch "$f1"
    cf1=$(cd "$SHELLSPEC_TMPBASE" && pwd -P)/rel.txt
    relative() {
      cd "$SHELLSPEC_TMPBASE" || return 1
      "$CLIENT" copy rel.txt
      printf 'exit=%s|' "$?"
      recob_field 1 paths
    }
    When call relative
    The output should equal "exit=0|$cf1"
  End

  It 'exits 0 when the bridge accepts the file clip'
    f1="$SHELLSPEC_TMPBASE/ok.txt"; touch "$f1"
    accepted() { "$CLIENT" copy "$f1"; }
    When call accepted
    The status should be success
  End

  # 6c: the sitting machine's pointer push. With a session open TO a peer,
  # the 2491 LocalForward answers — here stood in by the recorder's own
  # public port — and a local file copy mirrors its manifest there,
  # pointer-only, after the local clip.set.files. The recorder plays both
  # machines (same caveat as the over-SSH Describe below); the script is
  # re-read per connection, so one `ok` answers both exchanges.
  It 'pushes the pointer to the visited peer after the local set'
    f1="$SHELLSPEC_TMPBASE/vis.txt"; touch "$f1"
    visited() {
      recob_script 'ok'
      CLIPBOARD_BRIDGE_VISITED_PORT="$CLIPBOARD_BRIDGE_PORT" "$CLIENT" copy "$f1"
      printf 'exit=%s|ops=%s|%s,%s|host=%s|' "$?" "$(recob_count)" \
        "$(recob_endpoint 1)" "$(recob_endpoint 2)" "$(recob_field 2 host)"
      recob_ops | tr '\n' ','
    }
    When call visited
    The output should equal \
      "exit=0|ops=2|trusted,public|host=recob-spec-host|clip.set.files,store.persist.files,"
  End

  It 'stays purely local when nothing listens on the visited port'
    f1="$SHELLSPEC_TMPBASE/solo.txt"; touch "$f1"
    solo() {
      "$CLIENT" copy "$f1"
      printf 'exit=%s|ops=%s|' "$?" "$(recob_count)"
      recob_ops | tr '\n' ','
    }
    When call solo
    The output should equal "exit=0|ops=1|clip.set.files,"
  End

  # No local-tool fallback exists for a file clip, so the reply is the whole
  # verdict: a refusing bridge must fail the command rather than be shrugged off.
  It 'fails loudly (exit 1, message to stderr) when the bridge answers with an error'
    f1="$SHELLSPEC_TMPBASE/err.txt"; touch "$f1"
    refused() { recob_script 'err internal boom'; "$CLIENT" copy "$f1"; }
    When call refused
    The status should eq 1
    The stderr should include 'boom'
  End

  # §10: the old `unknown opcode` payload is the `unknown-op` CODE now, and §8
  # rule 3 forbids the client from branching on message text — so the hint the
  # shim used to synthesize ("this machine's bridge is outdated, run chezmoi
  # apply") is gone by design. What must survive is that the code itself reaches
  # the operator instead of being swallowed.
  It 'surfaces the unknown-op code when the bridge cannot dispatch a file clip'
    f1="$SHELLSPEC_TMPBASE/unknown-local.txt"; touch "$f1"
    unknown() {
      recob_script 'err unknown-op this build cannot dispatch clip.set.files'
      "$CLIENT" copy "$f1"
    }
    When call unknown
    The status should eq 1
    The stderr should include 'unknown-op'
  End

  It 'exits 1 naming a missing path, without contacting the bridge'
    f1="$SHELLSPEC_TMPBASE/exists.txt"; touch "$f1"
    missing="$SHELLSPEC_TMPBASE/does-not-exist.txt"
    absent_path() {
      "$CLIENT" copy "$f1" "$missing" 2>&1
      printf 'exit=%s|ops=%s' "$?" "$(recob_count)"
    }
    When call absent_path
    The output should include "$missing"
    The output should include 'exit=1|ops=0'
  End

  # Regression, carried across: the shim's reply-capturing branch had no
  # `|| true`, so a hard transport failure tripped `set -e` and killed the script
  # on the spot — exit 1, but silently. The compiled client reports the endpoint
  # it could not reach; pointing it at a socket that does not exist reproduces
  # the transport failure without stopping the listener.
  It 'fails with a message (not a silent death) when the trusted socket cannot be reached'
    f1="$SHELLSPEC_TMPBASE/nosock.txt"; touch "$f1"
    unreachable() {
      CLIPBOARD_BRIDGE_LOCAL_SOCKET="$RECOB_DIR/no-such.sock" "$CLIENT" copy "$f1"
    }
    When call unreachable
    The status should eq 1
    The stderr should include 'trusted clipboard bridge is not reachable'
  End

  It 'never touches the bridge when called with no args'
    sentinel="pbcopy-no-arg-sentinel-$$"
    no_args() { "$CLIENT" copy; printf 'exit=%s|ops=%s' "$?" "$(recob_count)"; }
    Data "$sentinel"
    When call no_args
    The output should equal 'exit=0|ops=0'
  End

  # Confirms the no-arg path genuinely reaches the real platform tool (not merely
  # "didn't touch the bridge"): a round trip through the actual macOS pasteboard
  # via the absolute /usr/bin/pbpaste, which no stubbing here can shadow.
  It 'still delivers stdin to the real system clipboard when called with no args'
    sentinel="pbcopy-roundtrip-sentinel-$$"
    roundtrip() { "$CLIENT" copy && /usr/bin/pbpaste; }
    Data "$sentinel"
    When call roundtrip
    The status should be success
    The output should include "$sentinel"
  End
End

Describe 'copy: file mode over SSH'
  Include tests/recob_helper.sh

  # Nothing is bound on port 1: the client's fallback keys on ECONNREFUSED
  # (§5.2), so "no peer" has to be a closed port rather than a silent one.
  NO_PEER_PORT=1

  setup() {
    export SSH_CONNECTION="x 1 y 22"
    recob_start
    CLIENT="$(recob_client_bin)"
    FILE="$RECOB_DIR/rem.txt"; touch "$FILE"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # One recorder plays both machines here, which the peer's own handler would
  # notice: §9.3's `mints_authority: local` makes a PUBLIC persist claiming the
  # daemon's own identity a `refused` (persist.rs), and in this harness the
  # client IS that identity. Scripting the reply keeps these examples on the
  # client's frames, which is what they are about; the daemon-side rule has its
  # own coverage in the recob suite. The script is re-read per connection, so one
  # directive answers both of them.
  It 'records the local origin row, then pushes the same operation to the peer'
    cf=$(cd "$RECOB_DIR" && pwd -P)/rem.txt
    both() {
      recob_script 'ok'
      "$CLIENT" copy "$FILE"
      printf 'exit=%s|ops=%s|%s,%s|host=%s|' "$?" "$(recob_count)" \
        "$(recob_endpoint 1)" "$(recob_endpoint 2)" "$(recob_field 1 host)"
      recob_ops | tr '\n' ','
    }
    When call both
    # Two `store.persist.files` and nothing else: the pasteboard-setting
    # `clip.set.files` must NOT appear. That is the bug the M rework exists to
    # fix — a `U` here only set a pasteboard on a machine that is typically
    # locked when reached over SSH, so no row ever landed.
    The output should equal \
      "exit=0|ops=2|trusted,public|host=recob-spec-host|store.persist.files,store.persist.files,"
  End

  It 'carries the NUL-joined absolute paths and this machine as the host'
    f2="$RECOB_DIR/rem-b.txt"; touch "$f2"
    cf1=$(cd "$RECOB_DIR" && pwd -P)/rem.txt
    cf2=$(cd "$RECOB_DIR" && pwd -P)/rem-b.txt
    payload() {
      recob_script 'ok'
      "$CLIENT" copy "$FILE" "$f2"
      printf 'exit=%s|' "$?"
      recob_field 1 paths | tr '\0' '@'
      printf '|'
      # The peer is told the same thing, which is what makes the manifest a
      # pointer it can later pull from.
      recob_field 2 paths | tr '\0' '@'
    }
    When call payload
    The output should equal "exit=0|$cf1@$cf2|$cf1@$cf2"
  End

  # The peer is reached at CLIPBOARD_BRIDGE_PORT and nowhere else: the recorder
  # listens on the port the helper exported, so an exchange arriving there is the
  # proof, and moving the variable to a closed port must strand the push rather
  # than let it find a bridge on the compiled-in default.
  It 'sends the peer push to CLIPBOARD_BRIDGE_PORT, and nowhere when nothing is bound there'
    stranded() {
      CLIPBOARD_BRIDGE_PORT="$NO_PEER_PORT" "$CLIENT" copy "$FILE" 2>&1
      printf 'exit=%s|ops=%s|%s' "$?" "$(recob_count)" "$(recob_op 1)"
    }
    When call stranded
    # Exit 0: the local origin record — the primary action — still landed.
    The output should include 'exit=0|ops=1|store.persist.files'
    The output should include 'peer not notified'
    The output should include 'reverse bridge down'
  End

  # The local record already succeeded by the time the peer is attempted, so a
  # peer-side refusal is a WARNING and never a command failure. `deny-auth` is a
  # connection-level directive that only bites where a credential is checked, so
  # it fails the public push and leaves the trusted record alone — the one
  # port-differentiated reply this single-listener harness can express.
  It 'warns but exits 0 when the peer refuses the credential'
    peer_denied() {
      recob_script 'deny-auth'
      "$CLIENT" copy "$FILE" 2>&1
      printf 'exit=%s|ops=%s|%s' "$?" "$(recob_count)" "$(recob_endpoint 1)"
    }
    When call peer_denied
    The output should include 'exit=0|ops=1|trusted'
    The output should include 'peer not notified'
    The output should include 'unauthorized'
  End

  # This machine's own bridge is the primary action: if IT is unreachable that is
  # a hard error regardless of the peer's state, and the peer is never contacted,
  # so its state cannot change the verdict.
  It 'hard-errors when the trusted socket of this machine is unreachable, leaving the peer uncontacted'
    local_down() {
      CLIPBOARD_BRIDGE_LOCAL_SOCKET="$RECOB_DIR/no-such.sock" "$CLIENT" copy "$FILE" 2>&1
      printf 'exit=%s|ops=%s' "$?" "$(recob_count)"
    }
    When call local_down
    The output should include 'trusted clipboard bridge is not reachable'
    The output should include 'exit=1|ops=0'
    # The interim that promoted the peer push to primary on a store-less platform
    # is retired: every platform has its own bridge and store now.
    The output should not include 'Phase 7 pending'
    The output should not include 'no local clipboard store'
  End

  It 'hard-errors when the local record is refused, leaving the peer uncontacted'
    local_refused() {
      recob_script 'err internal boom'
      "$CLIENT" copy "$FILE" 2>&1
      printf 'exit=%s|ops=%s|conns=%s' "$?" "$(recob_count)" "$(recob_connections)"
    }
    When call local_refused
    The output should include 'boom'
    # One operation, one connection: the client returned before dialing the peer.
    The output should include 'exit=1|ops=1|conns=1'
  End

  It 'exits 1 naming a missing path over SSH, without sending a frame'
    missing="$RECOB_DIR/rem-missing.txt"
    absent_path() {
      "$CLIENT" copy "$FILE" "$missing" 2>&1
      printf 'exit=%s|ops=%s' "$?" "$(recob_count)"
    }
    When call absent_path
    The output should include "$missing"
    The output should include 'exit=1|ops=0'
  End

  # Ephemeral-hostname boxes (a cloud dev-shell whose hostname changes daily)
  # cannot rely on scutil/hostname -s for the STABLE identity the sit-at
  # machine's peer-hostname front matter expects as a mount key.
  # ssh-prepare-connection pushes a self-name file at connect time and the client
  # prefers it, when it is present and safely shaped.
  It 'stamps the host from the self-name identity file when present and safely shaped'
    named() {
      recob_script 'ok'
      printf 'stable-devshell\n' > "$XDG_STATE_HOME/clipboard/self-name"
      "$CLIENT" copy "$FILE"
      printf 'exit=%s|host=%s' "$?" "$(recob_field 1 host)"
    }
    When call named
    The output should equal 'exit=0|host=stable-devshell'
  End

  # Defense in depth: the file sits on a shared box and could be stale,
  # hand-edited or malicious. It becomes both a stored row's host field and — on
  # whichever machine reads it back as a peer — a mount key and ssh target, so an
  # unsafe shape must fall back to real hostname resolution, never be trusted
  # verbatim.
  It 'falls back to the real hostname when the self-name file has an unsafe shape'
    expected_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null)
    evil() {
      recob_script 'ok'
      printf '* evil' > "$XDG_STATE_HOME/clipboard/self-name"
      "$CLIENT" copy "$FILE"
      printf 'exit=%s|host=%s' "$?" "$(recob_field 1 host)"
    }
    When call evil
    The output should equal "exit=0|host=$expected_host"
  End

  # Regression: a first-character check is not enough. The zsh original's `case`
  # pattern anchored only the first two characters, so a value with a safe prefix
  # and a shell-metacharacter TAIL sailed through. Every character must be
  # judged, wherever it sits.
  It 'falls back to the real hostname when the self-name file smuggles an injection after a safe prefix'
    expected_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null)
    midevil() {
      recob_script 'ok'
      printf 'cruise; rm -rf /tmp' > "$XDG_STATE_HOME/clipboard/self-name"
      "$CLIENT" copy "$FILE"
      printf 'exit=%s|host=%s|' "$?" "$(recob_field 1 host)"
      recob_raw
    }
    When call midevil
    The output should include "exit=0|host=$expected_host|"
    The output should not include 'rm -rf'
  End
End

# `pbcopy --content <file>` puts the file's raw BYTES on the clipboard under a
# detected UTI — `clip.set.rich`, the old op `C`. The blob is arbitrary binary,
# so the payload assertions compare hex against the fixture's own bytes rather
# than any text rendering of it.
Describe 'copy: --content at the machine'
  Include tests/recob_helper.sh

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    recob_start
    CLIENT="$(recob_client_bin)"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  It 'sends clip.set.rich over the trusted socket with the exact uti and a byte-identical blob'
    fixture="$SHELLSPEC_TMPBASE/blob.png"
    printf 'PNG\000HEADER\000MORE\000DATA' > "$fixture"
    blob_hex=$(od -An -tx1 < "$fixture" | tr -d ' \n')
    rich_frame() {
      "$CLIENT" copy --content "$fixture"
      printf 'exit=%s|%s|%s|%s|%s' "$?" "$(recob_op 1)" "$(recob_endpoint 1)" \
        "$(recob_field 1 uti)" "$(recob_field_hex 1 blob)"
    }
    When call rich_frame
    The output should equal "exit=0|clip.set.rich|trusted|public.png|$blob_hex"
  End

  It 'infers public.png from a .png extension'
    fixture="$SHELLSPEC_TMPBASE/pic.png"; touch "$fixture"
    uti() { "$CLIENT" copy --content "$fixture"; printf 'exit=%s|%s' "$?" "$(recob_field 1 uti)"; }
    When call uti
    The output should equal 'exit=0|public.png'
  End

  It 'infers com.adobe.pdf from a .pdf extension'
    fixture="$SHELLSPEC_TMPBASE/doc.pdf"; touch "$fixture"
    uti() { "$CLIENT" copy --content "$fixture"; printf 'exit=%s|%s' "$?" "$(recob_field 1 uti)"; }
    When call uti
    The output should equal 'exit=0|com.adobe.pdf'
  End

  It 'falls back to `file --mime-type -b` for an extensionless file'
    fixture="$SHELLSPEC_TMPBASE/mimetext"
    printf 'hello world\n' > "$fixture"
    uti() { "$CLIENT" copy --content "$fixture"; printf 'exit=%s|%s' "$?" "$(recob_field 1 uti)"; }
    When call uti
    The output should equal 'exit=0|public.utf8-plain-text'
  End

  It 'errors with the exact "cannot infer UTI" message for an unrecognized type'
    fixture="$SHELLSPEC_TMPBASE/weird.xyz"
    printf '\001\002\003\004' > "$fixture"
    unknown_type() { "$CLIENT" copy --content "$fixture"; printf 'exit=%s|ops=%s' "$?" "$(recob_count)"; }
    When call unknown_type
    The output should equal 'exit=1|ops=0'
    The stderr should equal "pbcopy: cannot infer UTI for $fixture"
  End

  It 'exits 1 naming a missing file, without contacting the bridge'
    missing="$SHELLSPEC_TMPBASE/does-not-exist-content.png"
    absent() { "$CLIENT" copy --content "$missing" 2>&1; printf 'exit=%s|ops=%s' "$?" "$(recob_count)"; }
    When call absent
    The output should include "$missing"
    The output should include 'exit=1|ops=0'
  End

  It 'errors when given zero files'
    none() { "$CLIENT" copy --content; }
    When call none
    The status should eq 1
    The stderr should include '--content'
  End

  It 'errors when given more than one file'
    f1="$SHELLSPEC_TMPBASE/multi-a.png"; touch "$f1"
    f2="$SHELLSPEC_TMPBASE/multi-b.png"; touch "$f2"
    two() { "$CLIENT" copy --content "$f1" "$f2"; }
    When call two
    The status should eq 1
    The stderr should include '--content'
  End

  It 'fails loudly when the bridge answers with an error'
    fixture="$SHELLSPEC_TMPBASE/err.png"; touch "$fixture"
    refused() { recob_script 'err internal boom'; "$CLIENT" copy --content "$fixture"; }
    When call refused
    The status should eq 1
    The stderr should include 'boom'
  End

  It 'surfaces the unknown-op code when the bridge cannot dispatch a rich clip'
    fixture="$SHELLSPEC_TMPBASE/unknown.png"; touch "$fixture"
    unknown() {
      recob_script 'err unknown-op this build cannot dispatch clip.set.rich'
      "$CLIENT" copy --content "$fixture"
    }
    When call unknown
    The status should eq 1
    The stderr should include 'unknown-op'
  End
End

Describe 'copy: --content over SSH'
  Include tests/recob_helper.sh

  NO_PEER_PORT=1

  setup() {
    export SSH_CONNECTION="x 1 y 22"
    recob_start
    CLIENT="$(recob_client_bin)"
    FIXTURE="$RECOB_DIR/rem.png"; touch "$FIXTURE"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # Over SSH the rich clip goes to the reverse-tunneled peer and nowhere else:
  # unlike a file clip there is no local row to record, because the bytes are the
  # clip. `public.png` is inside §9.3's public `uti_allow` set, which is what
  # keeps this an accepted operation rather than a `refused` one.
  It 'sends clip.set.rich to the peer on the public endpoint'
    peer_frame() {
      "$CLIENT" copy --content "$FIXTURE"
      printf 'exit=%s|ops=%s|%s|%s|%s' "$?" "$(recob_count)" \
        "$(recob_op 1)" "$(recob_endpoint 1)" "$(recob_field 1 uti)"
    }
    When call peer_frame
    The output should equal 'exit=0|ops=1|clip.set.rich|public|public.png'
  End

  # OSC 52 is text-only, so an absent bridge cannot be downgraded to it the way a
  # plain-text copy can — the operation has nowhere to go and says so.
  It 'errors with the reverse-bridge message when nothing is bound, without sending a frame'
    no_bridge() {
      CLIPBOARD_BRIDGE_PORT="$NO_PEER_PORT" "$CLIENT" copy --content "$FIXTURE"
      printf 'exit=%s|ops=%s' "$?" "$(recob_count)"
    }
    When call no_bridge
    The output should equal 'exit=1|ops=0'
    The stderr should equal 'pbcopy: --content needs the reverse bridge (OSC 52 cannot carry rich types)'
  End

  It 'surfaces the unknown-op code when the peer cannot dispatch a rich clip'
    unknown() {
      recob_script 'err unknown-op this build cannot dispatch clip.set.rich'
      "$CLIENT" copy --content "$FIXTURE"
    }
    When call unknown
    The status should eq 1
    The stderr should include 'unknown-op'
  End

  # §11.4's fail-open rule applied to rich types: a bridge that answers
  # `unauthorized` is a control doing its job, not an absent one, so the copy
  # fails rather than finding some lesser path.
  It 'fails loudly when the peer refuses the credential'
    denied() { recob_script 'deny-auth'; "$CLIENT" copy --content "$FIXTURE"; }
    When call denied
    The status should eq 1
    The stderr should include 'unauthorized'
  End
End

# The headless branch of plain-text copy: no pasteboard tool on PATH, so the
# store IS the clipboard and the trusted socket is where it lives. This is the
# old `T`-to-the-local-bridge fallback, now `clip.set` (§6.2's O+T collapse).
Describe 'copy: local text with no display tool'
  Include tests/recob_helper.sh

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    recob_start
    CLIENT="$(recob_client_bin)"
    # An empty PATH directory, not a prepend: a brew-installed wl-copy or xclip
    # would otherwise win the client's tool probe and skip the branch under test.
    NOBIN="$RECOB_DIR/nobin"; mkdir -p "$NOBIN"
    # Defeat the Darwin absolute-path branch on the Mac running this suite (a
    # test seam of the same class as PBCOPY_OSC52_SINK).
    export PBCOPY_DARWIN_BIN=/nonexistent
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  It 'falls back to clip.set against the trusted socket when no display tool exists'
    fallback() {
      printf hello | PATH="$NOBIN" "$CLIENT" copy
      printf 'exit=%s|%s|%s|%s|%s' "$?" "$(recob_op 1)" "$(recob_endpoint 1)" \
        "$(recob_field 1 text)" "$(recob_field 1 regtype)"
    }
    When call fallback
    The output should equal 'exit=0|clip.set|trusted|hello|v'
  End

  It 'relays the message the local bridge answered with when it rejects the copy'
    rejected() {
      recob_script 'err internal store write failed'
      printf hello | PATH="$NOBIN" "$CLIENT" copy
    }
    When call rejected
    The status should eq 1
    The stderr should include 'store write failed'
  End
End
