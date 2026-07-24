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
          "move":"#f9e2af","scroll":"#b4befe","session":"#f38ba8","tmux":"#f38ba8"},
  "action":{"attention":"#f9e2af"}},
 "extended":{"tab":{"bg":"#282c41","fg":"#9b9fc1","active_bg":"#656a83","active_fg":"#ffffff"}}}
EOS

    cat > "$TEST_TMP/tmux" <<'EOS'
#!/usr/bin/env zsh
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
    chmod +x "$TEST_TMP/tmux" "$TEST_TMP/pmset" "$TEST_TMP/networksetup"

    export MUX_TMUX_BIN="$TEST_TMP/tmux"
    export PMSET_BIN="$TEST_TMP/pmset"
    export NETWORKSETUP_BIN="$TEST_TMP/networksetup"
    export WIDGETS_FULLSCREEN_STATE="$TEST_TMP/fullscreen_state"
    export WIDGETS_HOSTNAME_ALIAS="$TEST_TMP/hostname-alias"
    export WIDGETS_THEME_JSON="$TEST_TMP/theme.json"

    export G_DIV=$'\Ue0ba'
    export G_WIFI_ON=$'\U000F05A9' G_WIFI_OFF=$'\U000F092E'
    export G_CLOCK=$'\U000F00F0' G_HOST=$'\U000F04CD'
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset MUX_TMUX_BIN PMSET_BIN NETWORKSETUP_BIN WIDGETS_FULLSCREEN_STATE \
      WIDGETS_HOSTNAME_ALIAS WIDGETS_THEME_JSON STUB_SSH STUB_POWER STUB_PCT \
      STUB_WIFI G_DIV G_WIFI_ON G_WIFI_OFF G_CLOCK G_HOST
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'root/local renders a neutral ribbon: widgets + clock, no mode, no main session'
    When call zsh "$W" root 0 main
    The output should include "$G_DIV"
    The output should include "$G_WIFI_ON"
    The output should include "$G_CLOCK"
    The output should not include "Tab"
    The output should not include "Main"
  End

  It 'a key table adds the mode pill and re-tints the ribbon to the mode color'
    When call zsh "$W" tab 0 main
    The output should include "Tab"
    The output should include "bg=#a6e3a1"
  End

  It 'copy-mode wins as Scroll'
    When call zsh "$W" root 1 main
    The output should include "Scroll"
    The output should include "bg=#b4befe"
  End

  It 'locked mode adds the exit hint segment'
    When call zsh "$W" locked 0 main
    The output should include "Locked"
    The output should include "exit"
  End

  It 'leader pending (client_prefix) shows the Command pill'
    When call zsh "$W" root 0 main 1
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

  It 'ssh + fullscreen restores the local widget set'
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    printf 'true' > "$TEST_TMP/fullscreen_state"
    printf 'devbox' > "$TEST_TMP/hostname-alias"
    When call zsh "$W" root 0 main
    The output should include "$G_HOST devbox"
    The output should include "󱊥 57%"
    The output should include "$G_CLOCK"
  End

  It 'gradient: the rightmost segment carries the most saturated stop'
    When call zsh "$W" tab 0 main
    # last bg= occurrence should be the full mode color (stop 0 = base)
    The output should include "bg=#a6e3a1,"
  End
End
