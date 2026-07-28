# W — window action: the bridge acting on the TERMINAL WINDOW of the machine
# it runs on, for a session at the far end of the tunnel.
#
# The bridge was already the wire between a remote mux session and the machine
# its terminal actually lives on; the clipboard just happened to be the first
# thing that needed it. Fullscreen used to be refused over SSH ("cannot
# control the local terminal from an SSH-hosted session"), which described the
# plumbing of the day rather than what was possible.
Describe 'clip::op_window_action'
  setup() {
    W_TMP=$(mktemp -d)
    CORE="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/clipboard-store-core.zsh"

    # the toggle the op delegates to: records its environment and argv
    { print '#!/usr/bin/env zsh'
      print 'print -r -- "MUX_TERMINAL=${MUX_TERMINAL:-} SSH_CONNECTION=[${SSH_CONNECTION:-}]" >> '"$W_TMP/toggle.log"
      print '[[ -z "${STUB_TOGGLE_FAILS:-}" ]] || { print -u2 "Ghostty has no windows"; exit 1 }'
    } > "$W_TMP/toggle"
    { print '#!/usr/bin/env zsh'
      print '[[ "${1:-}" == --flip ]] && { print -r -- "flip" >> '"$W_TMP/probe.log"'; exit 0 }'
      print 'print -rn -- "${STUB_PROBE_ANSWER-true}"'
    } > "$W_TMP/probe"
    chmod +x "$W_TMP/toggle" "$W_TMP/probe"

    export MUX_TOGGLE_FULLSCREEN_BIN="$W_TMP/toggle"
    export MUX_FULLSCREEN_PROBE="$W_TMP/probe"
  }
  cleanup() {
    rm -rf "$W_TMP"
    unset MUX_TOGGLE_FULLSCREEN_BIN MUX_FULLSCREEN_PROBE STUB_TOGGLE_FAILS STUB_PROBE_ANSWER
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # The op replies in frames, so the harness supplies send_ok/send_err and
  # prints what the far end would receive: "<status>|<payload>".
  act() {
    zsh -c '
      clip::self_host() { print -r -- host }
      source "$1"
      # AFTER the source: the core defines the real framing helpers, and a
      # frame on stdout is bytes, not something a spec can read.
      send_ok()  { print -r -- "O|${1:-}" }
      send_err() { print -r -- "E|$1" }
      clip::op_window_action "$2"
    ' -- "$CORE" "$1"
  }

  Describe 'fullscreen-toggle'
    It 'toggles the named terminal'
      When call act "fullscreen-toggle ghostty"
      The output should equal "O|"
    End

    # detect_terminal would find no TERM_PROGRAM in a socket service, and any
    # SSH_* inherited from the login that started it would make the toggle
    # conclude it is the remote end — of itself. Both are cleared/overridden.
    It 'tells the toggle which terminal it is, and that it is local'
      env_seen() {
        act "fullscreen-toggle ghostty" >/dev/null
        cat "$W_TMP/toggle.log"
      }
      When call env_seen
      The output should include "MUX_TERMINAL=ghostty"
      The output should include "SSH_CONNECTION=[]"
    End

    It 'passes a wezterm request through as wezterm'
      env_seen() {
        act "fullscreen-toggle wezterm" >/dev/null
        cat "$W_TMP/toggle.log"
      }
      When call env_seen
      The output should include "MUX_TERMINAL=wezterm"
    End

    It 'refuses a terminal it does not know rather than shelling out'
      When call act "fullscreen-toggle emacs"
      The output should include "E|"
      The output should include "unsupported terminal"
    End

    It 'names no terminal at all as an error, not a default'
      When call act "fullscreen-toggle"
      The output should include "E|"
    End

    # The far end must be able to tell "done" from "the window server said
    # no" — a silent O would leave the user pressing a key that does nothing.
    It 'reports the far terminals own error text'
      export STUB_TOGGLE_FAILS=1
      When call act "fullscreen-toggle ghostty"
      The output should include "E|"
      The output should include "no windows"
    End
  End

  Describe 'fullscreen-state'
    It 'answers with the probe verdict'
      When call act "fullscreen-state"
      The output should equal "O|true"
    End

    It 'passes a windowed answer through'
      export STUB_PROBE_ANSWER=false
      When call act "fullscreen-state"
      The output should equal "O|false"
    End

    # An unknowable answer (no Accessibility grant) stays EMPTY end to end:
    # the asker leaves its mirror alone rather than writing a wrong `false`.
    It 'stays empty when the origin cannot tell'
      export STUB_PROBE_ANSWER=
      When call act "fullscreen-state"
      The output should equal "O|"
    End
  End

  It 'rejects an action it does not implement'
    When call act "self-destruct"
    The output should include "E|"
    The output should include "unknown window action"
  End
End
