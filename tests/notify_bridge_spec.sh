# notify's destination routing (home/dot_local/lib/common.zsh).
#
# The question notify answers is not "can this machine paint an OSD" but "where
# is the human". Over ssh those differ: the local `hs` exists on a Mac reached
# remotely and draws on a screen nobody is watching. So a remote notify is
# framed as an `n` op and sent to the origin over the clipboard bridge, and the
# two paths are EXCLUSIVE -- a bridge failure must not quietly repaint the OSD
# on the wrong screen, which is the bug the route exists to remove.
#
# `nc` and `hs` are stubbed so nothing here touches a real bridge or a real
# Hammerspoon; which stub ran is the observable under test.
Describe 'notify: destination routing'
  COMMON="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/common.zsh"

  setup() {
    NB="$SHELLSPEC_TMPBASE/nb"
    rm -rf "$NB"
    mkdir -p "$NB/bin" "$NB/state/clipboard"
    export XDG_STATE_HOME="$NB/state"
    # Pins clip::self_host, so the origin field is a known value and not this
    # developer machine's name.
    printf 'thisbox\n' > "$NB/state/clipboard/self-name"

    # Stands in for the whole wire: records the framed request and answers with
    # a status byte. STUB_NC_DOWN models an endpoint that refuses the
    # connection (no listener, dead tunnel); STUB_SEND_FAILS models a far end
    # that answers and rejects the frame.
    cat > "$NB/bin/nc" <<EOF
#!/bin/sh
cat > "$NB/sent"
if [ -n "\${STUB_NC_DOWN:-}" ]; then exit 1; fi
if [ -n "\${STUB_SEND_FAILS:-}" ]; then
  printf 'E\000\000\000\001x'
else
  printf 'O\000\000\000\000'
fi
EOF
    cat > "$NB/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$NB/hs.log"
EOF
    chmod +x "$NB/bin/nc" "$NB/bin/hs"
    export PATH="$NB/bin:$PATH"
    export HS="$NB/bin/hs"
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY NOTIFY_VIA_BRIDGE
    unset STUB_NC_DOWN STUB_SEND_FAILS
  }
  cleanup() {
    unset XDG_STATE_HOME HS SSH_CONNECTION NOTIFY_VIA_BRIDGE
    unset STUB_NC_DOWN STUB_SEND_FAILS
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # -f: without it this repo's ~/.zshenv re-exports XDG_STATE_HOME with no
  # ${VAR:-default} guard and clobbers the sandbox above -- the same trap
  # documented in tests/clipboard-bridge_spec.sh's O Describe.
  act() {
    zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift; notify "$@"' \
      -- "$COMMON" "$@"
  }
  # The payload begins after the 5-byte <opcode><BE32 len> header. US -> '|'
  # so a spec can assert on field boundaries.
  sent_fields() { tail -c +6 "$NB/sent" 2>/dev/null | tr '\037' '|'; }

  Describe 'local session'
    It 'paints on this machine and never opens the bridge'
      When call act "hello"
      The status should be success
      The path "$NB/hs.log" should be exist
      The path "$NB/sent" should not be exist
    End
  End

  Describe 'ssh session with the bridge up'
    ssh_setup() { export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"; }
    BeforeEach 'ssh_setup'

    It 'sends an n frame instead of painting locally'
      When call act "hello"
      The status should be success
      The path "$NB/hs.log" should not be exist
      The contents of file "$NB/sent" should start with "n"
    End

    It 'carries origin, function, icon, sound and text as five US fields'
      act --icon "glyph:nf-md-bell" --sound Frog "build done" >/dev/null
      When call sent_fields
      The output should equal "thisbox|notify|glyph:nf-md-bell|Frog|build done"
    End

    # --ansi picks the OTHER Lua global; it has to survive the crossing or a
    # coloured message arrives as literal escape bytes. Empty icon and sound
    # stay as empty FIELDS -- the far end turns those into Lua nil.
    It 'names notifyAnsi when --ansi is given'
      act --ansi "coloured" >/dev/null
      When call sent_fields
      The output should equal "thisbox|notifyAnsi|||coloured"
    End
  End

  Describe 'ssh session with the bridge unreachable'
    ssh_setup() {
      export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"
      export STUB_NC_DOWN=1
    }
    BeforeEach 'ssh_setup'

    # The regression this guards: while the bridge probe was part of the
    # routing gate, an unreachable bridge sent the notification back down the
    # local path and painted the OSD on the remote box's own screen -- the
    # exact bug the route exists to remove. Silence is the correct loss.
    It 'fails quietly rather than painting on the wrong screen'
      When call act "hello"
      The status should equal 1
      The path "$NB/hs.log" should not be exist
    End
  End

  Describe 'ssh session where the far end refuses the frame'
    ssh_setup() {
      export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"
      export STUB_SEND_FAILS=1
    }
    BeforeEach 'ssh_setup'

    It 'reports failure without a local fallback'
      When call act "hello"
      The status should equal 1
      The path "$NB/hs.log" should not be exist
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
      When call act "from the tmux server"
      The status should be success
      The path "$NB/hs.log" should not be exist
      The contents of file "$NB/sent" should start with "n"
    End
  End

  # notify's own contract invites `notify … &`, and a backgrounded caller
  # routinely outlives its parent. While the payload lived in the shared
  # process scratch dir, the parent's EXIT trap deleted it mid-flight and the
  # send failed with nothing ever reaching the wire -- which is how copy-pwd's
  # feedback OSD, backgrounded exactly that way, went silent over ssh.
  It 'still delivers when backgrounded and the parent exits first'
    export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"
    bg() {
      zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99
                 shift
                 { notify "$@" >/dev/null 2>&1; } &
                 exit 0' -- "$COMMON" "backgrounded"
      sleep 2   # let the orphaned job reach the wire
    }
    When call bg
    The contents of file "$NB/sent" should start with "n"
  End

  # Nothing to show short-circuits before any routing decision: neither stub
  # should be touched.
  It 'still returns 2 for an empty message'
    export SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"
    When call act ""
    The status should equal 2
    The path "$NB/hs.log" should not be exist
    The path "$NB/sent" should not be exist
  End
End
