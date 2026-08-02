# Tests for theme-common.zsh — semantic tokens + theme helpers.
Describe 'theme-common.zsh'
  Include home/dot_local/lib/theme-common.zsh

  It 'maps THEME_SEPARATOR to the surface0 color'
    When call test "$THEME_SEPARATOR" = "$C_SURFACE0"
    The status should be success
  End

  It 'maps THEME_ACCENT to mauve'
    When call test "$THEME_ACCENT" = "$C_MAUVE"
    The status should be success
  End

  It 'theme::rule emits a sized bar at an explicit width'
    When call theme::rule 10
    The output should equal "━━━━━━"
  End

  # Regression: theme::rule is called by zellij-modal, which runs under
  # `set -euo pipefail`. A bare ${(l:cols::━:)} fill aborts under nounset
  # ("parameter not set"), silently killing every modal dialog before it
  # spawns its target. Run in a real nounset shell to guard that path.
  It 'theme::rule is nounset-safe (set -u)'
    When run zsh -uc 'source home/dot_local/lib/theme-common.zsh; theme::rule 10'
    The output should equal "━━━━━━"
    The status should be success
  End

  # ── hex → SGR (C1 canonical) ───────────────────────────────────────────────
  # theme::sgr_fg / theme::sgr_bg are the single hex→24-bit-SGR pair; the C1
  # consolidation folded the fzf-tab-rich xdigit guard in and routed six copies
  # (pick / backup-tm / mux_dialog / mux-whichkey / fzf-tab-rich) here.
  Describe 'theme::sgr_fg / theme::sgr_bg'
    It 'builds the exact truecolor set-foreground escape'
      When call theme::sgr_fg '#e5bf7b'
      The output should equal "$(printf '\033[38;2;229;191;123m')"
    End

    It 'builds the exact truecolor set-background escape'
      When call theme::sgr_bg '#e5bf7b'
      The output should equal "$(printf '\033[48;2;229;191;123m')"
    End

    # A leading '#' is optional: the six former copies split on it two
    # different ways (some sliced ${1[2,3]} and REQUIRED the '#'); the
    # canonical strips it so both forms land on the identical escape. This
    # is the "latent bug fixed" for the mux_dialog / mux-whichkey family.
    It 'accepts a bare (no-#) hex and yields the same escape as the #-form'
      hashed()  { theme::sgr_fg '#e5bf7b'; }
      bare()    { theme::sgr_fg 'e5bf7b'; }
      When call bare
      The output should equal "$(hashed)"
    End

    It 'accepts a bare hex for the background escape too'
      hashed()  { theme::sgr_bg '#e5bf7b'; }
      bare()    { theme::sgr_bg 'e5bf7b'; }
      When call bare
      The output should equal "$(hashed)"
    End

    # The folded-in guard: an empty / renamed palette token must emit NOTHING,
    # not \e[38;2;0;0;0m (black-on-black in a dialog footer).
    It 'emits nothing for empty input (guard, not black-on-black)'
      When call theme::sgr_fg ''
      The output should equal ''
    End

    It 'emits nothing for the background on empty input'
      When call theme::sgr_bg ''
      The output should equal ''
    End

    It 'emits nothing for a non-hex token'
      When call theme::sgr_fg 'zzz'
      The output should equal ''
    End

    It 'emits nothing for a too-short hex'
      When call theme::sgr_fg '#abc'
      The output should equal ''
    End
  End

  # ── hex → "R G B" decimal triple (C1: component consumers) ──────────────────
  Describe 'theme::hex_rgb'
    It 'prints the space-separated decimal triple'
      When call theme::hex_rgb '#e5bf7b'
      The output should equal '229 191 123'
    End

    It 'accepts a bare (no-#) hex'
      When call theme::hex_rgb 'e5bf7b'
      The output should equal '229 191 123'
    End

    It 'emits nothing for invalid / empty input (same guard)'
      When call theme::hex_rgb ''
      The output should equal ''
    End
  End
End
