#!/usr/bin/env zsh
# host.zsh — name a machine the way a human knows it.
# Spec: docs/superpowers/specs/2026-09-29-peer-alias-display-design.md (H6).
#
# SOURCED, never executed, and free of file-scope side effects (no setopt, no
# export, no mkdir): pick-clipboard sources it at top level, where a leaked
# option would change its own character counting.
#
# A machine's KEY is its clipboard identity (clip::self_host: self-name file,
# then LocalHostName, then hostname -s) — what every stored row's source_host
# carries. Its ALIAS is the friendly name in that machine's ~/.hostname-alias.
# Other machines' aliases are LEARNED at SSH login (environment.sh records
# `<key> <alias>` lines) because hostnames and aliases must never be committed.
#
# Every value is re-validated on READ as well as on write: the map is a plain
# file anyone can edit, and host::sql_case inlines values into SQL.

# host::aliases_file — path of the learned map (HOST_ALIASES_FILE overrides).
host::aliases_file() {
  print -rn -- "${HOST_ALIASES_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/hosts/aliases}"
}

# host::_valid <value> — the one value rule: ^[A-Za-z0-9._-]{1,64}$.
host::_valid() {
  emulate -L zsh
  setopt extended_glob
  [[ "$1" == [A-Za-z0-9._-](#c1,64) ]]
}

# host::display <key> [<self-key>] — the name to show for <key>.
# Own alias when <key> is this machine (callers pass their MY_HOST as
# <self-key>: computing it here would mean sourcing clipboard-store-core.zsh,
# whose file-scope setopt/export side effects pick-clipboard deliberately keeps
# in a subshell). Then the learned alias. Then <key> itself. Never fails.
host::display() {
  emulate -L zsh
  setopt extended_glob
  local key="${1-}" self="${2-}" k a
  if [[ -n "$key" && -n "$self" && "$key" == "$self" ]]; then
    local own="${HOST_SELF_ALIAS_FILE:-$HOME/.hostname-alias}"
    if [[ -r "$own" ]]; then
      IFS= read -r a <"$own" || true
      if host::_valid "$a"; then print -rn -- "$a"; return 0; fi
    fi
    print -rn -- "$key"
    return 0
  fi
  local f; f="$(host::aliases_file)"
  if [[ -n "$key" && -r "$f" ]]; then
    while IFS=' ' read -r k a; do
      if [[ "$k" == "$key" ]] && host::_valid "$a"; then
        print -rn -- "$a"
        return 0
      fi
    done <"$f"
  fi
  print -rn -- "$key"
}

# host::sql_case <column> — an SQL expression mapping <column> through the map,
# for places that name a host INSIDE sqlite (pick-clipboard's generated preview
# script cannot call zsh). Only lines whose BOTH fields pass host::_valid are
# inlined — the character rule admits no quote, so nothing can escape the
# string literals.
host::sql_case() {
  emulate -L zsh
  setopt extended_glob
  local col="$1" f k a out=""
  f="$(host::aliases_file)"
  if [[ -r "$f" ]]; then
    while IFS=' ' read -r k a; do
      host::_valid "$k" && host::_valid "$a" || continue
      out+=" WHEN '$k' THEN '$a'"
    done <"$f"
  fi
  if [[ -z "$out" ]]; then
    print -rn -- "$col"
  else
    print -rn -- "(CASE $col$out ELSE $col END)"
  fi
}
