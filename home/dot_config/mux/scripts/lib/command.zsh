#!/usr/bin/env zsh
# lib/command.zsh — turn a target's `action` into a runnable shell command,
# plus the float-geometry helpers the backend dispatchers share.
#
# Port of quicklaunch.wezterm's plugin/quick-launch/utils.lua
# (cmd_prefix + make_spawn_command).

# The dependency-free mux layer. Sourced here (this is the first quick-launch
# lib loaded that needs it) so the dispatch libs see mux::*.
source "${MUX_LIB:-$HOME/.local/lib}/mux-bootstrap.zsh"

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
    if ((first)); then
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
    # Quoted: the prefix string is eval'd by a shell downstream ($SHELL -c),
    # so a spaced cwd must stay one word. This also makes the
    # "no $VAR expansion" contract documented on ql_expand_tilde actually hold
    # at eval time.
    local cwd_abs
    cwd_abs="$(ql_expand_tilde "$cwd")"
    prefix="cd ${(q)cwd_abs}; "
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
      if ((${#args[@]} > 0)); then
        for f in "${args[@]}"; do
          case "$f" in
            # Tilde entries are expanded HERE (not left for the downstream
            # eval): the flatten below quotes every element, and a quoted
            # leading ~ would stay literal.
            "~" | "~/"*) abs="$(ql_expand_tilde "$f")" ;;
            /* | \\*) abs="$f" ;;
            *) if [[ -n "$cwd" ]]; then abs="$(ql_expand_tilde "$cwd")/$f"; else abs="$f"; fi ;;
          esac
          files+=("$abs")
        done
      fi
      if ((${#files[@]} > 0)); then
        # Each path is quoted individually — the string is eval'd by a shell
        # downstream, and an unquoted flatten word-splits spaced paths and
        # glob-expands bracketed ones. The editor is deliberately NOT quoted:
        # tools.editor may be multi-word ("code --wait").
        printf '%s%s' "$prefix" "$editor"
        printf ' %s' "${(@q)files}"
      else
        printf '%s%s' "$prefix" "$editor"
      fi
      ;;
    Remote)
      # Note: matches the Lua plugin — Remote does NOT get the cd/venv/mise
      # prefix, it is just `ssh <args>`.
      if ((${#args[@]} > 0)); then
        printf 'ssh %s' "$(ql_join ' ' "${args[@]}")"
      else
        echo "quick-launch: Remote action has no host args" >&2
        printf ''
      fi
      ;;
    Run)
      if ((${#args[@]} > 0)); then
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

ql_is_floating_direction() {
  local dir="$1"
  dir="$(printf '%s' "$dir" | tr '[:upper:]' '[:lower:]')"
  [[ "$dir" == "float" || "$dir" == "floating" ]]
}

# "<cols> <rows>" of the controlling tty — what a float is centred against.
# The shim's own reading of the tty (mux::terminal_size outside a
# multiplexer); NOT mux::terminal_size itself, which inside one answers for
# the multiplexer's window.
ql_terminal_size() {
  _mux::tty_terminal_size
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
      pos="$(((100 - pct) / 2))%"
    fi
  elif [[ "$value" =~ ^[0-9]+$ ]]; then
    span="$value"
    pos=$(((total - value) / 2))
    ((pos < 0)) && pos=0
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
    width_spec="$(ql_trim "${match[1]}")"
    height_spec="$(ql_trim "${match[2]}")"
  else
    width_spec="$size"
    height_spec="$size"
  fi

  read -r cols rows < <(ql_terminal_size)
  read -r width x < <(ql_float_axis_geometry "$width_spec" "$cols")
  read -r height y < <(ql_float_axis_geometry "$height_spec" "$rows")
  printf '%s %s %s %s\n' "$width" "$height" "$x" "$y"
}
