#!/usr/bin/env zsh
# terminal-location.zsh — pick a named background tint for the focused terminal
# session, for WezTerm window tinting.
#
# Returns a palette COLOR NAME (defined in wezterm.lua) or "local" (no tint).
# A session's color is resolved from the host its ssh command targets:
#
#   1. per-machine override — the onboarded entry's `color: <name>` field, if set
#   2. else the profile default — personal→cyan, dev-shell→blue, work→amber
#   3. else (an ssh host not onboarded) → grey
#   4. not an ssh session (the host machine itself) → local
#
# Source of truth is system-onboard's loose operator map
# (~/.config/chezmoi/onboard-map.yaml): each machine is recorded as
#   <slot>: { alias: <ssh-alias>, profile: ..., kind: ..., color: <name?> }
# An ssh command may name the alias OR its real HostName; system-onboard writes
# the alias→HostName bridge to the loose ~/.ssh/config.d/<alias>.conf, so a
# hostname is resolved back to its alias. This file only READS those loose
# artifacts (the secrets silo owns writing them). The `color` field is optional;
# until system-onboard learns --color it stays empty and the profile default
# applies. Env overrides (tests): $TERMINAL_LOCATION_ONBOARD_MAP,
# $TERMINAL_LOCATION_SSH_CONFIG_DIR.

emulate -L zsh
set -u

[[ -n "${__TERMINAL_LOCATION_ZSH:-}" ]] && return 0
typeset -g __TERMINAL_LOCATION_ZSH=1

[[ -n "${__ZELLIJ_SESSION_ZSH:-}" ]] || source "${0:A:h}/zellij-session.zsh"

# Profile → default palette color name. Used when a machine has no explicit
# `color`. Names must exist in wezterm.lua's palette.
typeset -gA TL_PROFILE_DEFAULT_COLOR=(
  personal cyan
  dev-shell blue
  work amber
)
# Color for an ssh host that is reachable but not in the onboard map.
typeset -g TL_REMOTE_DEFAULT_COLOR=grey

tl_onboard_map() {
  print -r -- "${TERMINAL_LOCATION_ONBOARD_MAP:-$HOME/.config/chezmoi/onboard-map.yaml}"
}

tl_ssh_config_dir() {
  print -r -- "${TERMINAL_LOCATION_SSH_CONFIG_DIR:-$HOME/.ssh/config.d}"
}

# Extract the ssh target host from a command line, stripping any `user@` prefix,
# `:path` suffix, and option flags (incl. the common arg-taking ones). Empty if
# the command is not an ssh invocation.
tl_ssh_target() {
  local cmd="$1"
  print -r -- "$cmd" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "ssh" || $i ~ /\/ssh$/) {
          j = i + 1
          while (j <= NF && $j ~ /^-/) {
            if ($j ~ /^-[bcDeFiIJLlmOopQRSWw]$/) j++  # flag takes a separate arg
            j++
          }
          t = $j
          sub(/^[^@]*@/, "", t)   # drop user@
          sub(/:.*/, "", t)       # drop :path
          print t
          exit
        }
      }
    }'
}

# An ssh command may target the alias OR its real endpoint. Resolve a real
# hostname back to its alias via the loose ~/.ssh/config.d/<alias>.conf entries.
tl_alias_for_target() {
  local target="$1" dir conf al hn
  [[ -n "$target" ]] || return 1
  dir="$(tl_ssh_config_dir)"
  [[ -d "$dir" ]] || return 1
  for conf in "$dir"/*.conf(N); do
    al="$(awk 'tolower($1)=="host"{print $2; exit}' "$conf")"
    hn="$(awk 'tolower($1)=="hostname"{print $2; exit}' "$conf")"
    if [[ "$target" == "$al" || "$target" == "$hn" ]]; then
      print -r -- "$al"
      return 0
    fi
  done
  return 1
}

# Echo "<color>\t<profile>" for an onboarded alias (either field may be empty).
# Empty profile means the alias is not in the map.
tl_map_color_profile() {
  local al="$1" map
  [[ -n "$al" ]] || return 1
  map="$(tl_onboard_map)"
  [[ -f "$map" ]] || return 1
  al="$al" yq -r '
    ([.[] | select(.alias == strenv(al))] | .[0]) // {}
    | [(.color // ""), (.profile // "")] | @tsv
  ' "$map" 2>/dev/null
}

# Palette color name for an ssh target (alias or real hostname): explicit
# per-machine color, else the profile default. Non-zero if not onboarded.
tl_colorname_for_target() {
  local target="$1" al cp color profile
  [[ -n "$target" ]] || return 1

  cp="$(tl_map_color_profile "$target")"
  color="${cp%%$'\t'*}"
  profile="${cp#*$'\t'}"
  if [[ -z "$color" && -z "$profile" ]]; then
    # Not an alias; map a real hostname to its alias, then retry.
    al="$(tl_alias_for_target "$target")" || return 1
    cp="$(tl_map_color_profile "$al")"
    color="${cp%%$'\t'*}"
    profile="${cp#*$'\t'}"
  fi

  [[ -n "$color" ]] && {
    print -r -- "$color"
    return 0
  }
  [[ -n "$profile" && -n "${TL_PROFILE_DEFAULT_COLOR[$profile]:-}" ]] && {
    print -r -- "${TL_PROFILE_DEFAULT_COLOR[$profile]}"
    return 0
  }
  return 1
}

# Path to the shared WezTerm tint palette (flat `name = "#hex"`). Env override
# for tests: $TERMINAL_LOCATION_TINT_PALETTE.
tl_tint_palette() {
  print -r -- "${TERMINAL_LOCATION_TINT_PALETTE:-${XDG_CONFIG_HOME:-$HOME/.config}/wezterm/tint-palette.toml}"
}

# Resolve a palette color NAME to its "#rrggbb" hex from tint-palette.toml — the
# same source WezTerm reads. Non-zero (no output) when the name is undefined or
# the palette is missing. Used by ssh-prepare-connection's theme step for the
# host→remote tint push.
tl_hex_for_colorname() {
  local name="$1" file hex
  [[ -n "$name" ]] || return 1
  file="$(tl_tint_palette)"
  [[ -r "$file" ]] || return 1
  hex="$(awk -v n="$name" '
    $0 ~ "^[[:space:]]*" n "[[:space:]]*=" {
      if (match($0, /#[0-9A-Fa-f]{6}/)) { print substr($0, RSTART, RLENGTH); exit }
    }' "$file")"
  [[ -n "$hex" ]] || return 1
  print -r -- "$hex"
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

# Focused terminal pane command via list-panes JSON. A floating modal (our
# pickers/dialogs) keeps its own focus while the originating tile stays focused
# in the tiled axis, so `is_focused` matches both; exclude floating panes so a
# transient modal never hijacks the window tint — the tiled pane is the context.
tl_focused_pane_command() {
  local session="$1" zj
  zj="$(tl_zellij_bin)" || return 1
  "$zj" -s "$session" action list-panes -a -j 2>/dev/null |
    jq -r '[.[] | select(.is_plugin == false and .is_focused == true and .is_floating == false)] | .[0].pane_command // empty' 2>/dev/null
}

# RUNNING_COMMAND of the sole client (fallback when no focused terminal pane).
tl_client_running_command() {
  local session="$1" zj count
  zj="$(tl_zellij_bin)" || return 1
  count=$("$zj" -s "$session" action list-clients 2>/dev/null | awk 'NR > 1 { c++ } END { print c + 0 }')
  ((count == 1)) || return 1
  "$zj" -s "$session" action list-clients 2>/dev/null |
    awk -F'  +' 'NR == 2 { for (i = 3; i <= NF; i++) printf "%s%s", (i > 3 ? " " : ""), $i }'
}

# Classify a command line → palette color name. An onboarded ssh target yields
# its color; any other ssh yields the remote default; non-ssh is non-zero (the
# caller treats that as local).
tl_classify_command() {
  local cmd="$1" target
  [[ -n "$cmd" ]] || return 1
  target="$(tl_ssh_target "$cmd")"
  [[ -n "$target" ]] || return 1
  tl_colorname_for_target "$target" && return 0
  print -r -- "$TL_REMOTE_DEFAULT_COLOR"
}

# resolve_terminal_location <client_pid>
#   Prints: local | <palette color name>
resolve_terminal_location() {
  local client_pid="${1:?usage: resolve_terminal_location <client_pid>}"
  local session cmd exe args

  exe=$(ps -p "$client_pid" -o comm= 2>/dev/null) || {
    print -r -- local
    return 0
  }

  # Bare ssh (or anything non-Zellij) in the pane: classify its own argv.
  if [[ "$exe" != *zellij* ]]; then
    args=$(ps -p "$client_pid" -o args= 2>/dev/null) || args=""
    tl_classify_command "$args" && return 0
    print -r -- local
    return 0
  fi

  # Zellij client: find its session, then the focused pane's command.
  session="$(resolve_session "$client_pid" 2>/dev/null)" || {
    print -r -- local
    return 0
  }

  cmd="$(tl_focused_pane_command "$session")"
  [[ -n "$cmd" ]] || cmd="$(tl_client_running_command "$session")" || cmd=""

  tl_classify_command "$cmd" && return 0
  print -r -- local
}
