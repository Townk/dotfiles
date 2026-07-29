# Tests for the mux MODE STACK (lib/mux/stack.zsh via the mux-stack CLI) —
# the single source of truth the which-key panel, the search dialog and the
# generated key tables all transition through (migration Phase 5).
#
# The stack is pure enough to test headlessly: a scratch tmux server on its
# own socket holds @mux_stack, and an OUTER scratch server attaches a real
# client to it — client_key_table and copy-mode are per-client/per-pane state,
# so a client-less server could not show that the key table and the popup are
# DERIVED VIEWS of the stack. Every behaviour asserted here was once a Mode B
# bug report (pops needing two presses, visibility leaking between modes).
Describe 'mux mode stack'
  setup_all() {
    MS_TMP=$(mktemp -d)
    chezmoi execute-template <home/dot_config/mux/whichkey.data.tmpl >"$MS_TMP/wk.data" 2>/dev/null
    # Isolation by TMUX_TMPDIR, not by `-L`: MUX_TMUX_BIN is ONE word, so a
    # scratch socket used to ride in a wrapper script — and every one of the
    # ~20 tmux calls a stack operation makes then cost TWO processes (sh +
    # tmux). Pointing TMUX_TMPDIR at the scratch dir lets plain `tmux` be the
    # binary and still reach only this server.
    export TMUX_TMPDIR="$MS_TMP"
    # Stand-in for mux-whichkey's panel driver: records that sync asked for a
    # panel, claims the driver flag for as long as `wksleep` says, and holds
    # its stdio open the whole time — a launch that is not fully detached
    # keeps the caller waiting exactly that long.
    cat >"$MS_TMP/wk" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$MS_TMP/opened"
tmux set -g @mux_wk_driver \$\$
s=\$(cat "$MS_TMP/wksleep" 2>/dev/null) || s=0
[ -n "\$s" ] || s=0
sleep "\$s"
tmux set -g @mux_wk_driver 0
EOS
    chmod +x "$MS_TMP/wk"
    tmux -f /dev/null new-session -d -s s -x 80 -y 24
    # A real client: the outer server runs `attach` in a pane (the nested-tmux
    # technique from docs/mux-parity.md).
    # `env -u TMUX`, and TMUX_TMPDIR spelled out: a pane inherits neither the
    # scratch tmpdir nor an unset TMUX, so a bare `tmux attach` here looks in
    # the real socket dir, finds no session, and dies without a word.
    tmux -L outer -f /dev/null new-session -d -s o -x 100 -y 30 \
      "env -u TMUX TMUX_TMPDIR=$MS_TMP tmux attach -t s"
    # Wait for it, and SAY SO if it never arrives: without a client there is
    # no client_key_table and no popup, and every example below would fail
    # with an assertion message that hides the real cause. Ten seconds,
    # because a loaded machine (the rest of the suite) can be slow to attach.
    i=0
    while [ "$i" -lt 200 ] && [ -z "$(tmux list-clients -F '#{client_tty}' 2>/dev/null)" ]; do
      sleep 0.05
      i=$((i + 1))
    done
    if [ -z "$(tmux list-clients -F '#{client_tty}' 2>/dev/null)" ]; then
      printf 'mux_stack_spec: no tmux client attached after 10s — cannot test\n' >&2
      return 1
    fi
  }
  cleanup_all() {
    tmux -L outer kill-server 2>/dev/null
    tmux kill-server 2>/dev/null
    rm -rf "$MS_TMP"
  }
  BeforeAll 'setup_all'
  AfterAll 'cleanup_all'

  reset_stack() {
    # let a stand-in panel from the previous example finish before its driver
    # flag is cleared under it
    i=0
    while [ "$i" -lt 100 ] && [ "$(tmux show -gv @mux_wk_driver 2>/dev/null)" -gt 0 ] 2>/dev/null; do
      sleep 0.05
      i=$((i + 1))
    done
    tmux set -gu @mux_stack 2>/dev/null
    tmux set -g @mux_wk_driver 0 2>/dev/null
    tmux set key-table root 2>/dev/null
    tmux send-keys -X cancel 2>/dev/null
    tmux set -pu @visual 2>/dev/null
    rm -f "$MS_TMP/opened"
    printf '0' >"$MS_TMP/wksleep"
    true
  }
  BeforeEach 'reset_stack'

  # The CLI, for the examples that are ABOUT the CLI (verb dispatch, and the
  # run-shell integration). Everything else drives the library in-process.
  stack() {
    MUX_TMUX_BIN=tmux MUX_LIB_DIR="$PWD/home/dot_local/lib" \
    WK_DATA="$MS_TMP/wk.data" MUX_WK="$MS_TMP/wk" \
      zsh "$PWD/home/dot_config/mux/scripts/executable_mux-stack" "$@"
  }
  # A whole sequence in ONE shell, ending in the stack top as "state:visible".
  # Spawning the CLI per operation cost ~1.4s an example — nearly all of it
  # process startup, since a single operation already makes ~20 tmux calls.
  seq() {
    local op script="source $PWD/home/dot_local/lib/mux/stack.zsh"$'\n'
    for op in "$@"; do
      case "${op%% *}" in
        push)      script+="mux_stack::push ${op#* }"$'\n' ;;
        vis)       script+="mux_stack::set_visible ${op#* }"$'\n' ;;
        pop)       script+="mux_stack::pop"$'\n' ;;
        clear)     script+="mux_stack::clear"$'\n' ;;
        sync)      script+="mux_stack::sync"$'\n' ;;
        reconcile) script+="mux_stack::reconcile"$'\n' ;;
      esac
    done
    script+='mux_stack::top && print -r -- "$MS_STATE:$MS_VIS" || print -r -- "(empty)"'
    MUX_TMUX_BIN=tmux MUX_LIB_DIR="$PWD/home/dot_local/lib" \
    WK_DATA="$MS_TMP/wk.data" MUX_WK="$MS_TMP/wk" \
      zsh -c "$script"
  }
  kt() { tmux display -p '#{client_key_table}'; }
  in_copy() { tmux display -p '#{?pane_in_mode,1,0}'; }
  visual() { tmux display -p '#{?#{@visual},1,0}'; }

  # Two terminals attached at once (Ghostty + WezTerm) is a supported setup,
  # and every client-scoped command has to name the client that pressed the
  # key. The fallback — `list-clients | head -1` — picks whichever attached
  # first, which is how pressing the leader in WezTerm opened the panel in
  # the Ghostty window.
  Describe 'multiple clients'
    seq_as() {   # seq_as <client-tty> <state>
      local c="$1" state="$2"
      MUX_CLIENT="$c" MUX_TMUX_BIN=tmux MUX_LIB_DIR="$PWD/home/dot_local/lib" \
      WK_DATA="$MS_TMP/wk.data" MUX_WK="$MS_TMP/wk" \
        zsh -c "source $PWD/home/dot_local/lib/mux/stack.zsh
                mux_stack::push $state"
      i=0
      while [ "$i" -lt 40 ] && [ ! -s "$MS_TMP/opened" ]; do sleep 0.05; i=$((i + 1)); done
      cat "$MS_TMP/opened" 2>/dev/null
    }

    It 'opens the panel on the client that invoked it'
      When call seq_as /dev/ttyINVOKER command
      The output should include "/dev/ttyINVOKER"
      The status should be success
    End

    It 'still works for callers that cannot name a client'
      When call seq_as "" command
      The output should include "open"
      The status should be success
    End
  End

  Describe 'push'
    It 'starts the stack shown'
      When call seq 'push command'
      The output should equal 'command:1'
    End

    It 'starts a start_hidden state hidden even under a shown parent'
      # zellij `start_hidden "scroll"`: entering Scroll must not paint a panel
      When call seq 'push command' 'push scroll'
      The output should equal 'scroll:0'
    End

    It 'inherits the panel the parent already had up'
      When call seq 'push command' 'push pane'
      The output should equal 'pane:1'
    End

    It 'inherits a hidden parent'
      When call seq 'push command' 'vis 0' 'push pane'
      The output should equal 'pane:0'
    End

    It 'does not stack the state you are already standing in'
      # editing a live search reopens the dialog on the SAME Search entry, and
      # M-w in Command re-arms the leader — a second entry would make
      # Backspace need two presses
      depth() { tmux show -gv @mux_stack; }
      When call seq 'push command' 'push search' 'push search'
      The output should equal 'search:0'
      The result of 'depth()' should equal 'command:1 search:0'
    End
  End

  Describe 'the key table is a derived view'
    It 'arms the one-shot prefix table for Command'
      When call seq 'push command'
      The output should equal 'command:1'
      The result of 'kt()' should equal 'prefix'
    End

    It 'arms the mode table for a table-backed mode'
      When call seq 'push command' 'push pane' 'push resize'
      The output should equal 'resize:1'
      The result of 'kt()' should equal 'resize'
    End

    It 'arms locked, which has no panel of its own'
      When call seq 'push command' 'push locked'
      The output should equal 'locked:1'
      The result of 'kt()' should equal 'locked'
    End

    It 'leaves the copy-mode states on the root table'
      # copy-mode-vi dispatches these; the stack only records which face it wears
      When call seq 'push command' 'push scroll'
      The output should equal 'scroll:0'
      The result of 'kt()' should equal 'root'
    End

    It 'returns to root when the stack empties'
      When call seq 'push command' 'push pane' 'clear'
      The output should equal '(empty)'
      The result of 'kt()' should equal 'root'
    End
  End

  Describe 'visibility'
    It 'toggles only the top entry'
      When call seq 'push command' 'push scroll' 'vis 1'
      The output should equal 'scroll:1'
    End

    It 'drops the top entry visibility with the entry'
      # Mode B find: hiding the panel in Scroll left Command hidden afterwards
      When call seq 'push command' 'push scroll' 'vis 1' 'vis 0' 'pop'
      The output should equal 'command:1'
    End

    It 'keeps a shown parent shown when a child pops'
      # search → BSpace → Scroll, with the panel still up (never dismissed)
      When call seq 'push command' 'push scroll' 'vis 1' 'push search' 'pop'
      The output should equal 'scroll:1'
    End
  End

  Describe 'pop'
    It 'pops exactly one level'
      When call seq 'push command' 'push pane' 'push resize' 'pop'
      The output should equal 'pane:1'
      The result of 'kt()' should equal 'pane'
    End

    It 'empties on the last entry'
      When call seq 'push command' 'pop'
      The output should equal '(empty)'
    End

    It 'is a no-op on an empty stack'
      When call seq 'pop'
      The output should equal '(empty)'
    End

    It 'still leaves a copy-mode entered from outside the stack'
      # a hook, or the app itself, can put the pane in copy-mode without ever
      # touching the stack — Backspace must not strand the user there
      stray_copy() {
        tmux copy-mode
        stack pop >/dev/null
        stack show
      }
      When call stray_copy
      The output should equal '(empty)'
      The result of 'in_copy()' should equal '0'
    End
  End

  Describe 'clear'
    It 'ends the whole stack'
      When call seq 'push command' 'push pane' 'push resize' 'clear'
      The output should equal '(empty)'
      The result of 'kt()' should equal 'root'
    End

    It 'still leaves a copy-mode entered from outside the stack'
      # Escape must end copy-mode even when nothing pushed it
      stray_clear() {
        tmux copy-mode
        stack clear >/dev/null
        stack show
      }
      When call stray_clear
      The output should equal '(empty)'
      The result of 'in_copy()' should equal '0'
    End
  End

  Describe 'copy-mode is a derived view too'
    It 'enters copy-mode with the cursor inert for Scroll'
      When call seq 'push command' 'push scroll'
      The output should equal 'scroll:0'
      The result of 'in_copy()' should equal '1'
      The result of 'visual()' should equal '0'
    End

    It 'raises the cursor for Copy without leaving copy-mode'
      When call seq 'push command' 'push scroll' 'push copy'
      The result of 'in_copy()' should equal '1'
      The result of 'visual()' should equal '1'
    End

    It 'drops back to Scroll when Copy pops, still in copy-mode'
      When call seq 'push command' 'push scroll' 'push copy' 'pop'
      The output should equal 'scroll:0'
      The result of 'in_copy()' should equal '1'
      The result of 'visual()' should equal '0'
    End

    It 'leaves copy-mode when the last copy state pops'
      When call seq 'push command' 'push scroll' 'pop'
      The output should equal 'command:1'
      The result of 'in_copy()' should equal '0'
    End

    It 'leaves copy-mode when the stack is cleared'
      When call seq 'push command' 'push scroll' 'push search' 'clear'
      The output should equal '(empty)'
      The result of 'in_copy()' should equal '0'
    End
  End

  Describe 'reconcile — the safety net for copy-mode leaving on its own'
    # y (copy-pipe-and-cancel), tmux's own q, a mouse scroll to the bottom:
    # copy-mode can END without any stack operation, and the entries would
    # linger — the next M-. would raise a panel for a mode nobody is in.
    It 'drops the copy states when the pane leaves copy-mode'
      escaped_copy() {
        stack push command >/dev/null
        stack push copy >/dev/null              # @visual 1
        tmux send-keys -X cancel      # as `y` or `q` would
        stack reconcile >/dev/null
        stack show
      }
      When call escaped_copy
      The output should equal 'command:1'
      The result of 'kt()' should equal 'prefix'
      # and the pane flags go with them: a stale @visual would make the next
      # copy-mode entry read as Copy instead of Scroll
      The result of 'visual()' should equal '0'
    End

    It 'leaves the stack alone while the pane is still in copy-mode'
      # the hook also fires on ENTERING copy-mode, and mid-transition (a
      # search is cleared by cancelling and re-entering copy-mode)
      still_in_copy() {
        stack push command >/dev/null
        stack push scroll >/dev/null
        stack reconcile >/dev/null
        stack show
      }
      When call still_in_copy
      The output should equal 'scroll:0'
    End

    It 'is a no-op on a stack with no copy state'
      When call seq 'push command' 'push pane' 'reconcile'
      The output should equal 'pane:1'
    End
  End

  Describe 'the panel launch'
    # THE parked blocker: sync forked `mux-whichkey open … &`, and the popup
    # child kept run-shell's pipe open — a run-shell that triggered sync never
    # returned. The launch is handed to the tmux server instead, so the caller
    # is never tied to the panel's lifetime.
    It 'does not wait for the panel it asks for'
      timed_push() {
        printf '1.5' >"$MS_TMP/wksleep"   # a panel that stays up for 1.5s
        local t0=$SECONDS i=0
        env timeout 8 tmux run-shell "TMUX_TMPDIR=$MS_TMP MUX_TMUX_BIN=tmux MUX_LIB_DIR=$PWD/home/dot_local/lib WK_DATA=$MS_TMP/wk.data MUX_WK=$MS_TMP/wk zsh $PWD/home/dot_config/mux/scripts/executable_mux-stack push command" >/dev/null
        local elapsed=$(( SECONDS - t0 ))
        while (( i < 60 )) && [[ ! -e "$MS_TMP/opened" ]]; do sleep 0.05; (( i++ )); done
        if (( elapsed < 2 )) && [[ -e "$MS_TMP/opened" ]]; then
          print -r -- detached
        else
          print -r -- "blocked (${elapsed}s)"
        fi
      }
      When call timed_push
      The output should equal 'detached'
    End

    It 'asks for a panel only when the top entry is shown'
      hidden_push() {
        stack push command >/dev/null      # Command's panel: a launch
        local i=0
        while (( i < 40 )) && [[ ! -e "$MS_TMP/opened" ]]; do sleep 0.05; (( i++ )); done
        rm -f "$MS_TMP/opened"
        stack push scroll >/dev/null       # start_hidden: none
        sleep 0.5                          # a launch would have landed by now
        stack show
      }
      When call hidden_push
      The output should equal 'scroll:0'
      The path "$MS_TMP/opened" should not be exist
    End

    It 'never runs two panel drivers at once'
      # the driver owns the popup for its whole loop; a second one would open
      # a popup over it and silently mutate the outer one
      second_push() {
        printf '1' >"$MS_TMP/wksleep"
        stack push command >/dev/null
        local i=0
        while (( i < 40 )) && [[ "$(tmux show -gv @mux_wk_driver 2>/dev/null)" == 0 ]]; do
          sleep 0.05; (( i++ ))
        done
        stack push pane >/dev/null
        sleep 0.5                          # a second launch would have landed
        wc -l <"$MS_TMP/opened" | tr -d ' '
      }
      When call second_push
      The output should equal '1'
    End

    # The teardown is the ONE call here that cannot be aimed at a particular
    # popup, only at a client — so it closes whatever popup that client has up.
    # A `dialog` key-table bind fires its own popup and this clear as two
    # independent run-shell -b jobs; the dialog reaches display-popup in one
    # round trip while clear needs several, so the -C landed on the DIALOG and
    # its waiting client exited 129 — the clipboard picker's "tmux-popup …
    # returned 129".
    ms_tty() { tmux list-clients -F '#{client_tty}' | head -1; }
    hold_popup() {         # a real popup on the real client + a live driver
      tmux set -g @mux_wk_driver $$ 2>/dev/null
      rm -f "$MS_TMP/popup"
      tmux display-popup -c "$(ms_tty)" -E \
        "sh -c 'touch $MS_TMP/popup; sleep 10'" >/dev/null 2>&1 &
      MS_POPUP=$!
      local i=0
      while (( i < 100 )) && [[ ! -e "$MS_TMP/popup" ]]; do sleep 0.05; (( i++ )); done
    }
    popup_state() {        # the waiting client is what -C makes exit
      sleep 0.5
      kill -0 $MS_POPUP 2>/dev/null && print -r -- survived || print -r -- closed
    }
    end_popup() {          # or reset_stack waits out a driver claim that lives
      tmux display-popup -C -c "$(ms_tty)" 2>/dev/null
      tmux set -g @mux_wk_driver 0 2>/dev/null
      wait $MS_POPUP 2>/dev/null
      true
    }
    clear_as() {           # clear_as <keep-popup> <client>
      MUX_STACK_KEEP_POPUP="$1" MUX_TMUX_BIN=tmux MUX_LIB_DIR="$PWD/home/dot_local/lib" \
      WK_DATA="$MS_TMP/wk.data" MUX_WK="$MS_TMP/wk" \
        zsh "$PWD/home/dot_config/mux/scripts/executable_mux-stack" clear "$2"
    }

    It 'takes the panel popup down when the mode ends'
      torn_down() { hold_popup; clear_as '' "$(ms_tty)"; popup_state; end_popup }
      When call torn_down
      The output should equal 'closed'
    End

    It 'leaves the popup alone for a caller opening one of its own'
      # MUX_STACK_KEEP_POPUP: the dialog owns the screen from here on, and the
      # -C would close the dialog rather than the panel it was meant for.
      kept() { hold_popup; clear_as 1 "$(ms_tty)"; popup_state; end_popup }
      When call kept
      The output should equal 'survived'
    End

    It 'aims the teardown at the client whose mode ended'
      # Untargeted, -C reaches for tmux's idea of the current client — which,
      # with a second terminal attached, is somebody else's popup.
      elsewhere() { hold_popup; clear_as '' /dev/ttyNOBODY; popup_state; end_popup }
      When call elsewhere
      The output should equal 'survived'
    End

    # Skipping the teardown strands nothing: a panel that lands after the mode
    # ended has nobody left to close it, so it reads the stack it was drawn for
    # and exits on finding the mode gone. Tty-less here, so a panel that DID
    # paint shows up as bytes on stdout.
    panel_bytes() {
      [[ -n "$1" ]] && tmux set -g @mux_stack "$1"
      MUX_TMUX_BIN=tmux TMUX_BIN=tmux MUX_LIB_DIR="$PWD/home/dot_local/lib" \
      WK_DATA="$MS_TMP/wk.data" \
        zsh "$PWD/home/dot_config/mux/scripts/executable_mux-whichkey" panel prefix \
        </dev/null | wc -c | tr -d ' '
    }

    It 'closes a panel that arrives after the mode ended'
      When call panel_bytes ''
      The output should equal '0'
      The stderr should equal ''        # it never even reached the keyread
    End

    It 'still draws the panel for a mode that is standing'
      When call panel_bytes 'command:1'
      The output should not equal '0'
      The stderr should include 'terminal'   # painted, then read: no tty here
    End

    It 'leaves the popup to the driver when the panel itself moved the stack'
      # inside the panel a popup is ALREADY up; it may not open a second one
      # (a popup over a popup silently mutates the outer one)
      inpanel() {
        MUX_STACK_INPANEL=1 MUX_TMUX_BIN="$MS_TMP/tmux" \
        MUX_LIB_DIR="$PWD/home/dot_local/lib" WK_DATA="$MS_TMP/wk.data" \
        MUX_WK="$MS_TMP/wk" \
          zsh "$PWD/home/dot_config/mux/scripts/executable_mux-stack" push command
      }
      When call inpanel
      The path "$MS_TMP/opened" should not be exist
    End
  End
End
