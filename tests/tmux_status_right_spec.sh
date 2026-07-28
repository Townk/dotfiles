# Tests for libexec/tmux-status-right — the Phase 4 zj-hud gradient ribbon
# (mode pill / hints / session / widgets / clock). Stubs replace
# pmset/networksetup/tmux; theme colors come from a fixture JSON; the
# fullscreen mirror and hostname alias are fixture files.
Describe 'tmux-status-right'
  setup() {
    TEST_TMP=$(mktemp -d)
    W="$PWD/home/dot_local/libexec/executable_tmux-status-right"

    cat > "$TEST_TMP/theme.json" <<'EOS'
{"roles":{"ui":{"bg":"#1e1e2e","fg":"#cdd6f4"},
  "mode":{"locked":"#fab387","resize":"#cba6f7","pane":"#89b4fa","tab":"#a6e3a1",
          "move":"#f9e2af","scroll":"#b4befe","session":"#f38ba8","tmux":"#f38ba8","rename":"#f9e2af","search":"#89b4fa","visual":"#cba6f7"},
  "action":{"attention":"#f9e2af"}},
 "palette":{"base":"#1e1e2e","white":"#ffffff"},
 "extended":{"tab":{"bg":"#282c41","fg":"#9b9fc1","active_bg":"#656a83","active_fg":"#ffffff"}}}
EOS

    cat > "$TEST_TMP/tmux" <<'EOS'
#!/usr/bin/env zsh
if [[ "$1" == "show" && "$3" == "@mux_stack" ]]; then
  print -r -- "${STUB_STACK:-}"
  exit 0
fi
if [[ "$1" == "show-environment" ]]; then
  if [[ -n "${STUB_SSH:-}" ]]; then
    print -- "SSH_CONNECTION=$STUB_SSH"
  else
    print -- "-SSH_CONNECTION"
  fi
fi
exit 0
EOS
    cat > "$TEST_TMP/pmset" <<'EOS'
#!/usr/bin/env zsh
print -- "Now drawing from '${STUB_POWER:-AC Power}'"
print -- " -InternalBattery-0 (id=1)	${STUB_PCT:-57}%; charging; 0:42 remaining"
EOS
    cat > "$TEST_TMP/networksetup" <<'EOS'
#!/usr/bin/env zsh
print -- "Wi-Fi Power (en0): ${STUB_WIFI:-On}"
EOS
    cat > "$TEST_TMP/osascript" <<'EOS'
#!/usr/bin/env zsh
while IFS= read -r _line; do :; done
print -- "${STUB_GHOSTTY_FULLSCREEN:-WINDOWED}"
EOS
    chmod +x "$TEST_TMP/tmux" "$TEST_TMP/pmset" "$TEST_TMP/networksetup" \
      "$TEST_TMP/osascript"

    # ribbon ssh truth = its own process env (zj-hud parity)
    unset SSH_CONNECTION SSH_CLIENT
    export MUX_TMUX_BIN="$TEST_TMP/tmux"
    export PMSET_BIN="$TEST_TMP/pmset"
    export NETWORKSETUP_BIN="$TEST_TMP/networksetup"
    export WIDGETS_OSASCRIPT_BIN="$TEST_TMP/osascript"
    export WIDGETS_FULLSCREEN_STATE="$TEST_TMP/fullscreen_state"
    export WIDGETS_HOSTNAME_ALIAS="$TEST_TMP/hostname-alias"
    export WIDGETS_THEME_JSON="$TEST_TMP/theme.json"

    export G_DIV=$'\Ue0ba'
    export G_WIFI_ON=$'\U000F05A9' G_WIFI_OFF=$'\U000F092E'
    export G_CLOCK=$'\U000F00F0' G_HOST=$'\U000F048D'
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset MUX_TMUX_BIN PMSET_BIN NETWORKSETUP_BIN WIDGETS_OSASCRIPT_BIN WIDGETS_FULLSCREEN_STATE \
      WIDGETS_HOSTNAME_ALIAS WIDGETS_THEME_JSON STUB_SSH SSH_CONNECTION SSH_CLIENT STUB_POWER STUB_PCT \
      STUB_WIFI STUB_GHOSTTY_FULLSCREEN G_DIV G_WIFI_ON G_WIFI_OFF G_CLOCK G_HOST
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'local windowed at rest renders nothing (system segments are fullscreen-only)'
    When call zsh "$W" root 0 main
    The output should equal ""
  End

  It 'local fullscreen shows power + wifi + clock, no mode, no main session'
    printf 'true' > "$TEST_TMP/fullscreen_state"
    When call zsh "$W" root 0 main
    The output should include "$G_DIV"
    The output should include "$G_WIFI_ON"
    The output should include "$G_CLOCK"
    The output should not include "Tab"
    The output should not include "Main"
  End

  It 'detects Ghostty non-native fullscreen independently of WezTerm state'
    printf 'false' > "$TEST_TMP/fullscreen_state"
    export STUB_GHOSTTY_FULLSCREEN=NON_NATIVE_FULLSCREEN
    When call zsh "$W" root 0 main 0 0 '' 0 0 '' 120 '' '' 0 '' xterm-ghostty
    The output should include "$G_CLOCK"
  End

  It 'does not reuse stale WezTerm fullscreen state for Ghostty'
    printf 'true' > "$TEST_TMP/fullscreen_state"
    export STUB_GHOSTTY_FULLSCREEN=WINDOWED
    When call zsh "$W" root 0 main 0 0 '' 0 0 '' 120 '' '' 0 '' xterm-ghostty
    The output should equal ""
  End

  It 'a key table adds the mode pill and re-tints the ribbon to the mode color'
    When call zsh "$W" tab 0 main
    The output should include "Tab"
    The output should include "bg=#a6e3a1"
  End

  # Rename is a MODE, so it wears a pill — and its hint advertises the keys
  # that kind of rename actually has. The roll is a SESSION affordance; a
  # window or pane rename must not claim it.
  It 'a session rename shows the Rename pill and the random-name hint'
    When call zsh "$W" root 0 main 0 0 session
    The output should include "Rename"
    The output should include "random"
    The output should include "cancel"
  End

  It 'a window rename offers cancel and nothing about rolling'
    When call zsh "$W" root 0 main 0 0 window
    The output should include "Rename"
    The output should include "cancel"
    The output should not include "random"
  End

  It 'copy-mode wins as Scroll'
    When call zsh "$W" root 1 main
    The output should include "Scroll"
    The output should include "bg=#b4befe"
  End

  It 'an active search in copy-mode shows Search on top of the stack'
    When call zsh "$W" root 1 main 0 1
    The output should include "Search"
    The output should not include "Scroll"
  End

  It 'the open search input (typing) already shows Search'
    When call zsh "$W" root 1 main 0 0 '' 0 1
    The output should include "Search"
  End

  # The MODE PILL names the top of the mode STACK. tmux state cannot say
  # WHICH state it is — the copy family is one tmux fact (pane_in_mode)
  # wearing three faces — it only says whether the stack has gone stale.
  Describe 'the mode pill'
    It 'keeps Search when a search stops matching'
      # Mode B find: M-c makes a lowercase term case-sensitive, every match
      # disappears, tmux clears search_present — and the pill fell back to
      # Scroll even though the user is still standing in Search
      When call env STUB_STACK='search:0' zsh "$W" root 1 main 0 0 '' 0 0
      The output should include "Search"
      The output should not include "Scroll"
    End

    It 'names the copy face the stack chose, not the one tmux can see'
      When call env STUB_STACK='command:1 scroll:1 copy:1' zsh "$W" root 1 main
      The output should include "Copy"
      The output should not include "Scroll"
    End

    It 'falls back to tmux state when the stack is stale'
      # nothing pushed it and the pane is not in copy-mode: the entry is a
      # leftover, so the bar must not advertise a mode the user is not in
      When call env STUB_STACK='command:1 scroll:0' zsh "$W" root 0 main
      The output should not include "Scroll"
    End

    It 'falls back when the stack names a table the client is not in'
      When call env STUB_STACK='command:1 pane:1' zsh "$W" root 0 main
      The output should not include "Pane"
    End

    It 'still resolves from tmux state when the stack is empty'
      When call env STUB_STACK='' zsh "$W" root 1 main
      The output should include "Scroll"
    End
  End

  # tmux draws its own [copy_position/limit] (N results) box in the pane's
  # top-right corner. It is foreign chrome — unthemed, and two raw numbers
  # that read as a match counter but are not — so status.conf empties
  # copy-mode-position-format and the fact worth keeping comes here instead.
  Describe 'the search position'
    # ` X / N ` — which match you are standing on, of how many. tmux has no
    # index format at all, so X is the search's OWN position (mux-search
    # keeps it; the cursor may wander without changing it).
    It 'shows position over count'
      When call env STUB_STACK='search:0' zsh "$W" root 1 main 0 1 '' 0 0 '' 120 'search:0' 6 0 2
      The output should include "2 / 6"
    End

    It 'sits after the flags, at the end of the ribbon side'
      order() {
        env STUB_STACK='search:0' zsh "$W" root 1 main 0 1 '' 0 0 '' 120 'search:0' 6 0 2 \
          | sed 's/#\[[^]]*\]//g' | grep -oE 'wrap|[0-9]+ / [0-9]+' | tr '\n' ' '
      }
      When call order
      The output should equal "wrap 2 / 6 "
    End

    It 'starts at the bottom-most match'
      When call env STUB_STACK='search:0' zsh "$W" root 1 main 0 1 '' 0 0 '' 120 'search:0' 3 0 1
      The output should include "1 / 3"
    End

    It 'reads zero of zero when the term stopped matching'
      # the M-c case: tmux clears its search state and the count comes back
      # empty — 0 / 0 is exactly the feedback that was missing
      When call env STUB_STACK='search:0' zsh "$W" root 1 main 0 0 '' 0 0 '' 120 'search:0' '' 0 ''
      The output should include "0 / 0"
    End

    It 'marks a count tmux could not finish'
      When call env STUB_STACK='search:0' zsh "$W" root 1 main 0 1 '' 0 0 '' 120 'search:0' 6 1 2
      The output should include "2 / 6+"
    End

    It 'shows nothing outside Search'
      When call env STUB_STACK='command:1 scroll:1' zsh "$W" root 1 main 0 0 '' 0 0 '' 120 'command:1 scroll:1' 6 0 2
      The output should not include " / "
    End
  End

  # The which-key hint ("󰘵 . keys") advertises a key the user can actually
  # press: it appears only while the mode on top of the STACK has its panel
  # down, and never while a dialog owns the keyboard.
  Describe 'the which-key hint'
    It 'advertises the toggle while the mode panel is down'
      When call env STUB_STACK='command:1 scroll:0' zsh "$W" root 1 main
      The output should include "keys"
      The output should include "Scroll"
    End

    It 'takes the stack from its ARGUMENT when the bar passes one'
      # status-right is a #(): tmux re-runs it when the format-expanded
      # ARGUMENTS change, so the stack has to be one of them — otherwise
      # raising the panel does not repaint the bar until the next tick.
      When call env STUB_STACK='command:1 scroll:0' zsh "$W" root 1 main 0 0 '' 0 0 '' 80 'command:1 scroll:1'
      The output should not include "keys"
      The output should include "Scroll"
    End

    It 'drops the hint once the panel is up'
      When call env STUB_STACK='command:1 scroll:1' zsh "$W" root 1 main
      The output should not include "keys"
      The output should include "Scroll"
    End

    It 'stays quiet while the search INPUT owns the keyboard'
      # the dialog is a popup: it swallows M-. , so advertising it lies
      When call env STUB_STACK='command:1 scroll:1 search:0' zsh "$W" root 1 main 0 0 '' 0 1
      The output should not include "keys"
      The output should include "Search"
    End

    It 'advertises it again once the term is committed'
      # (SearchMode): the dialog is gone, the panel is down, M-. works
      When call env STUB_STACK='command:1 scroll:1 search:0' zsh "$W" root 1 main 0 1
      The output should include "keys"
      The output should include "Search"
    End

    It 'drops it when the Search panel is raised'
      When call env STUB_STACK='command:1 scroll:1 search:1' zsh "$W" root 1 main 0 1
      The output should not include "keys"
      The output should include "Search"
    End

    It 'stays quiet while the rename dialog owns the keyboard'
      When call env STUB_STACK='command:1 pane:0' zsh "$W" root 0 main 0 0 1
      The output should not include "keys"
      The output should include "Rename"
    End
  End

  It 'copy/visual state shows the Copy pill over Scroll'
    When call zsh "$W" root 1 main 0 0 '' 1
    The output should include "Copy"
    The output should include "bg=#cba6f7"
  End

  It 'an open rename dialog tops the stack as Rename'
    When call zsh "$W" root 0 main 0 0 1
    The output should include "Rename"
    The output should include "bg=#f9e2af"
  End

  It 'locked mode adds the exit hint segment'
    When call zsh "$W" locked 0 main
    The output should include "Locked"
    The output should include "exit"
  End

  It 'the armed leader (prefix table) shows the Command pill'
    When call zsh "$W" prefix 0 main
    The output should include "Command"
    The output should include "bg=#f38ba8"
  End

  It 'an active key table wins over the pending leader'
    When call zsh "$W" tab 0 main 1
    The output should include "Tab"
    The output should not include "Command"
  End

  It 'a non-default session shows as a Title Case pill'
    When call zsh "$W" root 0 zellij-plugins
    The output should include "Zellij Plugins"
  End

  It 'AC at 100% shows the plug glyph alone'
    printf 'true' > "$TEST_TMP/fullscreen_state"
    export STUB_PCT=100
    When call zsh "$W" root 0 main
    The output should include "󰂄"
    The output should not include "100%"
  End

  It 'ssh keeps only the host segment (alias preferred) + no clock'
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    printf 'devbox' > "$TEST_TMP/hostname-alias"
    When call zsh "$W" root 0 main
    The output should include "$G_HOST devbox"
    The output should not include "%"
    The output should not include "$G_CLOCK"
  End

  It 'ssh stays host-only even in fullscreen (conditions are ANDed)'
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    printf 'true' > "$TEST_TMP/fullscreen_state"
    printf 'devbox' > "$TEST_TMP/hostname-alias"
    When call zsh "$W" root 0 main
    The output should include "$G_HOST devbox"
    The output should not include "󱊥"
    The output should not include "$G_CLOCK"
  End

  It 'uses the effective palette base behind pill dividers'
    jq '.palette.base = "#101020"' "$TEST_TMP/theme.json" \
      >"$TEST_TMP/theme.tmp" && mv "$TEST_TMP/theme.tmp" "$TEST_TMP/theme.json"
    When call zsh "$W" root 0 other-session
    The output should include "bg=#101020"
    The output should not include "bg=#1e1e2e"
  End

  It 'gradient: the rightmost segment carries the most saturated stop'
    When call zsh "$W" tab 0 main
    # last bg= occurrence should be the full mode color (stop 0 = base)
    The output should include "bg=#a6e3a1,"
  End
End
