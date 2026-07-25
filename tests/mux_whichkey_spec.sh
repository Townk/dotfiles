# Tests for mux-whichkey — the which-key PANEL renderer (Phase 5, D5): the
# zj-hud panel port. Data comes from a fixture rendered off keymap.yaml.
Describe 'mux-whichkey panel'
  setup() {
    WK_TMP=$(mktemp -d)
    chezmoi execute-template <home/dot_config/mux/whichkey.data.tmpl >"$WK_TMP/wk.data" 2>/dev/null
    export WK_DATA="$WK_TMP/wk.data"
    export TMPDIR="$WK_TMP"
    W="$PWD/home/dot_config/mux/scripts/executable_mux-whichkey"
  }
  cleanup() { rm -rf "$WK_TMP"; unset WK_DATA W; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  plain() { zsh "$W" row "$1" "$2" "${3:-0}" 0 0 0 "${4:-100}" "${5:-0}" | sed 's/#\[[^]]*\]//g'; }

  It 'draws the rounded frame with the mode breadcrumb as the top-border label'
    When call plain 0 tab
    The output should include "╭"
    The output should include "╮"
    The output should include "»"      # Command » Tab
  End

  It 'renders body cells as <keys> ➜ <icon> <label>'
    When call plain 1 tab
    The output should include "➜"
    The output should include "new tab"
    The output should include "│"
  End

  It 'carries the footer hints and page counter in the bottom border'
    When call plain 3 tab
    The output should include "close"
    The output should include "hide"
    The output should include "scroll"
    The output should include "/2"
    The output should include "╯"
  End

  It 'paginates: page 2 shows different entries than page 1'
    p1=$(plain 1 tab 0 100 0)
    p2=$(plain 1 tab 0 100 1)
    When call test "$p1" != "$p2"
    The status should be success
  End

  It 'is silent in the root table (resting modes have no panel)'
    When call plain 0 root
    The output should equal ""
  End

  It 'switch bindings (mode pushes) are colored apart from ordinary labels'
    When call zsh "$W" row 1 pane 0 0 0 0 100 0
    The output should include "Resize Pane"
    The output should include "fg=#89b4fa"   # switch_color
    The output should include "fg=#f5c2e7"   # label_color
  End

  # start_hidden: scroll — the panel stays down in Scroll until toggled
  # (zellij's `start_hidden "scroll"`), but Copy/visual shows it.
  It 'stays hidden in Scroll state'
    When call plain 0 root 1
    The output should equal ""
  End

  It 'shows for the Copy state'
    When call zsh "$W" row 0 root 1 1 0 0 100 0
    The output should include "╭"
  End
End
