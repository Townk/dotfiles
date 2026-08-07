# notify's destination routing (home/dot_local/lib/common.zsh), against the
# REAL RECOB listener in recording mode (spec §11.1) rather than a fake `nc`
# with a canned status byte.
#
# The question notify answers is not "can this machine paint an OSD" but "where
# is the human". Over ssh those differ: the local `hs` exists on a Mac reached
# remotely and draws on a screen nobody is watching. So a remote notify becomes
# ONE `osd.notify` exchange on the public endpoint (§6.1), and the two paths
# are EXCLUSIVE -- a bridge failure must not quietly repaint the OSD on the
# wrong screen, which is the bug the route exists to remove.
#
# WHAT THE CONVERSION CHANGED, beyond the transport.
#
#   * The `n` opcode and its five-US-fields payload are dead. The request is
#     named fields (§4.3), so "starts with n" became "the recorder heard
#     `osd.notify`", and the field boundaries assertion became per-field
#     equality against what the daemon's own decoder logged.
#   * The Lua global never crosses the wire anymore (P5): where the old payload
#     carried `notify`/`notifyAnsi` as its FUNCTION field, the request carries
#     `style`, the closed enum plain|ansi (§6.6), and the handler maps it to a
#     callable internally. The --ansi example pins the enum, not the symbol.
#   * The reply is a real §4.3 frame. STUB_NC_DOWN became "stop the listener"
#     (a genuine ECONNREFUSED); STUB_SEND_FAILS became a scripted
#     `err`, a §10 error the far end actually sends.
#
# The local `hs` is still a stub -- a spec must never paint a real OSD -- and
# RECOB_HS_BIN points the DAEMON's own notify handler at /usr/bin/true before
# it starts, so no example can reach the developer's screen even through a
# dispatch this file did not foresee. Success replies are scripted (`ok`), so
# the examples assert the client side of the exchange on any platform; the
# handler's own behavior is the daemon suite's business.
#
# ASSERTION SHAPE (the recob_helper contract): drive notify AND print what the
# recorder heard from inside ONE function, and assert on that function's
# output, so the exit status and the wire facts fail together in one message.
Describe 'notify: destination routing'
  Include tests/recob_helper.sh

  COMMON="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/common.zsh"

  setup() {
    # The suite may itself be running over SSH; ambient remoteness (or a leaked
    # override, or a caller's timeout tuning) must not route examples.
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY NOTIFY_VIA_BRIDGE
    unset CLIPBRIDGE_TIMEOUT_S RECOB_TIMEOUT_S
    # The daemon resolves its OSD tool from its OWN environment at spawn, so
    # the guard has to be exported before recob_start.
    export RECOB_HS_BIN=/usr/bin/true
    recob_start
    # recob_start exports XDG_STATE_HOME with self-name=$RECOB_SELF_NAME (which
    # pins clip::self_host, so origin_host is a known value and not this
    # developer machine's name), SYSTEM_BRIDGE_BIN (the suite's own build),
    # CLIPBOARD_BRIDGE_PORT/_LOCAL_SOCKET, and the §11.1 credential fixture
    # that lets the --peer TCP route authenticate.

    # The local route's Hammerspoon CLI, stubbed: which stub ran is the
    # observable under test, and hs.log existing means the LOCAL screen won.
    mkdir -p "$RECOB_DIR/bin"
    cat > "$RECOB_DIR/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RECOB_DIR/hs.log"
EOF
    chmod +x "$RECOB_DIR/bin/hs"
    export HS="$RECOB_DIR/bin/hs"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # -f: without it this repo's ~/.zshenv re-exports XDG_STATE_HOME with no
  # ${VAR:-default} guard and clobbers recob_start's sandbox -- the same trap
  # documented in tests/clipboard-bridge_spec.sh's O Describe.
  act() {
    zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift; notify "$@"' \
      -- "$COMMON" "$@"
  }

  # The nth operation's field NAMES, in wire order -- recob_hello_fields'
  # twin for op lines (a helper candidate; file-local for now because the
  # helper is owned elsewhere while this file converts). This is the only
  # probe that can tell an EMPTY field from an ABSENT one, which is exactly
  # the --ansi example's point: the far end turns empty icon/sound into Lua
  # nil, so they must still cross as fields.
  op_fields() {
    [ -f "${RECOB_RECORD_LOG:-}" ] || return 0
    awk -F'\t' '$2 != "hello"' "$RECOB_RECORD_LOG" | sed -n "${1}p" |
      cut -f3- | tr '\t' '\n' | sed -n 's/=.*//p' | tr '\n' ' ' | sed 's/ $//'
  }

  Describe 'local session'
    It 'paints on this machine and never opens the bridge'
      local_only() {
        act "hello" || return 1
        [ -f "$RECOB_DIR/hs.log" ] || return 2
        # Not merely "no osd.notify": no CONNECTION at all. The daemon is up
        # and reachable; the local route simply must not dial it.
        printf '%s|%s' "$(recob_count)" "$(recob_connections)"
      }
      When call local_only
      The output should equal '0|0'
    End
  End

  Describe 'ssh session with the bridge up'
    ssh_setup() { export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"; }
    BeforeEach 'ssh_setup'

    It 'sends one osd.notify on the public endpoint instead of painting locally'
      recob_script 'ok'
      routed() {
        act "hello" || return 1
        [ ! -e "$RECOB_DIR/hs.log" ] || return 2
        # One user action, one connection, one exchange (§6.3) -- and it is the
        # credentialed TCP endpoint, because that is where the tunnel lands.
        printf '%s|%s|%s|%s' \
          "$(recob_op 1)" "$(recob_endpoint 1)" \
          "$(recob_count)" "$(recob_connections)"
      }
      When call routed
      The output should equal 'osd.notify|public|1|1'
    End

    It 'carries origin, style, icon, sound and text as named fields'
      recob_script 'ok'
      payload() {
        act --icon "glyph:nf-md-bell" --sound Frog "build done" >/dev/null ||
          return 1
        printf '%s|%s|%s|%s|%s' \
          "$(recob_field 1 origin_host)" "$(recob_field 1 style)" \
          "$(recob_field 1 icon)" "$(recob_field 1 sound)" \
          "$(recob_field 1 text)"
      }
      When call payload
      The output should equal "$RECOB_SELF_NAME|plain|glyph:nf-md-bell|Frog|build done"
    End

    # --ansi used to pick the OTHER Lua global; the wire now carries the enum
    # instead of the symbol (P5, §6.6), and the daemon maps it internally. The
    # text is asserted in hex so the ESC bytes are pinned exactly -- a coloured
    # message must not arrive reencoded. Empty icon and sound stay as empty
    # FIELDS (the far end turns those into Lua nil), which is what the
    # field-name set proves and a decoded "" cannot.
    It 'crosses as style=ansi with byte-exact ANSI text when --ansi is given'
      ANSI="$(printf '\033[32mok\033[0m done')"
      recob_script 'ok'
      ansi_shape() {
        act --ansi "$ANSI" >/dev/null || return 1
        printf '%s|%s|%s' \
          "$(recob_field 1 style)" "$(recob_field_hex 1 text)" \
          "$(op_fields 1)"
      }
      When call ansi_shape
      The output should equal "ansi|$(printf '%s' "$ANSI" | xxd -p | tr -d '\n')|style icon sound origin_host text"
    End
  End

  Describe 'ssh session with the bridge unreachable'
    ssh_setup() { export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"; }
    BeforeEach 'ssh_setup'

    # The regression this guards: while the bridge probe was part of the
    # routing gate, an unreachable bridge sent the notification back down the
    # local path and painted the OSD on the remote box's own screen -- the
    # exact bug the route exists to remove. Silence is the correct loss.
    # recob_stop leaves the port REFUSING, not silent, so this is §5.2's
    # genuine tunnel-down shape rather than a stub's opinion of it.
    It 'fails quietly rather than painting on the wrong screen'
      down() { recob_stop; act "hello"; }
      When call down
      The status should equal 1
      The path "$RECOB_DIR/hs.log" should not be exist
      # "Quietly" is about the SCREEN and the rc, not stderr: the diagnostic
      # names the tunnel because that is the thing to fix.
      The stderr should include "not reachable"
      The stderr should include "tunnel down"
    End
  End

  Describe 'ssh session where the far end refuses the exchange'
    ssh_setup() { export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"; }
    BeforeEach 'ssh_setup'

    It 'reports failure without a local fallback'
      recob_script 'err internal osd refused'
      refused() {
        act "hello" && return 9
        [ $? -eq 1 ] || return 8
        [ ! -e "$RECOB_DIR/hs.log" ] || return 7
        # The request DID cross and decode -- the refusal is the far end's
        # answer, not a transport accident, and still no local repaint.
        printf '%s' "$(recob_op 1)"
      }
      When call refused
      The output should equal 'osd.notify'
      # §10: the code rides in a fixed, greppable position on stderr.
      The stderr should include "(internal)"
    End
  End

  # A tmux server does not inherit the attached client's SSH_*: it was born
  # from whatever session started it, possibly days earlier. tmux-alert-notify
  # and copy-pwd resolve remoteness per attached client and pass the verdict
  # in, so the bridge route must be reachable with no SSH_* at all.
  Describe 'NOTIFY_VIA_BRIDGE override'
    override_setup() { export NOTIFY_VIA_BRIDGE=1; }
    BeforeEach 'override_setup'

    It 'routes over the bridge with no SSH_ variables present'
      recob_script 'ok'
      overridden() {
        act "from the tmux server" || return 1
        [ ! -e "$RECOB_DIR/hs.log" ] || return 2
        printf '%s|%s' "$(recob_op 1)" "$(recob_field 1 text)"
      }
      When call overridden
      The output should equal 'osd.notify|from the tmux server'
    End
  End

  # notify's own contract invites `notify … &`, and a backgrounded caller
  # routinely outlives its parent. While the payload lived in the shared
  # process scratch dir, the parent's EXIT trap deleted it mid-flight and the
  # send failed with nothing ever reaching the wire -- which is how copy-pwd's
  # feedback OSD, backgrounded exactly that way, went silent over ssh. The
  # text rides the invoker's stdin now, but the behavior stays pinned:
  # delivery must not depend on the parent's lifetime.
  It 'still delivers when backgrounded and the parent exits first'
    export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"
    recob_script 'ok'
    bg() {
      zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99
                 shift
                 { notify "$@" >/dev/null 2>&1; } &
                 exit 0' -- "$COMMON" "backgrounded"
      # Waiting on the recorder, not a sleep: the orphan reaches the wire on
      # its own schedule.
      recob_wait_op osd.notify || return 1
      printf '%s|%s' "$(recob_op 1)" "$(recob_field 1 text)"
    }
    When call bg
    The output should equal 'osd.notify|backgrounded'
  End

  # Nothing to show short-circuits before any routing decision: no local
  # paint, no connection.
  It 'still returns 2 for an empty message'
    export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"
    empty() {
      act ""
      rc=$?
      [ ! -e "$RECOB_DIR/hs.log" ] || return 9
      printf '%s|%s' "$rc" "$(recob_connections)"
    }
    When call empty
    The output should equal '2|0'
  End
End
