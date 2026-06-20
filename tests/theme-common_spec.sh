# Tests for theme-common.zsh — semantic tokens + gum flag arrays.
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

  It 'themes the gum input cursor mauve'
    When call print -r -- "${theme_gum_input[*]}"
    The output should include "--cursor.foreground #cba6f7"
  End

  It 'themes the gum confirm selection with mauve bg + base fg'
    When call print -r -- "${theme_gum_confirm[*]}"
    The output should include "--selected.background #cba6f7"
    The output should include "--selected.foreground #1e1e2e"
  End

  It 'theme::rule emits a sized bar at an explicit width'
    When call theme::rule 10
    The output should equal "━━━━━━"
  End
End
