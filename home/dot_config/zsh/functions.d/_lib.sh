# Prompt colors from the single-source palette (~/.config/theme/palette.zsh →
# C_HEX_*, generated from .chezmoidata/theme.yaml), mapped by role. Source it
# (guarded + fork-free, a no-op if .zshrc already did) so these resolve even when
# _lib.sh is pulled in outside an interactive shell.
source "${THEME_PALETTE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/theme/palette.zsh}"
typeset -g C_GRE="%F{$C_HEX_GREEN}"
typeset -g C_RED="%F{$C_HEX_RED}"
typeset -g C_YEL="%F{$C_HEX_YELLOW}"
typeset -g C_BLU="%F{$C_HEX_BLUE}"
typeset -g C_BBL="%F{$C_HEX_SAPPHIRE}"
typeset -g C_CYA="%F{$C_HEX_TEAL}"
typeset -g C_MAG="%F{$C_HEX_MAUVE}"
typeset -g C_WHI="%F{$C_HEX_SUBTEXT1}"
typeset -g C_GRA="%F{$C_HEX_OVERLAY0}"
typeset -g C_BWH="%F{$C_HEX_WHITE}"
typeset -g C_ORA="%F{$C_HEX_PEACH}"
typeset -g C_PIN="%F{$C_HEX_PINK}"
typeset -g C_PUR="%F{$C_HEX_LAVENDER}"
typeset -g C_BLA="%F{$C_HEX_CRUST}"
typeset -g C_RES="%f"

function die {
  if [[ $# -ne 0 ]]; then
    print -P -- "$*" >&2
  fi
  return 1
}
