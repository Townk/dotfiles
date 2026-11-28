# Tests for the quick-launch Rex backend: lib/rows.zsh (the plain row emitter
# behind Rex's native picker) and lib/dispatch-rex.zsh (the twin of
# dispatch-tmux.zsh).
#
# The row rules are asserted with the mux shim's session queries stubbed, so
# they run anywhere. The dispatch half drives a real Rex server — a SCRATCH
# one on its own socket and state dir, never the developer's live server
# (spec_helper.sh unsets REX_SERVER; every call goes to the socket exported
# here) — and is skipped on a box without rex.
Describe 'quick-launch on Rex'
  load_libs() {
    export MUX_LIB="$PWD/home/dot_local/lib"
    source home/dot_config/mux/scripts/lib/config.zsh
    source home/dot_config/mux/scripts/lib/command.zsh
    source home/dot_config/mux/scripts/lib/dispatch.zsh
    source home/dot_config/mux/scripts/lib/dispatch-tmux.zsh
    source home/dot_config/mux/scripts/lib/dispatch-rex.zsh
    source home/dot_config/mux/scripts/lib/rows.zsh
    QL_JSON='{
      "panes":[{"id":"logs","name":"Logs","direction":"down","size":"30%","action":{"type":"Run","args":["sleep 60"]}},
               {"id":"pad","name":"Pad","direction":"floating","size":"60% x 40%","action":{"type":"Run","args":["sleep 60"]}}],
      "tabs":[{"id":"dev","name":"Dev","action":{"type":"Shell","cwd":"/tmp"}}],
      "workspaces":[
        {"id":"proj","name":"proj","tabs":[
          {"id":"t1","name":"Edit","panes":[
            {"id":"ed","name":"Editor","action":{"type":"Run","cwd":"/tmp","args":["sleep 60"]}},
            {"id":"sh","name":"Side","direction":"right","size":"40%","action":{"type":"Run","args":["sleep 60"]}},
            {"id":"opt","name":"Extra","optional":true,"action":{"type":"Run","args":["sleep 60"]}}]},
          {"id":"t2","name":"Notes","action":{"type":"Run","args":["sleep 60"]}}]},
        {"id":"dot-files","name":"dot-files","action":{"type":"Shell","cwd":"~/x"}},
        {"id":"box","name":"box","action":{"type":"Remote","args":["box.example"]}},
        {"id":"here","name":"here","action":{"type":"Shell"}}]}'
  }

  Describe 'rows'
    setup() {
      ROWS_TMP=$(mktemp -d)
      export XDG_CACHE_HOME="$ROWS_TMP/cache"
      load_libs
      # The shim's answers, as a picker running in session "here" would get.
      mux::current_session() { print -r -- here; }
      mux::current_tab_name() { print -r -- "${STUB_TAB:-}"; }
      mux::list_sessions() { print -rl -- here box scratch-pad; }
      mux::attached_sessions() { print -rl -- here box; }
    }
    cleanup() { rm -rf "$ROWS_TMP"; unset XDG_CACHE_HOME MUX_LIB STUB_TAB; }
    BeforeEach 'setup'
    AfterEach 'cleanup'

    ids() { ql_rows "$1" | cut -f1 | tr '\n' ' '; }
    field() { ql_rows "$1" | awk -F'\t' -v id="$2" -v n="$3" '$1 == id { print $n }'; }

    It 'omits the current session and orders live, ad-hoc, then not running'
      When call ids workspace
      The output should equal "box scratch-pad proj dot-files "
    End

    It 'tags a live session shown by an app as "other window"'
      When call field workspace box 5
      The output should equal "other window"
    End

    It 'tags an undefined live session as ad-hoc and detached'
      When call field workspace scratch-pad 5
      The output should equal "ad-hoc, detached"
    End

    It 'leaves a workspace that is not running untagged'
      When call field workspace proj 5
      The output should equal ""
    End

    It 'title-cases a session name the way the fzf picker does'
      When call field workspace dot-files 2
      The output should equal "Dot Files"
    End

    It 'describes a remote by its ssh target and picks the server icon'
      remote() { print -r -- "$(field workspace box 3)|$(field workspace box 4)"; }
      When call remote
      The output should equal "ssh box.example|server"
    End

    It 'floats recently picked workspaces to the front, keeping the rest in order'
      recent() {
        ql_record_usage workspace dot-files
        ql_record_usage workspace proj
        ids workspace
      }
      When call recent
      The output should equal "proj dot-files box scratch-pad "
    End

    It 'keeps one entry per id in the recency cache'
      twice() {
        ql_record_usage workspace proj
        ql_record_usage workspace box
        ql_record_usage workspace proj
        tr '\n' ' ' < "$XDG_CACHE_HOME/quick-launch/usage-workspace"
      }
      When call twice
      The output should equal "proj box "
    End

    It 'records nothing for kinds without a recency cache'
      When call ql_record_usage tab dev
      The status should be success
      The path "$XDG_CACHE_HOME/quick-launch/usage-workspace" should not be exist
    End

    It 'lists only the global panes outside their parents'
      When call ids pane
      The output should equal "logs pad "
    End

    It 'lists tabs in file order'
      When call ids tab
      The output should equal "dev "
    End

    It 'never emits a tab or newline inside a field'
      shape() { ql_rows workspace | awk -F'\t' 'NF != 5 { bad++ } END { print bad + 0 }'; }
      When call shape
      The output should equal "0"
    End
  End

  Describe 'rows inside a workspace tab'
    setup() {
      ROWS_TMP=$(mktemp -d)
      export XDG_CACHE_HOME="$ROWS_TMP/cache"
      load_libs
      mux::current_session() { print -r -- proj; }
      mux::current_tab_name() { print -r -- Edit; }
      mux::list_sessions() { print -rl -- proj; }
      mux::attached_sessions() { print -rl -- proj; }
    }
    cleanup() { rm -rf "$ROWS_TMP"; unset XDG_CACHE_HOME MUX_LIB; }
    BeforeEach 'setup'
    AfterEach 'cleanup'

    It 'offers the active tab'"'"'s panes first, its optional one included'
      panes() { ql_rows pane | cut -f1 | tr '\n' ' '; }
      When call panes
      The output should equal "ed sh opt logs pad "
    End
  End

  Describe 'float size'
    BeforeEach 'load_libs'
    It 'applies one value to both axes'
      When call ql_rx_float_size "70%"
      The output should equal "70% 70%"
    End
    It 'splits WIDTH x HEIGHT, percent or cells'
      When call ql_rx_float_size "100 x 30%"
      The output should equal "100 30%"
    End
    It 'falls back to 80% on nonsense'
      When call ql_rx_float_size "big"
      The output should equal "80% 80%"
    End
  End

  Describe 'backend selection'
    BeforeEach 'load_libs'
    AfterEach 'unset REX_SESSION TMUX'
    It 'drives Rex in a Rex pane'
      REX_SESSION=session:x
      When call ql_on_rex
      The status should be success
    End
    It 'yields to a tmux running inside the Rex pane'
      REX_SESSION=session:x TMUX=/tmp/s,1,0
      When call ql_on_rex
      The status should be failure
    End
    It 'refuses to open a workspace in a separate window'
      REX_SESSION=session:x
      When call ql_dispatch_window proj
      The status should be failure
      The stderr should include "not supported on Rex"
    End
  End

  Describe 'dispatch against a scratch server'
    rex_missing() { ! command -v rex >/dev/null 2>&1; }
    Skip if 'rex is not installed' rex_missing

    rx() { command rex --autostart=false -S "$RX_SERVER" "$@"; }
    view() { rx api call -s "$1" session.view; }

    # serve_ready <log> <command…> — start a scratch server in the background
    # and return when it is listening. No poll and no clock: the server's own log
    # says "Rex server ready" once its socket accepts, so the log goes through a
    # FIFO to a reader that keeps <log> as a file and reports that line (or the
    # server ending before it) on a second FIFO, which this blocks on. Sets
    # SERVE_PID; fails, showing the log, for a server that never got there.
    # (rex has no readiness flag, and its --timeout does not wait for a socket
    # that is not there yet: it fails at once.)
    serve_ready() {
      local log="$1" state=""
      shift
      mkfifo "$log.fifo" "$log.ready" || return 1
      awk -v log_file="$log" -v ready="$log.ready" '
        { print >> log_file; fflush(log_file) }
        /Rex server ready/ && !up { up = 1; print "ready" > ready; close(ready) }
        END { if (!up) { print "ended" > ready; close(ready) } }' <"$log.fifo" >/dev/null 2>&1 &
      "$@" >"$log.fifo" 2>&1 &
      SERVE_PID=$!
      read -r state <"$log.ready"
      rm -f "$log.fifo" "$log.ready"
      [[ "$state" == ready ]] || { cat "$log" >&2; return 1; }
    }
    start_server() {
      RX_STATE=$(mktemp -d)
      RX_SOCK="/tmp/qlrx-$$.sock"
      # The real CLI, against the scratch server only: spec_helper pins
      # MUX_REX_BIN to a rex that refuses, so no other spec reaches a live one.
      MUX_REX_BIN=$(command -v rex)
      export MUX_REX_BIN
      RX_SERVER="unix://$RX_SOCK"
      : > "$RX_STATE/init.lua"
      # Panes inherit the server's environment, so this ZDOTDIR is what every
      # shell the dispatch starts will read: an interactive one leaves a mark,
      # and none of them touches the developer's real ~/.zshrc.
      mkdir -p "$RX_STATE/zdot"
      print -r -- ': >> "$ZDOTDIR/interactive-ran"' >"$RX_STATE/zdot/.zshrc"
      serve_ready "$RX_STATE/server.log" env ZDOTDIR="$RX_STATE/zdot" \
        rex server run --listen "$RX_SERVER" --state-dir "$RX_STATE/state" \
        --config "$RX_STATE/init.lua" --restore=false || return 1
      RX_PID=$SERVE_PID
      RX_SID=$(rx new here --window first -c /tmp --shell none --json -- /bin/zsh -f | jq -r '.session_id')
      RX_BID=$(rx block ls -s "$RX_SID" --json | jq -r '.blocks[0].block_id')
    }
    stop_server() {
      rx server stop >/dev/null 2>&1
      kill "$RX_PID" 2>/dev/null
      rm -rf "$RX_STATE" "$RX_SOCK"
    }
    BeforeAll 'start_server'
    AfterAll 'stop_server'

    in_pane() {
      export REX_SERVER="$RX_SERVER" REX_SESSION="$RX_SID" REX_BLOCK="$RX_BID" SHELL=/bin/zsh
      load_libs
    }
    out_pane() { unset REX_SERVER REX_SESSION REX_BLOCK MUX_LIB; }
    BeforeEach 'in_pane'
    AfterEach 'out_pane'

    It 'builds a workspace: tabs, a split chain, labels, no optional pane, no placeholder'
      build() {
        local out sid
        out=$(ql_dispatch workspace proj) || return 1
        sid=${out#@select:}
        print -r -- "${out%%:*}"
        view "$sid" | jq -r '[.windows[].label] | join(",")'
        view "$sid" | jq -r '[.windows[0].layers[].blocks[].label] | join(",")'
        view "$sid" | jq -r '.windows | to_entries[] | select(.value.window_id == $a) | .key + 1' \
          --arg a "$(view "$sid" | jq -r '.active_window_id')"
      }
      When call build
      The line 1 of output should equal "@select"
      The line 2 of output should equal "Edit,Notes"
      The line 3 of output should equal "Editor,Side"
      The line 4 of output should equal "1"
    End

    It 'switches to an existing workspace instead of building a second one'
      again() {
        ql_dispatch workspace proj >/dev/null || return 1
        rx ls --json | jq -r '[.sessions[] | select(.label == "proj")] | length'
      }
      When call again
      The output should equal "1"
    End

    # The quick-launch SCRIPT runs under `set -e`; the libraries sourced by
    # this spec do not. A statement that is only fatal under errexit (an
    # arithmetic `((n++))` from zero) once ended the script after the session
    # was built and before `@select:` was printed — so the app never switched
    # to a workspace it had just created. This one runs the script itself.
    It 'reports a freshly built workspace when run as the real script'
      real_script() {
        local sid tmp
        sid=$(ql_rx_session_id proj)
        [[ -n "$sid" ]] && rx kill "$sid" >/dev/null 2>&1
        tmp=$(mktemp -d)
        print -r -- "$QL_JSON" >"$tmp/targets.json"
        QUICK_LAUNCH_TARGETS="$tmp/targets.json" XDG_CACHE_HOME="$tmp/cache" \
          zsh home/dot_config/mux/scripts/executable_quick-launch pick workspace proj | sed 's/:.*//'
        print -r -- "status=${pipestatus[1]}"
        rm -rf "$tmp"
      }
      When call real_script
      The line 1 of output should equal "@select"
      The line 2 of output should equal "status=0"
    End

    It 'treats a live session with no definition as a workspace'
      adhoc() {
        local sid
        sid=$(rx new loose --shell none --json -- /bin/zsh -f | jq -r '.session_id')
        [[ "$(ql_dispatch workspace loose)" == "@select:$sid" ]]
      }
      When call adhoc
      The status should be success
    End

    It 'opens a tab in the current session, then focuses it on the second ask'
      tab_twice() {
        ql_dispatch tab dev >/dev/null || return 1
        ql_dispatch tab dev >/dev/null || return 1
        view "$RX_SID" | jq -r '[.windows[] | select(.label == "Dev")] | length'
      }
      When call tab_twice
      The output should equal "1"
    End

    It 'opens a tab whose name starts with a dash, then focuses it on the second ask'
      dash_tab_twice() {
        ql_dispatch tab dash >/dev/null || return 1
        ql_dispatch tab dash >/dev/null || return 1
        view "$RX_SID" | jq -c '[.windows[] | .label | select(test("dashed"))]'
      }
      QL_JSON=$(jq -c '.tabs += [{"id":"dash","name":"-dashed","action":{"type":"Run","args":["sleep 60"]}}]' <<<"$QL_JSON")
      When call dash_tab_twice
      The output should equal '["-dashed"]'
    End

    # Found live: the server made the new window active and the app stayed on
    # the old tab. Only a client action moves the app, so the script has to
    # say which window to show — on create AND on focus.
    It 'names the window to show when it opens a tab, and again when it focuses it'
      shown() {
        local want first second
        first=$(ql_dispatch tab dev) || return 1
        second=$(ql_dispatch tab dev) || return 1
        want="@select:$RX_SID $(view "$RX_SID" | jq -r '[.windows[] | select(.label == "Dev") | .window_id] | first')"
        [[ "$first" == "$want" ]] && print -r -- created-ok
        [[ "$second" == "$want" ]] && print -r -- focused-ok
      }
      When call shown
      The line 1 of output should equal "created-ok"
      The line 2 of output should equal "focused-ok"
    End

    It 'names the window of an existing pane it focuses, wherever that pane is'
      pane_window() {
        local out
        ql_dispatch pane logs >/dev/null || return 1
        out=$(ql_dispatch pane logs) || return 1
        [[ "$out" == "@select:$RX_SID window:"* ]] && print -r -- ok
      }
      When call pane_window
      The output should equal "ok"
    End

    # Second live finding: the app's focus stayed on the old pane although
    # the server had moved it. No client action focuses a block by id, so the
    # split leaves focus alone and reports the side the new pane is on.
    It 'splits a new pane without taking focus and names the side it is on'
      side() {
        local before out
        before=$(view "$RX_SID" | jq -r '.windows[0].focused_block_id')
        out=$(ql_dispatch pane side-pane) || return 1
        print -r -- "$out"
        [[ "$(view "$RX_SID" | jq -r '.windows[0].focused_block_id')" == "$before" ]] && print -r -- focus-unmoved
      }
      QL_JSON=$(jq -c '.panes += [{"id":"side-pane","name":"SidePane","direction":"right","action":{"type":"Run","args":["sleep 60"]}}]' <<<"$QL_JSON")
      When call side
      The line 1 of output should equal "@focus:right"
      The line 2 of output should equal "focus-unmoved"
    End

    # Third live finding: a floating pane and an already-open pane cannot be
    # reached by direction. From the picker (QL_DEFER_FOCUS) they take no
    # focus and name the block; `focus-later` focuses it once the palette is
    # gone. From a shell they focus at once.
    It 'hands the focus of an already-open pane back to the picker'
      deferred() {
        local first out b
        ql_dispatch pane logs >/dev/null || return 1
        b=$(rx block ls -s "$RX_SID" --json | jq -r '[.blocks[] | select(.label == "Logs") | .block_id] | first')
        rx focus -s "$RX_SID" "$RX_BID" >/dev/null
        out=$(QL_DEFER_FOCUS=1 ql_dispatch pane logs) || return 1
        [[ "$out" == *"@focus-block:$b"* ]] && print -r -- named
        [[ "$(view "$RX_SID" | jq -r '.windows[0].focused_block_id')" == "$RX_BID" ]] && print -r -- not-focused-yet
        ql_rx_focus_later "$b" 0
        [[ "$(view "$RX_SID" | jq -r '.windows[0].focused_block_id')" == "$b" ]] && print -r -- focused-later
      }
      When call deferred
      The line 1 of output should equal "named"
      The line 2 of output should equal "not-focused-yet"
      The line 3 of output should equal "focused-later"
    End

    It 'focuses an already-open pane at once when no picker is involved'
      direct() {
        local b
        ql_dispatch pane logs >/dev/null || return 1
        b=$(rx block ls -s "$RX_SID" --json | jq -r '[.blocks[] | select(.label == "Logs") | .block_id] | first')
        rx focus -s "$RX_SID" "$RX_BID" >/dev/null
        ql_dispatch pane logs >/dev/null || return 1
        [[ "$(view "$RX_SID" | jq -r '.windows[0].focused_block_id')" == "$b" ]] && print -r -- focused
      }
      When call direct
      The output should equal "focused"
    End

    It 'hands the focus of a new floating pane back to the picker'
      float_deferred() {
        local out
        out=$(QL_DEFER_FOCUS=1 ql_dispatch pane pad3) || return 1
        [[ "$out" == "@focus-block:block:"* ]] && print -r -- named
        [[ "$(view "$RX_SID" | jq -r '.windows[0].focused_block_id')" != "${out#@focus-block:}" ]] && print -r -- not-focused-yet
      }
      QL_JSON=$(jq -c '.panes += [{"id":"pad3","name":"Pad3","direction":"floating","size":"50%","action":{"type":"Run","args":["sleep 60"]}}]' <<<"$QL_JSON")
      When call float_deferred
      The line 1 of output should equal "named"
      The line 2 of output should equal "not-focused-yet"
    End

    It 'runs a command through an interactive shell, as a tmux pane would'
      interactive() {
        local log="$RX_STATE/rex-argv.log"
        cat >"$RX_STATE/rexwrap" <<EOS
#!/bin/sh
echo "\$*" >>"$log"
exec rex "\$@"
EOS
        chmod +x "$RX_STATE/rexwrap"
        MUX_REX_BIN="$RX_STATE/rexwrap" ql_dispatch pane logs2 >/dev/null || return 1
        MUX_REX_BIN="$RX_STATE/rexwrap" ql_dispatch tab dev2 >/dev/null || return 1
        grep -c -- '--interactive -- /bin/zsh -c' "$log"
      }
      QL_JSON=$(jq -c '.panes += [{"id":"logs2","name":"Logs2","action":{"type":"Run","args":["sleep 60"]}}] | .tabs += [{"id":"dev2","name":"Dev2","action":{"type":"Run","args":["sleep 60"]}}]' <<<"$QL_JSON")
      When call interactive
      The output should equal "2"
    End

    It 'asks for an interactive shell in a floating pane too'
      float_inter() {
        # The mark is a FIFO here: opening it for reading blocks until an
        # interactive shell opens it to leave its mark. (A float started
        # without one never does, and the example hangs instead of failing.)
        local mark="$RX_STATE/zdot/interactive-ran"
        rm -f "$mark"
        mkfifo "$mark"
        ql_dispatch pane pad2 >/dev/null || return 1
        : <"$mark"
        rm -f "$mark"
        print -r -- true
      }
      QL_JSON=$(jq -c '.panes += [{"id":"pad2","name":"Pad2","direction":"floating","size":"50%","action":{"type":"Run","args":["sleep 60"]}}]' <<<"$QL_JSON")
      When call float_inter
      The output should equal "true"
    End

    It 'says nothing about windows while building a workspace'
      build_quiet() { ql_dispatch workspace proj | grep -c ' window:' || true; }
      When call build_quiet
      The output should equal "0"
    End

    It 'opens a pane as a labelled split, then focuses it on the second ask'
      pane_twice() {
        ql_dispatch pane logs >/dev/null || return 1
        ql_dispatch pane logs >/dev/null || return 1
        rx block ls -s "$RX_SID" --json | jq -r '[.blocks[] | select(.label == "Logs")] | length'
      }
      When call pane_twice
      The output should equal "1"
    End

    It 'opens a floating pane as its own layer, sized from the target'
      float() {
        ql_dispatch pane pad || return 1
        view "$RX_SID" | jq -r '
          [.windows[].layers[] | select(.kind != "tiled") | select(.blocks[].label == "Pad")
           | "\(.bounds[2]) \(.bounds[3])"] | first'
      }
      When call float
      The output should equal "0.6 0.4"
    End

    It 'fails for a target that does not exist'
      When call ql_dispatch pane nope
      The status should be failure
      The stderr should include "no pane target"
    End
  End
End
