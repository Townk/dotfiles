# The Rex side's shared primitives (reuse inventory, section B "Multiplexer
# layer"): each of these used to be written out at its call sites, and the
# copies had started to differ. One example group per helper, pinning the
# rex argv it sends and the answer it gives. Hermetic: `rex` is a stub that
# logs its argv and answers from fixtures; the tty is a canned sequence.
Describe 'Rex primitives of the mux shim'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() {
    RH_TMP=$(mktemp -d)
    cat >"$RH_TMP/rex" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$RH_TMP/rex.log"
case " \$* " in
  *" client ls "*) cat "$RH_TMP/clients.json" ;;
  *" session.view "*) [ "\${STUB_VIEW:-ok}" = ok ] || exit 1; cat "$RH_TMP/view.json" ;;
  *" ls --json "*) echo '{"sessions":[{"session_id":"session:1","label":"Main"},{"session_id":"session:2","label":"Jobs"},{"session_id":"session:3","label":"Jobs"}]}' ;;
  *" session.new_layer "*) cat >"$RH_TMP/req.json"; echo '{"block_ids":["block:layer"]}' ;;
  *" block inspect "*)
    n=\$(cat "$RH_TMP/inspects" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" >"$RH_TMP/inspects"
    # STUB_INSPECT: one exit status per call, the last one repeating.
    set -- \${STUB_INSPECT:-0}
    [ "\$n" -le "\$#" ] || n=\$#
    eval "exit \\\${\$n}" ;;
esac
exit 0
EOS
    chmod +x "$RH_TMP/rex"
    cat >"$RH_TMP/view.json" <<'EOS'
{"session_id":"session:1","active_window_id":"window:b","windows":[
 {"window_id":"window:a","label":"logs","focused_block_id":"block:a1","layers":[
   {"layer_id":"layer:a","kind":"tiled","blocks":[{"block_id":"block:a1","label":"shell"}]}]},
 {"window_id":"window:b","label":"work","focused_block_id":"block:f1","layers":[
   {"layer_id":"layer:b","kind":"tiled","blocks":[{"block_id":"block:b1","label":"Quick View"},{"block_id":"block:b2"}]},
   {"layer_id":"layer:f","kind":"floating","bounds":[0.1,0.2,0.8,0.6],"blocks":[{"block_id":"block:f1","label":"Quick View"}]}]},
 {"window_id":"window:c","label":"logs","layers":[
   {"layer_id":"layer:c","kind":"tiled","blocks":[{"block_id":"block:c1"}]}]}]}
EOS
    cat >"$RH_TMP/clients.json" <<'EOS'
{"clients":[
 {"client_id":"client:mac","info":{"kind":"app"},"connection_state":"connected","principal":{"transport":"unix"},"session_ids":["session:1","session:2"]},
 {"client_id":"client:ipad","info":{"kind":"app"},"connection_state":"connected","principal":{"transport":"tailscale"},"session_ids":["session:2"]},
 {"client_id":"client:idle","info":{"kind":"app"},"connection_state":"connected","principal":{"transport":"unix"},"session_ids":[]},
 {"client_id":"client:gone","info":{"kind":"app"},"connection_state":"lost","principal":{"transport":"unix"},"session_ids":["session:1"]},
 {"client_id":"client:cli","info":{"kind":"cli"},"connection_state":"connected","principal":{"transport":"unix"}}]}
EOS
    export MUX_REX_BIN="$RH_TMP/rex" REX_SESSION=session:1 REX_BLOCK=block:b1
    unset TMUX STUB_VIEW STUB_INSPECT _MUX_RX_AWAIT_MISSES
  }
  cleanup() { rm -rf "$RH_TMP"; unset MUX_REX_BIN REX_SESSION REX_BLOCK TMUX STUB_VIEW STUB_INSPECT; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  calls() { cat "$RH_TMP/rex.log" 2>/dev/null || true; }
  inspects() { cat "$RH_TMP/inspects" 2>/dev/null || print 0; }

  # The one launcher of a layer running rex-modal: the floats, mux-modal and
  # rex-picker all go through it, so the command line is pinned here once.
  Describe '_mux_rx_modal_layer'
    layer() { ( cd "$RH_TMP" && HOME=/home/u _mux_rx_modal_layer "$@" ); }
    cmdline() { jq -r '.layout.block.options.command | join(" ")' "$RH_TMP/req.json"; }
    req_cwd() { jq -r '.layout.block.options.cwd // "none"' "$RH_TMP/req.json"; }

    It 'runs rex-modal over our block, in our directory, and prints the block'
      plain() { layer 70% 60% Pick -- --no-chrome -- /bin/true a; cmdline; [[ "$(req_cwd)" == "$RH_TMP" ]] && print cwd-ours; jq -r '.layout.block.label' "$RH_TMP/req.json"; }
      When call plain
      The output should equal "block:layer
/home/u/.config/mux/scripts/rex-modal --origin block:b1 --no-chrome -- /bin/true a
cwd-ours
Pick"
    End

    It 'promises a height in cells to the target, ahead of the caller'"'"'s variables'
      rows() { layer --env A=1 --env B=2 57 15 "" -- -- /bin/true >/dev/null; cmdline; }
      When call rows
      The output should equal "env MUX_REX_MODAL_ROWS=15 A=1 B=2 /home/u/.config/mux/scripts/rex-modal --origin block:b1 -- /bin/true"
    End

    It 'takes another directory, or none, from the caller'
      dirs() { layer --cwd /tmp 70% 60% "" -- -- /bin/true >/dev/null; req_cwd; layer --cwd "" 70% 60% "" -- -- /bin/true >/dev/null; req_cwd; }
      When call dirs
      The output should equal "/tmp
none"
    End

    It 'runs the modal named by $MUX_REX_MODAL'
      other() { MUX_REX_MODAL=/opt/modal layer --env A=1 70% 60% "" -- -- /bin/true >/dev/null; cmdline; }
      When call other
      The output should equal "env A=1 /opt/modal --origin block:b1 -- /bin/true"
    End
  End

  Describe '_mux_rx_run'
    It 'never lets a call start a server'
      ran() { _mux_rx_run whoami --json; calls; }
      When call ran
      The output should equal "--autostart=false whoami --json"
    End

    It 'puts a leading --timeout in front of the subcommand, as its own'
      ran() { _mux_rx_run --timeout 5s -C client:mac do -s session:1 some.action; calls; }
      When call ran
      The output should equal "--autostart=false --timeout 5s -C client:mac do -s session:1 some.action"
    End

    It 'leaves a --timeout that is not first to the subcommand'
      ran() { _mux_rx_run wait --timeout 9s block:x; calls; }
      When call ran
      The output should equal "--autostart=false wait --timeout 9s block:x"
    End

    It 'fails without calling anything when there is no rex'
      none() ( unset MUX_REX_BIN REX_BIN_DIR; HOME="$RH_TMP/nohome"; PATH=/nonexistent; _mux_rx_run whoami )
      Skip if 'a rex is installed where the shim looks' test -x /opt/homebrew/bin/rex -o -x /usr/local/bin/rex
      When call none
      The status should be failure
    End
  End

  Describe '_mux_rx_view'
    It 'reads our session with no timeout by default'
      ran() { _mux_rx_view >/dev/null; calls; }
      When call ran
      The output should equal "--autostart=false api call -s session:1 session.view"
    End

    It 'reads the session named, under the timeout named'
      ran() { _mux_rx_view --timeout 3s block:x >/dev/null; calls; }
      When call ran
      The output should equal "--autostart=false --timeout 3s api call -s block:x session.view"
    End
  End

  Describe 'readers of the view'
    It 'lists every window of a label, in tab order'
      When call _mux_rx_window_by_label logs
      The output should equal "window:a
window:c"
    End

    It 'prints nothing for a label no window has'
      When call _mux_rx_window_by_label nope
      The output should equal ""
    End

    It 'asks the session it is given'
      ran() { _mux_rx_window_by_label work session:9; calls; }
      When call ran
      The output should equal "window:b
--autostart=false api call -s session:9 session.view"
    End

    It 'finds the window a block sits in, tiled or floating'
      both() { _mux_rx_window_of block:c1; _mux_rx_window_of block:f1; _mux_rx_window_of block:none; }
      When call both
      The output should equal "window:c
window:b"
    End

    It 'gives the floating layer holding a block, with its bounds'
      When call _mux_rx_float_of block:f1
      The output should equal "layer:f 0.1 0.2 0.8 0.6"
    End

    It 'gives nothing for a tiled block'
      When call _mux_rx_float_of block:b1
      The output should equal ""
    End

    It 'lists the floating blocks of a label, leaving a tiled one of the same label alone'
      When call _mux_rx_floats_by_label "Quick View"
      The output should equal "block:f1"
    End

    It 'gives the focused block of the ACTIVE window'
      When call _mux_rx_focused_block
      The output should equal "block:f1"
    End

    It 'reads a view it is handed without asking the server'
      handed() {
        _mux_rx_focused_block session:1 '{"active_window_id":"w","windows":[{"window_id":"w","focused_block_id":"block:z"}]}'
        _mux_rx_window_by_label t "" '{"windows":[{"window_id":"window:t","label":"t"}]}'
        print -r -- "calls=$(calls | wc -l | tr -d ' ')"
      }
      When call handed
      The output should equal "block:z
window:t
calls=0"
    End

    # The caller that fetched under its own timeout and got nothing must not
    # be answered by a second, unbounded fetch.
    It 'does not fetch again when the view it was handed is empty'
      handed() { _mux_rx_focused_block session:1 ""; print -r -- "calls=$(calls | wc -l | tr -d ' ')"; }
      When call handed
      The output should equal "calls=0"
    End

    It 'prints nothing when the server does not answer'
      export STUB_VIEW=down
      When call _mux_rx_window_of block:b1
      The output should equal ""
    End
  End

  Describe '_mux_rx_session_id'
    It 'gives the id of the first session with that exact label'
      ids() { _mux_rx_session_id Jobs; _mux_rx_session_id Main; _mux_rx_session_id main; calls | sort -u; }
      When call ids
      The output should equal "session:2
session:1
--autostart=false ls --json"
    End
  End

  Describe '_mux_rx_app_clients'
    It 'lists connected apps with the first session each shows, under a timeout'
      ran() { _mux_rx_app_clients; calls; }
      When call ran
      The output should equal "client:mac session:1
client:ipad session:2
--autostart=false --timeout 3s client ls --json"
    End

    It 'keeps only the apps on this machine with --local'
      When call _mux_rx_app_clients --local
      The output should equal "client:mac session:1"
    End

    It 'keeps the apps showing a session, and names that session'
      When call _mux_rx_app_clients --session session:2
      The output should equal "client:mac session:2
client:ipad session:2"
    End

    It 'combines the two'
      both() { _mux_rx_app_clients --local --session session:2; _mux_rx_app_clients --session session:9 --local; }
      When call both
      The output should equal "client:mac session:2"
    End

    It 'prints nothing, quietly, when the server does not answer'
      down() { : >"$RH_TMP/clients.json"; _mux_rx_app_clients --local; }
      When call down
      The output should equal ""
      The stderr should equal ""
    End
  End

  Describe '_mux_rx_block_gone'
    probe() { _mux_rx_block_gone block:x; print -r -- "rc=$?"; }

    It 'asks once, by block id, under a timeout'
      ran() { _mux_rx_block_gone block:x; calls; }
      When call ran
      The output should equal "--autostart=false --timeout 3s block inspect -s block:x block:x"
    End

    Parameters
      0 1   # the server answered for it: alive
      3 0   # the server does not know it: gone
      4 0   # no server: gone with it
      1 2   # anything else proves nothing
      124 2 # a timeout too
    End
    It "answers $2 when block inspect exits $1"
      export STUB_INSPECT="$1"
      When call probe
      The output should equal "rc=$2"
    End
  End

  Describe '_mux_rx_wait_block_gone'
    waited() { _mux_rx_wait_block_gone "$@"; print -r -- "rc=$? probes=$(inspects)"; }

    It 'returns as soon as the block is gone'
      export STUB_INSPECT="0 0 3"
      When call waited block:x
      The output should equal "rc=0 probes=3"
    End

    It 'gives up after a run of unanswered probes'
      export STUB_INSPECT="1"
      When call waited block:x 3
      The output should equal "rc=0 probes=3"
    End

    It 'starts the count again when the server answers'
      export STUB_INSPECT="1 1 0 1 1 0 1 1 1"
      When call waited block:x 3
      The output should equal "rc=0 probes=9"
    End

    It 'takes its default run from $_MUX_RX_AWAIT_MISSES'
      export STUB_INSPECT="1" _MUX_RX_AWAIT_MISSES=2
      When call waited block:x
      The output should equal "rc=0 probes=2"
    End

    It 'stops, saying so, once the process it waits for has exited'
      dead() { true & local pid=$!; wait "$pid"; export STUB_INSPECT=0; waited block:x 25 "$pid"; }
      When call dead
      The output should equal "rc=1 probes=0"
    End
  End

  Describe 'mux::in_rex'
    answer() { mux::in_rex && print yes || print no; }

    It 'is true in a Rex pane'
      When call answer
      The output should equal "yes"
    End

    It 'yields to a tmux started inside the pane'
      export TMUX=/tmp/s,1,0
      When call answer
      The output should equal "no"
    End

    It 'is false with a session but no pane'
      unset REX_BLOCK
      When call answer
      The output should equal "no"
    End

    It 'does not listen to $MUX_BACKEND'
      unset REX_BLOCK REX_SESSION
      export MUX_BACKEND=rex
      When call answer
      The output should equal "no"
      unset MUX_BACKEND
    End
  End

  Describe 'the pane tty size'
    # A canned tty: one "rows cols" per read from $RH_TMP/sizes, the last
    # line repeating; `none` is a tty that cannot be read.
    fake_tty() {
      print -rl -- "$@" >"$RH_TMP/sizes"
      : >"$RH_TMP/reads"
      mux::tty_size() {
        local n line
        print x >>"$RH_TMP/reads"
        n=$(wc -l <"$RH_TMP/reads")
        line="$(sed -n "${n}p" "$RH_TMP/sizes")"
        [[ -n "$line" ]] || line="$(tail -n 1 "$RH_TMP/sizes")"
        [[ "$line" == none ]] && return 1
        print -r -- "$line"
      }
    }
    awaited() { mux::await_tty_size "$@"; print -r -- "rc=$? reads=$(wc -l <"$RH_TMP/reads" | tr -d ' ')"; }

    It 'reads "rows cols" from the tty, or fails with nothing'
      real() { local s; if s="$(mux::tty_size 2>/dev/null)"; then [[ "$s" == <->" "<-> ]]; else [[ -z "$s" ]]; fi; }
      When call real
      The status should be success
    End

    It 'waits for two equal reads by default'
      settled() { fake_tty "24 80" "30 100" "41 132" "41 132" "50 200"; awaited --stable 20 0.01; }
      When call settled
      The output should equal "41 132
rc=0 reads=4"
    End

    It 'prints the last size read when it never settles within the tries'
      restless() { fake_tty "1 1" "2 2" "3 3" "4 4" "5 5"; awaited 3 0.01; }
      When call restless
      The output should equal "3 3
rc=0 reads=3"
    End

    It 'waits for the size to move off the one named with --not'
      moved() { fake_tty "24 80" "24 80" "41 132"; awaited --not 24x80 12 0.01; }
      When call moved
      The output should equal "41 132
rc=0 reads=3"
    End

    It 'settles for the named size when the tries run out'
      born() { fake_tty "24 80"; awaited --not 24x80 4 0.01; }
      When call born
      The output should equal "24 80
rc=0 reads=4"
    End

    It 'fails with nothing when the tty cannot be read'
      blind() { fake_tty "24 80" none; awaited --stable 5 0.01; }
      When call blind
      The output should equal "rc=1 reads=2"
    End

    It 'gives "cols rows" for a float outside a multiplexer, 80x24 with no tty'
      sized() { fake_tty "41 132"; _mux::tty_terminal_size; fake_tty none; _mux::tty_terminal_size; }
      When call sized
      The output should equal "132 41
80 24"
    End
  End
End

# The path of the CLI inside the Rex Mac app is data (rexAppCli) for the
# files that are templates, and a literal in the zsh libs, which are not. One
# value, and one "find rex" preamble for the three apply hooks.
Describe 'the Rex app bundle path'
  app_path() { sed -n 's/^rexAppCli: "\(.*\)"$/\1/p' home/.chezmoidata/mux.yaml; }
  literal_in() { grep -o 'app="$HOME/[^"]*"' "$1" | sed -e 's/^app="$HOME\///' -e 's/"$//'; }
  render() { chezmoi -S "$SHELLSPEC_PROJECT_ROOT" execute-template <"$1"; }
  HOOKS="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts"

  It 'is the same in the data and in the mux shim'
    When call literal_in home/dot_local/lib/mux/rex.zsh
    The output should equal "$(app_path)"
    The output should include "com.superlogical.rex"
  End

  It 'is the same in the data and in the job lib'
    When call literal_in home/dot_local/lib/job/rex.zsh
    The output should equal "$(app_path)"
  End

  It 'is spelled in no template: they take it from the data'
    spelled() {
      grep -l 'com\.superlogical\.rex/RexServer' home/.chezmoiscripts/* home/.chezmoitemplates/* \
        home/dot_config/rex/init.lua.tmpl 2>/dev/null || true
    }
    When call spelled
    The output should equal ""
  End

  It 'reaches all three hooks through one preamble'
    preambles() {
      local f
      for f in run_onchange_after_59-reload-rex run_after_60-rex-main-session run_onchange_after_61-rex-settings; do
        render "$HOOKS/$f.sh.tmpl" | sed -n '/^rex="${MUX_REX_BIN:-}"$/,/|| exit 0$/p' | shasum | cut -d' ' -f1
      done | sort -u | wc -l | tr -d ' '
      render "$HOOKS/run_after_60-rex-main-session.sh.tmpl" | grep -c "app=\"\$HOME/$(app_path)\""
      grep -c 'includeTemplate "rex-bin.sh.tmpl"' "$HOOKS"/run_onchange_after_59-reload-rex.sh.tmpl \
        "$HOOKS"/run_after_60-rex-main-session.sh.tmpl "$HOOKS"/run_onchange_after_61-rex-settings.sh.tmpl | cut -d: -f2 | tr '\n' ' '
    }
    When call preambles
    The output should equal "1
1
1 1 1 "
  End

  It 'reaches the Rex config, which still parses'
    Skip if 'no luac' eval '! command -v luac >/dev/null 2>&1'
    config() { render home/dot_config/rex/init.lua.tmpl >"$SHELLSPEC_TMPBASE/init.lua" && luac -p "$SHELLSPEC_TMPBASE/init.lua" && grep -c "HOME .. \"/$(app_path)\"" "$SHELLSPEC_TMPBASE/init.lua"; }
    When call config
    The output should equal "1"
  End
End
