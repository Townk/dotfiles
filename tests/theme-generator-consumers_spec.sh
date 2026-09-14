# generate-theme.sh renders a consumer's theme only where that consumer is
# deployed. The GUI terminals and the agent harnesses are trait-gated in
# .chezmoiignore, so their directories never exist on a headless box or an
# appliance; the generator used to `mkdir -p` them anyway, leaving a stray
# ~/.pi, ~/.claude, ~/.config/ghostty and ~/.config/wezterm behind (found on
# the first appliance onboard, 2026-09-14).
#
# The generator is copied into a scratch dir before running: its Blink render
# writes into the repo's assets/ next to the script (not under THEME_DEST), so a
# copy keeps the test off the real tree. chezmoi is stubbed to echo its input.
Describe 'generate-theme.sh renders per-consumer themes only where the consumer exists'
  SRC="$SHELLSPEC_PROJECT_ROOT/custom-builds/theme"

  setup() {
    TMP="$(mktemp -d "$SHELLSPEC_TMPBASE/theme-consumers.XXXXXX")"
    DEST="$TMP/home"; BIN="$TMP/bin"; GEN="$TMP/gen"
    mkdir -p "$DEST" "$BIN" "$GEN"
    cp "$SRC/generate-theme.sh" "$GEN/"
    cp -R "$SRC/templates" "$GEN/templates"
    printf '#!/bin/sh\ncat\n' >"$BIN/chezmoi"; chmod +x "$BIN/chezmoi"
  }
  cleanup() { rm -rf "$TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_gen() { PATH="$BIN:$PATH" THEME_DEST="$DEST" THEME_CTP_NO_FETCH=1 bash "$GEN/generate-theme.sh"; }

  It 'creates none of the gated consumer dirs on a box that has none of the apps'
    When run run_gen
    The status should be success
    The stdout should include "skipped"
    The stderr should include "nvim"   # ctp cache absent in the sandbox: the documented ⚠ skip
    The path "$DEST/.config/theme/chezmoi-system.zsh" should be exist
    The path "$DEST/.config/glow/chezmoi-system.json" should be exist
    The path "$DEST/.pi" should not be exist
    The path "$DEST/.claude" should not be exist
    The path "$DEST/.config/ghostty" should not be exist
    The path "$DEST/.config/wezterm" should not be exist
  End

  It 'renders into the consumers that are present and skips the rest'
    mkdir -p "$DEST/.pi/agent" "$DEST/.config/wezterm"
    When run run_gen
    The status should be success
    The stdout should include ".pi/agent/themes/chezmoi-system.json"
    The stderr should include "nvim"
    The path "$DEST/.pi/agent/themes/chezmoi-system.json" should be exist
    The path "$DEST/.config/wezterm/colors/chezmoi-system.toml" should be exist
    The path "$DEST/.config/wezterm/tint-palette.toml" should be exist
    The path "$DEST/.claude" should not be exist
    The path "$DEST/.config/ghostty" should not be exist
  End
End
