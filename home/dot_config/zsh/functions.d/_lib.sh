# Prompt colors from the single-source palette (~/.config/theme/chezmoi-system.zsh →
# C_HEX_*, generated from .chezmoidata/theme.yaml), mapped by role. Source it
# (guarded + fork-free, a no-op if .zshrc already did) so these resolve even when
# _lib.sh is pulled in outside an interactive shell.
#
# These are zsh PROMPT escapes (`%F{…}` / `%f`), for `print -P` and `die` — NOT
# the RAW SGR sequences common.zsh publishes. They live under the P_* namespace
# precisely so the two vocabularies can never collide under one name: a scope
# that sourced both must still get raw SGR from C_* and prompt tokens from P_*.
source "${THEME_PALETTE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/theme/chezmoi-system.zsh}"
typeset -g P_GRE="%F{$C_HEX_GREEN}"
typeset -g P_RED="%F{$C_HEX_RED}"
typeset -g P_YEL="%F{$C_HEX_YELLOW}"
typeset -g P_BLU="%F{$C_HEX_BLUE}"
typeset -g P_BBL="%F{$C_HEX_SAPPHIRE}"
typeset -g P_CYA="%F{$C_HEX_TEAL}"
typeset -g P_MAG="%F{$C_HEX_MAUVE}"
typeset -g P_WHI="%F{$C_HEX_SUBTEXT1}"
typeset -g P_GRA="%F{$C_HEX_OVERLAY0}"
typeset -g P_BWH="%F{$C_HEX_WHITE}"
typeset -g P_ORA="%F{$C_HEX_PEACH}"
typeset -g P_PIN="%F{$C_HEX_PINK}"
typeset -g P_PUR="%F{$C_HEX_LAVENDER}"
typeset -g P_BLA="%F{$C_HEX_CRUST}"
typeset -g P_RES="%f"

function die {
  if [[ $# -ne 0 ]]; then
    print -P -- "$*" >&2
  fi
  return 1
}
