#!/usr/bin/env zsh
# mode.zsh — THE mux mode resolver (migration Phase 5).
#
# One answer to "which mode am I in, and what does it look like", shared by
# every consumer: the status bar's mode pill, the which-key panel, and the
# panel's M-. toggle. Before this existed each had its own copy and they
# drifted — the toggle read only #{client_key_table}, which copy-mode never
# changes, so M-. in Scroll opened the Command panel (Mode B find).
#
# States, their titles/icons/colors and the panel table backing each one are
# generated from .chezmoidata/keymap.yaml into whichkey.data (#state rows),
# so the bar and the panel cannot disagree about any of them.
#
#   mux_mode::resolve <key_table> <in_copy> <visual> <searching> <search> [prefix_armed]
#     → MM_STATE MM_TITLE MM_ICON MM_COLOR MM_TABLE ; returns 1 when resting
#   mux_mode::meta <state>  → the same fields (+ MM_PARENT, the breadcrumb
#                             chain the panel walks, and MM_KEYTABLE, the
#                             tmux key table the state arms) for a known state

MUX_MODE_DATA="${WK_DATA:-$HOME/.config/mux/whichkey.data}"

mux_mode::meta() {
  local l
  l="$(awk -F'\t' -v s="$1" '$1=="#state" && $2==s {print; exit}' "$MUX_MODE_DATA" 2>/dev/null)"
  [[ -n "$l" ]] || return 1
  local -a f; f=("${(@ps:\t:)l}")
  MM_STATE="$1" MM_TITLE="${f[3]}" MM_ICON="${f[4]}" MM_COLOR="${f[5]}"
  MM_TABLE="${f[6]:-}" MM_PARENT="${f[7]:-}" MM_KEYTABLE="${f[8]:-}"
  return 0
}

mux_mode::resolve() {
  local table="${1:-root}" in_copy="${2:-0}" visual="${3:-0}"
  local searching="${4:-0}" search="${5:-0}" armed="${6:-0}"
  local state=""
  if [[ "$in_copy" == 1 ]]; then
    # copy-mode is one tmux mode wearing three faces; the pane options
    # (@searching / @visual) say which.
    if [[ "$searching" == 1 || "$search" == 1 ]]; then state=search
    elif [[ "$visual" == 1 ]]; then state=copy
    else state=scroll
    fi
  else
    case "$table" in
      prefix) state=command ;;
      tab|pane|session|resize|move|locked|nested) state="$table" ;;
      *) [[ "$armed" == 1 ]] && state=command ;;
    esac
  fi
  [[ -n "$state" ]] || return 1        # resting (root / normal): no mode
  mux_mode::meta "$state"
}
