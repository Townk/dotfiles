# Tests for home/dot_config/tmux/keymap.conf.tmpl — the tmux key tables
# mirroring the Zellij modes (migration spec D2/D3, Phase 1).
#
# Renders the template via `chezmoi execute-template` (data comes from the
# canonical source's .chezmoidata — the keymap uses no machine-specific data)
# and loads it into a scratch tmux server on an isolated -L socket, then
# asserts table structure with list-keys. Servers are cheap and the socket
# never touches a real session.
Describe 'tmux keymap tables'
  setup_all() {
    KM_TMP=$(mktemp -d)
    chezmoi execute-template <home/dot_config/tmux/keymap.conf.tmpl >"$KM_TMP/keymap.conf" 2>/dev/null
    # Phase 4: the theme's %hidden color fragments must parse BEFORE
    # status.conf composes formats from them — same order as tmux.conf.
    chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl >"$KM_TMP/theme.conf" 2>/dev/null
    chezmoi execute-template <home/dot_config/tmux/status.conf.tmpl >"$KM_TMP/status.conf" 2>/dev/null
    chezmoi execute-template <home/dot_config/tmux/menus.conf.tmpl >"$KM_TMP/menus.conf" 2>/dev/null
    printf 'source-file "%s"\nsource-file "%s"\nsource-file "%s"\nsource-file "%s"\n' \
      "$KM_TMP/theme.conf" "$KM_TMP/keymap.conf" "$KM_TMP/status.conf" "$KM_TMP/menus.conf" >"$KM_TMP/tmux.conf"
    # A detached session keeps the scratch server alive — a session-less tmux
    # server exits immediately, and any later tmux -L call would silently
    # start a fresh, CONFIG-LESS server (default binds only).
    tmux -L kmspec -f "$KM_TMP/tmux.conf" new-session -d -s kmspec-keep -x 80 -y 24
  }
  cleanup_all() {
    tmux -L kmspec kill-server 2>/dev/null
    rm -rf "$KM_TMP"
  }
  BeforeAll 'setup_all'
  AfterAll 'cleanup_all'

  keys() { tmux -L kmspec list-keys -T "$1"; }

  It 'binds the leader chords in the prefix table'
    When call keys prefix
    The output should include "split-window"
    The output should include "mux-quit-confirm"
    The output should include "copy-pwd"
  End

  It 'binds the Phase 2 picker and rename popups'
    When call tmux -L kmspec list-keys
    The output should include "pick-glyph"
    The output should include "pick-clipboard"
    The output should include "mux-rename window"
    The output should include "mux-rename pane"
  End

  It 'enters the mode tables from the prefix'
    When call keys prefix
    The output should include "key-table pane"
    The output should include "key-table tab"
    The output should include "key-table session"
    The output should include "key-table locked"
  End

  It 'mirrors zellij tab mode'
    When call keys tab
    The output should include "select-window -t :=1"
    The output should include "next-window"
    The output should include "last-window"
  End

  It 'mirrors zellij pane mode'
    When call keys pane
    The output should include "select-pane -L"
    The output should include "key-table resize"
    The output should include "key-table move"
  End

  It 'gives every mode table an Escape back to root'
    _missing=""
    for t in pane tab resize move session; do
      tmux -L kmspec list-keys -T "$t" | grep -q "key-table root" || _missing="$_missing $t"
    done
    When call test -z "$_missing"
    The status should be success
  End

  # NB: asserted via the GLOBAL listing — `list-keys -T locked` renders
  # nothing for a table holding a single M-Escape+set bind (tmux 3.7b
  # quirk; the bind registers fine and shows up globally).
  locked_binds() { tmux -L kmspec list-keys | grep -- "-T locked"; }

  It 'locked table only exits on M-Escape'
    When call locked_binds
    The output should include "M-Escape"
    The lines of output should equal 1
  End

  It 'root nav is vim/fzf-aware'
    When call keys root
    The output should include "C-h"
    The output should include "select-pane -L"
    The output should include "send-keys C-h"
  End

  It 'copy-mode has the prompt-jump duality on n'
    When call tmux -L kmspec list-keys -T copy-mode-vi
    The output should include "next-prompt"
    The output should include "search-again"
    The output should include "capture-pane"
  End

  It 'status-right rides the ribbon renderer with live mode arguments'
    When call tmux -L kmspec show -g status-right
    The output should include "tmux-status-right"
    The output should include "client_key_table"
  End

  It 'window pills are the zj-hud tab chrome'
    When call tmux -L kmspec show -gw window-status-format
    The output should include "▌"
    The output should include "pane_current_path"
  End

  It 'window pills carry the alarm flag icons'
    When call tmux -L kmspec show -gw window-status-format
    The output should include "window_activity_flag"
    The output should include "window_silence_flag"
  End

  It 'prefix f toggles pane frames (zellij TogglePaneFrames twin)'
    When call keys prefix
    The output should include "pane-border-status"
  End

  It 'every mode table carries its which-key menu on M-. (Phase 5)'
    # NB: asserted via the GLOBAL listing (the list-keys -T quirk; ledger).
    When call tmux -L kmspec list-keys
    The output should include "-T tab M-."
    The output should include "-T pane M-."
    The output should include "-T prefix M-."
    The output should include "-T copy-mode-vi M-."
    The output should include "display-menu"
  End

  It 'alert hooks route to the notifier'
    When call tmux -L kmspec show-hooks -g
    The output should include "tmux-alert-notify activity"
    The output should include "tmux-alert-notify silence"
  End
End

Describe 'prompt-marks.sh (OSC 133 emitter)'
  It 'is a silent no-op in a non-interactive shell'
    When call zsh -c 'source home/dot_config/zsh/functions.d/prompt-marks.sh; echo ok'
    The output should equal "ok"
    The status should be success
  End

  # The -t 1 guard needs a real tty — script(1) provides one (the same
  # serializer trick from the Phase 0 sixel debugging, repurposed).
  It 'registers the precmd hook in an interactive tty shell'
    When call script -q /dev/null zsh -fic 'source home/dot_config/zsh/functions.d/prompt-marks.sh; (( ${precmd_functions[(I)_prompt_mark_precmd]} )) && echo hooked'
    The output should include "hooked"
  End
End
