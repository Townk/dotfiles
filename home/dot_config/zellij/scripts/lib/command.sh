#!/usr/bin/env bash
# lib/command.sh — turn a target's `action` into a runnable shell command,
# and turn a list of panes into a Zellij KDL layout string.
#
# Port of quicklaunch.wezterm's plugin/quick-launch/utils.lua
# (cmd_prefix + make_spawn_command + the split/layout logic).

# Read a JSON array's `.args[]` into a bash array named by $1 (nameref-free
# so it works on bash 3.2: we assign to the caller's variable via printf).
# Usage: ql_read_args ARRVAR "$action_json"
ql_read_args() {
  local __name="$1" __json="$2" __line
  eval "$__name=()"
  while IFS= read -r __line; do
    eval "$__name+=(\"\$__line\")"
  done < <(jq -r '.args[]?' <<<"$__json")
}

# Join the remaining args with $1 as the separator. Safe with zero args.
ql_join() {
  local sep="$1"
  shift || true
  local out="" first=1 a
  for a in "$@"; do
    if (( first )); then
      out="$a"
      first=0
    else
      out+="$sep$a"
    fi
  done
  printf '%s' "$out"
}

# Build the command prefix: `cd <cwd>; <python_venv>; <mise_env>; `.
# Order matches the spec (cd, then venv, then mise) so both environments are
# live for the actual command.
ql_cmd_prefix() {
  local action="$1"
  local prefix="" cwd venv mise_env mise_bin
  cwd="$(jq -r '.cwd // empty' <<<"$action")"
  if [[ -n "$cwd" ]]; then
    prefix="cd $(ql_expand_tilde "$cwd"); "
  fi

  venv="$(jq -r '.python_venv // empty' <<<"$action")"
  if [[ -n "$venv" ]]; then
    if [[ "$venv" == "auto" ]]; then
      # Same precedence chain as the Lua plugin: first activate script wins.
      prefix+='[ -f .venv/bin/activate ] && source .venv/bin/activate || [ -f venv/bin/activate ] && source venv/bin/activate || [ -f .env/bin/activate ] && source .env/bin/activate; '
    else
      prefix+="source $venv; "
    fi
  fi

  mise_env="$(jq -r '.mise_env // empty' <<<"$action")"
  if [[ -n "$mise_env" ]]; then
    mise_bin="$(ql_mise)"
    if [[ -n "$mise_bin" ]]; then
      if [[ "$mise_env" == "auto" ]]; then
        prefix+="eval \"\$($mise_bin env)\"; "
      else
        prefix+="eval \"\$($mise_bin env --config $mise_env)\"; "
      fi
    fi
  fi
  printf '%s' "$prefix"
}

# Build the full shell command string for an action. Echoes empty for a
# `Shell` action (the pane is just an interactive shell; cwd is applied on
# the pane itself). Port of make_spawn_command's per-type branches.
ql_action_command() {
  local action="$1" type
  type="$(jq -r '.type // "Shell"' <<<"$action")"

  if [[ "$type" == "Shell" ]]; then
    printf ''
    return
  fi

  local prefix
  prefix="$(ql_cmd_prefix "$action")"
  local args
  ql_read_args args "$action"

  case "$type" in
    Edit)
      local editor cwd
      editor="$(ql_editor)"
      cwd="$(jq -r '.cwd // empty' <<<"$action")"
      local files=() f abs
      if (( ${#args[@]} > 0 )); then
        for f in "${args[@]}"; do
          case "$f" in
            /* | "~"* | \\*) abs="$f" ;;
            *) if [[ -n "$cwd" ]]; then abs="$(ql_expand_tilde "$cwd")/$f"; else abs="$f"; fi ;;
          esac
          files+=("$abs")
        done
      fi
      if (( ${#files[@]} > 0 )); then
        printf '%s%s %s' "$prefix" "$editor" "${files[*]}"
      else
        printf '%s%s' "$prefix" "$editor"
      fi
      ;;
    Remote)
      # Note: matches the Lua plugin — Remote does NOT get the cd/venv/mise
      # prefix, it is just `ssh <args>`.
      if (( ${#args[@]} > 0 )); then
        printf 'ssh %s' "$(ql_join ' ' "${args[@]}")"
      else
        echo "quick-launch: Remote action has no host args" >&2
        printf ''
      fi
      ;;
    Run)
      if (( ${#args[@]} > 0 )); then
        printf '%s%s' "$prefix" "$(ql_join ' && ' "${args[@]}")"
      else
        echo "quick-launch: Run action has no args" >&2
        printf '%s' "$prefix"
      fi
      ;;
    *)
      echo "quick-launch: unknown action type '$type'" >&2
      printf ''
      ;;
  esac
}

# Escape a string for use inside a KDL double-quoted value.
ql_kdl_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

ql_is_floating_direction() {
  local dir="$1"
  dir="$(printf '%s' "$dir" | tr '[:upper:]' '[:lower:]')"
  [[ "$dir" == "float" || "$dir" == "floating" ]]
}

ql_terminal_size() {
  local zj="${ZELLIJ_BIN:-/opt/homebrew/bin/zellij}" tab_id size
  if [[ -x "$zj" ]]; then
    tab_id="$("$zj" action list-tabs -s 2>/dev/null | awk -F'  +' 'NR > 1 && $4 == "true" { print $1; exit }')" || tab_id=""
    size="$(
      "$zj" action list-panes -a 2>/dev/null | awk -F'  +' -v tab="$tab_id" '
        NR == 1 { next }
        tab != "" && $1 != tab { next }
        $5 != "terminal" || $10 != "false" || $11 != "false" { next }
        { right = $12 + $15; bottom = $13 + $14 }
        right > cols { cols = right }
        bottom > rows { rows = bottom }
        END { if (cols > 0 && rows > 0) print cols, rows }
      '
    )" || size=""
    if [[ -n "$size" ]]; then
      printf '%s\n' "$size"
      return
    fi
  fi
  { stty size </dev/tty 2>/dev/null || printf '24 80\n'; } | awk '{ print $2, $1 }'
}

ql_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

ql_float_axis_geometry() {
  local value="$1" total="$2" span pos pct
  if [[ "$value" == *% ]]; then
    pct="${value%?}"
    if [[ "$pct" =~ ^[0-9]+$ ]]; then
      span="$pct%"
      pos="$(( (100 - pct) / 2 ))%"
    fi
  elif [[ "$value" =~ ^[0-9]+$ ]]; then
    span="$value"
    pos=$(( (total - value) / 2 ))
    (( pos < 0 )) && pos=0
  fi

  if [[ -z "${span:-}" ]]; then
    span="80%"
    pos="10%"
  fi
  printf '%s %s\n' "$span" "$pos"
}

ql_float_geometry() {
  local size width_spec height_spec width height x y cols rows
  size="$(ql_trim "${1:-80%}")"
  if [[ "$size" =~ ^(.+)[[:space:]]*[xX][[:space:]]*(.+)$ ]]; then
    width_spec="$(ql_trim "${BASH_REMATCH[1]}")"
    height_spec="$(ql_trim "${BASH_REMATCH[2]}")"
  else
    width_spec="$size"
    height_spec="$size"
  fi

  read -r cols rows < <(ql_terminal_size)
  read -r width x < <(ql_float_axis_geometry "$width_spec" "$cols")
  read -r height y < <(ql_float_axis_geometry "$height_spec" "$rows")
  printf '%s %s %s %s\n' "$width" "$height" "$x" "$y"
}

ql_kdl_value() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    printf '%s' "$v"
  else
    printf '"%s"' "$(ql_kdl_escape "$v")"
  fi
}

ql_float_kdl_attrs() {
  local width height x y
  read -r width height x y < <(ql_float_geometry "$1")
  printf ' floating=true width=%s height=%s x=%s y=%s' \
    "$(ql_kdl_value "$width")" \
    "$(ql_kdl_value "$height")" \
    "$(ql_kdl_value "$x")" \
    "$(ql_kdl_value "$y")"
}

# Emit a single leaf `pane` KDL node for a pane JSON object.
# Args: pane_json, indent, size(optional)
ql_pane_leaf() {
  local pane="$1" indent="$2" size="${3:-}"
  local action name cwd cmd sizeattr nameattr cwdattr floatattr dir
  action="$(jq -c '.action // {}' <<<"$pane")"
  name="$(jq -r '.name // .id // empty' <<<"$pane")"
  dir="$(jq -r '.direction // empty' <<<"$pane")"
  cwd="$(jq -r '.action.cwd // empty' <<<"$pane")"
  [[ -n "$cwd" ]] && cwd="$(ql_expand_tilde "$cwd")"
  cmd="$(ql_action_command "$action")"

  if ql_is_floating_direction "$dir"; then
    floatattr="$(ql_float_kdl_attrs "$(jq -r '.size // "80%"' <<<"$pane")")"
    sizeattr=""
  else
    [[ -n "$size" ]] && sizeattr=" size=\"$size\"" || sizeattr=""
    floatattr=""
  fi
  [[ -n "$name" ]] && nameattr=" name=\"$(ql_kdl_escape "$name")\"" || nameattr=""
  [[ -n "$cwd" ]] && cwdattr=" cwd=\"$(ql_kdl_escape "$cwd")\"" || cwdattr=""

  if [[ -z "$cmd" ]]; then
    printf '%spane%s%s%s%s\n' "$indent" "$nameattr" "$cwdattr" "$sizeattr" "$floatattr"
  else
    # close_on_exit mirrors the standalone-tab path (`new-tab --close-on-exit`):
    # the pane *is* the program, so when it exits (e.g. you quit the editor) the
    # tab closes instead of parking on a "press <Enter> to re-run" prompt. The
    # bar + floating plugin panes from default_tab_template don't keep the tab
    # alive once the command pane is gone.
    printf '%spane command="/bin/bash" close_on_exit=true%s%s%s%s {\n' "$indent" "$nameattr" "$cwdattr" "$sizeattr" "$floatattr"
    printf '%s    args "-c" "%s"\n' "$indent" "$(ql_kdl_escape "$cmd")"
    printf '%s}\n' "$indent"
  fi
}

# Recursively emit a right-leaning nested pane tree from a flat pane array,
# mirroring the Lua split_all_panes chain: pane[0] is the tab's initial
# pane, pane[i+1] splits off pane[i] in its `direction` taking its `size`.
# Args: panes_json(array), index, indent, size(applied to this subtree root)
ql_pane_tree() {
  local panes="$1" i="$2" indent="$3" size="${4:-}"
  local n cur
  n="$(jq 'length' <<<"$panes")"
  cur="$(jq -c ".[$i]" <<<"$panes")"

  if (( i == n - 1 )); then
    ql_pane_leaf "$cur" "$indent" "$size"
    return
  fi

  local nxt dir sd nsize sizeattr
  nxt="$(jq -c ".[$((i + 1))]" <<<"$panes")"
  dir="$(jq -r '.direction // "down"' <<<"$nxt" | tr '[:upper:]' '[:lower:]')"
  case "$dir" in
    up | down) sd="horizontal" ;;
    *) sd="vertical" ;;
  esac
  nsize="$(jq -r '.size // empty' <<<"$nxt")"
  [[ -n "$size" ]] && sizeattr=" size=\"$size\"" || sizeattr=""

  printf '%spane split_direction="%s"%s {\n' "$indent" "$sd" "$sizeattr"
  if [[ "$dir" == "down" || "$dir" == "right" ]]; then
    ql_pane_leaf "$cur" "$indent    " ""
    ql_pane_tree "$panes" "$((i + 1))" "$indent    " "$nsize"
  else
    ql_pane_tree "$panes" "$((i + 1))" "$indent    " "$nsize"
    ql_pane_leaf "$cur" "$indent    " ""
  fi
  printf '%s}\n' "$indent"
}

# Emit a `tab name="..." { ... }` KDL node for a tab JSON object.
ql_tab_kdl() {
  local tab="$1" indent="${2:-}"
  local name panes tiled_panes floating_panes count float_count
  name="$(jq -r '.name // .id // empty' <<<"$tab")"
  # `optional: true` panes are excluded from the auto-layout (matching the
  # Lua plugin's split_all_panes `if not ql_pane.optional`); they remain
  # launchable on demand from the pane menu.
  panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$tab")"
  tiled_panes="$(jq -c '[ .[] | select((.direction // "" | ascii_downcase) as $d | ($d != "float" and $d != "floating")) ]' <<<"$panes")"
  floating_panes="$(jq -c '[ .[] | select((.direction // "" | ascii_downcase) as $d | ($d == "float" or $d == "floating")) ]' <<<"$panes")"
  count="$(jq 'length' <<<"$tiled_panes")"
  float_count="$(jq 'length' <<<"$floating_panes")"

  printf '%stab name="%s" {\n' "$indent" "$(ql_kdl_escape "$name")"
  if (( count == 0 )); then
    # A tab with no panes but its own action becomes a single pane running
    # that action; otherwise an empty default pane (interactive shell).
    local action
    action="$(jq -c '.action // empty' <<<"$tab")"
    if [[ -n "$action" && "$action" != "null" ]]; then
      local synth
      synth="$(jq -c '{action: .action, name: (.name // .id)}' <<<"$tab")"
      ql_pane_leaf "$synth" "$indent    " ""
    else
      printf '%s    pane\n' "$indent"
    fi
  else
    ql_pane_tree "$tiled_panes" 0 "$indent    " ""
  fi
  if (( float_count > 0 )); then
    local i fp
    for (( i = 0; i < float_count; i++ )); do
      fp="$(jq -c ".[$i]" <<<"$floating_panes")"
      ql_pane_leaf "$fp" "$indent    " ""
    done
  fi
  printf '%s}\n' "$indent"
}

# Build a full `layout { tab { ... } }` string for a single tab target
# (consumed by `zellij action new-tab --layout-string`).
ql_build_tab_layout() {
  local tab="$1"
  printf 'layout {\n'
  ql_tab_kdl "$tab" "    "
  printf '}\n'
}

# Build a full multi-tab `layout { ... }` string for a workspace target.
# Used by the `quick-launch layout workspace ID` debug command to show the
# workspace as a single conceptual layout; the launcher itself builds the
# session tab-by-tab (see ql_open_workspace). Workspace-level panes are
# appended to the first tab, matching the Lua plugin.
ql_build_workspace_layout() {
  local ws="$1"
  local tabs ws_panes tcount
  tabs="$(jq -c '.tabs // []' <<<"$ws")"
  # Workspace-level panes (appended to the first tab) also honor `optional`.
  ws_panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$ws")"
  tcount="$(jq 'length' <<<"$tabs")"

  printf 'layout {\n'
  if (( tcount == 0 )); then
    local synth
    if [[ "$(jq 'length' <<<"$ws_panes")" -gt 0 ]]; then
      synth="$(jq -c --argjson p "$ws_panes" '{name: (.name // .id), panes: $p}' <<<"$ws")"
    elif [[ "$(jq -r 'has("action") and ((.action.type // "") != "")' <<<"$ws")" == true ]]; then
      # A bare workspace action (e.g. an SSH target) becomes the single pane.
      synth="$(jq -c '{name: (.name // .id), action: .action}' <<<"$ws")"
    else
      synth="$(jq -c '{name: (.name // .id)}' <<<"$ws")"
    fi
    ql_tab_kdl "$synth" "    "
  else
    local t tab
    for (( t = 0; t < tcount; t++ )); do
      tab="$(jq -c ".[$t]" <<<"$tabs")"
      if (( t == 0 )) && [[ "$(jq 'length' <<<"$ws_panes")" -gt 0 ]]; then
        tab="$(jq -c --argjson wsp "$ws_panes" '.panes = ((.panes // []) + $wsp)' <<<"$tab")"
      fi
      ql_tab_kdl "$tab" "    "
    done
  fi
  printf '}\n'
}

# Build a full "layout with config" for a nested_zellij workspace: the bar-less
# workspace layout (its command pane runs the SSH/Run target directly, so no
# throwaway login-shell tab flashes the MOTD), plus an embedded `keybinds` block
# that makes the session a TRUE passthrough for the remote's own Zellij.
#
# Locked mode is unreachable for a custom-layout session: Zellij starts it in
# `normal` regardless of any `default_mode` (verified 0.44 quirk — a layout flag
# resets the mode), and there's no CLI to lock an already-attached client
# (`action switch-mode` only touches the ephemeral client it spawns). So we stay
# in `normal` — where unbound keys are forwarded verbatim — and `clear-defaults`
# drops every inherited binding so the leader (Alt+w etc.) reaches the remote's
# own Zellij. Two keys are kept local: `Ctrl+Alt+Space` summons the workspace
# picker (also how WezTerm's Cmd+Shift+P reaches it when nested), and `Alt+Enter`
# toggles the local terminal fullscreen (meaningless if forwarded to the remote)
# while still deferring to a local fzf picker via context-keys' `when fzf`.
# Consumed via `zellij ... options --default-layout <file>`.
# $2 is the home dir (the picker Run needs absolute script paths).
ql_build_nested_layout() {
  local ws="$1" home="$2"
  ql_build_workspace_layout "$ws"
  cat <<EOF
keybinds clear-defaults=true {
    normal {
        bind "Ctrl Alt Space" {
            Run "$home/.config/zellij/scripts/zellij-modal" "--title" "Quick Launch — Workspace" "--" "$home/.config/zellij/scripts/quick-launch-zellij" "workspace" {
                name ""
                close_on_exit true
                floating true
                pinned true
                borderless false
                width "70%"
                height "60%"
            }
        }
        bind "Alt Enter" {
            MessagePlugin "context-keys" {
                name "alt+enter"
                payload "default: run $home/.config/zellij/scripts/terminal-toggle-fullscreen; when fzf: \$source"
            }
        }
    }
}
EOF
}
