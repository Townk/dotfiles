#!/usr/bin/env bash
# lib/dispatch.sh — focus-or-create a workspace / tab / pane via the zellij
# CLI. Port of quicklaunch.wezterm's plugin/quick-launch/actions.lua.

# Absolute zellij binary (the modal scripts use the same default + override).
ZJ="${ZELLIJ_BIN:-/opt/homebrew/bin/zellij}"

# Look up a target by id. Echoes the element JSON or empty. Panes are
# searched everywhere they can be defined (top-level + nested in tabs and
# workspaces), so an `optional` pane declared inside a workspace is still
# launchable on its own; tabs/workspaces are matched at the top level.
ql_get_element() {
  local kind="$1" id="$2"
  case "$kind" in
    pane)
      jq -c --arg id "$id" '
        [ .panes[]?, (.tabs[]?.panes[]?), (.workspaces[]?.panes[]?), (.workspaces[]?.tabs[]?.panes[]?) ]
        | map(select(.id == $id)) | .[0] // empty
      ' <<<"$QL_JSON"
      ;;
    tab) jq -c --arg id "$id" '.tabs[]? | select(.id == $id)' <<<"$QL_JSON" | head -n1 ;;
    workspace) jq -c --arg id "$id" '.workspaces[]? | select(.id == $id)' <<<"$QL_JSON" | head -n1 ;;
    *) return 1 ;;
  esac
}

# --- panes -----------------------------------------------------------------

# Find a live terminal pane whose title matches $1 and echo its pane id
# (terminal_N). `list-panes` prints "PANE_ID  TYPE  TITLE" (header row first,
# columns separated by 2+ spaces); we set each pane's title to its `name`
# when creating it, so the title is our dedup key. If nothing matches we just
# create a new pane (no dedup) — acceptable.
ql_pane_id_by_name() {
  local name="$1"
  "$ZJ" action list-panes 2>/dev/null | awk -F'  +' -v n="$name" '
    NR == 1 { next }
    $2 == "terminal" && $3 == n { print $1; exit }
  '
}

ql_open_pane() {
  local pane="$1"
  local name dir zdir action cwd cmd
  name="$(jq -r '.name // .id' <<<"$pane")"
  dir="$(jq -r '.direction // "down"' <<<"$pane" | tr '[:upper:]' '[:lower:]')"
  # `zellij action new-pane -d` only accepts right|down; up/left fall back to
  # the nearest supported axis. (Exact sizing/up/left fidelity is available
  # through tab/workspace layouts.)
  case "$dir" in
    up | down) zdir="down" ;;
    left | right) zdir="right" ;;
    *) zdir="down" ;;
  esac

  local pid
  pid="$(ql_pane_id_by_name "$name")"
  if [[ -n "$pid" ]]; then
    "$ZJ" action focus-pane-id "$pid" && return 0
  fi

  action="$(jq -c '.action // {}' <<<"$pane")"
  cwd="$(jq -r '.action.cwd // empty' <<<"$pane")"
  [[ -n "$cwd" ]] && cwd="$(ql_expand_tilde "$cwd")"
  cmd="$(ql_action_command "$action")"

  local cli=("$ZJ" action new-pane -d "$zdir" --name "$name")
  [[ -n "$cwd" ]] && cli+=(--cwd "$cwd")
  if [[ -n "$cmd" ]]; then
    cli+=(-- sh -c "$cmd")
  fi
  "${cli[@]}"
}

# --- tabs ------------------------------------------------------------------

ql_open_tab() {
  local tab="$1" name
  name="$(jq -r '.name // .id' <<<"$tab")"

  if "$ZJ" action query-tab-names 2>/dev/null | grep -Fxq "$name"; then
    "$ZJ" action go-to-tab-name "$name"
    return 0
  fi

  # Non-optional panes (same selection the layout builder uses).
  local panes count
  panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$tab")"
  count="$(jq 'length' <<<"$panes")"

  # The element whose action seeds the tab's initial pane: the first pane if
  # the tab declares panes, otherwise the tab's own action.
  local primary action cwd cmd
  if (( count > 0 )); then
    primary="$(jq -c '.[0]' <<<"$panes")"
  else
    primary="$(jq -c '{action: (.action // {}), name: (.name // .id)}' <<<"$tab")"
  fi
  action="$(jq -c '.action // {}' <<<"$primary")"
  cwd="$(jq -r '.action.cwd // empty' <<<"$primary")"
  [[ -n "$cwd" ]] && cwd="$(ql_expand_tilde "$cwd")"
  cmd="$(ql_action_command "$action")"

  # Create the tab WITHOUT a layout-string so it inherits the configured
  # new_tab_template — i.e. the zj-hud bar plus the floating which-key/search
  # plugin panes. The action runs as the tab's initial command inside that
  # template's pane (a Shell action has no command, so we get a plain shell).
  #
  # `--close-on-exit` makes a command tab behave like the WezTerm plugin: the
  # pane *is* the program, so when it exits (e.g. you quit the editor) the tab
  # closes instead of parking on a "press <Enter> to re-run" prompt. A Shell
  # action has no command, so the tab is a plain interactive shell that closes
  # only when the shell itself exits.
  local cli=("$ZJ" action new-tab --name "$name")
  [[ -n "$cwd" ]] && cli+=(--cwd "$cwd")
  [[ -n "$cmd" ]] && cli+=(--close-on-exit -- sh -c "$cmd")
  "${cli[@]}"

  # Multi-pane tab: split the remaining panes off inside the freshly created
  # tab (zj-hud is already present from the template above).
  if (( count > 1 )); then
    local i p
    for (( i = 1; i < count; i++ )); do
      p="$(jq -c ".[$i]" <<<"$panes")"
      ql_open_pane "$p"
    done
  fi
}

# --- workspaces (sessions) -------------------------------------------------

ql_workspace_cwd() {
  local ws="$1" c
  c="$(jq -r '(.tabs[0].panes[0].action.cwd) // (.panes[0].action.cwd) // (.tabs[0].action.cwd) // empty' <<<"$ws")"
  [[ -n "$c" ]] && ql_expand_tilde "$c"
}

ql_session_exists() {
  local id="$1"
  "$ZJ" list-sessions -ns 2>/dev/null | awk '{print $1}' | grep -Fxq "$id"
}

ql_open_workspace() {
  local ws="$1" id cwd kdl
  id="$(jq -r '.id' <<<"$ws")"

  if ql_session_exists "$id"; then
    "$ZJ" action switch-session "$id"
    return 0
  fi

  cwd="$(ql_workspace_cwd "$ws")"
  kdl="$(ql_build_workspace_layout "$ws")"
  local cli=("$ZJ" action switch-session "$id" --layout-string "$kdl")
  [[ -n "$cwd" ]] && cli+=(--cwd "$cwd")
  "${cli[@]}"
}

# --- external commands ------------------------------------------------------

ql_open_external() {
  local el="$1" action
  action="$(jq -c '.action // {}' <<<"$el")"

  local args
  ql_read_args args "$action"
  if (( ${#args[@]} == 0 )); then
    echo "quick-launch: External action has no command args" >&2
    return 1
  fi
  args[0]="$(ql_expand_tilde "${args[0]}")"
  "${args[@]}"
}

# --- entry -----------------------------------------------------------------

ql_dispatch() {
  local kind="$1" id="$2" el
  el="$(ql_get_element "$kind" "$id")"
  if [[ -z "$el" ]]; then
    echo "quick-launch: no $kind target with id '$id'" >&2
    return 1
  fi
  if [[ "$(jq -r '.action.type // empty' <<<"$el")" == "External" ]]; then
    ql_open_external "$el"
    return
  fi
  case "$kind" in
    pane) ql_open_pane "$el" ;;
    tab) ql_open_tab "$el" ;;
    workspace) ql_open_workspace "$el" ;;
    *) echo "quick-launch: unknown kind '$kind'" >&2; return 2 ;;
  esac
}
