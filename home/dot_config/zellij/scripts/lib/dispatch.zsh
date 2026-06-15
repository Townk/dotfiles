#!/usr/bin/env zsh
# lib/dispatch.zsh — focus-or-create a workspace / tab / pane via the zellij
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

# Open a pane. With a second arg ($session) the pane is created in that named
# session (used while populating a freshly created workspace) and the
# focus-or-create dedup is skipped — a new session always starts empty.
ql_open_pane() {
  local pane="$1" session="${2:-}"
  local name dir zdir action cwd cmd floating=false
  name="$(jq -r '.name // .id' <<<"$pane")"
  dir="$(jq -r '.direction // "down"' <<<"$pane" | tr '[:upper:]' '[:lower:]')"
  # `zellij action new-pane -d` only accepts right|down; up/left fall back to
  # the nearest supported axis. (Exact sizing/up/left fidelity is available
  # through tab/workspace layouts.)
  if ql_is_floating_direction "$dir"; then
    floating=true
    zdir=""
  else
    case "$dir" in
      up | down) zdir="down" ;;
      left | right) zdir="right" ;;
      *) zdir="down" ;;
    esac
  fi

  if [[ -z "$session" ]]; then
    local pid
    pid="$(ql_pane_id_by_name "$name")"
    if [[ -n "$pid" ]]; then
      "$ZJ" action focus-pane-id "$pid" && return 0
    fi
    if [[ -n "${ZELLIJ_MODAL_TARGET_PANE:-}" ]]; then
      "$ZJ" action focus-pane-id "$ZELLIJ_MODAL_TARGET_PANE" 2>/dev/null || true
    fi
  fi

  action="$(jq -c '.action // {}' <<<"$pane")"
  cwd="$(jq -r '.action.cwd // empty' <<<"$pane")"
  [[ -n "$cwd" ]] && cwd="$(ql_expand_tilde "$cwd")"
  cmd="$(ql_action_command "$action")"

  local cli=("$ZJ")
  [[ -n "$session" ]] && cli+=(--session "$session")
  cli+=(action new-pane --name "$name")
  if [[ "$floating" == true ]]; then
    local width height x y
    read -r width height x y < <(ql_float_geometry "$(jq -r '.size // "80%"' <<<"$pane")")
    cli+=(--floating --width "$width" --height "$height" --x "$x" --y "$y")
  else
    cli+=(-d "$zdir")
  fi
  [[ -n "$cwd" ]] && cli+=(--cwd "$cwd")
  [[ -n "$cmd" ]] && cli+=(--close-on-exit -- "$SHELL" -c "$cmd")
  "${cli[@]}"
}

# --- tabs ------------------------------------------------------------------

# Open a tab. With a second arg ($session) the tab is created in that named
# session (used while populating a freshly created workspace) and the
# focus-or-create dedup is skipped — a new session always starts empty.
ql_open_tab() {
  local tab="$1" session="${2:-}" name
  name="$(jq -r '.name // .id' <<<"$tab")"

  if [[ -z "$session" ]]; then
    if "$ZJ" action query-tab-names 2>/dev/null | grep -Fxq "$name"; then
      "$ZJ" action go-to-tab-name "$name"
      return 0
    fi
  fi

  # Non-optional panes (same selection the layout builder uses).
  local panes tiled_panes floating_panes count float_count
  panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$tab")"
  tiled_panes="$(jq -c '[ .[] | select((.direction // "" | ascii_downcase) as $d | ($d != "float" and $d != "floating")) ]' <<<"$panes")"
  floating_panes="$(jq -c '[ .[] | select((.direction // "" | ascii_downcase) as $d | ($d == "float" or $d == "floating")) ]' <<<"$panes")"
  count="$(jq 'length' <<<"$tiled_panes")"
  float_count="$(jq 'length' <<<"$floating_panes")"

  # The element whose action seeds the tab's initial pane: the first pane if
  # the tab declares panes, otherwise the tab's own action.
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

  # Create the tab WITHOUT a layout-string so it inherits the configured
  # new_tab_template — i.e. the zj-hud bar plus the floating which-key/search
  # plugin panes. The action runs as the tab's initial command inside that
  # template's pane (a Shell action has no command, so we get a plain shell).
  # A per-tab `--layout-string` does NOT render the bar reliably, so workspaces
  # build their tabs through this same plain-`new-tab` path.
  #
  # `--close-on-exit` makes a command tab behave like the WezTerm plugin: the
  # pane *is* the program, so when it exits (e.g. you quit the editor) the tab
  # closes instead of parking on a "press <Enter> to re-run" prompt. A Shell
  # action has no command, so the tab is a plain interactive shell that closes
  # only when the shell itself exits.
  local cli=("$ZJ")
  [[ -n "$session" ]] && cli+=(--session "$session")
  cli+=(action new-tab --name "$name")
  [[ -n "$cwd" ]] && cli+=(--cwd "$cwd")
  [[ -n "$cmd" ]] && cli+=(--close-on-exit -- "$SHELL" -c "$cmd")
  "${cli[@]}"

  # Multi-pane tab: split the remaining panes off inside the freshly created
  # tab (zj-hud is already present from the template above).
  if ((count > 1)); then
    local i p
    for ((i = 1; i < count; i++)); do
      p="$(jq -c ".[$i]" <<<"$tiled_panes")"
      ql_open_pane "$p" "$session"
    done
  fi
  if ((float_count > 0)); then
    local i p
    for ((i = 0; i < float_count; i++)); do
      p="$(jq -c ".[$i]" <<<"$floating_panes")"
      ql_open_pane "$p" "$session"
    done
  fi
}

# --- workspaces (sessions) -------------------------------------------------

ql_session_exists() {
  local id="$1"
  # `-ns` prints one clean session name per line (no formatting/markers), so
  # match the whole line — session names contain spaces (e.g. "Home MacMini M4
  # Pro"), which an `awk '{print $1}'` would truncate, breaking the dedup.
  "$ZJ" list-sessions -ns 2>/dev/null | grep -Fxq "$id"
}

# True when a workspace is a nested-Zellij target (`nested_zellij: true`): a
# bar-less session whose sole job is to host another full Zellij (e.g. a remote
# over SSH). These launch from a generated layout-with-config that runs in plain
# `normal` mode with `clear-defaults` keybinds, so every key except the local
# picker chord passes through to the remote — see ql_nested_layout_file.
ql_workspace_is_nested() {
  [[ "$(jq -r '.nested_zellij // false' <<<"$1")" == true ]]
}

# Generate (and cache) the layout-with-config file for a nested workspace, and
# echo its path. Regenerated on every launch — it's just jq+printf, and the
# launch.d definition may have changed since last time.
ql_nested_layout_file() {
  local ws="$1" id dir file
  id="$(jq -r '.id' <<<"$ws")"
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/quick-launch/layouts"
  file="$dir/${id}.kdl"
  mkdir -p "$dir"
  ql_build_nested_layout "$ws" "$HOME" >|"$file"
  printf '%s' "$file"
}

# Record a session name as nested so WezTerm (via nested-session-check) can tell
# nested sessions from normal ones and remap Cmd+Shift+P accordingly. Append-only
# and deduped; stale entries for dead sessions are harmless.
ql_register_nested() {
  local name="$1" reg="${XDG_CACHE_HOME:-$HOME/.cache}/quick-launch/nested-sessions"
  mkdir -p "${reg%/*}"
  grep -Fxq "$name" "$reg" 2>/dev/null || printf '%s\n' "$name" >>"$reg"
}

# Build a workspace's tabs into an already-created, client-attached session
# $sname, then drop the throwaway default tab. Honors `.tabs`, workspace-level
# `.panes` (appended to the first tab), and a bare workspace-level `.action`
# (its own tab) when there are no tabs/panes. Shared by the swap and new-window
# entry points. Attaching the client BEFORE this runs matters: tabs added with
# a client present render their bar (the proven standalone-tab behavior).
ql_workspace_build() {
  local ws="$1" sname="$2"
  local tabs ws_panes tcount created=0
  tabs="$(jq -c '.tabs // []' <<<"$ws")"
  # Workspace-level panes (appended to the first tab) also honor `optional`.
  ws_panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$ws")"
  tcount="$(jq 'length' <<<"$tabs")"

  if ((tcount == 0)); then
    # No tabs: seed workspace-level panes into a single tab if there are any;
    # else, if the workspace carries its own action (a bare Run/Remote/etc.
    # target like an SSH session), seed a single tab from that action; else
    # leave the session's lone default tab as the whole workspace.
    if [[ "$(jq 'length' <<<"$ws_panes")" -gt 0 ]]; then
      local synth
      synth="$(jq -c --argjson p "$ws_panes" '{name: (.name // .id), panes: $p}' <<<"$ws")"
      ql_open_tab "$synth" "$sname" && created=1
    elif [[ "$(jq -r 'has("action") and ((.action.type // "") != "")' <<<"$ws")" == true ]]; then
      local synth
      synth="$(jq -c '{name: (.name // .id), action: .action}' <<<"$ws")"
      ql_open_tab "$synth" "$sname" && created=1
    fi
  else
    local t tab
    for ((t = 0; t < tcount; t++)); do
      tab="$(jq -c ".[$t]" <<<"$tabs")"
      if ((t == 0)) && [[ "$(jq 'length' <<<"$ws_panes")" -gt 0 ]]; then
        tab="$(jq -c --argjson wsp "$ws_panes" '.panes = ((.panes // []) + $wsp)' <<<"$tab")"
      fi
      ql_open_tab "$tab" "$sname" && created=1
    done
  fi

  # Remove the throwaway default tab (stable id 0) once real tabs exist.
  if ((created)); then
    "$ZJ" --session "$sname" action close-tab-by-id 0 >/dev/null 2>&1 || true
  fi
}

# Open a workspace as its own session, switching the current client to it. We
# create the session detached with the full `default` layout — exactly like a
# normal session — then attach the client and build the workspace's tabs through
# the same plain-`new-tab` path standalone tabs use. No coupling to default.kdl.
#
# A nested_zellij workspace takes the short path: its whole layout (the command
# pane + the normal-mode clear-defaults passthrough keybinds) is generated up
# front, so the session is created from that file with no tab-build — which also
# avoids the throwaway login-shell tab that would flash the MOTD.
ql_open_workspace() {
  local ws="$1" sname win lf nested=false
  # The Zellij session name is the workspace `name` (falling back to `id`), per
  # the schema — `id` is only the dedup/CLI key. This is also the join key the
  # picker and the .zshrc boot session ("Main") use, so switching matches the
  # live session instead of spawning an id-named duplicate.
  sname="$(jq -r '.name // .id' <<<"$ws")"
  win="${SCRIPT_DIR:-${${(%):-%x}:A:h:h}}/quick-launch-window"
  ql_workspace_is_nested "$ws" && {
    nested=true
    ql_register_nested "$sname"
  }

  # Already running → if a separate OS window is currently attached to it,
  # bring that window forward rather than mirroring the session into this one.
  # `--focus` resolves the hosting window live from the session's client socket
  # and exits non-zero when no window is attached (or the terminal can't be
  # queried), so we fall through to switching the current client in place.
  if ql_session_exists "$sname"; then
    "$win" --focus "$sname" >/dev/null 2>&1 && return 0
    "$ZJ" action switch-session "$sname"
    return 0
  fi

  if [[ "$nested" == true ]]; then
    lf="$(ql_nested_layout_file "$ws")"
    if ! "$ZJ" attach -b "$sname" options --default-layout "$lf" </dev/null >/dev/null 2>&1; then
      echo "quick-launch: failed to create session '$sname'" >&2
      return 1
    fi
    "$ZJ" action switch-session "$sname"
    return 0
  fi

  # Create the session in the background with the default layout. `attach -b` is
  # synchronous (the session + its lone default tab exist when it returns);
  # `options --default-layout` pins the layout regardless of the configured
  # default_layout. stdin is closed so it can't block when launched from inside
  # an existing session (the quick-launch modal).
  if ! "$ZJ" attach -b "$sname" options --default-layout default </dev/null >/dev/null 2>&1; then
    echo "quick-launch: failed to create session '$sname'" >&2
    return 1
  fi

  # Pull the client in first, so tabs created below render with the bar. The
  # attach is asynchronous; give it a moment to land before we start adding
  # tabs, so each tab is built with the client present.
  "$ZJ" action switch-session "$sname"
  sleep 0.3
  ql_workspace_build "$ws" "$sname"
}

# Open a workspace in a SEPARATE OS terminal window (Ghostty/WezTerm) rather
# than switching the current client — so two workspaces can sit side by side.
# The new window becomes the session's client; we let it attach, then build the
# tabs from here (mirroring the swap path's ordering). A slow window start could
# occasionally need a redraw for a full-layout workspace.
#
# A nested_zellij workspace is fully self-contained: the new window runs a
# single `attach -c … options --default-layout <genfile>` that creates+attaches
# the session from its generated layout — no dispatcher pre-create, no remote
# tab-build, no sleep, and no MOTD-flashing default tab.
ql_open_workspace_window() {
  local ws="$1" sname win lf
  sname="$(jq -r '.name // .id' <<<"$ws")"
  win="${SCRIPT_DIR:-${${(%):-%x}:A:h:h}}/quick-launch-window"

  if ql_workspace_is_nested "$ws"; then
    ql_register_nested "$sname"
    # Existing → just attach in the new window. New → create+attach from the
    # generated layout (bar-less, normal-mode passthrough keybinds baked in).
    if ql_session_exists "$sname"; then
      "$win" "$sname" -- "$ZJ" attach "$sname"
    else
      lf="$(ql_nested_layout_file "$ws")"
      "$win" "$sname" -- "$ZJ" attach -c "$sname" options --default-layout "$lf"
    fi
    return $?
  fi

  # Already running → just open a window attached to it.
  if ql_session_exists "$sname"; then
    "$win" "$sname" -- "$ZJ" attach "$sname"
    return $?
  fi

  # Create detached with the default layout, then let the new window attach as
  # the client before we populate tabs.
  if ! "$ZJ" attach -b "$sname" options --default-layout default </dev/null >/dev/null 2>&1; then
    echo "quick-launch: failed to create session '$sname'" >&2
    return 1
  fi
  "$win" "$sname" -- "$ZJ" attach "$sname"
  sleep 0.5
  ql_workspace_build "$ws" "$sname"
}

# --- entry -----------------------------------------------------------------

ql_dispatch() {
  local kind="$1" id="$2" el
  el="$(ql_get_element "$kind" "$id")"
  if [[ -z "$el" ]]; then
    echo "quick-launch: no $kind target with id '$id'" >&2
    return 1
  fi
  case "$kind" in
    pane) ql_open_pane "$el" ;;
    tab) ql_open_tab "$el" ;;
    workspace) ql_open_workspace "$el" ;;
    *)
      echo "quick-launch: unknown kind '$kind'" >&2
      return 2
      ;;
  esac
}

# Dispatch a workspace into a separate OS window (the picker's Alt+Enter path).
ql_dispatch_window() {
  local id="$1" el
  el="$(ql_get_element workspace "$id")"
  if [[ -z "$el" ]]; then
    echo "quick-launch: no workspace target with id '$id'" >&2
    return 1
  fi
  ql_open_workspace_window "$el"
}
