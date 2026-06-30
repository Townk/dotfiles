#!/usr/bin/env zsh
# theme-common.zsh — semantic theme tokens (THEME_*), decoration glyphs,
# and theme::rule, all built from the C_*/C_HEX_* palette in common.zsh.
# SOURCED, never executed. The single styling source of truth for the dialog
# family (zellij-modal, input::*, zj::*).

_theme_self="${(%):-%x}"
source "$(dirname "$_theme_self")/common.zsh"
unset _theme_self

[ -n "${__THEME_COMMON_LOADED:-}" ] && return 0
__THEME_COMMON_LOADED=1

# --- semantic SGR tokens (composed from C_*, never raw colors) ---------------
THEME_H1="${C_BOLD}${C_MAUVE}"      # modal title (▓▓▓ …)
THEME_H2="${C_BOLD}${C_TEXT}"       # sub-heading / active form tab
THEME_SEPARATOR="${C_SURFACE0}"     # rule under the title
THEME_INPUT_BORDER="${C_SURFACE2}"  # input box border
THEME_KEY_BINDING="${C_WHITE}"      # keybinding chord keys (bright white, matches zj-hud whichkey)
THEME_COMMENT="${C_OVERLAY0}"       # muted labels
THEME_ACCENT="${C_MAUVE}"           # cursor / prompt / active marker
THEME_TEXT_NORMAL="${C_TEXT}"
THEME_TEXT_BOLD="${C_BOLD}${C_TEXT}"
THEME_DANGER="${C_DANGER}"
THEME_RESET="${C_RES}"

# --- decoration glyphs (callers may override per call) -----------------------
THEME_ICON_PROMPT="󰧑"
THEME_ICON_CHECK="✓"
THEME_ICON_ACTIVE="▌"
THEME_ICON_TAB_SEP="▏"

# theme::sgr_fg "#rrggbb" — a 24-bit set-foreground SGR built from a hex value.
# Use for color that must render regardless of the source-time `[ -t 1 ]` gate:
# the C_*/THEME_* SGR vars are empty when a script's stdout is a captured file
# (e.g. input-widget under zellij-modal), but C_HEX_* are always set. The
# input::confirm hint always prints to /dev/tty, so it builds its colors here.
theme::sgr_fg() {
  local h="${1#\#}"
  printf '\e[38;2;%d;%d;%dm' "$(( 0x${h:0:2} ))" "$(( 0x${h:2:2} ))" "$(( 0x${h:4:2} ))"
}

# theme::sgr_bg "#rrggbb" — a 24-bit set-background SGR. Used to paint a modal's
# canvas (e.g. the dialog/which-key background) so a whole line/region fills the
# color, not just the glyphs. Pair with `\e[K` (erase to EOL) to flood a row.
theme::sgr_bg() {
  local h="${1#\#}"
  printf '\e[48;2;%d;%d;%dm' "$(( 0x${h:0:2} ))" "$(( 0x${h:2:2} ))" "$(( 0x${h:4:2} ))"
}

# theme::args — fill the global AI_THEME_ARGS with the --theme-* flags for
# ai-playbook input (and the pager) from the shared SEMANTIC roles (C_ROLE_*).
# One source for the dialog colors; the binary keeps its own defaults if these
# are absent. The button-* chrome is the `neutral` action intent (tab chrome);
# danger/warning stay on the tuned dialog variants. Action INTENTS for buttons
# are exported separately via ~/.config/theme/chezmoi-system.json (roles.action) for
# TUIs to read directly.
typeset -ga AI_THEME_ARGS
theme::args() {
  AI_THEME_ARGS=(
    --theme-accent         "$C_ROLE_UI_ACCENT"
    --theme-border         "$C_ROLE_UI_BORDER_FOCUS"
    --theme-danger         "$C_HEX_DIALOG_DANGER"
    --theme-warning        "$C_HEX_DIALOG_WARNING"
    --theme-base           "$C_ROLE_UI_DIALOG_BG"
    --theme-text           "$C_ROLE_UI_FG"
    --theme-muted          "$C_ROLE_UI_OVERLAY"
    --theme-rule           "$C_ROLE_UI_SEPARATOR"
    --theme-key            "$C_ROLE_UI_KEY"
    --theme-field-border   "$C_ROLE_UI_BORDER"
    --theme-button-bg      "$C_HEX_TAB_BG"
    --theme-button-fg      "$C_HEX_TAB_FG"
    --theme-button-sel-bg  "$C_HEX_TAB_ACTIVE_BG"
    --theme-button-sel-fg  "$C_HEX_TAB_ACTIVE_FG"
    --theme-scroll-thumb   "$C_ROLE_UI_MUTED"
  )
}

# theme::rule [COLS] — print a horizontal rule of ━, width = COLS-4 (the modal's
# 2-cell inset on each side). With no COLS, read the live tty width via stty
# (zellij doesn't reliably export COLUMNS), falling back to $COLUMNS or 80.
theme::rule() {
  local cols="${1:-}"
  if [[ -z "$cols" ]]; then
    cols=$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}') || true
    [[ -z "$cols" ]] && cols="${COLUMNS:-80}"
  fi
  cols=$((cols - 4))
  ((cols < 1)) && cols=1
  # Pad an explicitly-set empty parameter ($fill) to width $cols with ━. The
  # parameter name is REQUIRED: a bare ${(l:cols::━:)} aborts under `set -u`
  # ("parameter not set"), which silently kills zellij-modal (run with
  # `set -euo pipefail`) before it spawns its dialog target.
  local fill=""
  printf '%s' "${(l:cols::━:)fill}"
}
