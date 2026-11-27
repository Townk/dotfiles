#!/usr/bin/env zsh
# lib/dispatch.zsh — look a quick-launch target up and hand it to the
# backend's dispatcher (lib/dispatch-tmux.zsh, lib/dispatch-rex.zsh). Port of
# quicklaunch.wezterm's plugin/quick-launch/actions.lua.

# Look up a target by id. Echoes the element JSON or empty. Panes are
# searched everywhere they can be defined (top-level + nested in tabs and
# workspaces), so an `optional` pane declared inside a workspace is still
# launchable on its own; tabs/workspaces are matched at the top level.
# ql_on_rex — true when this run should drive Rex: a Rex pane (or a Rex Lua
# action, which exports the focused session) with no tmux in between. Spelled
# out here rather than read from mux::backend because the entry branches
# below are spelled the same way, and they must agree on precedence: an inner
# tmux started inside Rex wins.
ql_on_rex() {
  [[ -z "${TMUX:-}" && -n "${REX_SESSION:-}" ]]
}

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
    workspace)
      local el
      el="$(jq -c --arg id "$id" '.workspaces[]? | select(.id == $id)' <<<"$QL_JSON" | head -n1)"
      # AD-HOC session: the picker also offers LIVE sessions with no entry in
      # the targets file (before this they were visible in list-sessions but
      # unreachable from the picker). Their id IS the session name, so a
      # minimal {id, name} is everything the workspace path needs — it joins on
      # `name // id`, finds the session already running, and takes the
      # focus-or-switch branch. Deliberately no `icon`, so they render with the
      # same default a configured workspace without one gets.
      # Backend-aware, same test the dispatcher itself uses below. This runs
      # BEFORE the backend branch, so it cannot rely on it. Outside any mux
      # there is no live session to find.
      if [[ -z "$el" ]]; then
        local _live=1
        if [[ -n "${TMUX:-}" ]]; then
          ql_tx_session_exists "$id" || _live=0
        elif ql_on_rex; then
          ql_rx_session_exists "$id" || _live=0
        else
          _live=0
        fi
        (( _live )) && el="$(jq -nc --arg id "$id" '{id: $id, name: $id}')"
      fi
      print -r -- "$el"
      ;;
    *) return 1 ;;
  esac
}

# --- workspaces (sessions) -------------------------------------------------

# True when a workspace is a nested-mux target (`nested_mux: true`): a
# bar-less session whose sole job is to host another full multiplexer (e.g. a
# remote over SSH), so every key except the local picker chord passes through
# to the remote — see ql_tx_apply_nested.
ql_workspace_is_nested() {
  # nested_mux is the backend-neutral schema key (mux migration D14);
  # nested_zellij is read as its alias so existing definitions keep working.
  [[ "$(jq -r '.nested_mux // .nested_zellij // false' <<<"$1")" == true ]]
}

# Record a session name as nested so WezTerm (via nested-session-check) can tell
# nested sessions from normal ones and remap Cmd+Shift+P accordingly. Append-only
# and deduped; stale entries for dead sessions are harmless.
ql_register_nested() {
  local name="$1" reg="${XDG_CACHE_HOME:-$HOME/.cache}/quick-launch/nested-sessions"
  mkdir -p "${reg%/*}"
  grep -Fxq "$name" "$reg" 2>/dev/null || printf '%s\n' "$name" >>"$reg"
}

# --- entry -----------------------------------------------------------------

ql_dispatch() {
  local kind="$1" id="$2" el
  el="$(ql_get_element "$kind" "$id")"
  if [[ -z "$el" ]]; then
    echo "quick-launch: no $kind target with id '$id'" >&2
    return 1
  fi
  # Backend branch: a tmux session takes the ql_tx_* dispatcher
  # (lib/dispatch-tmux.zsh), a Rex pane the ql_rx_* one (lib/dispatch-rex.zsh).
  # The innermost mux wins, matching mux::backend.
  if [[ -n "${TMUX:-}" ]]; then
    ql_tx_dispatch_el "$kind" "$el"
    return
  fi
  if ql_on_rex; then
    ql_rx_dispatch_el "$kind" "$el"
    return
  fi
  echo "quick-launch: not inside tmux or Rex — nothing to open '$id' in" >&2
  return 1
}

# Dispatch a workspace into a separate OS window (the picker's Alt+Enter path).
ql_dispatch_window() {
  local id="$1" el
  el="$(ql_get_element workspace "$id")"
  if [[ -z "$el" ]]; then
    echo "quick-launch: no workspace target with id '$id'" >&2
    return 1
  fi
  if [[ -n "${TMUX:-}" ]]; then
    ql_tx_open_workspace_window "$el"
    return
  fi
  if ql_on_rex; then
    ql_rx_open_workspace_window "$el"
    return
  fi
  echo "quick-launch: not inside tmux or Rex — nothing to open '$id' in" >&2
  return 1
}
