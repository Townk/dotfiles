# Tests for libexec/tmux-status-widgets — the Phase 4 status-bar widget
# string (power/battery/wifi/host/clock with the zj-hud visibility rules).
# Stubs replace pmset/networksetup/tmux; the fullscreen mirror and hostname
# alias are fixture files under $TEST_TMP.
Describe 'tmux-status-widgets'
  setup() {
    TEST_TMP=$(mktemp -d)
    W="$PWD/home/dot_local/libexec/executable_tmux-status-widgets"

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

    # Glyphs by codepoint (safer than pasting private-use chars here).
    export G_WIFI_ON=$'\U000F05A9' G_WIFI_OFF=$'\U000F092E'
    export G_CLOCK=$'\U000F00F0' G_BATT_MID=$'\U000F12A2'
    export G_HOST="󰒍"
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset MUX_TMUX_BIN PMSET_BIN NETWORKSETUP_BIN WIDGETS_FULLSCREEN_STATE \
      WIDGETS_HOSTNAME_ALIAS STUB_SSH STUB_POWER STUB_PCT STUB_WIFI \
      G_WIFI_ON G_WIFI_OFF G_CLOCK G_BATT_MID G_HOST
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'local on AC shows tiered power + wifi + clock, no host'
    When call zsh "$W" main
    The output should include "󱊥 57%"
    The output should include "$G_WIFI_ON"
    The output should include "$G_CLOCK"
    The output should not include "$G_HOST"
  End

  It 'AC at 100% shows the plug glyph alone (no percentage)'
    export STUB_PCT=100
    When call zsh "$W" main
    The output should include "󰂄"
    The output should not include "100%"
  End

  It 'on battery shows the battery tier glyph, not the charging one'
    export STUB_POWER="Battery Power" STUB_PCT=42
    When call zsh "$W" main
    The output should include "$G_BATT_MID 42%"
    The output should not include "󱊥"
  End

  It 'wifi off shows the off glyph'
    export STUB_WIFI="Off"
    When call zsh "$W" main
    The output should include "$G_WIFI_OFF"
    The output should not include "$G_WIFI_ON"
  End

  It 'ssh shows only the host segment, alias preferred'
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    printf 'devbox' > "$TEST_TMP/hostname-alias"
    When call zsh "$W" main
    The output should include "$G_HOST devbox"
    The output should not include "%"
    The output should not include "$G_CLOCK"
  End

  It 'ssh falls back to hostname -s without an alias file'
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    When call zsh "$W" main
    The output should include "$G_HOST $(hostname -s)"
  End

  It 'ssh + fullscreen adds the local widget set back'
    export STUB_SSH="10.0.0.2 55000 10.0.0.9 22"
    printf 'true' > "$TEST_TMP/fullscreen_state"
    printf 'devbox' > "$TEST_TMP/hostname-alias"
    When call zsh "$W" main
    The output should include "$G_HOST devbox"
    The output should include "󱊥 57%"
    The output should include "$G_CLOCK"
  End
End
