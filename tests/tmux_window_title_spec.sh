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

  # zj-hud gives each process its own glyph (icons::process_icon); the tmux
  # chain is generated from .muxTabIcons so the two speak one vocabulary.
  Describe 'per-process icons'
    icon_chain() { tmux -L wtspec show -gv @__win_proc_icon 2>/dev/null; }

    It 'maps the agents, editors and tools zj-hud maps'
      chain() { chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl | grep '^%hidden win_proc_icon='; }
      When call chain
      The output should include "pane_current_command},claude"
      The output should include "pane_current_command},cursor-agent"
      The output should include "pane_current_command},nvim"
      The output should include "pane_current_command},node"
      The output should include "pane_current_command},lazygit"
    End

    It 'keeps the generic run glyph as the fallback'
      chain() { chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl | grep '^%hidden win_proc_icon='; }
      When call chain
      The output should include "󰜎"
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
End