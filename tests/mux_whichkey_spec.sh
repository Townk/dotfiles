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

  # A popup has no current pane, so tmux expands "where I came from" formats
  # to nothing when the panel source-files a command: `new-window -c
  # "#{pane_current_path}"` fell back to the session's start directory when
  # dispatched from the panel, while the identical key-table bind inherited
  # the pane's cwd. The panel resolves that ONE format itself.
  # The script ends in a dispatcher, so lift just the function under test
  # (same technique the quick-launch cache spec uses).
  expand() {
    STUB="$WK_TMP/tmux"
    { print '#!/bin/sh'
      print 'case "$*" in *pane_current_path*) printf "/origin/dir\n" ;; esac'
    } > "$STUB"
    chmod +x "$STUB"
    ARG="$1" WKBIN="$W" TMUX_STUB="$STUB" zsh -c '
      TMUX_BIN="$TMUX_STUB"
      eval "$(sed -n "/^_expand_origin()/,/^}/p" "$WKBIN")"
      _expand_origin "$ARG"
    '
  }

  It 'resolves the origin cwd into a command the popup would expand empty'
    When call expand 'new-window -c "#{pane_current_path}"'
    The output should equal 'new-window -c "/origin/dir"'
  End

  It 'leaves other #-sequences alone (tmux must still see #W and %%)'
    When call expand 'command-prompt -F -I "#W" { rename-window "%%" }'
    The output should equal 'command-prompt -F -I "#W" { rename-window "%%" }'
  End

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

  # The label colour IS the entry's disposition toward the mode stack:
  # pink ends the mode, blue enters another one, green STAYS in this one.
  colored() { zsh "$W" render "$1" "${2:-0}" "${3:-25}" | tr -d '\000'; }
  It 'paints a sticky binding green, an ending one pink'
    When call colored scroll
    The output should include $'\e[38;2;166;227;161mscroll down'    # green
    The output should include $'\e[38;2;245;194;231medit scrollback'  # pink
  End

  It 'still paints a mode switch blue'
    When call colored scroll
    The output should include $'\e[38;2;137;180;250mCopy mode'
  End

  # _paint answers in REPLY and leaves PAGE/PAGES for its CALLER. It used to
  # be called as `$(_paint …)`, and the subshell swallowed both — the panel
  # loop read an unset PAGES, so C-d/C-u could never turn a page.
  It 'leaves the page count visible to the caller'
    When call zsh "$W" pages prefix 6
    The output should equal "0/4"
  End

  It 'reports a single page when the table fits'
    When call zsh "$W" pages scroll 25
    The output should equal "0/1"
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

Describe 'panel coverage vs the zellij which-key labels'
  # Every label in the zellij layout must have a counterpart in keymap.yaml,
  # except the features tmux genuinely does not have (spec §6 dispositions)
  # and the n/N duality (tmux has ONE copy-mode, so those labels say
  # "match / prompt").
  It 'covers every zellij label except the documented non-equivalents'
    When call python3 - "$PWD"
      #|import re, sys, yaml, pathlib
      #|root = pathlib.Path(sys.argv[1])
      #|lay = (root/'home/dot_config/zellij/layouts/default.kdl.tmpl').read_text()
      #|labels = re.findall(r'wk mode="([^"]+)"\s+binding="([^"]+)"\s+desc="([^"]+)"', lay)
      #|ALLOW = {'about Zellij','configuration','layout manager','plugin manager','share',
      #|         'split pane stack','toggle embed pane','toggle floating',
      #|         'toggle floating (sticky)','toggle pinned pane',
      #|         'next match','previous match'}
      #|MAP = {'tmux':'prefix','tab':'tab','pane':'pane','session':'session',
      #|       'scroll':'copy','search':'copy'}
      #|d = yaml.safe_load((root/'home/.chezmoidata/keymap.yaml').read_text())['keymap']['tables']
      #|missing = []
      #|for mode, b, desc in labels:
      #|    for m in mode.split(','):
      #|        t = MAP.get(m.strip())
      #|        if not t or desc in ALLOW: continue
      #|        if desc not in {e['desc'] for e in d[t]['entries']}:
      #|            missing.append(f'{m}:{b}={desc}')
      #|print('\n'.join(sorted(set(missing))))
      #|sys.exit(1 if missing else 0)
    The status should be success
    The output should equal ""
  End
End
