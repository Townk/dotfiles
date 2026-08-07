# mux-fullscreen-probe — Ghostty's fullscreen mirror, refreshed OFF the hot path.
#
# WezTerm pushes its fullscreen state from wezterm.lua on every window event.
# Ghostty has no such hook, so the state must be asked for — and asking costs
# 4-11 seconds through the accessibility API. Asking from the ribbon renderer
# (a tmux `#()` job, which tmux will not re-run while one is in flight) meant
# the bar was not re-expanded between runs at all: a mode began and ended
# inside a single render, so no mode pill ever appeared. The question now
# lives here, driven by the client-resized hook.
Describe 'mux-fullscreen-probe'
  Include tests/recob_helper.sh

  BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_mux-fullscreen-probe"

  setup() {
    FP_TMP=$(mktemp -d)
    STATE="$FP_TMP/ghostty_fullscreen"
    { print '#!/bin/sh'
      print 'while IFS= read -r _l; do :; done'
      print 'echo "${STUB_STATE:-WINDOWED}"'
    } > "$FP_TMP/osascript"
    { print '#!/bin/sh'; print 'echo "$*" >> '"$FP_TMP/tmuxcalls" } > "$FP_TMP/tmux"
    chmod +x "$FP_TMP/osascript" "$FP_TMP/tmux"
  }
  cleanup() { rm -rf "$FP_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  probe() {
    STUB_STATE="$1" \
    TMPDIR="$FP_TMP" \
    MUX_LIB_DIR="$FP_TMP/nolib" \
    WIDGETS_OSASCRIPT_BIN="$FP_TMP/osascript" \
    MUX_TMUX_BIN="$FP_TMP/tmux" \
    WIDGETS_GHOSTTY_FULLSCREEN_STATE="$STATE" \
      zsh "$BIN" >/dev/null 2>&1
    cat "$STATE" 2>/dev/null || echo "<absent>"
  }

  It 'records native fullscreen'
    When call probe NATIVE_FULLSCREEN
    The output should equal "true"
  End

  It 'records the non-native (maximised) case as fullscreen too'
    When call probe NON_NATIVE_FULLSCREEN
    The output should equal "true"
  End

  It 'records a windowed terminal'
    When call probe WINDOWED
    The output should equal "false"
  End

  # NOT_RUNNING from a Ghostty that is plainly running means the ASKER was not
  # granted Accessibility — not that the window vanished. Writing `false` on
  # that answer would quietly switch the fullscreen segments off and read as a
  # rendering bug, so an untrustworthy answer must leave the mirror alone.
  Describe 'an answer it cannot trust'
    It 'leaves an existing mirror untouched rather than clobbering it'
      keeps() {
        printf 'true' > "$STATE"
        probe NOT_RUNNING
      }
      When call keeps
      The output should equal "true"
    End

    It 'writes nothing at all when there is no mirror yet'
      When call probe NO_WINDOWS
      The output should equal "<absent>"
    End
  End

  It 'asks the bar to repaint once the mirror moves'
    calls() {
      probe NATIVE_FULLSCREEN >/dev/null
      cat "$FP_TMP/tmuxcalls" 2>/dev/null
    }
    When call calls
    The output should include "refresh-client -S"
  End

  # A resize arrives as a BURST — every intermediate size while dragging an
  # edge fires the hook, and each probe is seconds long. Without coalescing,
  # one drag spawns dozens of overlapping accessibility calls.
  # --print is the answer WITHOUT touching the mirror: it is how the origin
  # answers a `window.fullscreen.state` request from the far end of the
  # tunnel, so both machines run the same probe rather than two
  # implementations.
  Describe '--print'
    printed() {
      STUB_STATE="$1" TMPDIR="$FP_TMP" MUX_LIB_DIR="$FP_TMP/nolib" \
      WIDGETS_OSASCRIPT_BIN="$FP_TMP/osascript" MUX_TMUX_BIN="$FP_TMP/tmux" \
      WIDGETS_GHOSTTY_FULLSCREEN_STATE="$STATE" \
        zsh "$BIN" --print
      print -rn -- "|mirror=$(cat "$STATE" 2>/dev/null)"
    }

    It 'prints the state and leaves the mirror alone'
      When call printed NATIVE_FULLSCREEN
      The output should equal "true|mirror="
    End

    It 'prints nothing when it cannot tell'
      When call printed NOT_RUNNING
      The output should equal "|mirror="
    End
  End

  # Over SSH the window is on the OTHER machine, so the question travels the
  # clipboard bridge — ONE `window.fullscreen.state` on the credentialed
  # public endpoint (§6.1), whose reply field `state` carries the answer; the
  # old `W fullscreen-state` bare-string payload is dead. The peer port only
  # listens on the remote end of the reverse forward, which is exactly the
  # "am I the remote end" test, and is exactly what recob_start provides: a
  # REAL `recobd --record` on a per-example CLIPBOARD_BRIDGE_PORT, plus the
  # sandboxed XDG_STATE_HOME + credential fixture that lets the --peer TCP
  # route authenticate, plus SYSTEM_BRIDGE_BIN pointing the real zsh client
  # wrapper at the suite's own build. Replies are scripted, because an
  # unscripted window op would run the daemon's real handler.
  Describe 'over the bridge'
    fp_hex() { printf '%s' "$1" | xxd -p | tr -d '\n'; }

    remote_setup() {
      # The suite may itself run over SSH; ambient remoteness or a caller's
      # timeout tuning must not steer these examples.
      unset SSH_CONNECTION SSH_CLIENT SSH_TTY
      unset CLIPBRIDGE_TIMEOUT_S RECOB_TIMEOUT_S RECOB_ACTION_TIMEOUT_S
      # Daemon-side guards, exported BEFORE recob_start: every reply here is
      # scripted, but even a dispatch this file did not foresee must answer
      # `unavailable` rather than probe or animate this developer machine's
      # real terminal window (the RECOB_HS_BIN precedent in
      # notify_bridge_spec.sh).
      export MUX_TOGGLE_FULLSCREEN_BIN="$FP_TMP/no-such-toggle"
      export MUX_FULLSCREEN_PROBE="$FP_TMP/no-such-probe"
      recob_start
    }
    remote_cleanup() {
      recob_stop
      unset MUX_TOGGLE_FULLSCREEN_BIN MUX_FULLSCREEN_PROBE
    }
    BeforeEach 'remote_setup'
    AfterEach 'remote_cleanup'

    # -f: this repo's ~/.zshenv re-exports XDG_STATE_HOME with no ${VAR:-}
    # guard and would clobber recob_start's sandbox — where the credential
    # fixture the --peer route authenticates with lives (the trap
    # notify_bridge_spec.sh documents).
    remote() {
      TMPDIR="$FP_TMP" MUX_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" \
      WIDGETS_OSASCRIPT_BIN="$FP_TMP/osascript" MUX_TMUX_BIN="$FP_TMP/tmux" \
      WIDGETS_GHOSTTY_FULLSCREEN_STATE="$STATE" \
        zsh -f "$BIN" >/dev/null 2>&1
      cat "$STATE" 2>/dev/null || echo "<absent>"
    }

    It 'asks the machine the window is actually on: ONE window.fullscreen.state, public endpoint, one connection'
      recob_script "ok state=$(fp_hex true)"
      asked() {
        remote >/dev/null
        printf '%s|%s|%s|%s' "$(recob_op 1)" "$(recob_endpoint 1)" \
          "$(recob_count)" "$(recob_connections)"
      }
      When call asked
      The output should equal 'window.fullscreen.state|public|1|1'
    End

    It 'mirrors the peer answer'
      # The local osascript stub would answer WINDOWED (false), so `true` in
      # the mirror can only have come off the wire.
      recob_script "ok state=$(fp_hex true)"
      When call remote
      The output should equal "true"
    End

    It 'mirrors a windowed peer over an existing fullscreen mirror'
      recob_script "ok state=$(fp_hex false)"
      overwrites() { printf 'true' > "$STATE"; remote; }
      When call overwrites
      The output should equal "false"
    End

    # The origin answers `state` EMPTY when its own probe cannot tell (the
    # NOT_RUNNING/Accessibility case) — the same "an untrustworthy answer
    # must leave the mirror alone" rule the local examples pin.
    It 'leaves the mirror alone when the peer cannot tell'
      recob_script 'ok state='
      keeps() { printf 'true' > "$STATE"; remote; }
      When call keeps
      The output should equal "true"
    End

    It 'leaves the mirror alone when the reply carries no state field at all'
      recob_script 'ok'
      keeps() { printf 'true' > "$STATE"; remote; }
      When call keeps
      The output should equal "true"
    End

    # The true/false validation stands BETWEEN the wire and the state file: a
    # peer must not be able to write arbitrary bytes into a file the ribbon
    # renders.
    It 'refuses to mirror an answer that is neither true nor false'
      recob_script "ok state=$(fp_hex NOT_RUNNING)"
      keeps() { printf 'false' > "$STATE"; remote; }
      When call keeps
      The output should equal "false"
    End

    It 'leaves the mirror alone when the far end answers an error'
      recob_script 'err unavailable no fullscreen probe on this machine'
      keeps() { printf 'true' > "$STATE"; remote; }
      When call keeps
      The output should equal "true"
    End

    It 'leaves the mirror alone when the bridge fails mid-question'
      recob_script 'close'
      keeps() { printf 'false' > "$STATE"; remote; }
      When call keeps
      The output should equal "false"
    End
  End

  # The toggle already knows the state inverted — it asked for it — so it can
  # move the mirror without paying for a second round trip over the tunnel.
  Describe '--flip'
    flip() {
      TMPDIR="$FP_TMP" MUX_LIB_DIR="$FP_TMP/nolib" MUX_TMUX_BIN="$FP_TMP/tmux" \
      WIDGETS_GHOSTTY_FULLSCREEN_STATE="$STATE" \
        zsh "$BIN" --flip >/dev/null 2>&1
      cat "$STATE" 2>/dev/null
    }

    It 'turns a windowed mirror into a fullscreen one'
      on() { printf 'false' > "$STATE"; flip; }
      When call on
      The output should equal "true"
    End

    It 'turns it back'
      off() { printf 'true' > "$STATE"; flip; }
      When call off
      The output should equal "false"
    End

    It 'treats an absent mirror as windowed, so the first toggle lights it'
      When call flip
      The output should equal "true"
    End
  End

  It 'coalesces a burst behind an atomic lock'
    src() { cat "$BIN"; }
    When call src
    The output should include 'mkdir "$LOCK"'
    The output should include "rmdir"
  End
End
