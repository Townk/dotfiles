#!/usr/bin/env zsh
# lib/dispatch-tmux.zsh — tmux backend of the quick-launch dispatch (mux
# migration Phase 3, spec §7). Sourced beside dispatch.zsh; the entry points
# there branch to these ql_tx_* twins when the session is tmux. Shared logic
# (element lookup, action/prefix assembly, float geometry math, config merge)
# stays in command.zsh/dispatch.zsh — only the mux CLI surface forks.
#
# Mapping (spec Phase 3):
#   pane focus-or-create  → @ql_id pane option (zellij used pane titles)
#   tab  focus-or-create  → select-window -t "=name" ∥ new-window -n
#   workspace             → new-session -d + switch-client; the throwaway
#                           default tab problem disappears (the first tab IS
#                           the session's initial window)
#   float direction       → display-popup (modal — the accepted popup
#                           inversion; backgrounded so dispatch returns)
#   --close-on-exit       → tmux default (remain-on-exit off)
#   nested (D14)          → prefix None + key-table nested + status off on
#                           the session (bar-less, like zellij's layout)

QL_TX="${MUX_TMUX_BIN:-tmux}"

# Find a live pane whose @ql_id matches; echoes "%id" or empty.
ql_tx_pane_by_id() {
  local id="$1"
  "$QL_TX" list-panes -s -F '#{pane_id} #{@ql_id}' 2>/dev/null |
    awk -v id="$id" '$2 == id { print $1; exit }'
}

# Open a pane. With $2 (session) the pane is created there (workspace build)
# and dedup is skipped — a new session always starts empty.
ql_tx_open_pane() {
  local pane="$1" session="${2:-}"
  local id name dir cwd cmd action
  id="$(jq -r '.id' <<<"$pane")"
  name="$(jq -r '.name // .id' <<<"$pane")"
  dir="$(jq -r '.direction // "down"' <<<"$pane" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "$session" ]]; then
    local pid
    pid="$(ql_tx_pane_by_id "$id")"
    if [[ -n "$pid" ]]; then
      "$QL_TX" select-window -t "$pid" 2>/dev/null || true
      "$QL_TX" select-pane -t "$pid" && return 0
    fi
  fi

  action="$(jq -c '.action // {}' <<<"$pane")"
  cwd="$(jq -r '.action.cwd // empty' <<<"$pane")"
  [[ -n "$cwd" ]] && cwd="$(ql_expand_tilde "$cwd")"
  cmd="$(ql_action_command "$action")"

  # Parity: zellij's new-pane inherits the focused pane's cwd; tmux's
  # split-window/display-popup default to the session start dir, which broke
  # cwd-sensitive targets like the git-log pane (Mode B find, 2026-07-24).
  # display -p resolves the origin: the client's active pane from a popup,
  # $TMUX_PANE from a plain shell. Session builds keep the explicit-cwd-only
  # behavior (their targets define their own dirs).
  if [[ -z "$cwd" && -z "$session" ]]; then
    cwd="$("$QL_TX" display -p '#{pane_current_path}' 2>/dev/null)" || cwd=""
  fi

  if ql_is_floating_direction "$dir"; then
    # Floats are popups on tmux (modal — D7's accepted inversion). Centered
    # via the shared percent math; backgrounded so dispatch returns while the
    # popup lives. No @ql_id dedup possible on a popup — reopening is cheap.
    local width height x y
    read -r width height x y < <(ql_float_geometry "$(jq -r '.size // "80%"' <<<"$pane")")
    local -a popup=("$QL_TX" display-popup -E -w "$width" -h "$height")
    [[ -n "$cwd" ]] && popup+=(-d "$cwd")
    [[ -n "$session" ]] && popup+=(-t "$session:")
    popup+=("${cmd:-$SHELL}")
    # We usually run INSIDE the quick-launch popup: opening a popup while one
    # is up makes tmux MODIFY the existing popup and IGNORE -w/-h/-d (wrong
    # geometry AND wrong cwd), and a plain backgrounded child can die with
    # the popup's pty. Hand the spawn to the server, delayed past our own
    # close (Mode B find, 2026-07-24).
    "$QL_TX" run-shell -b -d 0.2 "${(j: :)${(@q)popup}}"
    return 0
  fi

  # Tiled: real directional splits — tmux has before-variants, so up/left keep
  # their meaning (the zellij CLI folds them to down/right).
  local -a split=("$QL_TX" split-window)
  case "$dir" in
    down) split+=(-v) ;;
    up) split+=(-vb) ;;
    right) split+=(-h) ;;
    left) split+=(-hb) ;;
    *) split+=(-v) ;;
  esac
  [[ -n "$session" ]] && split+=(-t "$session:")
  [[ -n "$cwd" ]] && split+=(-c "$cwd")
  # -P prints the new pane id so we can stamp @ql_id + the title without a
  # focus round-trip.
  local new_id
  if [[ -n "$cmd" ]]; then
    new_id="$("${split[@]}" -P -F '#{pane_id}' "$SHELL -c ${(q)cmd}")"
  else
    new_id="$("${split[@]}" -P -F '#{pane_id}')"
  fi
  [[ -n "$new_id" ]] && {
    "$QL_TX" set -p -t "$new_id" @ql_id "$id" 2>/dev/null || true
    "$QL_TX" select-pane -t "$new_id" -T "$name" 2>/dev/null || true
  }
}

# Open a tab (window). With $2 (session) it is created there; dedup skipped.
# $3 == "first" builds it as the session's INITIAL window (rename + respawn
# semantics via new-session already having created it — we just populate).
ql_tx_open_tab() {
  local tab="$1" session="${2:-}" name
  name="$(jq -r '.name // .id' <<<"$tab")"

  if [[ -z "$session" ]]; then
    if "$QL_TX" select-window -t "=$name" 2>/dev/null; then
      return 0
    fi
  fi

  local panes tiled_panes floating_panes count float_count
  panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$tab")"
  tiled_panes="$(jq -c '[ .[] | select((.direction // "" | ascii_downcase) as $d | ($d != "float" and $d != "floating")) ]' <<<"$panes")"
  floating_panes="$(jq -c '[ .[] | select((.direction // "" | ascii_downcase) as $d | ($d == "float" or $d == "floating")) ]' <<<"$panes")"
  count="$(jq 'length' <<<"$tiled_panes")"
  float_count="$(jq 'length' <<<"$floating_panes")"

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

  local -a nw=("$QL_TX" new-window -n "$name")
  [[ -n "$session" ]] && nw+=(-t "$session:")
  [[ -n "$cwd" ]] && nw+=(-c "$cwd")
  local first_pane
  if [[ -n "$cmd" ]]; then
    first_pane="$("${nw[@]}" -P -F '#{pane_id}' "$SHELL -c ${(q)cmd}")"
  else
    first_pane="$("${nw[@]}" -P -F '#{pane_id}')"
  fi
  [[ -n "$first_pane" ]] && {
    local pid0
    pid0="$(jq -r 'if '"$count"' > 0 then (.panes // [])[0].id // empty else empty end' <<<"$tab")"
    [[ -n "$pid0" ]] && "$QL_TX" set -p -t "$first_pane" @ql_id "$pid0" 2>/dev/null || true
  }

  local i p
  if ((count > 1)); then
    for ((i = 1; i < count; i++)); do
      p="$(jq -c ".[$i]" <<<"$tiled_panes")"
      ql_tx_open_pane "$p" "$session"
    done
  fi
  if ((float_count > 0)); then
    for ((i = 0; i < float_count; i++)); do
      p="$(jq -c ".[$i]" <<<"$floating_panes")"
      ql_tx_open_pane "$p" "$session"
    done
  fi
}

ql_tx_session_exists() {
  "$QL_TX" list-sessions -F '#{session_name}' 2>/dev/null | grep -Fxq "$1"
}

# Build a workspace's tabs into session $sname. Mirrors ql_workspace_build's
# jq shaping; differs structurally: tmux sessions start with ONE window that
# the FIRST tab renames/populates (no throwaway default tab to close).
ql_tx_workspace_build() {
  local ws="$1" sname="$2"
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
  # NB: `tab` is already local above — re-declaring it with `local` here
  # would make zsh's typeset PRINT its value (a real overnight gotcha).
  for tab in "${queue[@]}"; do
    ql_tx_open_tab "$tab" "$sname"
  done
  # Drop the session's initial placeholder window (index base) now that real
  # windows exist — the tmux twin of closing zellij's throwaway default tab.
  local base
  base="$("$QL_TX" show-options -gv base-index 2>/dev/null)" || base=0
  "$QL_TX" kill-window -t "$sname:${base:-0}" 2>/dev/null || true
}

# nested_mux (D14; old nested_zellij key read as alias — see
# ql_workspace_is_nested in dispatch.zsh): the outer tmux session gets
# prefix None + key-table nested, so every key except the nested-table
# escape hatches (C-M-Space and the MEH-s spellings → workspace picker)
# passes to the inner mux. `status off` makes it bar-less like zellij's
# generated nested layout: the inner mux is the only one drawing a bar.
ql_tx_apply_nested() {
  local sname="$1"
  "$QL_TX" set -t "$sname" prefix None
  "$QL_TX" set -t "$sname" key-table nested
  "$QL_TX" set -t "$sname" status off
}

ql_tx_open_workspace() {
  local ws="$1" sname nested=false
  sname="$(jq -r '.name // .id' <<<"$ws")"
  ql_workspace_is_nested "$ws" && {
    nested=true
    ql_register_nested "$sname"
  }

  if ql_tx_session_exists "$sname"; then
    "$QL_TX" switch-client -t "$sname"
    return 0
  fi

  local action cmd
  action="$(jq -c '.action // {}' <<<"$ws")"
  cmd="$(ql_action_command "$action")"

  if [[ "$nested" == true ]]; then
    if [[ -n "$cmd" ]]; then
      "$QL_TX" new-session -d -s "$sname" "$SHELL -c ${(q)cmd}"
    else
      "$QL_TX" new-session -d -s "$sname"
    fi
    ql_tx_apply_nested "$sname"
    "$QL_TX" switch-client -t "$sname"
    return 0
  fi

  "$QL_TX" new-session -d -s "$sname" || {
    echo "quick-launch: failed to create session '$sname'" >&2
    return 1
  }
  ql_tx_workspace_build "$ws" "$sname"
  "$QL_TX" switch-client -t "$sname"
}

# Separate OS window: reuse quick-launch-window's spawn half (the command
# after `--` is backend-provided; its zellij --focus fast-path is skipped —
# Phase 6 rewires it onto mux::client_sessions).
ql_tx_open_workspace_window() {
  local ws="$1" sname win action cmd tint
  local -a tint_args=()
  sname="$(jq -r '.name // .id' <<<"$ws")"
  tint="$(jq -r '.color // empty' <<<"$ws")"
  [[ -n "$tint" ]] && tint_args=(--tint "$tint")
  win="${SCRIPT_DIR:-${${(%):-%x}:A:h:h}}/quick-launch-window"

  if ql_workspace_is_nested "$ws"; then
    ql_register_nested "$sname"
    action="$(jq -c '.action // {}' <<<"$ws")"
    cmd="$(ql_action_command "$action")"
    [[ -n "$cmd" ]] || {
      echo "quick-launch: nested workspace '$sname' has no command" >&2
      return 1
    }
    # The window's tint is classified from the command it runs, and `attach`
    # hides the ssh destination behind it — so resolve the color from the REAL
    # command here unless the workspace names one. In a subshell because the
    # lib sets `set -u` for whatever scope sources it; `|| tint=""` because a
    # non-ssh command is a legitimate answer (no tint) and the caller runs
    # under `set -e`.
    if [[ -z "$tint" ]]; then
      tint="$({ source "${${(%):-%x}:A:h}/terminal-location.zsh"; tl_classify_command "$cmd"; } 2>/dev/null)" || tint=""
      [[ -n "$tint" ]] && tint_args=(--tint "$tint")
    fi
    # An outer session, not the bare command. Running the ssh directly leaves
    # the window with no local mux at all, and the workspace picker is then
    # unreachable from it on either terminal — the migration lost this, since
    # zellij's window path always attached to the bar-less nested layout.
    ql_tx_session_exists "$sname" || {
      "$QL_TX" new-session -d -s "$sname" "$SHELL -c ${(q)cmd}" || {
        echo "quick-launch: failed to create session '$sname'" >&2
        return 1
      }
      ql_tx_apply_nested "$sname"
    }
    "$win" "${tint_args[@]}" "$sname" -- "$QL_TX" attach -t "$sname"
    return $?
  fi

  if ql_tx_session_exists "$sname"; then
    "$win" "$sname" -- "$QL_TX" attach -t "$sname"
    return $?
  fi

  "$QL_TX" new-session -d -s "$sname" || {
    echo "quick-launch: failed to create session '$sname'" >&2
    return 1
  }
  ql_tx_workspace_build "$ws" "$sname"
  ql_workspace_is_nested "$ws" && ql_tx_apply_nested "$sname"
  "$win" "$sname" -- "$QL_TX" attach -t "$sname"
}

ql_tx_dispatch_el() {
  local kind="$1" el="$2"
  case "$kind" in
    pane) ql_tx_open_pane "$el" ;;
    tab) ql_tx_open_tab "$el" ;;
    workspace) ql_tx_open_workspace "$el" ;;
    *) return 2 ;;
  esac
}
