#!/usr/bin/env zsh
# stack.zsh — THE mux mode stack (migration Phase 5).
#
# The stack is the single source of truth. tmux's key table, the pane's
# copy-mode and the which-key popup are DERIVED VIEWS of it, never sources:
# every actor (the panel, the search dialog, the generated key bindings)
# performs one of the operations below and then `sync` makes the world match.
# Before this existed the stack was inferred from a static parent map plus
# tmux's single key-table value, and three programs each kept their own idea
# of "where does Backspace go" — which is why pops needed pressing twice and
# visibility leaked between modes.
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
#
# The copy-mode family (scroll/copy/search) is one tmux mode wearing three
# faces, so entering and leaving those entries carries the tmux side with it
# (@visual, the cursor, clearing a search). That teardown used to live in
# THREE places — copy-mode-vi's Backspace, mux-search's @search_parent and
# the panel — and they disagreed.

MUX_TMUX_BIN="${MUX_TMUX_BIN:-tmux}"
source "${MUX_LIB_DIR:-$HOME/.local/lib}/mux/mode.zsh"
MUX_WK="${MUX_WK:-$HOME/.config/mux/scripts/mux-whichkey}"
MUX_CURSOR="${MUX_CURSOR:-$HOME/.config/mux/scripts/mux-scroll-cursor}"

# MS_FRESH: this process just WROTE the stack, so the copy in memory is the
# truth and sync need not read it back — one fewer round-trip on the keypress
# path. Operations are serialized by the keypress that triggered them.
mux_stack::_get() {
  [[ "${MS_FRESH:-0}" == 1 ]] && return 0
  local raw; raw="$("$MUX_TMUX_BIN" show -gv @mux_stack 2>/dev/null)" || raw=""
  MS_ENTRIES=(${(s: :)raw})
}
mux_stack::_put() {
  "$MUX_TMUX_BIN" set -g @mux_stack "${(j: :)MS_ENTRIES}" 2>/dev/null
  MS_FRESH=1
}
mux_stack::top() {
  mux_stack::_get
  if (( ${#MS_ENTRIES} == 0 )); then MS_STATE="" MS_VIS=0; return 1; fi
  local e="${MS_ENTRIES[-1]}"
  MS_STATE="${e%%:*}" MS_VIS="${e##*:}"
  return 0
}

# one #cfg field of the generated panel data (start_hidden lives there)
mux_stack::_cfg() {
  local key="$1" data="${WK_DATA:-$HOME/.config/mux/whichkey.data}" line kv
  line="$(grep -m1 '^#cfg' "$data" 2>/dev/null)" || return 1
  for kv in ${(ps:\t:)line}; do
    [[ "$kv" == "$key="* ]] && { print -r -- "${kv#*=}"; return 0 }
  done
  return 1
}

# Is a panel driver alive and holding the popup? @mux_wk_driver carries the
# driver's PID, not a flag: a driver killed with its popup (or a server that
# outlived one) would otherwise leave a claim nobody ever releases and no
# panel would open again.
mux_stack::driver_live() {
  local d
  d="$("$MUX_TMUX_BIN" show -gv @mux_wk_driver 2>/dev/null)" || return 1
  [[ "$d" == <1-> ]] || return 1
  kill -0 "$d" 2>/dev/null
}

# ---- the copy-mode family --------------------------------------------------
# Every tmux call is a process spawn plus a socket round-trip (~20ms), and a
# transition runs on a keypress — so the pane and its mode are read ONCE per
# operation and writes ride in batched command lists.
mux_stack::_is_copy() { [[ "$1" == scroll || "$1" == copy || "$1" == search ]] }
mux_stack::_probe() {                # -> MS_PANE MS_INCOPY (cached per call)
  [[ -n "${MS_PANE:-}" ]] && return 0
  local r; r="$("$MUX_TMUX_BIN" display -p '#{pane_id}|#{?pane_in_mode,1,0}' 2>/dev/null)"
  MS_PANE="${r%%|*}" MS_INCOPY="${r##*|}"
  [[ "$MS_INCOPY" == 1 ]] || MS_INCOPY=0
  return 0
}
mux_stack::_pane()    { mux_stack::_probe; print -rn -- "$MS_PANE" }
mux_stack::_in_copy() { mux_stack::_probe; [[ "$MS_INCOPY" == 1 ]] }
# The copy-mode cursor is the REAL terminal cursor — one script owns its
# visibility/shape and reads the state back off tmux (idempotent), but it
# costs a shell and a jq, so it never rides on the keypress path: the server
# runs it. The pane-mode-changed hook covers entering and leaving copy-mode;
# this covers the face changes INSIDE it, which fire no hook.
mux_stack::_cursor() {
  mux_stack::_probe
  [[ -n "$MS_PANE" ]] || return 0
  "$MUX_TMUX_BIN" run-shell -b "'$MUX_CURSOR' '$MS_PANE'" 2>/dev/null
  return 0
}
mux_stack::_visual() {
  mux_stack::_probe
  [[ -n "$MS_PANE" ]] && "$MUX_TMUX_BIN" set -p -t "$MS_PANE" @visual "$1" 2>/dev/null
  return 0
}
# tmux 3.7 has no search-cancel and even an empty search-forward keeps the old
# term, so a Search entry is cleared by exiting and re-entering copy-mode and
# restoring the viewport from #{scroll_position} (ledger row).
mux_stack::_clear_search() {
  local p pos
  mux_stack::_probe; p="$MS_PANE"; [[ -n "$p" ]] || return 0
  pos="$("$MUX_TMUX_BIN" display -p -t "$p" '#{scroll_position}' 2>/dev/null)"
  [[ "$pos" == <-> ]] || pos=0
  "$MUX_TMUX_BIN" set -p -t "$p" -u @search_term ';' \
                  set -p -t "$p" -u @searching ';' \
                  send-keys -t "$p" -X cancel ';' \
                  copy-mode -t "$p" 2>/dev/null
  (( pos > 0 )) && "$MUX_TMUX_BIN" send-keys -t "$p" -X -N "$pos" scroll-up 2>/dev/null
  return 0
}

# What tmux must do because <state> just landed on the stack. Only the
# copy-mode family has one: every other state is nothing but its key table.
mux_stack::_enter() {
  local state="$1" v=""
  mux_stack::_is_copy "$state" || return 0
  mux_stack::_probe
  [[ -n "$MS_PANE" ]] || return 0
  case "$state" in
    scroll) v=0 ;;
    copy)   v=1 ;;
  esac
  if (( MS_INCOPY )); then
    # already in copy-mode: only the face changes, and no hook fires for that
    [[ -n "$v" ]] && mux_stack::_visual "$v"
    mux_stack::_cursor
  else
    # entering: one trip, and the pane-mode-changed hook paints the cursor
    if [[ -n "$v" ]]; then
      "$MUX_TMUX_BIN" set -p -t "$MS_PANE" @visual "$v" ';' \
                      copy-mode -t "$MS_PANE" 2>/dev/null
    else
      "$MUX_TMUX_BIN" copy-mode -t "$MS_PANE" 2>/dev/null
    fi
    MS_INCOPY=1
  fi
}

# …and because <state> just left it, with <new> now on top. Leaving the LAST
# copy state leaves copy-mode; between copy states only the face changes.
mux_stack::_leave() {
  local state="$1" new="$2" p
  mux_stack::_is_copy "$state" || return 0
  [[ "$state" == search ]] && mux_stack::_clear_search
  mux_stack::_probe; p="$MS_PANE"
  [[ -n "$p" ]] || return 0
  if mux_stack::_is_copy "$new"; then
    [[ "$new" == copy ]] && mux_stack::_visual 1 || mux_stack::_visual 0
    mux_stack::_cursor        # a face change inside copy-mode fires no hook
  else
    "$MUX_TMUX_BIN" send-keys -t "$p" -X cancel ';' \
                    set -p -t "$p" -u @visual ';' \
                    set -p -t "$p" -u @searching ';' \
                    set -p -t "$p" -u @search_term ';' \
                    set -p -t "$p" -u @search_idx ';' \
                    set -p -t "$p" -u wrap-search ';' \
                    set -p -t "$p" -u copy-mode-current-match-style 2>/dev/null
    MS_INCOPY=0               # leaving copy-mode fires the hook: it paints
  fi
}

# ---- the operations --------------------------------------------------------
# A mutator is mid-flight: the pane-mode-changed hook fires on every step of a
# transition (clearing a search cancels copy-mode and re-enters it), and
# reconcile must not read a half-applied world.
mux_stack::_busy() { "$MUX_TMUX_BIN" set -g @mux_stack_busy "$1" 2>/dev/null; return 0 }

mux_stack::push() {
  local state="$1" vis sh
  [[ -n "$state" ]] || return 1
  mux_stack::_busy 1
  mux_stack::_get
  # Pushing the state you are already standing in is a re-entry, not a level:
  # editing a live search reopens the dialog on the same Search entry, and the
  # leader chord in Command re-arms Command. A second entry would cost an
  # extra Backspace to get out of.
  if (( ${#MS_ENTRIES} )) && [[ "${MS_ENTRIES[-1]%%:*}" == "$state" ]]; then
    mux_stack::_enter "$state"
    mux_stack::sync
    mux_stack::_busy 0
    return 0
  fi
  # A pushed mode inherits the panel you already had up; a start_hidden state
  # (zellij's `start_hidden "scroll"`) starts down regardless.
  vis=1
  (( ${#MS_ENTRIES} )) && vis="${MS_ENTRIES[-1]##*:}"
  for sh in ${(s:,:)$(mux_stack::_cfg start_hidden)}; do
    [[ -n "$sh" && "$sh" == "$state" ]] && vis=0
  done
  MS_ENTRIES+=("${state}:${vis}")
  mux_stack::_put
  mux_stack::_enter "$state"
  mux_stack::sync
  mux_stack::_busy 0
}

mux_stack::pop() {
  local old new
  mux_stack::_busy 1
  mux_stack::_get
  if (( ${#MS_ENTRIES} == 0 )); then
    # copy-mode can be entered without the stack (a hook, the app itself) —
    # Backspace must not strand the user in it
    mux_stack::_in_copy && mux_stack::_leave scroll ""
    mux_stack::sync
    mux_stack::_busy 0
    return 0
  fi
  old="${MS_ENTRIES[-1]%%:*}"
  MS_ENTRIES=("${MS_ENTRIES[@]:0:$(( ${#MS_ENTRIES} - 1 ))}")
  mux_stack::_put
  new=""
  (( ${#MS_ENTRIES} )) && new="${MS_ENTRIES[-1]%%:*}"
  mux_stack::_leave "$old" "$new"
  mux_stack::sync
  mux_stack::_busy 0
}

mux_stack::clear() {
  local old=""
  mux_stack::_busy 1
  mux_stack::_get
  (( ${#MS_ENTRIES} )) && old="${MS_ENTRIES[-1]%%:*}"
  # nothing on the stack but the pane is in copy-mode (a hook, the app
  # itself): Escape still has to end it, same as Backspace does
  [[ -z "$old" ]] && mux_stack::_in_copy && old=scroll
  MS_ENTRIES=()
  mux_stack::_put
  mux_stack::_leave "$old" ""
  mux_stack::sync
  mux_stack::_busy 0
}

mux_stack::set_visible() {
  local v="${1:-1}"
  mux_stack::_get
  (( ${#MS_ENTRIES} )) || return 0
  MS_ENTRIES[-1]="${MS_ENTRIES[-1]%%:*}:${v}"
  mux_stack::_put
  mux_stack::sync
}

# The world moved without us: copy-mode can END on its own (y's
# copy-pipe-and-cancel, tmux's own q, a mouse scroll out of the buffer), and
# the copy entries would linger — the next M-. would raise a panel for a mode
# nobody is in. The pane-mode-changed hook calls this; it only ever DROPS the
# copy states (they are always the top of the stack), never runs their leave
# actions, which would put the pane back into copy-mode.
mux_stack::reconcile() {
  local e changed=0
  local -a keep
  [[ "$("$MUX_TMUX_BIN" show -gv @mux_stack_busy 2>/dev/null)" == 1 ]] && return 0
  mux_stack::_in_copy && return 0
  # Past that guard the pane is NOT in copy-mode, so its copy-mode flags are
  # stale whatever the stack says — and they must be cleared BEFORE the
  # no-entries early return below. A mouse selection (drag, double-click)
  # enters copy-mode without ever pushing an entry, so that return fires and
  # used to leave @visual set behind: the next Scroll entry then read as Copy,
  # which is exactly the drift this clearing exists to prevent.
  mux_stack::_probe
  [[ -n "$MS_PANE" ]] && \
    "$MUX_TMUX_BIN" set -p -t "$MS_PANE" -u @visual ';' \
                    set -p -t "$MS_PANE" -u @searching ';' \
                    set -p -t "$MS_PANE" -u @search_term 2>/dev/null
  mux_stack::_get
  keep=()
  for e in $MS_ENTRIES; do
    mux_stack::_is_copy "${e%%:*}" && { changed=1; break }
    keep+=("$e")
  done
  (( changed )) || return 0
  MS_ENTRIES=("${keep[@]}")
  mux_stack::_put
  mux_stack::sync
}

# ---- the one place that touches the world ----------------------------------
# Arm the key table the top entry declares (keymap.yaml `key_table`), then
# make the popup match that entry's visibility.
mux_stack::sync() {
  local kt="" table="" vis=0 client driver
  local -a ct
  if mux_stack::top && mux_mode::meta "$MS_STATE" 2>/dev/null; then
    kt="$MM_KEYTABLE" table="$MM_TABLE" vis="$MS_VIS"
  fi
  # The client is named EXPLICITLY below: sync runs from run-shell
  # (client-less) and from inside a popup (no pane of its own), and
  # switch-client without a target fails with "no current client" in both.
  #
  # $MUX_CLIENT is the client that pressed the key, handed down by the
  # binding — `#{client_tty}` DOES expand in a run-shell, backgrounded or
  # not (measured 2026-07-28; an older comment here claimed otherwise). It
  # matters as soon as a second terminal attaches: the fallback below takes
  # whichever client list-clients returns first, so pressing the leader in
  # WezTerm opened the panel in the Ghostty window and the key table was
  # armed for the wrong client.
  local cd
  if [[ "${MUX_CLIENT:-}" == /dev/* ]]; then
    client="$MUX_CLIENT"
    MS_DRIVER="$("$MUX_TMUX_BIN" show -gv @mux_wk_driver 2>/dev/null)"
  else
    # Its tty and the driver claim come back in one trip — user options are
    # format variables too.
    cd="$("$MUX_TMUX_BIN" list-clients -F '#{client_tty}|#{@mux_wk_driver}' 2>/dev/null | head -1)"
    client="${cd%%|*}" MS_DRIVER="${cd##*|}"
  fi
  ct=(); [[ -n "$client" ]] && ct=(-c "$client")
  if [[ "$kt" == prefix ]]; then
    # the leader is tmux's ONE-SHOT prefix table, armed per client
    "$MUX_TMUX_BIN" set key-table root ';' \
                    switch-client "${ct[@]}" -T prefix 2>/dev/null
  else
    "$MUX_TMUX_BIN" set key-table "${kt:-root}" 2>/dev/null
  fi

  # Inside the panel a popup is already up and it is the driver's to own: a
  # popup opened over a popup silently mutates the outer one, and a popup
  # cannot resize itself. The driver re-reads the stack when the panel exits.
  [[ -z "${MUX_STACK_INPANEL:-}" ]] || return 0
  [[ -n "$client" ]] || return 0
  driver=0
  [[ "$MS_DRIVER" == <1-> ]] && kill -0 "$MS_DRIVER" 2>/dev/null && driver=1
  if [[ "$vis" == 1 && -n "$table" ]]; then
    # Hand the launch to the SERVER (run-shell -b): a forked child would keep
    # the calling run-shell's pipe open for as long as the panel is up, and a
    # run-shell that triggered sync then never returned (Mode B find).
    (( driver )) || \
      "$MUX_TMUX_BIN" run-shell -b "'$MUX_WK' open '$client'" 2>/dev/null
  else
    (( driver )) && "$MUX_TMUX_BIN" display-popup -C 2>/dev/null
  fi
  return 0
}
