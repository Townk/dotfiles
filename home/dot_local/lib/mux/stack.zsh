#!/usr/bin/env zsh
# stack.zsh — THE mux mode stack (migration Phase 5).
#
# The stack is the single source of truth. tmux's key table and the which-key
# popup are DERIVED VIEWS of it, never sources: every actor (the panel, the
# search dialog, the generated key bindings) performs one of the operations
# below and then `sync` makes the world match. Before this existed the stack
# was inferred from a static parent map plus tmux's single key-table value,
# and three programs each kept their own idea of "where does Backspace go" —
# which is why pops needed pressing twice and visibility leaked between modes.
#
#   @mux_stack = "command:1 scroll:1 search:1"   state:visible, bottom→top
#
#   mux_stack::push <state>      push (inherits the parent's visibility
#                                unless the state is start_hidden)
#   mux_stack::pop               pop the top entry (its visibility dies with it)
#   mux_stack::clear             empty the stack
#   mux_stack::set_visible 0|1   set the TOP entry's visibility
#   mux_stack::top               → MS_STATE / MS_VIS
#   mux_stack::sync              arm the key table + match the popup
#
# Every mutator ends in sync, so callers never touch key tables or popups.

MUX_TMUX_BIN="${MUX_TMUX_BIN:-tmux}"
source "${MUX_LIB_DIR:-$HOME/.local/lib}/mux/mode.zsh"
MUX_WK="${MUX_WK:-$HOME/.config/mux/scripts/mux-whichkey}"

mux_stack::_get() {
  local raw; raw="$("$MUX_TMUX_BIN" show -gv @mux_stack 2>/dev/null)" || raw=""
  MS_ENTRIES=(${(s: :)raw})
}
mux_stack::_put() {
  "$MUX_TMUX_BIN" set -g @mux_stack "${(j: :)MS_ENTRIES}" 2>/dev/null
}
mux_stack::top() {
  mux_stack::_get
  if (( ${#MS_ENTRIES} == 0 )); then MS_STATE="" MS_VIS=0; return 1; fi
  local e="${MS_ENTRIES[-1]}"
  MS_STATE="${e%%:*}" MS_VIS="${e##*:}"
  return 0
}

# start_hidden states come from the generated panel data (keymap.yaml).
mux_stack::_start_hidden() {
  local data="${WK_DATA:-$HOME/.config/mux/whichkey.data}" line kv
  line="$(grep -m1 '^#cfg' "$data" 2>/dev/null)" || return 1
  for kv in ${(ps:\t:)line}; do
    [[ "$kv" == start_hidden=* ]] && { print -r -- "${kv#*=}"; return 0 }
  done
  return 1
}

mux_stack::push() {
  local state="$1" vis parent_vis sh
  [[ -n "$state" ]] || return 1
  mux_stack::_get
  parent_vis=1
  (( ${#MS_ENTRIES} )) && parent_vis="${MS_ENTRIES[-1]##*:}"
  # A pushed mode inherits the panel you already had up; a start_hidden state
  # (zellij's `start_hidden "scroll"`) starts down regardless.
  vis="$parent_vis"
  for sh in ${(s:,:)$(mux_stack::_start_hidden)}; do
    [[ -n "$sh" && "$sh" == "$state" ]] && vis=0
  done
  MS_ENTRIES+=("${state}:${vis}")
  mux_stack::_put
  mux_stack::sync
}

mux_stack::pop() {
  mux_stack::_get
  (( ${#MS_ENTRIES} )) || { mux_stack::sync; return 0 }
  MS_ENTRIES=("${MS_ENTRIES[@]:0:$(( ${#MS_ENTRIES} - 1 ))}")
  mux_stack::_put
  mux_stack::sync
}

mux_stack::clear() {
  MS_ENTRIES=()
  mux_stack::_put
  mux_stack::sync
}

mux_stack::set_visible() {
  local v="${1:-1}"
  mux_stack::_get
  (( ${#MS_ENTRIES} )) || return 0
  MS_ENTRIES[-1]="${MS_ENTRIES[-1]%%:*}:${v}"
  mux_stack::_put
  mux_stack::sync
}

# The one place that touches the world: arm the key table the top entry
# implies, then make the popup match that entry's visibility.
mux_stack::sync() {
  local client
  client="$("$MUX_TMUX_BIN" list-clients -F '#{client_tty}' 2>/dev/null | head -1)"
  if ! mux_stack::top; then
    "$MUX_TMUX_BIN" set key-table root 2>/dev/null
    "$MUX_TMUX_BIN" display-popup -C 2>/dev/null
    return 0
  fi
  case "$MS_STATE" in
    command) "$MUX_TMUX_BIN" set key-table root 2>/dev/null
             "$MUX_TMUX_BIN" switch-client -T prefix 2>/dev/null ;;
    tab|pane|session|resize|move|locked|nested)
             "$MUX_TMUX_BIN" set key-table "$MS_STATE" 2>/dev/null ;;
    *)       "$MUX_TMUX_BIN" set key-table root 2>/dev/null ;;   # copy-mode states
  esac
  if [[ "$MS_VIS" == 1 ]] && mux_mode::meta "$MS_STATE" 2>/dev/null && [[ -n "$MM_TABLE" ]]; then
    "$MUX_WK" open "$MS_STATE" "$client" >/dev/null 2>&1 &
  else
    "$MUX_TMUX_BIN" display-popup -C 2>/dev/null
  fi
  return 0
}
