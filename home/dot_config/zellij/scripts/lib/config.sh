#!/usr/bin/env bash
# lib/config.sh — read & normalize the quick-launch targets file.
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

# Absolute path to the targets file. Mirrors the Lua default of
# `<config_dir>/quick-launch-targets.yaml`, overridable via env so the
# zellij adapter (or tests) can point elsewhere.
ql_config_path() {
  echo "${QUICK_LAUNCH_TARGETS:-$HOME/.config/zellij/quick-launch-targets.yaml}"
}

# Load the targets file into $QL_JSON (compact, single-line JSON). The input
# parser is chosen from the file extension, matching the Lua plugin's
# extension switch.
ql_load() {
  local path
  path="$(ql_config_path)"
  if [[ ! -r "$path" ]]; then
    echo "quick-launch: cannot read targets file: $path" >&2
    return 1
  fi
  case "$path" in
    *.json) QL_JSON="$(yq -p=json -o=json -I=0 '.' "$path")" ;;
    *.toml) QL_JSON="$(yq -p=toml -o=json -I=0 '.' "$path")" ;;
    *) QL_JSON="$(yq -p=yaml -o=json -I=0 '.' "$path")" ;;
  esac
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

# Capitalize the first character (portable; ${x^} is bash 4+ only and macOS
# /usr/bin/bash is 3.2). Used for fzf prompts.
ql_cap() {
  local s="$1"
  printf '%s%s' "$(printf '%s' "${s:0:1}" | tr '[:lower:]' '[:upper:]')" "${s:1}"
}
