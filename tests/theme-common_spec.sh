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
End
