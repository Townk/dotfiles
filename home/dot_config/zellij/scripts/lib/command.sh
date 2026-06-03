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

ql_shell_join() {
  local out="" first=1 a q
  for a in "$@"; do
    printf -v q '%q' "$a"
    if (( first )); then
      out="$q"
      first=0
    else
      out+=" $q"
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
    External)
      if (( ${#args[@]} > 0 )); then
        ql_shell_join "${args[@]}"
      else
        echo "quick-launch: External action has no command args" >&2
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

# Emit a single leaf `pane` KDL node for a pane JSON object.
# Args: pane_json, indent, size(optional)
ql_pane_leaf() {
  local pane="$1" indent="$2" size="${3:-}"
  local action name cwd cmd sizeattr nameattr cwdattr
  action="$(jq -c '.action // {}' <<<"$pane")"
  name="$(jq -r '.name // .id // empty' <<<"$pane")"
  cwd="$(jq -r '.action.cwd // empty' <<<"$pane")"
  [[ -n "$cwd" ]] && cwd="$(ql_expand_tilde "$cwd")"
  cmd="$(ql_action_command "$action")"

  [[ -n "$size" ]] && sizeattr=" size=\"$size\"" || sizeattr=""
  [[ -n "$name" ]] && nameattr=" name=\"$(ql_kdl_escape "$name")\"" || nameattr=""
  [[ -n "$cwd" ]] && cwdattr=" cwd=\"$(ql_kdl_escape "$cwd")\"" || cwdattr=""

  if [[ -z "$cmd" ]]; then
    printf '%spane%s%s%s\n' "$indent" "$nameattr" "$cwdattr" "$sizeattr"
  else
    printf '%spane command="sh"%s%s%s {\n' "$indent" "$nameattr" "$cwdattr" "$sizeattr"
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
  local name panes count
  name="$(jq -r '.name // .id // empty' <<<"$tab")"
  # `optional: true` panes are excluded from the auto-layout (matching the
  # Lua plugin's split_all_panes `if not ql_pane.optional`); they remain
  # launchable on demand from the pane menu.
  panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$tab")"
  count="$(jq 'length' <<<"$panes")"

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
    ql_pane_tree "$panes" 0 "$indent    " ""
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

# Build a full multi-tab `layout { ... }` string for a workspace target
# (consumed by `zellij action switch-session --layout-string`). Workspace-
# level panes are appended to the first tab, matching the Lua plugin.
ql_build_workspace_layout() {
  local ws="$1"
  local tabs ws_panes tcount
  tabs="$(jq -c '.tabs // []' <<<"$ws")"
  # Workspace-level panes (appended to the first tab) also honor `optional`.
  ws_panes="$(jq -c '[ (.panes // [])[] | select(.optional != true) ]' <<<"$ws")"
  tcount="$(jq 'length' <<<"$tabs")"

  printf 'layout {\n'
  if (( tcount == 0 )); then
    local name
    name="$(jq -r '.name // .id' <<<"$ws")"
    printf '    tab name="%s" {\n' "$(ql_kdl_escape "$name")"
    if [[ "$(jq 'length' <<<"$ws_panes")" -gt 0 ]]; then
      ql_pane_tree "$ws_panes" 0 "        " ""
    else
      printf '        pane\n'
    fi
    printf '    }\n'
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
