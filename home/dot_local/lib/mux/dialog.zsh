#!/usr/bin/env zsh
# mux/dialog.zsh — the compact tmux dialog, drawn once.
#
# Both floating dialogs on the tmux backend (search and rename) are the SAME
# object with a different accent, glyph and payload: a three-row popup
# anchored bottom-right, a coloured left rule, a mode glyph, and a half-block
# input field. It is a port of zj-hud's render_field (src/search/mod.rs and
# src/rename/mod.rs draw the identical shape there too), so the constants
# below are the plugin's and both backends land on the same pixels.
#
# Sourced by ~/.config/mux/scripts/mux-search and mux-rename:
#
#   source "${MUX_LIB:-$HOME/.local/lib}/mux/dialog.zsh"
#   mux_dialog::init '.extended.dialog.warning'   # the accent slot
#   mux_dialog::launch "${0:A}" window            # from the --launch branch
#   mux_dialog::frame "$I_RENAME"                 # inside the popup
#   mux_dialog::field "$buf"                      # …and on every keystroke
#
# A dialog that needs room on the right for its own controls (search's three
# toggles) passes the cell count as the second argument to ::field and draws
# into that reserve itself.

# theme::sgr_fg/theme::sgr_bg — the canonical hex→SGR pair (C1). Resolved
# relative to this file (../theme-common.zsh); idempotent if already loaded.
_mux_dialog_self="${(%):-%x}"
source "${_mux_dialog_self:h:h}/theme-common.zsh"
unset _mux_dialog_self

# ---- geometry (zj-hud's PANE_WIDTH/PANE_HEIGHT and column constants) -------
typeset -g MD_W=40 MD_H=3
typeset -g MD_GLYPH_COL=2 MD_INPUT_COL=5 MD_RIGHT_INSET=5
typeset -g MD_INPUT_END=$(( MD_W - MD_RIGHT_INSET ))
typeset -g MD_AREA_W=$(( MD_INPUT_END - MD_INPUT_COL + 1 ))

typeset -g MD_TMUX="${MUX_TMUX_BIN:-tmux}"

# ---- colours ---------------------------------------------------------------
# One jq pass for the four slots every dialog uses plus the caller's accent.
# The slots are the ones the plugin compiles in: canvas = tab chrome bg,
# field = dialog mantle, rule sits over the bar's own background. Literal hex
# never appears here — the theme lint enforces that, and a palette change has
# to move both backends together.
mux_dialog::init() {
  local accent_path="${1:-.extended.dialog.search_accent}"
  local theme_json="${THEME_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/theme/chezmoi-system.json}"
  local -a c
  c=("${(@f)$(jq -r "
    .extended.tab.bg, .roles.ui.bg, .roles.ui.dialog_bg,
    ${accent_path}, .palette.white,
    .roles.action.attention, .roles.ui.border_inactive
  " "$theme_json" 2>/dev/null)}") || c=()
  (( ${#c} == 7 )) || return 1

  typeset -g MD_BG="$(theme::sgr_bg ${c[1]})"
  typeset -g MD_THEME_BG="$(theme::sgr_bg ${c[2]})"
  typeset -g MD_INPUT_BG="$(theme::sgr_bg ${c[3]})"
  typeset -g MD_ACCENT_FG="$(theme::sgr_fg ${c[4]})"
  typeset -g MD_ACCENT_BG="$(theme::sgr_bg ${c[4]})"
  typeset -g MD_WHITE_FG="$(theme::sgr_fg ${c[5]})"
  typeset -g MD_ON_FG="$(theme::sgr_fg ${c[6]})"
  typeset -g MD_OFF_FG="$(theme::sgr_fg ${c[7]})"
  typeset -g MD_BOX_FG="$(theme::sgr_fg ${c[3]})"
  typeset -g MD_RESET=$'\e[0m'
}

# ---- primitives ------------------------------------------------------------
mux_dialog::at()  { print -rn -- $'\e['"$1;$2H" }   # 1-indexed row;col
mux_dialog::rep() { local out="" i; for (( i = 0; i < $2; i++ )); do out+="$1"; done; print -rn -- "$out" }

# ---- launch ----------------------------------------------------------------
# Anchored bottom-right, one row above the status line. `-y` positions the
# BOTTOM edge (ledger row), and the popup is opened with -E -B so the dialog
# owns its whole canvas.
mux_dialog::launch() {
  local self="$1"; shift
  local cw ch
  cw="$("$MD_TMUX" display -p '#{client_width}')" || return 1
  ch="$("$MD_TMUX" display -p '#{client_height}')" || return 1
  exec "$MD_TMUX" display-popup -E -B -w "$MD_W" -h "$MD_H" \
    -x $(( cw - MD_W - 1 )) -y $(( ch - 2 )) "$self" "$@"
}

# ---- chrome ----------------------------------------------------------------
# The static frame: canvas, the accent rule down the left, the half-block box
# around the field, and the mode glyph beside it.
mux_dialog::frame() {
  local glyph="$1" row blank interior
  blank="$(mux_dialog::rep ' ' $MD_W)"
  for row in 1 2 3; do
    mux_dialog::at $row 1; print -rn -- "${MD_BG}${blank}"
    mux_dialog::at $row 1; print -rn -- "${MD_THEME_BG}${MD_ACCENT_FG}┃${MD_RESET}"
  done
  interior=$(( MD_INPUT_END - MD_INPUT_COL + 2 ))
  mux_dialog::at 1 $MD_INPUT_COL
  print -rn -- "${MD_BG}${MD_BOX_FG}𜺠$(mux_dialog::rep '▂' $interior)𜺣${MD_RESET}"
  mux_dialog::at 3 $MD_INPUT_COL
  print -rn -- "${MD_BG}${MD_BOX_FG}𜺫$(mux_dialog::rep '🮂' $interior)𜺨${MD_RESET}"
  mux_dialog::at 2 $MD_INPUT_COL;            print -rn -- "${MD_BG}${MD_BOX_FG}▐${MD_RESET}"
  mux_dialog::at 2 $(( MD_INPUT_END + 3 ));  print -rn -- "${MD_BG}${MD_BOX_FG}▌${MD_RESET}"
  mux_dialog::at 2 $(( MD_GLYPH_COL + 1 ));  print -rn -- "${MD_BG}${MD_WHITE_FG}${glyph}${MD_RESET}"
}

# ---- the field -------------------------------------------------------------
# mux_dialog::field <buffer> [reserve]
#   reserve = cells kept clear on the right for the caller's own controls.
# The text tail-scrolls so the cursor block stays visible in a long value.
mux_dialog::field() {
  local buf="$1" reserve="${2:-0}" shown start field_w
  field_w=$(( MD_AREA_W - reserve ))
  (( field_w > 0 )) || field_w=1
  shown="$buf"
  if (( ${#shown} > field_w - 1 )); then
    start=$(( ${#shown} - field_w + 2 ))
    shown="${shown[$start,-1]}"
  fi
  mux_dialog::at 2 $(( MD_INPUT_COL + 1 ))
  print -rn -- "${MD_INPUT_BG}$(mux_dialog::rep ' ' $(( MD_AREA_W + 1 )))"
  mux_dialog::at 2 $(( MD_INPUT_COL + 1 ))
  print -rn -- "${MD_INPUT_BG}${shown}${MD_ACCENT_BG}${MD_BOX_FG} ${MD_RESET}"
}
