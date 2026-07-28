# Tests for terminal-toggle-fullscreen's host-terminal dispatch.
Describe 'terminal-toggle-fullscreen'
  setup() {
    TEST_TMP=$(mktemp -d)
    export APPLESCRIPT_LOG="$TEST_TMP/applescript.log"

    cat >"$TEST_TMP/osascript" <<'EOF'
#!/usr/bin/env zsh
while IFS= read -r line; do print -r -- "$line" >>"$APPLESCRIPT_LOG"; done
print -- true
EOF
    cat >"$TEST_TMP/uname" <<'EOF'
#!/usr/bin/env zsh
print -- Darwin
EOF
    chmod +x "$TEST_TMP/osascript" "$TEST_TMP/uname"
    ORIGINAL_PATH="$PATH"
    export PATH="$TEST_TMP:$PATH"
    unset SSH_CONNECTION SSH_CLIENT
  }
  cleanup() {
    PATH="$ORIGINAL_PATH"
    rm -rf "$TEST_TMP"
    unset APPLESCRIPT_LOG TERM_PROGRAM GHOSTTY_RESOURCES_DIR
  }
  BeforeEach setup
  AfterEach cleanup

  It 'uses Ghostty fullscreen action on the focused terminal'
    export TERM_PROGRAM=ghostty
    When call zsh home/dot_config/mux/scripts/executable_terminal-toggle-fullscreen
    The contents of file "$APPLESCRIPT_LOG" should include 'focused terminal'
    The contents of file "$APPLESCRIPT_LOG" should include 'perform action "toggle_fullscreen"'
    The contents of file "$APPLESCRIPT_LOG" should not include 'AXFullScreen'
    The output should equal ""
    The status should be success
  End

  # An explicit terminal wins over detection. The bridge runs this on the
  # ORIGIN from a socket service with no TERM_PROGRAM and, quite possibly,
  # its own SSH_* set from whatever login started it — detection would give
  # up or wrongly conclude "remote". The far end already knows which terminal
  # it is talking to, so it says so.
  It 'obeys an explicit terminal over detection, even with SSH set'
    export SSH_CONNECTION="fe80::1 1 fe80::2 22" MUX_TERMINAL=ghostty
    When call zsh home/dot_config/mux/scripts/executable_terminal-toggle-fullscreen
    The contents of file "$APPLESCRIPT_LOG" should include 'perform action "toggle_fullscreen"'
    The status should be success
  End

  # Fullscreen over SSH used to be refused outright. The window is on the
  # machine we came from and the clipboard bridge is already a wire to it, so
  # the toggle rides that instead (opcode W) — the refusal described the old
  # plumbing, not what was possible.
  Describe 'over ssh'
    bridge_setup() {
      BR_TMP=$(mktemp -d)
      # a stand-in bridge client: records the call, reports the port live
      { print 'clipbridge::probe() { [[ -n "${STUB_BRIDGE_UP:-}" ]] }'
        print 'clipbridge::send() {'
        print '  print -r -- "send $3 [$(cat $4)]" >> '"$BR_TMP/calls"
        print '  [[ -z "${STUB_SEND_FAILS:-}" ]]'
        print '}'
      } > "$BR_TMP/clipboard-bridge-client.zsh"
      print '#!/bin/sh' > "$BR_TMP/probe"
      print 'echo "flip $*" >> '"$BR_TMP/calls" >> "$BR_TMP/probe"
      chmod +x "$BR_TMP/probe"
      export MUX_LIB_DIR="$BR_TMP" MUX_FULLSCREEN_PROBE="$BR_TMP/probe"
      export SSH_CONNECTION="fe80::1 1 fe80::2 22"
      export TERM=xterm-ghostty
      unset MUX_TERMINAL
    }
    bridge_cleanup() {
      rm -rf "$BR_TMP"
      unset MUX_LIB_DIR MUX_FULLSCREEN_PROBE SSH_CONNECTION STUB_BRIDGE_UP STUB_SEND_FAILS MUX_PEER_TERM
    }
    BeforeEach 'bridge_setup'
    AfterEach 'bridge_cleanup'

    run_it() {
      zsh home/dot_config/mux/scripts/executable_terminal-toggle-fullscreen >/dev/null 2>&1
      print -r -- "rc=$?"
      cat "$BR_TMP/calls" 2>/dev/null
    }

    It 'sends the toggle to the machine the window is on'
      export STUB_BRIDGE_UP=1
      When call run_it
      The output should include "rc=0"
      The output should include "send W [fullscreen-toggle ghostty]"
    End

    # The state just inverted and we asked for it — re-asking would cost
    # another round trip to learn what we already know.
    It 'moves the ribbon mirror without a second round trip'
      export STUB_BRIDGE_UP=1
      When call run_it
      The output should include "flip --flip"
    End

    It 'names the terminal from TERM, which is what ssh actually carries'
      export STUB_BRIDGE_UP=1 MUX_PEER_TERM=wezterm-256color
      When call run_it
      The output should include "fullscreen-toggle wezterm"
    End

    # A down forward is the one case where remote fullscreen genuinely cannot
    # work — and it must say THAT, not the old blanket refusal.
    It 'fails with the real reason when the forward is down'
      err() {
        zsh home/dot_config/mux/scripts/executable_terminal-toggle-fullscreen 2>&1 >/dev/null
      }
      When call err
      The output should include "bridge"
      The output should not include "cannot control the local terminal"
      The status should be failure
    End

    It 'reports a refusal from the far end rather than claiming success'
      export STUB_BRIDGE_UP=1 STUB_SEND_FAILS=1
      err() {
        zsh home/dot_config/mux/scripts/executable_terminal-toggle-fullscreen 2>&1 >/dev/null
      }
      When call err
      The output should include "refused"
      The status should be failure
    End
  End
End
