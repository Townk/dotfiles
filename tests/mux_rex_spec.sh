# Tests for the Rex backend of the mux::* shim — home/dot_local/lib/mux/rex.zsh
# and its wiring in mux-bootstrap.zsh.
#
# Two halves:
#
#   1. DETECTION and DISPATCH, with no rex binary involved: which backend the
#      env resolves to, that an unrecognised backend fails loudly instead of
#      falling into another multiplexer's implementation, and that consumers
#      stay on their inline paths in a Rex pane until opted in.
#
#   2. The VERBS against a real Rex server — a SCRATCH one, started here on its
#      own socket and state dir with --restore=false. Never the developer's
#      live server: spec_helper.sh unsets REX_SERVER, and every call below goes
#      through the scratch socket this file exports. Skipped as a whole on a
#      box without rex.
#
# The scratch socket lives directly in /tmp, not under mktemp's directory: a
# unix socket path is capped near 104 bytes and macOS's $TMPDIR plus a mktemp
# suffix plus a filename does not reliably fit.
Describe 'mux shim — Rex backend'
  Include home/dot_local/lib/mux-bootstrap.zsh

  Describe 'backend detection'
    cleanup_env() { unset MUX_BACKEND TMUX REX_SESSION; }
    AfterEach 'cleanup_env'

    It 'resolves to rex in a Rex pane'
      REX_SESSION="session:x"
      When call mux::backend
      The output should equal "rex"
    End

    It 'lets tmux win when tmux runs inside a Rex pane'
      REX_SESSION="session:x" TMUX="/tmp/sock,1,0"
      When call mux::backend
      The output should equal "tmux"
    End

    It 'accepts MUX_BACKEND=rex as an explicit override'
      MUX_BACKEND=rex TMUX="/tmp/sock,1,0"
      When call mux::backend
      The output should equal "rex"
    End

    It 'is none with no session env at all'
      When call mux::backend
      The output should equal "none"
    End

    It 'does not count a Rex pane as "in a tmux session"'
      # .zshrc relies on this distinction; see the comment on its autostart gate.
      REX_SESSION="session:x"
      When call mux::in_session
      The status should be failure
    End
  End

  Describe 'unknown backend'
    # MUX_BACKEND only admits known names, so an unknown backend is simulated
    # the way it would really arise: mux::backend returning something new.
    setup_unknown() { mux::backend() { print -r -- wezmux; }; }
    BeforeEach 'setup_unknown'

    It 'fails loudly instead of running another backend (list_sessions)'
      When call mux::list_sessions
      The status should be failure
      The stderr should include "no implementation for backend 'wezmux'"
    End

    It 'fails loudly on attached_sessions, which used to fall through to another backend'
      When call mux::attached_sessions
      The status should be failure
      The stderr should include "wezmux"
    End

    It 'fails loudly on terminal_size, the other old fallthrough'
      When call mux::terminal_size
      The status should be failure
      The stderr should include "wezmux"
    End
  End

  Describe 'outside any session'
    It 'stays quiet: "none" is a state, not a mistake'
      When call mux::list_sessions
      The status should be failure
      The stderr should equal ""
    End
  End

  Describe 'consumer gate'
    stub_bin() {
      GATE_TMP=$(mktemp -d)
      print -r -- '#!/bin/sh' > "$GATE_TMP/rex"; chmod +x "$GATE_TMP/rex"
      export MUX_REX_BIN="$GATE_TMP/rex"
    }
    unstub_bin() { rm -rf "$GATE_TMP"; unset MUX_REX_BIN REX_SESSION; }
    BeforeEach 'stub_bin'
    AfterEach 'unstub_bin'

    # The consumers are ported: a Rex pane is a mux like any other, with no
    # knob (it was $MUX_REX_CONSUMERS while they were not).
    It 'reports a Rex pane as available'
      REX_SESSION="session:x"
      When call mux::available
      The status should be success
    End

    It 'reports nothing available outside any pane'
      unset REX_SESSION TMUX
      When call mux::available
      The status should be failure
    End

    It 'reports the backend itself as usable either way'
      REX_SESSION="session:x"
      When call _mux_rx_available
      The status should be success
    End

    It 'resolves the binary through mux::bin'
      When call mux::bin rex
      The output should equal "$GATE_TMP/rex"
    End
  End

  Describe 'geometry'
    It 'turns a percentage into a fraction'
      When call _mux_rx_fraction 70% 0
      The output should equal "0.7000"
    End

    It 'turns cells into a fraction of the window'
      When call _mux_rx_fraction 40 160
      The output should equal "0.2500"
    End

    It 'clamps a size larger than the window'
      When call _mux_rx_fraction 300 160
      The output should equal "1.0000"
    End

    It 'falls back to 80% when cells are given but the window is unknown'
      When call _mux_rx_fraction 40 0
      The output should equal "0.8000"
    End
  End

  Describe 'verbs against a scratch server'
    rex_missing() { ! command -v rex >/dev/null 2>&1; }
    Skip if 'rex is not installed' rex_missing

    rx() { command rex --autostart=false -S "$RX_SERVER" "$@"; }

    start_server() {
      RX_STATE=$(mktemp -d)
      RX_SOCK="/tmp/mxrx-$$.sock"
      RX_SERVER="unix://$RX_SOCK"
      : > "$RX_STATE/init.lua"
      # Born "inside tmux", as a server started from a tmux pane is (see the
      # layer example below).
      TMUX=/tmp/mxrx-fake,1,0 TMUX_PANE=%9 \
        command rex server run --listen "$RX_SERVER" --state-dir "$RX_STATE/state" \
        --config "$RX_STATE/init.lua" --restore=false >"$RX_STATE/server.log" 2>&1 &
      RX_PID=$!
      local i
      for i in {1..50}; do
        rx whoami >/dev/null 2>&1 && break
        sleep 0.1
      done
      RX_SID=$(rx new spec-main --window first -c /tmp --shell none --json -- /bin/zsh -f |
        jq -r '.session_id')
      RX_BID=$(rx block ls -s "$RX_SID" --json | jq -r '.blocks[0].block_id')
      rx new spec-other --shell none -- /bin/sh >/dev/null
    }
    stop_server() {
      rx server stop >/dev/null 2>&1
      kill "$RX_PID" 2>/dev/null
      rm -rf "$RX_STATE" "$RX_SOCK"
    }
    BeforeAll 'start_server'
    AfterAll 'stop_server'

    in_pane() { export REX_SERVER="$RX_SERVER" REX_SESSION="$RX_SID" REX_BLOCK="$RX_BID"; }
    out_pane() { unset REX_SERVER REX_SESSION REX_BLOCK; }
    BeforeEach 'in_pane'
    AfterEach 'out_pane'

    It 'names the current session by its label'
      When call mux::current_session
      The output should equal "spec-main"
    End

    It 'lists every session'
      When call mux::list_sessions
      The line 1 of output should equal "spec-main"
      The line 2 of output should equal "spec-other"
    End

    It 'refuses to resolve a session from a client pid'
      When call mux::resolve_session 12345
      The status should be failure
    End

    It 'reports no attached session when only CLI clients are connected'
      When call mux::attached_sessions
      The output should equal ""
    End

    It 'reports the tab our block is in, by position and by name'
      When call mux::current_tab
      The output should equal "1"
    End

    It 'reports the tab name'
      When call mux::current_tab_name
      The output should equal "first"
    End

    It 'reports the pane cwd from the foreground process'
      When call mux::pane_cwd
      The output should equal "/private/tmp"
    End

    It 'reports the foreground command'
      When call mux::focused_command
      The output should equal "zsh"
    End

    It 'reports the window size in cells'
      When call mux::terminal_size
      The output should match pattern "[0-9]* [0-9]*"
    End

    It 'sends text and reads it back from the screen'
      send_and_dump() {
        mux::send_text 'echo rx-$((40+2))-marker'
        mux::send_key enter
        sleep 0.5
        mux::dump_screen
      }
      When call send_and_dump
      The output should include "rx-42-marker"
    End

    It 'splits, labels the new block, and counts it'
      split_and_count() {
        local b
        b=$(mux::split down --size 30% --name spec-split --cwd /tmp -- /bin/sh -c 'sleep 30')
        [[ "$b" == block:* ]] || return 1
        rx block ls -s "$RX_SID" --json |
          jq -r --arg b "$b" '.blocks[] | select(.block_id == $b) | .label'
        mux::pane_count
      }
      When call split_and_count
      The line 1 of output should equal "spec-split"
      The line 2 of output should equal "2"
    End

    It 'opens a floating layer for a popup'
      popup_layers() {
        mux::popup 60% 50% --title spec-pop -- /bin/sh -c 'sleep 30' || return 1
        rx api call -s "$RX_SID" session.view |
          jq -r '[.windows[].layers[] | select(.kind != "tiled") | .blocks[].label] | join(",")'
      }
      When call popup_layers
      The output should equal "spec-pop"
    End

    # A layer's command starts from the SERVER's environment, and one that
    # took an inherited $TMUX at its word would act as a tmux pane. The server
    # itself leaves TMUX/TMUX_PANE out and sets COLORTERM (0.1.0-preview.25),
    # which is why _mux_rx_layer does not wrap its command in `env -u …`.
    # If this fails after a Rex update, the wrapper has become necessary.
    It 'runs a layer command without the tmux variables the server was born with'
      layer_env() {
        local f="$RX_STATE/layer-env" i
        unset COLORTERM
        mux::popup 50% 50% --title spec-env -- /bin/sh -c \
          'echo "tmux=${TMUX-unset} pane=${TMUX_PANE-unset} color=${COLORTERM-unset}" >"$1"; sleep 30' sh "$f" || return 1
        for i in {1..50}; do [[ -s "$f" ]] && break; sleep 0.1; done
        cat "$f"
      }
      When call layer_env
      The output should equal "tmux=unset pane=unset color=truecolor"
    End

    It 'reports floats as available and creates one sized in cells'
      float_one() {
        mux::has_float_pane || return 1
        mux::float_pane 40 10 -- /bin/sh -c 'sleep 30'
      }
      When call float_one
      The output should start with "block:"
    End

    It 'creates a named tab and replaces it when asked for a singleton'
      tabs() {
        mux::new_tab --name spec-tab --cwd /tmp -- /bin/sh -c 'sleep 30' || return 1
        mux::new_tab --name spec-tab --singleton -- /bin/sh -c 'sleep 30' || return 1
        rx api call -s "$RX_SID" session.view |
          jq -r '[.windows[] | select(.label == "spec-tab")] | length'
      }
      When call tabs
      The output should equal "1"
    End

    It 'focuses a named tab instead of opening a second when asked to'
      one_tab() {
        mux::new_tab --name spec-focus -- /bin/sh -c 'sleep 30' || return 1
        mux::new_tab --name other-tab -- /bin/sh -c 'sleep 30' || return 1
        mux::new_tab --name spec-focus --focus-existing -- /bin/sh -c 'sleep 30' || return 1
        rx api call -s "$RX_SID" session.view |
          jq -r '([.windows[] | select(.label == "spec-focus")] | length) as $n
            | (.active_window_id as $a | .windows[] | select(.window_id == $a) | .label) as $l | "\($n) \($l)"'
      }
      When call one_tab
      The output should equal "1 spec-focus"
    End

    # The label is positional for `rex window new`, so one that starts with
    # a dash would be read as flags (`-spec…` is `-s pec…`: another session).
    It 'opens a tab whose name starts with a dash, and replaces it as a singleton'
      dash_tabs() {
        mux::new_tab --name -spec-dash -- /bin/sh -c 'sleep 30' || return 1
        mux::new_tab --name -spec-dash --singleton -- /bin/sh -c 'sleep 30' || return 1
        rx api call -s "$RX_SID" session.view |
          jq -c '[.windows[] | .label | select(test("spec-dash"))]'
      }
      When call dash_tabs
      The output should equal '["-spec-dash"]'
    End

    It 'renames another session and then kills it'
      rename_kill() {
        mux::rename_session spec-renamed spec-other || return 1
        mux::list_sessions | grep -c '^spec-renamed$'
        mux::kill_session spec-renamed || return 1
        mux::list_sessions | grep -c '^spec-renamed$' || true
      }
      When call rename_kill
      The line 1 of output should equal "1"
      The line 2 of output should equal "0"
    End

    It 'never starts a server of its own when the socket is stale'
      stale() {
        REX_SERVER="unix:///tmp/mxrx-nope-$$.sock" mux::list_sessions
        [[ ! -e "/tmp/mxrx-nope-$$.sock" ]]
      }
      When call stale
      The status should be success
      The output should equal ""
    End
  End
End
