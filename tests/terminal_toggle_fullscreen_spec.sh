# Tests for terminal-toggle-fullscreen's host-terminal dispatch.
Describe 'terminal-toggle-fullscreen'
  Include tests/recob_helper.sh

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
    # All three of the canonical remote-detection triple: detect_terminal now
    # honors SSH_TTY too (the no-pty `ssh -T` fix), so the local-session cases
    # must clear it as well or an ambient SSH_TTY misreads them as remote.
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
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
  # the toggle rides that as ONE `window.fullscreen.toggle{terminal}` on the
  # credentialed public endpoint (§6.1; `terminal` is §6.6's closed enum
  # ghostty|wezterm) — the old `W fullscreen-toggle <term>` payload is dead.
  # These examples drive the REAL zsh client wrapper against a REAL
  # `recobd --record` (tests/recob_helper.sh): recob_start exports the
  # per-example CLIPBOARD_BRIDGE_PORT the script probes for liveness, the
  # sandboxed XDG_STATE_HOME + credential fixture that lets the --peer TCP
  # route authenticate, and SYSTEM_BRIDGE_BIN pointing at the suite's own
  # build. Replies are scripted, because an unscripted window op would run
  # the daemon's real handler.
  Describe 'over ssh'
    TOGGLE_BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_terminal-toggle-fullscreen"

    bridge_setup() {
      BR_TMP=$(mktemp -d)
      unset CLIPBRIDGE_TIMEOUT_S RECOB_TIMEOUT_S RECOB_ACTION_TIMEOUT_S MUX_BRIDGE_TIMEOUT_S
      # Daemon-side guards, exported BEFORE recob_start: every reply here is
      # scripted, but even a dispatch this file did not foresee must answer
      # `unavailable` rather than animate this developer machine's real
      # terminal window (the RECOB_HS_BIN precedent in notify_bridge_spec.sh).
      export MUX_TOGGLE_FULLSCREEN_BIN="$BR_TMP/no-such-toggle"
      export MUX_FULLSCREEN_PROBE="$BR_TMP/no-such-probe"
      recob_start
      # The ribbon-mirror flip is a LOCAL script the toggle runs afterwards,
      # not a bridge exchange, so it stays a spy.
      print -r -- '#!/bin/sh' > "$BR_TMP/probe"
      print -r -- 'echo "flip $*" >> '"$BR_TMP/calls" >> "$BR_TMP/probe"
      chmod +x "$BR_TMP/probe"
      export MUX_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
      export MUX_FULLSCREEN_PROBE="$BR_TMP/probe"
      export SSH_CONNECTION="fe80::1 1 fe80::2 22"
      export TERM=xterm-ghostty
      unset MUX_TERMINAL MUX_PEER_TERM
    }
    bridge_cleanup() {
      recob_stop
      rm -rf "$BR_TMP"
      unset MUX_LIB_DIR MUX_FULLSCREEN_PROBE MUX_TOGGLE_FULLSCREEN_BIN SSH_CONNECTION MUX_PEER_TERM
    }
    BeforeEach 'bridge_setup'
    AfterEach 'bridge_cleanup'

    # -f: this repo's ~/.zshenv re-exports XDG_STATE_HOME with no ${VAR:-}
    # guard and would clobber recob_start's sandbox — where the credential
    # fixture the --peer route authenticates with lives (the trap
    # notify_bridge_spec.sh documents).
    run_it() {
      zsh -f "$TOGGLE_BIN" >/dev/null 2>&1
      print -r -- "rc=$?"
      cat "$BR_TMP/calls" 2>/dev/null
    }

    # The failure-path runner: stderr folded into the function's own output so
    # the message, the exit status and the wire count fail together.
    run_err() {
      _err=$(zsh -f "$TOGGLE_BIN" 2>&1 >/dev/null)
      _rc=$?
      print -r -- "$_err"
      print -r -- "rc=$_rc ops=$(recob_count)"
    }

    It 'sends ONE window.fullscreen.toggle naming the terminal, on the public endpoint'
      recob_script 'ok'
      sent() {
        run_it
        printf '%s|%s|%s|%s|%s' "$(recob_op 1)" "$(recob_field 1 terminal)" \
          "$(recob_endpoint 1)" "$(recob_count)" "$(recob_connections)"
      }
      When call sent
      The output should include "rc=0"
      The output should include "window.fullscreen.toggle|ghostty|public|1|1"
    End

    # A toggle makes the far machine DO something: a window animation, and on
    # the very first use a macOS Automation consent dialog that blocks until
    # a human clicks it. The clipboard's 2s wire timeout reported "refused"
    # for a toggle that had actually happened (measured, 2026-07-28). The
    # request therefore goes out with --action — the §5.2 ACTION deadline,
    # whose 20s default lives in the client binary and survives the empty
    # RECOB_ACTION_TIMEOUT_S an unset MUX_BRIDGE_TIMEOUT_S maps to — and
    # MUX_BRIDGE_TIMEOUT_S still tunes it. The deadline never crosses the
    # wire, so it is pinned at the invoker seam: a pass-through spy that logs
    # the invocation and execs the suite's real system-bridge, so the
    # exchange itself still runs against the real recorder.
    It 'goes out under the action deadline, tuned by MUX_BRIDGE_TIMEOUT_S'
      recob_script 'ok'
      spied() {
        print -r -- '#!/bin/sh' > "$BR_TMP/spy"
        print -r -- 'echo "action_timeout=<${RECOB_ACTION_TIMEOUT_S-unset}> argv=$*" >> '"$BR_TMP/spy.log" >> "$BR_TMP/spy"
        print -r -- 'exec "'"$(recob_bridge_bin)"'" "$@"' >> "$BR_TMP/spy"
        chmod +x "$BR_TMP/spy"
        SYSTEM_BRIDGE_BIN="$BR_TMP/spy" zsh -f "$TOGGLE_BIN" >/dev/null 2>&1 || return 1
        SYSTEM_BRIDGE_BIN="$BR_TMP/spy" MUX_BRIDGE_TIMEOUT_S=7 \
          zsh -f "$TOGGLE_BIN" >/dev/null 2>&1 || return 2
        grep 'argv=call' "$BR_TMP/spy.log"
      }
      When call spied
      The line 1 of output should equal 'action_timeout=<> argv=call --peer --action window.fullscreen.toggle terminal=ghostty'
      The line 2 of output should equal 'action_timeout=<7> argv=call --peer --action window.fullscreen.toggle terminal=ghostty'
    End

    # The state just inverted and we asked for it — re-asking would cost
    # another round trip to learn what we already know. `window_ops=1` is the
    # wire half of the claim: the flip spawned no second exchange.
    It 'moves the ribbon mirror without a second round trip'
      recob_script 'ok'
      flipped() {
        run_it
        printf 'window_ops=%s' "$(recob_count)"
      }
      When call flipped
      The output should include "rc=0"
      The output should include "flip --flip"
      The output should include "window_ops=1"
    End

    It 'names the terminal from an explicit override when given one'
      export MUX_PEER_TERM=wezterm-256color
      recob_script 'ok'
      named() { run_it; printf 'terminal=<%s>' "$(recob_field 1 terminal)"; }
      When call named
      The output should include "rc=0"
      The output should include "terminal=<wezterm>"
    End

    # THE bug the keybinding hit: inside tmux, $TERM is tmux-256color and
    # TERM_PROGRAM is "tmux" — tmux overwrites both, so a run-shell (which is
    # how the binding gets here) can identify nothing from its own env. tmux
    # itself knows: the client's termname, and the session env that
    # update-environment refreshes on attach.
    Describe 'inside tmux, where TERM is tmux own'
      tmux_setup() {
        { print '#!/usr/bin/env zsh'
          print 'if [[ "$1" == display ]]; then print -r -- "${STUB_CLIENT_TERM-xterm-ghostty}"; exit 0; fi'
          print 'if [[ "$1" == show-environment ]]; then'
          print '  [[ -n "${STUB_SESSION_TERM:-}" ]] && print -r -- "TERM=$STUB_SESSION_TERM" || print -r -- "-TERM"'
          print '  exit 0'
          print 'fi'
        } > "$BR_TMP/tmux"
        chmod +x "$BR_TMP/tmux"
        export MUX_TMUX_BIN="$BR_TMP/tmux" TMUX=/tmp/sock,1,0 TERM=tmux-256color
        unset MUX_PEER_TERM
      }
      BeforeEach 'tmux_setup'
      AfterEach 'unset MUX_TMUX_BIN TMUX STUB_CLIENT_TERM STUB_SESSION_TERM'

      It 'asks tmux for the client terminal instead of believing TERM'
        recob_script 'ok'
        named() { run_it; printf 'terminal=<%s>' "$(recob_field 1 terminal)"; }
        When call named
        The output should include "rc=0"
        The output should include "terminal=<ghostty>"
      End

      It 'falls back to the session environment tmux refreshes on attach'
        export STUB_CLIENT_TERM= STUB_SESSION_TERM=wezterm-256color
        recob_script 'ok'
        named() { run_it; printf 'terminal=<%s>' "$(recob_field 1 terminal)"; }
        When call named
        The output should include "rc=0"
        The output should include "terminal=<wezterm>"
      End

      # `ops=0`: the refusal is decided before anything is sent — a daemon is
      # up and answering, and still no operation crosses.
      It 'still fails honestly when tmux knows of no outer terminal'
        export STUB_CLIENT_TERM= STUB_SESSION_TERM=
        When call run_err
        The output should include "cannot tell which terminal"
        The output should include "rc=1 ops=0"
      End
    End

    # A down forward is the one case where remote fullscreen genuinely cannot
    # work — and it must say THAT, not the old blanket refusal. Port 1 is
    # closed (binding it needs root), so the probe's §5.2 connect result is a
    # genuine ECONNREFUSED rather than a stub's opinion of one.
    It 'fails with the real reason when the forward is down'
      down() {
        _err=$(CLIPBOARD_BRIDGE_PORT=1 zsh -f "$TOGGLE_BIN" 2>&1 >/dev/null)
        _rc=$?
        print -r -- "$_err"
        print -r -- "rc=$_rc ops=$(recob_count)"
      }
      When call down
      The output should include "the bridge to your terminal is down (port 1)"
      The output should not include "cannot control the local terminal"
      The output should include "rc=1 ops=0"
    End

    # The request DID cross and decode — the refusal is the far end's §10
    # answer, not a transport accident — and no flip may follow a toggle that
    # did not happen.
    It 'reports a refusal from the far end rather than claiming success'
      recob_script 'err unavailable no fullscreen toggle on this machine'
      refused() {
        _err=$(zsh -f "$TOGGLE_BIN" 2>&1 >/dev/null)
        _rc=$?
        print -r -- "$_err"
        _flip=none; [ -e "$BR_TMP/calls" ] && _flip=ran
        print -r -- "rc=$_rc op=$(recob_op 1) flip=$_flip"
      }
      When call refused
      The output should include "refused the fullscreen toggle"
      The output should include "rc=1 op=window.fullscreen.toggle flip=none"
    End
  End
End
