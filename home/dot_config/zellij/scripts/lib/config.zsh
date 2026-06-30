#!/usr/bin/env zsh
# lib/config.zsh — read, merge & normalize the quick-launch targets
# (default.yaml + launch.d/* under the targets directory).
#
# Port of quicklaunch.wezterm's plugin/quick-launch/config.lua.
#
# Strategy: convert the targets file (YAML by default; JSON/TOML also
# supported) to compact JSON exactly once via `yq`, stash it in the global
# $QL_JSON, and run every subsequent query through `jq`. jq's nested
# traversal is far more predictable in a script than chained yq expressions,
# and `yq -o=json` gives us a single, format-agnostic entry point — the same
# "read any of yaml/json/toml" behavior the Lua plugin had via
# wezterm.serde.*_decode.

# Targets directory (default ~/.config/zellij/quick-launch), overridable via
# $QUICK_LAUNCH_DIR. Holds the managed `default.yaml` plus an optional
# `launch.d/` of host-local fragments.
ql_config_dir() {
  echo "${QUICK_LAUNCH_DIR:-$HOME/.config/zellij/quick-launch}"
}

# A single-file override (used by the picker's merged cache and by tests). When
# set it bypasses directory discovery entirely; empty otherwise.
ql_config_path() {
  local single="${QUICK_LAUNCH_TARGETS:-}"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/quick-launch/merged.json"
  [[ "$single" == "$cache" ]] && single=""
  echo "$single"
}

# Convert one targets file to compact JSON; parser chosen by extension. Mirrors
# the Lua plugin's "read any of yaml/json/toml" behavior.
ql_file_to_json() {
  case "$1" in
    *.json) yq -p=json -o=json -I=0 '.' "$1" ;;
    *.toml) yq -p=toml -o=json -I=0 '.' "$1" ;;
    *) yq -p=yaml -o=json -I=0 '.' "$1" ;;
  esac
}

# Ordered list of source files: default.yaml first, then every launch.d
# fragment in C-collation order. Later files win on `id` collisions.
ql_source_files() {
  local dir def
  dir="$(ql_config_dir)"
  def="$dir/default.yaml"
  [[ -r "$def" ]] && printf '%s\n' "$def"
  if [[ -d "$dir/launch.d" ]]; then
    find "$dir/launch.d" -maxdepth 1 -type f \
      \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.toml' \) \
      2>/dev/null | LC_ALL=C sort
  fi
}

# Load targets into $QL_JSON (compact, single-line JSON). With a single-file
# override we read just that file; otherwise we merge default.yaml + launch.d/*:
# `tools` is shallow-merged (last wins) and the workspaces/tabs/panes lists are
# concatenated then deduped by `id`, with later files overriding earlier ones
# in place (entries without an `id` are always kept).
ql_load() {
  local single
  single="$(ql_config_path)"
  if [[ -n "$single" ]]; then
    if [[ ! -r "$single" ]]; then
      echo "quick-launch: cannot read targets file: $single" >&2
      return 1
    fi
    QL_JSON="$(ql_file_to_json "$single")"
    return
  fi

  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(ql_source_files)
  if ((${#files[@]} == 0)); then
    echo "quick-launch: no targets found in $(ql_config_dir)" >&2
    return 1
  fi

  # Fast path: reuse the already-merged cache when it is newer than every source
  # file (the menu writes it via ql_write_merged_cache). Skips the per-file yq +
  # jq merge — the dominant cost of opening the menu — whenever configs are
  # unchanged. A touched-but-unchanged source just forces one harmless re-merge.
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/quick-launch/merged.json"
  if [[ -s "$cache" ]]; then
    local stale=0
    for f in "${files[@]}"; do
      [[ "$f" -nt "$cache" ]] && { stale=1; break; }
    done
    if (( ! stale )); then
      QL_JSON="$(<"$cache")"
      [[ -n "$QL_JSON" ]] && return 0
    fi
  fi

  QL_JSON="$(
    for f in "${files[@]}"; do ql_file_to_json "$f"; done | jq -sc '
      def merge_list($docs; $k):
        reduce ($docs[] | (.[$k] // [])[]) as $e ([];
          if ($e.id // null) == null then . + [$e]
          elif any(.[]; .id == $e.id) then map(if .id == $e.id then $e else . end)
          else . + [$e] end);
      . as $docs
      | {
          tools:      (reduce $docs[] as $d ({}; . * ($d.tools // {}))),
          workspaces: merge_list($docs; "workspaces"),
          tabs:       merge_list($docs; "tabs"),
          panes:      merge_list($docs; "panes")
        }
    '
  )" || {
    echo "quick-launch: failed to merge targets in $(ql_config_dir)" >&2
    return 1
  }
}

# Editor resolution: tools.editor -> $EDITOR -> nvim. Mirrors the Lua
# fallback chain (which ended at /usr/bin/vim); we end at `nvim` to match
# this setup's editor.
ql_editor() {
  local e
  e="$(jq -r '.tools.editor // empty' <<<"$QL_JSON")"
  [[ -n "$e" ]] || e="${EDITOR:-}"
  [[ -n "$e" ]] || e="nvim"
  echo "$e"
}

# mise binary resolution: tools.mise -> `mise` on PATH -> empty. When empty,
# `mise_env` action options are silently ignored, matching the Lua behavior.
ql_mise() {
  local m
  m="$(jq -r '.tools.mise // empty' <<<"$QL_JSON")"
  [[ -n "$m" ]] || m="$(command -v mise 2>/dev/null || true)"
  echo "$m"
}

# Expand a leading ~ / ~/ to $HOME (port of the Lua expand_tilde). Anything
# else is returned verbatim — we deliberately do NOT expand $VARS or globs.
ql_expand_tilde() {
  local p="$1"
  case "$p" in
    "~") echo "$HOME" ;;
    "~/"*) echo "$HOME/${p#\~/}" ;;
    *) echo "$p" ;;
  esac
}

# Capitalize the first character. Used for fzf prompts.
ql_cap() {
  local s="$1"
  printf '%s' "${(U)s[1,1]}${s[2,-1]}"
}
