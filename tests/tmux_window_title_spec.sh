# Window titles: parity with zj-hud's compose_body (docs/mux-parity.md).
#
# zj-hud's priority 2 is "non-shell process -> per-process icon + the pane's
# OSC title when it says something the process name does not". tmux captures
# that title in #{pane_title} but named its windows #{pane_current_command},
# so an agent that publishes its session and its progress showed up as
# "node". These drive a real server: the title arrives as an escape sequence
# from a real shell, which is the only way to prove tmux tracks it.
Describe 'tmux window titles'
  setup_all() {
    WT_TMP=$(mktemp -d)
    chezmoi execute-template <home/dot_config/tmux/tmux.conf.tmpl >"$WT_TMP/base.conf" 2>/dev/null
    chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl >"$WT_TMP/theme.conf" 2>/dev/null
    # Only the pieces under test: the base options (automatic-rename-format)
    # and the theme (the pill body). Sourcing the keymap would pull in the
    # panel scripts, which have nothing to do with titles.
    printf 'source-file "%s"\nsource-file "%s"\n' "$WT_TMP/base.conf" "$WT_TMP/theme.conf" >"$WT_TMP/tmux.conf"
    tmux -L wtspec -f "$WT_TMP/tmux.conf" new-session -d -s wt -x 100 -y 24 "sh -i"
    sleep 1
  }
  cleanup_all() { tmux -L wtspec kill-server 2>/dev/null; rm -rf "$WT_TMP"; }
  BeforeAll 'setup_all'
  AfterAll 'cleanup_all'

  title() {   # emit an OSC 2 title from the pane, like an agent does
    tmux -L wtspec send-keys -t wt "printf '\\033]2;$1\\033\\\\'" Enter
    i=0
    while [ "$i" -lt 40 ] && [ "$(tmux -L wtspec display -p '#{window_name}')" != "$1" ]; do
      sleep 0.1; i=$((i + 1))
    done
    tmux -L wtspec display -p '#{window_name}'
  }

  It 'names the window after the OSC title an app publishes'
    When call title "claude — refactoring auth"
    The output should equal "claude — refactoring auth"
  End

  It 'follows the title as it changes, so progress shows'
    When call title "claude — step 4/7"
    The output should equal "claude — step 4/7"
  End

  # tmux SEEDS pane_title with the hostname, so a naive #{pane_title} would
  # put the machine name in every idle shell's pill. A window created
  # WITHOUT -n keeps automatic-rename on, which is the case under test.
  It 'never shows the hostname tmux seeds pane_title with'
    seeded() {
      tmux -L wtspec new-window -d -t wt: "sh -i" 2>/dev/null
      sleep 1.5
      # index of the window just created (last in the list)
      w="$(tmux -L wtspec list-windows -t wt -F '#{window_index}' | tail -1)"
      # its pane title IS the host at this point; the NAME must not be
      title="$(tmux -L wtspec display -p -t "wt:$w" '#{pane_title}')"
      name="$(tmux -L wtspec display -p -t "wt:$w" '#{window_name}')"
      [ "$name" = "$title" ] && printf 'name==title(%s)' "$name" || printf 'name=%s' "$name"
      tmux -L wtspec kill-window -t "wt:$w" 2>/dev/null
    }
    When call seeded
    The output should not include "name==title"
    # the process name is what it falls back to
    The output should include "name="
  End

  # Upstream renamed claude-code's binary to claude.exe, which broke the icon
  # lookup keyed on the bare name. The command is normalised once — a
  # trailing .exe is stripped — so a vendor's platform suffix cannot cost us
  # an icon, and nothing else is touched (weird.exec keeps its name).
  Describe 'command normalisation'
    norm() {
      tmux -L wtspec set -g @__c "$1" 2>/dev/null
      tmux -L wtspec display -p '#{s|\.exe$||:#{@__c}}'
    }

    It 'strips a trailing .exe so claude.exe still finds its icon'
      When call norm "claude.exe"
      The output should equal "claude"
    End

    It 'leaves an ordinary command alone'
      When call norm "nvim"
      The output should equal "nvim"
    End

    It 'is anchored — a .exec suffix is not an .exe'
      When call norm "weird.exec"
      The output should equal "weird.exec"
    End

    It 'keys the generated icon chain off the normalised command'
      chain() { chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl | grep '^%hidden win_proc_icon='; }
      When call chain
      The output should include 'win_cmd'
      The output should not include '==:#{pane_current_command},claude}'
    End
  End

  # zj-hud gives each process its own glyph (icons::process_icon); the tmux
  # chain is generated from .muxTabIcons so the two speak one vocabulary.
  Describe 'per-process icons'
    icon_chain() { tmux -L wtspec show -gv @__win_proc_icon 2>/dev/null; }

    It 'maps the agents, editors and tools zj-hud maps'
      chain() { chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl | grep '^%hidden win_proc_icon='; }
      When call chain
      The output should include '==:$win_cmd,claude}'
      The output should include '==:$win_cmd,cursor-agent}'
      The output should include '==:$win_cmd,nvim}'
      The output should include '==:$win_cmd,node}'
      The output should include '==:$win_cmd,lazygit}'
    End

    It 'keeps the generic run glyph as the fallback'
      chain() { chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl | grep '^%hidden win_proc_icon='; }
      When call chain
      The output should include "󰜎"
    End

    # A wrong glyph is unreviewable as a character, and one class of mistake is
    # invisible even as an escape: sudo is \u{F292} (nf-fa-hashtag) in
    # icons.rs, and the port first wrote it \U000F0292 (nf-md-fridge_bottom)
    # by copying the shape of its md-range neighbours. Pin the code points.
    It 'carries the code points icons.rs carries, not lookalike escapes'
      chain() { chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl | grep '^%hidden win_proc_icon='; }
      When call chain
      The output should include "$(printf '\U0010FB00')"    # usr-cursor-ai — agent, cursor-agent
      The output should include "$(printf '\U0010E861')"    # fa-claude
      The output should include "$(printf '\U0010FB02')"    # usr-pi
      The output should include "$(printf '\U0000F292')"    # nf-fa-hashtag — sudo
      The output should not include "$(printf '\U000F0292')"
    End

    # The plugin's bash/zsh/fish entries sit behind is_shell's early-out in
    # compose_body and can never render, so the table has no shell keys and
    # the pill's own shell branch answers for all four of is_shell's names.
    It 'sends every shell is_shell knows to the cwd body instead'
      body() { chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl | grep '^%hidden win_body='; }
      When call body
      The output should include '==:$win_cmd,zsh}'
      The output should include '==:$win_cmd,bash}'
      The output should include '==:$win_cmd,fish}'
      The output should include '==:$win_cmd,nu}'
    End

    It 'renders a known process with its own glyph, not the generic one'
      # nvim is in the map and on every machine this config targets.
      render() {
        tmux -L wtspec new-window -d -t wt: 'nvim --clean' 2>/dev/null
        sleep 1.5
        w="$(tmux -L wtspec list-windows -t wt -F '#{window_index}' | tail -1)"
        tmux -L wtspec display -p -t "wt:$w" "$(tmux -L wtspec show -gv window-status-format)" \
          | sed 's/\x1b\[[0-9;]*m//g'
        tmux -L wtspec kill-window -t "wt:$w" 2>/dev/null
      }
      When call render
      The output should include ""
      The output should not include "󰜎"
    End
  End

  # #{pane_current_command} is not the command you ran: tmux picks a process
  # out of the pane's foreground process GROUP, and on macOS not the group
  # leader. Measured 2026-07-29 on an `agent` pane — leader ~/.local/bin/agent,
  # five node/npm children sharing its pgid — tmux reported "node", so the pill
  # drew node's hexagon where zellij hands zj-hud the leader and it draws the
  # Cursor cube. The shell stamps the name it ran onto the pane (@win_proc) and
  # every process comparison goes through win_cmd, which prefers it.
  Describe 'the @win_proc stamp'
    It 'prefers the stamp over the process tmux picked'
      stamped() {
        tmux -L wtspec new-window -d -t wt: "sh -i" 2>/dev/null
        sleep 1
        w="$(tmux -L wtspec list-windows -t wt -F '#{window_index}' | tail -1)"
        tmux -L wtspec set -p -t "wt:$w" @win_proc agent
        tmux -L wtspec display -p -t "wt:$w" 'stamped=#{E:win_cmd} icon=#{E:win_proc_icon}'
        # …and gone at the next prompt, or the pill would never show a cwd
        # again. Unstamped, win_cmd IS tmux's own answer — whatever that is on
        # this platform for the pane's `sh -i`.
        tmux -L wtspec set -up -t "wt:$w" @win_proc
        tmux -L wtspec display -p -t "wt:$w" \
          'cleared=#{?#{==:#{E:win_cmd},#{pane_current_command}},tmux-own-answer,#{E:win_cmd}}'
        tmux -L wtspec kill-window -t "wt:$w" 2>/dev/null
      }
      When call stamped
      The line 1 should equal "stamped=agent icon=$(printf '\U0010FB00')"
      The line 2 should equal "cleared=tmux-own-answer"
    End
  End

  # The push half: the shell knows what it ran, so preexec tells tmux and
  # precmd takes it back. Driven through a stub tmux — what matters is which
  # calls the hooks make, and that they make none at all for a command tmux
  # already names correctly (a set costs a ~10ms round-trip).
  Describe 'mux-tab-proc.sh'
    setup_proc() {
      PROC_TMP=$(mktemp -d)
      chezmoi execute-template <home/dot_config/zsh/functions.d/mux-tab-proc.sh.tmpl \
        >"$PROC_TMP/hook.sh" 2>/dev/null
      printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/calls"\n' "$PROC_TMP" >"$PROC_TMP/tmux"
      chmod +x "$PROC_TMP/tmux"
    }
    cleanup_proc() { rm -rf "$PROC_TMP"; }
    BeforeEach 'setup_proc'
    AfterEach 'cleanup_proc'

    # -fi: the hook file guards itself on an interactive shell, and -f keeps
    # the user's rc files out of it.
    run_hooks() {   # <command line> [tmux-env]
      zsh -fi -c "source '$PROC_TMP/hook.sh'
        TMUX='${2-/tmp/sock,1,0}' TMUX_PANE=%7 MUX_TMUX_BIN='$PROC_TMP/tmux'
        _mux_tab_proc_stamp '$1'
        _mux_tab_proc_clear" 2>/dev/null
      # The header proves the harness ran: "calls:" alone is a hook that made
      # no call, an empty output would be a hook that never got to try.
      printf 'calls:\n'
      cat "$PROC_TMP/calls" 2>/dev/null || :
    }

    It 'stamps a hidden command on the pane it runs in, then takes it back'
      When call run_hooks 'agent --model gpt-5'
      The line 2 should equal "set -p -t %7 @win_proc agent"
      The line 3 should equal "set -up -t %7 @win_proc"
    End

    It 'stamps the basename, so a path-qualified launch still matches a key'
      When call run_hooks "$HOME/.local/bin/cursor-agent"
      The line 2 should equal "set -p -t %7 @win_proc cursor-agent"
    End

    It 'spends nothing on a command tmux already names correctly'
      When call run_hooks 'ls -la'
      The output should equal "calls:"
    End

    It 'does nothing outside tmux'
      When call run_hooks 'agent' ''
      The output should equal "calls:"
    End

    It 'registers itself on both hooks'
      hooked() {
        zsh -fi -c "source '$PROC_TMP/hook.sh'
          (( \${preexec_functions[(I)_mux_tab_proc_stamp]} )) && echo preexec
          (( \${precmd_functions[(I)_mux_tab_proc_clear]} )) && echo precmd" 2>/dev/null
      }
      When call hooked
      The output should include "preexec"
      The output should include "precmd"
    End
  End
End