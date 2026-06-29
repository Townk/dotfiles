#!/usr/bin/env zsh
# terminal-location.zsh — classify where the focused terminal session effectively
# runs (local vs remote targets) for WezTerm window background tinting.
#
# Optional mapping file: ~/.config/wezterm/terminal-location.yaml
# (chezmoi source: private_terminal-location.yaml). Example:
#
#   sessions:
#     home: ["Home MacMini"]
#     dev: ["Dev Shell"]
#   hosts:
#     home: ["mac-mini"]
#     dev: ["dev-shell"]
#
# Session names match Zellij workspace `name` values. Host entries match
# substrings (case-insensitive) in an ssh command line.

emulate -L zsh
set -u

[[ -n "${__TERMINAL_LOCATION_ZSH:-}" ]] && return 0
typeset -g __TERMINAL_LOCATION_ZSH=1

[[ -n "${__ZELLIJ_SESSION_ZSH:-}" ]] || source "${0:A:h}/zellij-session.zsh"

tl_config_file() {
  local f="${TERMINAL_LOCATION_CONFIG:-$HOME/.config/wezterm/terminal-location.yaml}"
  [[ -f "$f" ]] && print -r -- "$f"
}

tl_nested_registry() {
  print -r -- "${XDG_CACHE_HOME:-$HOME/.cache}/quick-launch/nested-sessions"
}

tl_is_nested_session() {
  local name="$1"
  grep -Fxq "$name" "$(tl_nested_registry)" 2>/dev/null
}

tl_yq_to_json() {
  yq -p=yaml -o=json -I=0 '.' "$1" 2>/dev/null
}

# Echo a location id when $session matches sessions.<loc>[] in config.
tl_session_to_location() {
  local session="$1" config="$2" json loc
  [[ -n "$config" ]] || return 1
  json="$(tl_yq_to_json "$config")" || return 1
  loc="$(jq -r --arg s "$session" '
    .sessions // {} | to_entries[]
    | select(.value | index($s)) | .key
  ' <<<"$json")"
  [[ -n "$loc" && "$loc" != null ]] && {
    print -r -- "$loc"
    return 0
  }
  return 1
}

# Echo a location id when $cmd matches hosts.<loc>[] substrings in config.
tl_command_to_location() {
  local cmd="$1" config="$2" json loc pattern
  [[ -n "$cmd" && -n "$config" ]] || return 1
  json="$(tl_yq_to_json "$config")" || return 1
  cmd="${cmd:l}"
  for loc in home dev remote; do
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      if [[ "$cmd" == *"${pattern:l}"* ]]; then
        print -r -- "$loc"
        return 0
      fi
    done < <(jq -r --arg loc "$loc" '.hosts[$loc][]?' <<<"$json" 2>/dev/null)
  done
  return 1
}

tl_command_is_ssh() {
  local cmd="$1"
  [[ "$cmd" == ssh\ * || "$cmd" == */ssh\ * || "$cmd" == *"/ssh "* ]]
}

tl_zellij_bin() {
  local z="${ZELLIJ_BIN:-${commands[zellij]:-}}"
  [[ -n "$z" && -x "$z" ]] && {
    print -r -- "$z"
    return 0
  }
  for z in /opt/homebrew/bin/zellij /usr/local/bin/zellij "$HOME/.local/bin/zellij"; do
    [[ -x "$z" ]] && {
      print -r -- "$z"
      return 0
    }
  done
  return 1
}

# Focused terminal pane command via list-panes JSON.
tl_focused_pane_command() {
  local session="$1" zj
  zj="$(tl_zellij_bin)" || return 1
  "$zj" -s "$session" action list-panes -a -j 2>/dev/null |
    jq -r '[.[] | select(.is_plugin == false and .is_focused == true)] | .[0].pane_command // empty' 2>/dev/null
}

tl_client_running_command() {
  local session="$1" zj count
  zj="$(tl_zellij_bin)" || return 1
  count=$("$zj" -s "$session" action list-clients 2>/dev/null | awk 'NR > 1 { c++ } END { print c + 0 }')
  ((count == 1)) || return 1
  "$zj" -s "$session" action list-clients 2>/dev/null |
    awk -F'  +' 'NR == 2 { for (i = 3; i <= NF; i++) printf "%s%s", (i > 3 ? " " : ""), $i }'
}

tl_classify_command() {
  local cmd="$1" config="$2" loc
  [[ -n "$cmd" ]] || return 1
  loc="$(tl_command_to_location "$cmd" "$config")" && {
    print -r -- "$loc"
    return 0
  }
  if tl_command_is_ssh "$cmd"; then
    print -r -- remote
    return 0
  fi
  return 1
}

# resolve_terminal_location <client_pid>
#   Prints one of: local, home, dev, remote
resolve_terminal_location() {
  local client_pid="${1:?usage: resolve_terminal_location <client_pid>}"
  local config loc session cmd exe args

  config="$(tl_config_file)" || config=""

  exe=$(ps -p "$client_pid" -o comm= 2>/dev/null) || {
    print -r -- local
    return 0
  }

  if [[ "$exe" != *zellij* ]]; then
    args=$(ps -p "$client_pid" -o args= 2>/dev/null) || args=""
    if tl_classify_command "$args" "$config"; then
      return 0
    fi
    print -r -- local
    return 0
  fi

  session="$(resolve_session "$client_pid" 2>/dev/null)" || {
    print -r -- local
    return 0
  }

  loc="$(tl_session_to_location "$session" "$config")" && {
    print -r -- "$loc"
    return 0
  }

  if tl_is_nested_session "$session"; then
    print -r -- remote
    return 0
  fi

  cmd="$(tl_focused_pane_command "$session")"
  if [[ -z "$cmd" ]]; then
    cmd="$(tl_client_running_command "$session")" || cmd=""
  fi

  if tl_classify_command "$cmd" "$config"; then
    return 0
  fi

  print -r -- local
}
