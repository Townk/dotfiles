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
#
# THE single hex→SGR pair (C1 consolidation): the former pick / backup-tm /
# mux_dialog / mux-whichkey / fzf-tab-rich copies route here. A leading '#' is
# optional (some copies REQUIRED it and mis-parsed a bare hex). The xdigit
# guard — folded in from fzf-tab-rich's copy — emits NOTHING for empty/invalid
# input, so a renamed/absent palette token no longer paints black-on-black
# (\e[38;2;0;0;0m) in a dialog footer.
theme::sgr_fg() {
  emulate -L zsh -o extended_glob
  local h="${1#\#}"
  [[ $h == [[:xdigit:]](#c6) ]] || return 0
  printf '\e[38;2;%d;%d;%dm' "$(( 0x${h:0:2} ))" "$(( 0x${h:2:2} ))" "$(( 0x${h:4:2} ))"
}

# theme::sgr_bg "#rrggbb" — a 24-bit set-background SGR. Used to paint a modal's
# canvas (e.g. the dialog/which-key background) so a whole line/region fills the
# color, not just the glyphs. Pair with `\e[K` (erase to EOL) to flood a row.
# Same '#'-optional + xdigit-guard rules as theme::sgr_fg.
theme::sgr_bg() {
  emulate -L zsh -o extended_glob
  local h="${1#\#}"
  [[ $h == [[:xdigit:]](#c6) ]] || return 0
  printf '\e[48;2;%d;%d;%dm' "$(( 0x${h:0:2} ))" "$(( 0x${h:2:2} ))" "$(( 0x${h:4:2} ))"
}

# theme::hex_rgb "#rrggbb" — the decimal component triple "R G B" (space
# separated), for consumers that do color math on the channels rather than
# emit an SGR (the status-bar OKLab gradient). Same '#'-optional + xdigit-guard
# rules as theme::sgr_fg; emits nothing on invalid/empty input.
theme::hex_rgb() {
  emulate -L zsh -o extended_glob
  local h="${1#\#}"
  [[ $h == [[:xdigit:]](#c6) ]] || return 0
  printf '%d %d %d' "$(( 0x${h:0:2} ))" "$(( 0x${h:2:2} ))" "$(( 0x${h:4:2} ))"
}

# theme::json_path — resolve THE single palette JSON every reader must agree on
# (C2 consolidation). One resolution order, so the status bar (cache tier) and
# the dialogs (formerly canonical tier) can never render DIFFERENT palettes on
# one screen — the split-palette-under-SSH bug:
#   1. $THEME_PALETTE_JSON  — the sole override going forward (.zshrc exports it,
#      pointing at the effective/SSH-tinted cache copy). This RETIRES the old
#      per-reader seams WIDGETS_THEME_JSON / THEME_JSON (Decision 3).
#   2. else the effective cache copy $XDG_CACHE_HOME/theme/chezmoi-system.json
#      if readable — theme-apply writes the override-tinted palette there.
#   3. else the canonical config copy $XDG_CONFIG_HOME/theme/chezmoi-system.json.
# Prints the resolved path; never fails (the config tier is unconditional).
# The POSIX-sh consumers that cannot source this (pbpaste) inline the SAME order.
theme::json_path() {
  emulate -L zsh
  if [[ -n "${THEME_PALETTE_JSON:-}" ]]; then
    print -r -- "$THEME_PALETTE_JSON"
  elif [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/theme/chezmoi-system.json" ]]; then
    print -r -- "${XDG_CACHE_HOME:-$HOME/.cache}/theme/chezmoi-system.json"
  else
    print -r -- "${XDG_CONFIG_HOME:-$HOME/.config}/theme/chezmoi-system.json"
  fi
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
