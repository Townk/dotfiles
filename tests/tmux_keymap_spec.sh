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
    chezmoi execute-template <home/dot_config/tmux/keymap-base.conf.tmpl >"$KM_TMP/keymap-base.conf" 2>/dev/null
    chezmoi execute-template <home/dot_config/tmux/keymap.conf.tmpl >"$KM_TMP/keymap.conf" 2>/dev/null
    # Phase 4: the theme's %hidden color fragments must parse BEFORE
    # status.conf composes formats from them — same order as tmux.conf.
    chezmoi execute-template <custom-builds/theme/templates/tmux-theme.conf.tmpl >"$KM_TMP/theme.conf" 2>/dev/null
    chezmoi execute-template <home/dot_config/tmux/status.conf.tmpl >"$KM_TMP/status.conf" 2>/dev/null
    printf 'source-file "%s"\nsource-file "%s"\nsource-file "%s"\nsource-file "%s"\n' \
      "$KM_TMP/theme.conf" "$KM_TMP/keymap-base.conf" "$KM_TMP/keymap.conf" \
      "$KM_TMP/status.conf" >"$KM_TMP/tmux.conf"
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

  It 'gives every mode table the same two mode-stack pops'
    # Escape ends the stack, Backspace pops one level — identical commands in
    # every table, because the stack (not the table) knows where they lead.
    _missing=""
    for t in pane tab resize move session; do
      _b="$(tmux -L kmspec list-keys -T "$t")"
      case "$_b" in *"mux-stack clear"*) ;; *) _missing="$_missing $t:Escape" ;; esac
      case "$_b" in *"mux-stack pop"*) ;; *) _missing="$_missing $t:BSpace" ;; esac
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

  # Phase 6.4 (D21): agents want Down/Up where vim wants the raw key, and
  # both differ from "move focus". Three outcomes, so the probes chain —
  # a single run-shell classifier would put zsh startup on a held nav key.
  It 'root C-j/C-k reach an agent as Down/Up before the vim/fzf lane'
    When call keys root
    The output should include "(cursor-)?agent"
    The output should include "send-keys Down"
    The output should include "send-keys Up"
  End

  # Phase 6.1/6.4: Alt+Enter toggles the host terminal's fullscreen, but an
  # fzf pane owns the key (the quick-launch "separate window" accept).
  It 'root M-Enter toggles fullscreen unless fzf owns the pane'
    When call keys root
    The output should include "terminal-toggle-fullscreen"
    The output should include "M-Enter"
  End

  # Phase 6.3 (D20): tm routes address the SESSION the pane is stamped with,
  # never a pid, and only fire on a stamped pane.
  It 'root tm-scrub routes fire on the @ctx stamp and pass through elsewhere'
    When call keys root
    The output should include "@ctx"
    The output should include "@tm_session"
    The output should include "system-backup-tm"
    The output should include "route --session"
  End

  It 'the explore lens passes its keys through to yazi'
    When call keys root
    # tm-explore is the pass-through class: yazi binds J/K/A itself.
    The output should include "tm-explore"
  End

  It 'routes n/N through the search stepper, which keeps the prompt-jump duality'
    # n means "next MATCH" in Search and "next prompt" elsewhere in
    # copy-mode. The choice moved into mux-search with the search's own
    # position (tmux search-again looks from the CURSOR, so scrolling used
    # to change which match came next) — mux_search_spec covers both arms.
    When call tmux -L kmspec list-keys -T copy-mode-vi
    The output should include "mux-search --next"
    The output should include "mux-search --prev"
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

  It 'the leader pushes Command on the stack and M-. toggles the panel (Phase 5)'
    When call tmux -L kmspec list-keys
    The output should include "mux-stack push command"
    The output should include "mux-whichkey toggle"
  End

  It 'ends every generated bind in exactly one mode-stack operation'
    # entering a mode pushes it, an action ends the stack, a `stay` action
    # leaves it alone — the same rule the panel's own dispatcher follows.
    When call keys pane
    The output should include 'key-table resize \; run-shell -b "'      # push
    The output should include 'mux-stack push resize'
    The output should include 'kill-pane'
    The output should include 'mux-stack clear'
    The output should not include 'select-pane -L \; run-shell'          # stay
  End

  It 'generated mode tables carry their commands in brace blocks'
    # a bare `;` in a config file is a command SEPARATOR — the generator
    # wraps every command so multi-command binds cannot self-execute.
    When call keys tab
    The output should include "new-window"
    The output should include "select-window -t :=1"
  End

  It 'alert hooks route to the notifier'
    When call tmux -L kmspec show-hooks -g
    The output should include "tmux-alert-notify activity"
    The output should include "tmux-alert-notify silence"
  End

  # ---- MEH direct bindings (spec 2026-07-27-meh-direct-bindings) -----------
  # Ctrl+Alt+Shift root binds. Three spellings each, because WezTerm folds
  # Shift into the CODEPOINT (C-M-P), Ghostty sets the shift bit AND shifts the
  # codepoint (C-M-S-P), and the kitty protocol shifts neither (C-M-S-p).
  # `"?` matters: tmux QUOTES a key name containing #, $ or % when listing it,
  # so C-M-# comes back as "C-M-#" and an unquoted pattern silently undercounts.
  meh() { tmux -L kmspec list-keys -T root | grep -E '^bind-key +-T root +"?C-M-'; }
  # The scroll/prompt binds are the stateful ones — they alone test pane_in_mode.
  meh_scroll() { meh | grep pane_in_mode; }
  meh_stateless() { meh | grep -v pane_in_mode; }

  It 'binds every MEH chord in all its terminal spellings'
    When call meh
    The lines of output should equal 65
  End

  It 'maps every spelling of MEH-p to the project picker'
    When call meh
    The output should include "C-M-P     "
    The output should include "C-M-S-P   "
    The output should include "C-M-S-p   "
    The output should include "quick-launch menu workspace"
  End

  It 'covers the other five actions'
    When call meh
    The output should include "quick-launch menu tab"
    The output should include "quick-launch menu pane"
    The output should include "pick-clipboard"
    The output should include "copy-pwd --relative"
    The output should include "copy-pwd --absolute"
    The output should include "new-window"
  End

  # Shift folds a DIGIT to the layout's shifted punctuation, not to a digit, so
  # the tab jumps are named C-M-! … C-M-) — plus the kitty form, which shifts
  # neither and stays C-M-S-<digit>.
  It 'jumps to all ten tabs, in each spelling'
    When call meh
    The output should include "select-window -t :=1"
    The output should include "select-window -t :=10"
    The output should include "C-M-!"
    The output should include "C-M-S-!"
    The output should include "C-M-S-1"
    The output should include "C-M-)"
  End

  # b/f complete the pair with C-b/C-f (page): prompt in Scroll state, but the
  # vi meanings survive in Copy state, the same @visual split j/k use.
  It 'binds b/f to prompt jumps in Scroll and vi motions in Copy'
    When call keys copy-mode-vi
    The output should include "previous-word"
    The output should include "jump-forward"
    The output should include "top-line ; send-keys -X previous-prompt"
    The output should include "bottom-line ; send-keys -X next-prompt"
  End

  # Batch 3: the only STATEFUL MEH binds. They enter copy-mode, so they carry
  # @visual, the mode-stack push and a guard — and `#{pane_in_mode}` splits
  # entry from repeat so three presses do not stack three `scroll` entries.
  It 'scrolls and jumps prompts, entering copy-mode once'
    When call meh
    The output should include "send-keys -X scroll-up"
    The output should include "send-keys -X scroll-down"
    The output should include "send-keys -X previous-prompt"
    The output should include "send-keys -X next-prompt"
    # Anchor to the viewport edge FIRST, so prompts already on screen are
    # skipped — otherwise the cursor walks them and the view never moves.
    The output should include "send-keys -X top-line"
    The output should include "send-keys -X bottom-line"
    The output should include "pane_in_mode"
    The output should include "mux-stack push scroll"
    The output should include "@visual"
  End

  # Arrows carry modifiers numerically, so Shift cannot fold into a codepoint:
  # ONE spelling, no per-terminal dialect.
  It 'binds the arrow forms of the scroll pair'
    When call meh
    The output should include "C-M-S-Up"
    The output should include "C-M-S-Down"
  End

  # Scrolling tmux's buffer under nvim/fzf is wrong — they own their own. And
  # the false branch must be ABSENT: a MEH bind can never send-keys its own
  # chord through, it would arrive as a different key entirely.
  It 'guards the scroll binds and never falls through to the pane'
    When call meh_scroll
    The output should include "pane_tty"
    The output should include "fzf"
    The output should not include "send-keys C-M-"
  End

  # Fired from the ROOT table there is no key-table to reset and no stack entry
  # to pop; carrying the leader's plumbing over would corrupt @mux_stack.
  It 'strips the mode plumbing the leader versions carry'
    When call meh_stateless
    The output should not include "key-table root"
    The output should not include "mux-stack"
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

# The session environment is the truthful record of the OUTER terminal and of
# whether this attach is remote. update-environment is what refreshes it from
# each attaching client — so what is in that array decides whether a shell
# spawned later believes it is on SSH.
Describe 'tmux update-environment'
  setup_all() {
    UE_TMP=$(mktemp -d)
    chezmoi execute-template <home/dot_config/tmux/tmux.conf.tmpl 2>/dev/null \
      | grep -E '^set -g[ua] update-environment' >"$UE_TMP/ue.conf"
    tmux -L uespec -f /dev/null new-session -d -s ue -x 80 -y 24
    tmux -L uespec source-file "$UE_TMP/ue.conf"
  }
  cleanup_all() { tmux -L uespec kill-server 2>/dev/null; rm -rf "$UE_TMP"; }
  BeforeAll 'setup_all'
  AfterAll 'cleanup_all'

  ue() { tmux -L uespec show -gv update-environment; }
  count_of() { tmux -L uespec show -gv update-environment | tr ' ' '\n' | grep -c "^$1\$"; }

  It 'carries the outer terminal identity'
    When call ue
    The output should include "TERM_PROGRAM"
  End

  It 'refreshes every SSH variable the prompt reads, not just one'
    # powerlevel10k calls a shell remote on ANY of these three. With only
    # SSH_CONNECTION refreshed, a server once attached over ssh handed stale
    # SSH_CLIENT/SSH_TTY to every new pane and the prompt showed `@user`
    # forever — on local and VNC attaches too (Mode B).
    When call ue
    The output should include "SSH_CONNECTION"
    The output should include "SSH_CLIENT"
    The output should include "SSH_TTY"
  End

  It 'appends exactly once however often the config is sourced'
    # `set -ga` on an ARRAY option appends every time: after a day of reloads
    # the array held 53 copies of TERM. The `set -gu` reset makes it stable.
    tmux -L uespec source-file "$UE_TMP/ue.conf"
    tmux -L uespec source-file "$UE_TMP/ue.conf"
    When call count_of TERM
    The output should equal 1
  End
End
