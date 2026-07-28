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
  # replies to a `fullscreen-state` request from the far end of the tunnel,
  # so both machines run the same probe rather than two implementations.
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
  # clipboard bridge (opcode W) instead of asking a window server that does
  # not own the window. The peer port only listens on the remote end of the
  # reverse forward, which is exactly the "am I the remote end" test.
  Describe 'over the bridge'
    remote_setup() {
      { print 'clipbridge::probe() { [[ -n "${STUB_BRIDGE_UP:-}" ]] }'
        print 'clipbridge::request() {'
        print '  print -r -- "request $3 [$(cat $4)]" >> '"$FP_TMP/bridge.log"
        print '  [[ -z "${STUB_PEER_FAILS:-}" ]] || return 1'
        print '  print -rn -- "${STUB_PEER_ANSWER-true}"'
        print '}'
      } > "$FP_TMP/clipboard-bridge-client.zsh"
    }
    BeforeEach 'remote_setup'

    remote() {
      STUB_BRIDGE_UP=1 TMPDIR="$FP_TMP" MUX_LIB_DIR="$FP_TMP" \
      WIDGETS_OSASCRIPT_BIN="$FP_TMP/osascript" MUX_TMUX_BIN="$FP_TMP/tmux" \
      WIDGETS_GHOSTTY_FULLSCREEN_STATE="$STATE" \
      STUB_PEER_ANSWER="${1-true}" STUB_PEER_FAILS="${2:-}" \
        zsh "$BIN" >/dev/null 2>&1
      print -rn -- "$(cat "$STATE" 2>/dev/null)"
    }

    It 'asks the machine the window is actually on'
      asked() {
        remote true >/dev/null
        cat "$FP_TMP/bridge.log" 2>/dev/null
      }
      When call asked
      The output should include "request W [fullscreen-state]"
    End

    It 'mirrors the peer answer'
      When call remote true
      The output should equal "true"
    End

    It 'leaves the mirror alone when the peer cannot tell'
      keeps() { printf 'true' > "$STATE"; remote "" ; }
      When call keeps
      The output should equal "true"
    End

    It 'leaves the mirror alone when the bridge fails mid-question'
      keeps() { printf 'false' > "$STATE"; remote true 1; }
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
