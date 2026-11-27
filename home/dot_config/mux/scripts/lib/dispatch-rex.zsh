#!/usr/bin/env zsh
# dispatch-rex.zsh — the quick-launch Rex backend: the twin of
# dispatch-tmux.zsh, same shape and the same function order, so the two files
# diff cleanly.
#
# Sourced by quick-launch after dispatch.zsh. Needs command.zsh, which brings
# in mux-bootstrap.zsh and with it the `_mux_rx_*` helpers this file is built
# on (the rex CLI wrapper that never autostarts a server, and the floating
# layer builder with its cell→fraction geometry).
#
# How Rex differs from the tmux twin:
#
#   * Identity is a LABEL. A workspace is a Rex session labelled with the
#     workspace's name, a tab is a window labelled with the tab's name, a pane
#     is a block labelled with the pane's name. Rex has no per-pane user option
#     to stamp an id into (tmux: @ql_id), and a label has the advantage of
#     being what the user sees in the pane header.
#   * Nothing here can move the CLIENT. Focusing a block or a window is a
#     session-level change the app follows, but bringing the app to another
#     session is a client action (`session.select`), and this script runs
#     from `rex.exec`, which has no client. So opening a workspace PRINTS
#     `@select:<session-id>` on stdout and the Lua action that called us
#     queues the switch.
#   * The same goes for TABS, which was not obvious: `rex window new` and
#     `rex window focus` make a window the session's active one on the
#     server, and the app's tab selection does not follow (found in the
#     first live session — a new tab opened behind the one in view). So tab
#     and pane opens print `@select:<session-id> <window-id>` as well.
#   * And for the focused PANE. A split made with --focus moves the focus on
#     the server, yet the app stayed on the pane it was in (second finding
#     of that session; the palette closing puts the app's focus back where
#     it was). There is no client action that focuses a block by id, only
#     by direction — so an interactive pane open splits WITHOUT taking
#     focus and prints `@focus:<direction>`: the new pane is, by
#     construction, the neighbour in that direction of the pane the app is
#     still on, and the Lua action queues `pane.focus` that way.
#   * That trick only reaches a NEW TILED pane. A floating pane, and a pane
#     that is already open, have no direction to name. What does work
#     (third finding, measured with a key sent to the app's focused pane):
#     the app DOES follow a server-side focus change — just not one made
#     while the palette is closing. So with $QL_DEFER_FOCUS set (the Lua
#     action sets it) these two cases take no focus now and print
#     `@focus-block:<block-id>`; the action starts a detached
#     `quick-launch focus-later`, which focuses the block a moment after
#     the palette is gone. Without the variable — `quick-launch open` typed
#     in a shell, no palette — they focus at once.
#   * A command runs through an INTERACTIVE shell (`--interactive`). Rex
#     otherwise gives a command the login environment only, and a tmux pane
#     has always had everything ~/.zshrc exports — EDITOR, the fzf and theme
#     variables, the mise session. Targets were written against that.
#   * There is no nested_mux, no tint and no separate-window launcher: Rex is
#     the terminal, so a `Remote` workspace is simply a session whose pane
#     runs ssh, and its keys are not in competition with ours.
#
# $REX_SESSION / $REX_BLOCK say where "here" is. The Lua action passes the
# FOCUSED session and block in those two variables — the server's own
# environment, which is what `rex.exec` would otherwise hand down, knows
# nothing about focus.

# ql_rx_session_id <label> — the id of the session with that exact label,
# empty when there is none.
ql_rx_session_id() {
  _mux_rx_run ls --json 2>/dev/null |
    jq -r --arg l "$1" '[.sessions[]? | select(.label == $l) | .session_id] | first // empty'
}

# ql_rx_block_by_label <session> <label> — first block of that label in the
# session (tmux twin: ql_tx_pane_by_id, session-wide for the same reason — a
# session-scoped target's pane counts as open wherever it sits).
ql_rx_block_by_label() {
  _mux_rx_run block ls -s "$1" --json 2>/dev/null |
    jq -r --arg l "$2" '[.blocks[]? | select(.label == $l) | .block_id] | first // empty'
}

# ql_rx_first_block <json> — the first block id in a creation result. `rex
# new`, `rex window new` and `rex run` each nest it differently.
ql_rx_first_block() {
  jq -r '[.. | .block_id? // empty, (.block_ids? // [])[]] | first // empty' <<<"$1"
}

# ql_rx_show <session> <window> — tell the caller which window the app
# should be looking at. See the header: only a client action can move it.
ql_rx_show() {
  [[ -n "${1:-}" && -n "${2:-}" ]] && print -r -- "@select:$1 $2"
  return 0
}

# ql_rx_window_of <session> <block> — the window a block sits in.
ql_rx_window_of() {
  _mux_rx_view "$1" | jq -r --arg b "$2" '
    [.windows[]? | select([.layers[]?.blocks[]?.block_id] | index($b)) | .window_id] | first // empty'
}

# ql_rx_argv <cmd> — sets `reply` to the argv that runs a quick-launch
# command line, or to nothing for an interactive shell. The line is a shell
# string (ql_action_command joins with `&&`, prefixes `cd …;`), so it needs a
# shell; Rex already runs a block's command inside the login environment.
# `--interactive` rides in front of the `--`: it is a flag of the rex
# command the argv is appended to, and it only means something with a
# command (a bare shell block is interactive already).
ql_rx_argv() {
  reply=()
  [[ -n "${1:-}" ]] && reply=(--interactive -- "${SHELL:-/bin/zsh}" -c "$1")
  return 0
}

# ql_rx_float_size <size> — "<w> <h>" from the pane's `size` field: `80%`,
# `80% x 60%`, `100x30`. One value applies to both axes. Percentages keep
# their `%`; bare numbers are cells — exactly what _mux_rx_layer accepts.
ql_rx_float_size() {
  local size w h
  size="$(ql_trim "${1:-80%}")"
  if [[ "$size" =~ ^(.+)[[:space:]]*[xX][[:space:]]*(.+)$ ]]; then
    w="$(ql_trim "${match[1]}")"
    h="$(ql_trim "${match[2]}")"
  else
    w="$size" h="$size"
  fi
  [[ "$w" == <-> || "$w" == <->% ]] || w=80%
  [[ "$h" == <-> || "$h" == <->% ]] || h=80%
  print -r -- "$w $h"
}

# ql_rx_open_pane <pane-json> [session] [anchor-block]
# With no session: FOCUS the pane if a block of its name is already open in
# our session, else split it off the focused block. With a session: always
# create (workspace/tab construction), splitting off <anchor-block>.
# Sets QL_RX_LAST_BLOCK to the block created, so a caller building a chain
# can split the next pane off this one.
ql_rx_open_pane() {
  local pane="$1" session="${2:-}" anchor="${3:-}"
  local name dir cwd cmd action building=1
  name="$(jq -r '.name // .id' <<<"$pane")"
  dir="$(jq -r '.direction // "down"' <<<"$pane" | tr '[:upper:]' '[:lower:]')"
  QL_RX_LAST_BLOCK=""

  if [[ -z "$session" ]]; then
    building=0
    session="${REX_SESSION:-}"
    [[ -n "$session" ]] || { echo "quick-launch: not in a Rex session" >&2; return 1; }
    anchor="${REX_BLOCK:-}"
    local existing
    existing="$(ql_rx_block_by_label "$session" "$name")"
    if [[ -n "$existing" ]]; then
      # The pane may live in another tab of this session.
      ql_rx_show "$session" "$(ql_rx_window_of "$session" "$existing")"
      if [[ -n "${QL_DEFER_FOCUS:-}" ]]; then
        print -r -- "@focus-block:$existing"
        return 0
      fi
      _mux_rx_run focus -s "$session" "$existing" >/dev/null 2>&1 && return 0
    fi
  fi

  action="$(jq -c '.action // {}' <<<"$pane")"
  cwd="$(jq -r '.action.cwd // empty' <<<"$pane")"
  [[ -n "$cwd" ]] && cwd="$(ql_expand_tilde "$cwd")"
  cmd="$(ql_action_command "$action")"
  # No cwd on an interactive open: inherit the focused pane's directory.
  # Session construction leaves it unset so the pane lands in the default.
  if [[ -z "$cwd" ]] && (( ! building )) && [[ -n "$anchor" ]]; then
    cwd="$(REX_SESSION="$session" REX_BLOCK="$anchor" _mux_rx_pane_cwd 2>/dev/null)" || cwd=""
  fi

  local -a reply
  ql_rx_argv "$cmd"

  if ql_is_floating_direction "$dir"; then
    local w h
    read -r w h < <(ql_rx_float_size "$(jq -r '.size // "80%"' <<<"$pane")")
    # _mux_rx_layer builds the block itself, so the interactive shell is
    # asked for by variable and the CLI flag is dropped from the argv.
    local defer=0
    (( ! building )) && [[ -n "${QL_DEFER_FOCUS:-}" ]] && defer=1
    QL_RX_LAST_BLOCK="$(REX_SESSION="$session" REX_BLOCK="$anchor" _MUX_RX_LAYER_INTERACTIVE=1 \
      _MUX_RX_LAYER_FOCUS=$(( ! defer )) \
      _mux_rx_layer "$w" "$h" "$name" "$cwd" "$session" "${(@)reply:#--interactive}")"
    [[ -n "$QL_RX_LAST_BLOCK" ]] || return 1
    (( defer )) && print -r -- "@focus-block:$QL_RX_LAST_BLOCK"
    return 0
  fi

  local -a flags=(-s "$session" --label "$name" --json)
  [[ -n "$anchor" ]] && flags+=(-b "$anchor")
  local focus_dir=down
  case "$dir" in
    up) flags+=(--split=above); focus_dir=up ;;
    right) flags+=(--split=right); focus_dir=right ;;
    left) flags+=(--split=left); focus_dir=left ;;
    *) flags+=(--split=below) ;;
  esac
  # Opened on request: leave the focus where the app has it and let the
  # caller move it (see the header). While building, focus is irrelevant.
  (( building )) || flags+=(--focus=false)
  local size
  size="$(jq -r '.size // empty' <<<"$pane")"
  [[ "$size" == <->% ]] && flags+=(--ratio "${size%\%}")
  [[ -n "$cwd" ]] && flags+=(-c "$cwd")

  local out
  if ((${#reply})); then
    out="$(_mux_rx_run run "${flags[@]}" "${reply[@]}" 2>/dev/null)" || return 1
  else
    out="$(_mux_rx_run split "${flags[@]}" 2>/dev/null)" || return 1
  fi
  QL_RX_LAST_BLOCK="$(ql_rx_first_block "$out")"
  [[ -n "$QL_RX_LAST_BLOCK" ]] || return 1
  (( building )) || print -r -- "@focus:$focus_dir"
  return 0
}

# ql_rx_open_tab <tab-json> [session]
# With no session: focus the window of that label in our session, else build
# it there. With a session: always build (workspace construction).
ql_rx_open_tab() {
  local tab="$1" session="${2:-}" name
  name="$(jq -r '.name // .id' <<<"$tab")"

  if [[ -z "$session" ]]; then
    session="${REX_SESSION:-}"
    [[ -n "$session" ]] || { echo "quick-launch: not in a Rex session" >&2; return 1; }
    local existing
    existing="$(_mux_rx_view "$session" |
      jq -r --arg n "$name" '[.windows[]? | select(.label == $n) | .window_id] | first // empty')"
    if [[ -n "$existing" ]]; then
      if _mux_rx_run window focus -s "$session" "$existing" >/dev/null 2>&1; then
        ql_rx_show "$session" "$existing"
        return 0
      fi
    fi
    local interactive=1
  fi

  # Same split as the tmux twin: tiled panes form the chain, floats are laid
  # over the finished tab, optional panes are never auto-opened.
  local panes tiled_panes floating_panes count float_count
  panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$tab")"
  tiled_panes="$(jq -c '[ .[] | select((.direction // "" | ascii_downcase) as $d | ($d != "float" and $d != "floating")) ]' <<<"$panes")"
  floating_panes="$(jq -c '[ .[] | select((.direction // "" | ascii_downcase) as $d | ($d == "float" or $d == "floating")) ]' <<<"$panes")"
  count="$(jq 'length' <<<"$tiled_panes")"
  float_count="$(jq 'length' <<<"$floating_panes")"

  # The window's first block: tiled pane 0, or the tab's own action.
  local primary action cwd cmd
  if ((count > 0)); then
    primary="$(jq -c '.[0]' <<<"$tiled_panes")"
  else
    primary="$(jq -c '{action: (.action // {}), name: (.name // .id)}' <<<"$tab")"
  fi
  action="$(jq -c '.action // {}' <<<"$primary")"
  cwd="$(jq -r '.action.cwd // empty' <<<"$primary")"
  [[ -n "$cwd" ]] && cwd="$(ql_expand_tilde "$cwd")"
  cmd="$(ql_action_command "$action")"

  local -a reply flags=(-s "$session" --json)
  [[ -n "$cwd" ]] && flags+=(-c "$cwd")
  ql_rx_argv "$cmd"
  local out first
  out="$(_mux_rx_run window new "${flags[@]}" "$name" "${reply[@]}" 2>/dev/null)" || {
    echo "quick-launch: failed to create tab '$name'" >&2
    return 1
  }
  first="$(ql_rx_first_block "$out")"
  [[ -n "$first" ]] || return 1
  local new_window
  new_window="$(jq -r '[.. | .window_id? // empty] | first // empty' <<<"$out")"
  # Label the first block as its pane, so a later pane-open focuses it
  # instead of opening a duplicate (tmux twin: the @ql_id stamp).
  if ((count > 0)); then
    _mux_rx_run block rename -s "$session" "$first" \
      "$(jq -r '.name // .id' <<<"$primary")" >/dev/null 2>&1 || true
  fi

  # The chain: each tiled pane splits off the one before it.
  local i p prev="$first"
  for ((i = 1; i < count; i++)); do
    p="$(jq -c ".[$i]" <<<"$tiled_panes")"
    ql_rx_open_pane "$p" "$session" "$prev" && prev="$QL_RX_LAST_BLOCK"
  done
  for ((i = 0; i < float_count; i++)); do
    p="$(jq -c ".[$i]" <<<"$floating_panes")"
    ql_rx_open_pane "$p" "$session" "$first" || true
  done
  # Opened on request (not as part of building a workspace): show it.
  (( ${interactive:-0} )) && ql_rx_show "$session" "$new_window"
  return 0
}

ql_rx_session_exists() {
  [[ -n "$(ql_rx_session_id "$1")" ]]
}

# ql_rx_workspace_build <ws-json> <session-id> <placeholder-window-id>
# Populate a freshly created session. Same queue rules as the tmux twin; the
# placeholder is the window Rex made with the session, closed once the real
# tabs exist (tmux: kill the base-index window).
ql_rx_workspace_build() {
  local ws="$1" sid="$2" placeholder="$3"
  local tabs ws_panes tcount
  tabs="$(jq -c '.tabs // []' <<<"$ws")"
  ws_panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$ws")"
  tcount="$(jq 'length' <<<"$tabs")"

  local -a queue=()
  if ((tcount == 0)); then
    if [[ "$(jq 'length' <<<"$ws_panes")" -gt 0 ]]; then
      queue+=("$(jq -c --argjson p "$ws_panes" '{name: (.name // .id), panes: $p}' <<<"$ws")")
    elif [[ "$(jq -r 'has("action") and ((.action.type // "") != "")' <<<"$ws")" == true ]]; then
      queue+=("$(jq -c '{name: (.name // .id), action: .action}' <<<"$ws")")
    fi
  else
    local t tab
    for ((t = 0; t < tcount; t++)); do
      tab="$(jq -c ".[$t]" <<<"$tabs")"
      if ((t == 0)) && [[ "$(jq 'length' <<<"$ws_panes")" -gt 0 ]]; then
        tab="$(jq -c --argjson wsp "$ws_panes" '.panes = ((.panes // []) + $wsp)' <<<"$tab")"
      fi
      queue+=("$tab")
    done
  fi

  ((${#queue[@]})) || return 0
  local built=0
  for tab in "${queue[@]}"; do
    ql_rx_open_tab "$tab" "$sid" && ((built++))
  done
  # Only drop the placeholder once something replaced it — closing a
  # session's last window would close the session.
  ((built)) && [[ -n "$placeholder" ]] &&
    _mux_rx_run window close -s "$sid" "$placeholder" >/dev/null 2>&1
  # Land on the first tab, not the last one built.
  ((built)) && _mux_rx_run window focus -s "$sid" 1 >/dev/null 2>&1
  return 0
}

# ql_rx_open_workspace <ws-json> — switch to the session of that name, or
# create and populate it first. Prints the `@select:` directive either way.
ql_rx_open_workspace() {
  local ws="$1" sname sid
  sname="$(jq -r '.name // .id' <<<"$ws")"

  sid="$(ql_rx_session_id "$sname")"
  if [[ -n "$sid" ]]; then
    print -r -- "@select:$sid"
    return 0
  fi

  local out placeholder
  out="$(_mux_rx_run new "$sname" --json 2>/dev/null)" || {
    echo "quick-launch: failed to create session '$sname'" >&2
    return 1
  }
  sid="$(jq -r '.session_id // empty' <<<"$out")"
  placeholder="$(jq -r '.initial_windows[0].window_id // empty' <<<"$out")"
  [[ -n "$sid" ]] || return 1

  ql_rx_workspace_build "$ws" "$sid" "$placeholder"
  print -r -- "@select:$sid"
}

# A workspace in its own OS window is a client-side move this script cannot
# make; refuse rather than open it in place and call that success.
ql_rx_open_workspace_window() {
  echo "quick-launch: opening a workspace in a separate window is not supported on Rex yet" >&2
  return 1
}

# ql_rx_focus_later <block> [seconds] — focus a block after a short wait.
# Run DETACHED by the Lua picker action: by the time it fires the palette has
# finished closing, and a focus change made then is one the app follows.
ql_rx_focus_later() {
  local block="$1" delay="${2:-0.3}"
  [[ -n "$block" && -n "${REX_SESSION:-}" ]] || return 1
  sleep "$delay"
  _mux_rx_run focus -s "$REX_SESSION" "$block" >/dev/null 2>&1
}

ql_rx_dispatch_el() {
  local kind="$1" el="$2"
  case "$kind" in
    pane) ql_rx_open_pane "$el" ;;
    tab) ql_rx_open_tab "$el" ;;
    workspace) ql_rx_open_workspace "$el" ;;
    *) return 2 ;;
  esac
}
