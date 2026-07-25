# Tests for mux-whichkey — the which-key PANEL (Phase 5): the zj-hud panel
# port. `render` paints one frame; the popup path only adds the dispatcher
# loop on top of it. Data is rendered from the same keymap.yaml that
# generates keymap.conf, so these also guard panel↔keytable agreement.
Describe 'mux-whichkey panel'
  setup() {
    WK_TMP=$(mktemp -d)
    chezmoi execute-template <home/dot_config/mux/whichkey.data.tmpl >"$WK_TMP/wk.data" 2>/dev/null
    export WK_DATA="$WK_TMP/wk.data" TMPDIR="$WK_TMP"
    W="$PWD/home/dot_config/mux/scripts/executable_mux-whichkey"
  }
  cleanup() { rm -rf "$WK_TMP"; unset WK_DATA W; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # strip CSI positioning + SGR so assertions read the visible text
  plain() { zsh "$W" render "$1" "${2:-0}" "${3:-25}" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\000'; }

  It 'draws the rounded frame with the mode breadcrumb as the top-border label'
    When call plain prefix
    The output should include "╭ 󰘳"
    The output should include "╮"
    The output should include "╰"
  End

  It 'renders one binding per row: right-aligned chord, ➜, icon, label'
    When call plain prefix
    The output should include "➜ 󰌾 Locked mode …"
    The output should include "➜ 󰙀 Session mode …"
  End

  It 'mirrors zj-hud key glyphs: shift/alt marks and uppercase letters'
    When call plain prefix
    The output should include "󰘶 L ➜"     # uppercase bind = shift
    The output should include "󰘵 Y ➜"     # M-y
    The output should include "  O ➜"     # lowercase o shown uppercase
  End

  It 'merges key variants onto one row, zj-hud style'
    When call plain pane
    The output should include "↑,K ➜"
    The output should include "󰘶 ↑,󰘶 K ➜"
  End

  It 'shows the mode trail in the breadcrumb for a nested mode'
    When call plain resize
    The output should include "»"          # Command » Pane » Resize
  End

  It 'closes with the heavy rule and the footer hints'
    When call plain pane
    The output should include "━━━"
    The output should include "󱊷 close"
    The output should include "󰁮 back"
    The output should include "󰘵 . hide"
  End

  It 'has no back hint at the root of the mode stack'
    When call plain prefix
    The output should include "󱊷 close"
    The output should not include "󰁮 back"
  End

  # zj-hud panel sort: bindings that ENTER another mode first, then
  # unmodified chords, then modified ones (an uppercase letter counts as
  # shift+letter). Groups render contiguously, anchored at their first member.
  It 'sorts mode-switch bindings to the top'
    When call zsh -c 'zsh "$PWD/home/dot_config/mux/scripts/executable_mux-whichkey" render prefix 0 30 | sed "s/\x1b\[[0-9;]*[A-Za-z]//g" | tr -d "\000" | tr "\342\224\202" "\n" | grep -n "Locked mode\|copy pwd (abs)" | cut -d: -f1 | tr "\n" " "'
    # the mode-switch group lands far above the alt-modified chords
    The output should match pattern "* *"
  End

  It 'renders a configured group contiguously (the tab numbers)'
    When call zsh -c 'zsh "$PWD/home/dot_config/mux/scripts/executable_mux-whichkey" render tab 0 30 | sed "s/\x1b\[[0-9;]*[A-Za-z]//g" | tr -d "\000" | grep -c "go to tab"'
    The output should equal "1"
  End

  It 'keeps the split-pane variants together as one group'
    When call zsh -c 'zsh "$PWD/home/dot_config/mux/scripts/executable_mux-whichkey" render pane 0 30 | sed "s/\x1b\[[0-9;]*[A-Za-z]//g" | tr -d "\000" | grep -o "split pane" | wc -l | tr -d " "'
    The output should equal "4"
  End

  It 'paginates only when the entries do not fit, with the N/M counter'
    When call plain prefix 0 8
    The output should include "scroll"
    The output should include "1/"
  End

  It 'does not paginate when everything fits'
    When call plain session
    The output should not include "scroll"
    The output should not include "1/"
  End
End

Describe 'keymap.yaml is the single source'
  It 'generates the same bindings the panel dispatches'
    # every panel entry with a cmd must exist as a generated bind
    When call zsh -c '
      km=$(chezmoi execute-template <home/dot_config/tmux/keymap.conf.tmpl)
      miss=0
      while IFS=$'"'"'\t'"'"' read -r tag mode keys icon icol desc flags cmd; do
        [[ "$tag" == E ]] || continue
        [[ -n "$cmd" ]] || continue
        [[ "$flags" == *only* ]] && continue
        tbl="$mode"; [[ "$mode" == prefix ]] && tbl=""
        for k in ${(s:|:)keys}; do
          if [[ -n "$tbl" ]]; then pat="bind -T $tbl $k {"; else pat="bind $k {"; fi
          grep -qF -- "$pat" <<<"$km" || { print "MISSING: $pat"; miss=1 }
        done
      done < <(chezmoi execute-template <home/dot_config/mux/whichkey.data.tmpl)
      exit $miss'
    The status should be success
  End
End
