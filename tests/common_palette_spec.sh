# Tests for the extended truecolor palette in common.zsh.

# The palette file is a generated artifact (run_onchange_after_54); on a fresh
# machine .setup.sh deploys common.zsh consumers (system-onboard) BEFORE the
# full apply that renders it. The stdlib must tolerate that window under the
# strict mode those consumers run with (set -eu -o pipefail).
Describe 'common.zsh — missing palette (fresh-machine bootstrap window)'
  It 'sources cleanly when the palette file does not exist yet'
    When run zsh -c 'set -eu -o pipefail
      THEME_PALETTE_FILE=/nonexistent/chezmoi-system.zsh
      source home/dot_local/lib/common.zsh
      print -r -- sourced'
    The status should be success
    The output should equal 'sourced'
  End
End

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
