# Tests for the extended truecolor palette in common.zsh.
Describe 'common.zsh — extended palette'
  Include home/dot_local/lib/common.zsh

  It 'exposes the mauve hex value (ungated)'
    When call test "$C_HEX_MAUVE" = "#cba6f7"
    The status should be success
  End

  It 'exposes the three Catppuccin grays'
    When call test "$C_HEX_SURFACE0$C_HEX_SURFACE2$C_HEX_OVERLAY0" = "#313244#585b70#6c7086"
    The status should be success
  End

  It 'exposes danger red and base'
    When call test "$C_HEX_DANGER$C_HEX_BASE" = "#f38ba8#1e1e2e"
    The status should be success
  End
End
