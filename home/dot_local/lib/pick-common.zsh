#!/usr/bin/env zsh
# pick-common.zsh — shared scaffolding for the fzf picker scripts
#                   (pick-glyph, pick-gitmoji, …).
#
# Off-PATH internal library, SOURCED (not executed) by the pickers:
#     source "${PICK_COMMON_LIB:-$HOME/.local/lib/pick-common.zsh}"
#
# It owns the picker "layer 2": everything from an assembled lines
# cache onward — the fzf flag/palette block, border handling, the
# NBSP-terminated header, running fzf, the --expect key split, the
# cancel (exit 130) path, and the per-selection emit + clipboard loop.
# Each picker keeps "layer 1": acquiring its data and assembling its
# colour-formatted LINES_CACHE (via a jq emitter that uses pick.jq's
# emit_line contract).
#
# Three optional UX features live here too, enabled by the picker
# setting a few globals (all opt-in, so a bare picker still works):
#   * Recency sort   — set `pick_usage_file`: recently-chosen items are
#                      floated to the top of the list (then the normal
#                      order). `--tiebreak=index` makes input order the
#                      tiebreak, so this just reorders the fed lines.
#   * Resume         — set `pick_state_file`: the final query + cursor
#                      item are saved on exit; a `--resume` launch
#                      restores both (query via --query, cursor via
#                      `start:pos(N)` computed with a `fzf --filter`
#                      pass so it's robust to recency reordering).
#   * Insert & stay  — set `pick_stay_binds` (+ `pick_self`): bind keys
#                      that inject the current item without dismissing
#                      the picker, via fzf `execute-silent`. The sink is
#                      the originating zellij pane when PICK_INJECT_PANE
#                      / PICK_INJECT_ZELLIJ are exported (the zellij-
#                      modal embed), else the system clipboard.
#
# Contract with the sourcing picker:
#   * Set PICK_NAME before first use (pick::die prefix).
#   * Fill `pick_ui`, call pick::build_fzf_args → global `fzf_args`.
#   * Set `pick_input` to the cache→fzf stream filter (`( cat )`, or an
#     awk source-filter), then pick::run "$LINES_CACHE" sets pick_query
#     / pick_key / pick_selection.
#   * Set `mode` (resolved from pick_key) and define `pick_emit_one
#     <line>` (appends to global `result`); then pick::emit_selection.
#
# Wire format is defined in pick.jq — see pick::split_tail for the
# shell side of the same contract.

# --- diagnostics ---------------------------------------------------

pick::die() { print -ru2 -- "${PICK_NAME:-pick}: $*"; exit 1; }

pick::need() {
  command -v "$1" >/dev/null 2>&1 || pick::die "$1 not found in PATH${2:+ ($2)}"
}

# --- cache staleness ----------------------------------------------

# True (return 0) if the assembled-lines cache must be rebuilt: it is
# missing/empty, or ANY remaining argument (source JSON, the picker
# script, pick.jq, …) is newer than it.
pick::cache_stale() {
  local cache=$1; shift
  [[ -s "$cache" ]] || return 0
  local src
  for src in "$@"; do
    [[ -e "$src" && "$src" -nt "$cache" ]] && return 0
  done
  return 1
}

# --- clipboard -----------------------------------------------------

# Echo the first available clipboard-copy command (for the bare-mode
# stay-insert sink), or nothing if none is found.
pick::detect_clip() {
  if   command -v pbcopy  >/dev/null 2>&1; then print -r -- "pbcopy"
  elif command -v wl-copy >/dev/null 2>&1; then print -r -- "wl-copy"
  elif command -v xclip   >/dev/null 2>&1; then print -r -- "xclip -selection clipboard"
  fi
}

# Copy a string to the clipboard via the first available helper. No
# trailing newline so a paste at a shell prompt doesn't auto-execute.
pick::clipboard() {
  local s=$1
  if   command -v pbcopy  >/dev/null 2>&1; then printf '%s' "$s" | pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$s" | wl-copy
  elif command -v xclip   >/dev/null 2>&1; then printf '%s' "$s" | xclip -selection clipboard
  else pick::die "no clipboard helper found (pbcopy / wl-copy / xclip)"
  fi
}

# --- recency sort --------------------------------------------------

# Stream the lines cache to stdout, floating recently-used items to the
# top (in recency order) when `pick_usage_file` is set and non-empty;
# otherwise pass the cache through unchanged. The recency id is tail
# field `pick_id_field` (default 1). The remaining ("cold") lines keep
# their original order, so the underlying sort is preserved as the
# fallback once fzf's --tiebreak=index kicks in.
pick::ordered_cache() {
  local cache=$1
  if [[ -n "${pick_usage_file:-}" && -s "${pick_usage_file}" ]]; then
    awk -v idf="${pick_id_field:-1}" '
      FNR==NR { rank[$0]=FNR; nu=FNR; next }   # usage file: 1 id per line, most-recent first
      {
        p = index($0, "\037"); tail = substr($0, p + 1);
        split(tail, a, "\036"); id = a[idf];
        if (id in rank) recents[rank[id]] = $0; else rest[++r] = $0;
      }
      END {
        for (i = 1; i <= nu; i++) if (i in recents) print recents[i];
        for (i = 1; i <= r;  i++) print rest[i];
      }
    ' "$pick_usage_file" "$cache"
  else
    cat -- "$cache"
  fi
}

# The full producer side of the fzf pipeline: recency-ordered cache
# piped through the picker's input filter (source filter, or cat).
pick::feed() {
  local -a input; input=( "${pick_input[@]}" ); (( ${#input} )) || input=( cat )
  pick::ordered_cache "$1" | "${input[@]}"
}

# --- fzf argument construction ------------------------------------

# Build the standardized fzf argument list into the global `fzf_args`
# from `pick_ui`. Keys (all optional unless noted):
#   height/margin/padding   fzf geometry (defaults 45% / 0,0,0,0)
#   no_border               1 → --no-border, else --border
#   input_border            0/none disables; 1 = rounded; else passthrough
#   multi                   1 → --multi + select-all + 2-line header
#   query                   seed query (omitted when empty)
#   header                  keybind-hint line (required for a useful UI)
#   multi_help              2nd header line w/ multi (has a default)
#   expect                  comma-separated --expect keys
#
# The palette and structural flags are identical across pickers and
# baked in. --print-query is always set so pick::run can capture the
# final query for the resume feature; it's consumed internally and
# never leaks to the picker's stdout. Stay-insert binds (pick_stay_binds)
# are appended last.
pick::build_fzf_args() {
  local NBSP=$'\u00a0'
  fzf_args=(
    --color=bg:'#1e1e2e'
    --color=bg+:'#313244'
    --color=fg:'#cdd6f4'
    --color=fg+:'#cdd6f4'
    --color=hl:'#f9e2af'
    --color=hl+:'#f9e2af'
    --color=prompt:'#cba6f7'
    --color=pointer:'#f5e0dc'
    --color=marker:'#b4befe'
    --color=info:'#cba6f7'
    --color=gutter:'#1e1e2e'
    --color=header:'#585b70'
    --color=spinner:'#f5e0dc'
    --color=border:'#585b70'
    --filepath-word
    --height="${pick_ui[height]:-45%}"
    --layout=reverse
    --info=inline-right
    --exit-0
    --select-1
    --ansi
    --margin="${pick_ui[margin]:-0,0,0,0}"
    --padding="${pick_ui[padding]:-0,0,0,0}"
    --prompt=$'\uF422  '
    --pointer=$' \u2794'
    --marker=$'\u2714'
    --delimiter=$'\x1f'
    --with-nth=1
    --tiebreak=index
    --highlight-line
    # Render every row from column 0 and truncate the overflow on the
    # right (with fzf's "··" marker), treating the line as one string.
    # Without this, fzf horizontally scrolls long lines to keep the
    # match visible, which left-truncates the glyph/name when the hit
    # lands in a far-right column (e.g. a long Unicode description).
    --no-hscroll
    # Capture the final query (consumed by pick::run for --resume).
    --print-query
  )

  [[ -n "${pick_ui[expect]:-}" ]] && fzf_args+=( "--expect=${pick_ui[expect]}" )

  if (( ${pick_ui[no_border]:-0} )); then
    fzf_args+=( --no-border )
  else
    fzf_args+=( --border )
  fi

  case "${pick_ui[input_border]:-1}" in
    0|none) ;;
    1)      fzf_args+=( --input-border ) ;;
    *)      fzf_args+=( "--input-border=${pick_ui[input_border]}" ) ;;
  esac

  local header="${pick_ui[header]:-}"
  local multi_help="${pick_ui[multi_help]:-tab: mark  ·  ^A: select-all}"
  if (( ${pick_ui[multi]:-0} )); then
    fzf_args+=(
      --multi
      --bind 'ctrl-a:select-all'
      --header="$header"$'\n'"$multi_help"$'\n'"$NBSP"
    )
  else
    fzf_args+=( --header="$header"$'\n'"$NBSP" )
  fi

  pick::add_stay_binds

  # `if` (not `&&`) so an empty query doesn't make a failing test the
  # last statement and trip the caller's `set -e`.
  if [[ -n "${pick_ui[query]:-}" ]]; then
    fzf_args+=( --query "${pick_ui[query]}" )
  fi
  return 0
}

# Append "insert without dismissing" binds. For each "key:mode" in
# `pick_stay_binds`, bind <key> to an fzf execute-silent that formats
# the current line in <mode> (reusing the picker's own `--emit MODE`
# subcommand) and writes it to the sink WITHOUT closing the picker:
#   * embed (PICK_INJECT_PANE + PICK_INJECT_ZELLIJ set): zellij
#     write-chars into the originating pane.
#   * else, if a clipboard helper exists: copy.
# `pick_self` must be the picker's own path. No-op if neither sink is
# available or pick_stay_binds is empty.
pick::add_stay_binds() {
  (( ${#pick_stay_binds[@]:-0} )) || return 0
  local self="${pick_self:-}"
  [[ -n "$self" ]] || return 0

  local embed=0
  [[ -n "${PICK_INJECT_PANE:-}" && -n "${PICK_INJECT_ZELLIJ:-}" ]] && embed=1

  local clip; clip="$(pick::detect_clip)"
  (( embed )) || [[ -n "$clip" ]] || return 0   # no sink → no stay binds

  local b key m
  for b in "${pick_stay_binds[@]}"; do
    key="${b%%:*}"; m="${b#*:}"
    if (( embed )); then
      # {} is the current line (fzf shell-quotes it at keypress); the
      # \$(…) runs the picker's emitter then; --pane-id/path expand now.
      fzf_args+=( --bind "${key}:execute-silent(${PICK_INJECT_ZELLIJ} action write-chars --pane-id ${PICK_INJECT_PANE} -- \"\$(${self} --emit ${m} -- {})\")" )
    else
      fzf_args+=( --bind "${key}:execute-silent(${self} --emit ${m} -- {} | ${clip})" )
    fi
  done
  return 0
}

# --- resume --------------------------------------------------------

# Load the saved query + cursor id into pick_resume_query /
# pick_resume_id (empty if no state). State file is 2 lines:
# query, then id.
pick::load_state() {
  pick_resume_query=""; pick_resume_id=""
  [[ -n "${pick_state_file:-}" && -s "${pick_state_file}" ]] || return 0
  { IFS= read -r pick_resume_query; IFS= read -r pick_resume_id } < "$pick_state_file" || true
  return 0
}

# Given the saved cursor id, compute its row in the resumed view and
# append a `start:pos(N)` bind so fzf opens with that item highlighted.
# We replay the saved query through `fzf --filter` over the same fed
# input, so the row number matches the interactive ranking (and stays
# correct even after recency reordering). No-op if the id can't be
# located.
pick::resume_pos() {
  local cache=$1
  [[ -n "${pick_resume_id:-}" ]] || return 0
  local idx
  idx=$( { pick::feed "$cache" \
            | fzf --filter="${pick_resume_query:-}" --tiebreak=index \
                  --delimiter=$'\x1f' --with-nth=1 \
            | awk -v idf="${pick_id_field:-1}" -v want="$pick_resume_id" '
                { p = index($0, "\037"); tail = substr($0, p + 1);
                  split(tail, a, "\036");
                  if (a[idf] == want) { print NR; exit } }'
        } 2>/dev/null || true )
  [[ -n "$idx" ]] && fzf_args+=( --bind "start:pos($idx)" )
  return 0
}

# --- run fzf -------------------------------------------------------

# Stream the recency-ordered, filtered cache into fzf. On cancel (fzf
# non-zero) or empty selection, exit 130 (clean cancel). On success
# set globals pick_query (final query, from --print-query), pick_key
# (pressed --expect key, empty for plain Enter), pick_selection.
pick::run() {
  local cache=$1
  local out
  out=$(pick::feed "$cache" | fzf "${fzf_args[@]}") || exit 130

  # Output layout: line 1 = query (--print-query), line 2 = --expect
  # key, remaining lines = selection.
  pick_query="${out%%$'\n'*}";     out="${out#*$'\n'}"
  pick_key="${out%%$'\n'*}";       pick_selection="${out#*$'\n'}"
  [[ -n "$pick_selection" ]] || exit 130
}

# --- output --------------------------------------------------------

# Split one picker line's hidden tail (after the first \x1f) into the
# global `pick_fields` array on \x1e. Empty fields are preserved. By
# the pick.jq contract pick_fields[-1] is the raw character/emoji.
pick::split_tail() {
  local tail="${1#*$'\x1f'}"
  pick_fields=( "${(@ps:\x1e:)tail}" )
}

# Iterate the selection, calling the picker's `pick_emit_one <line>`
# (which appends to global `result`). Print the result, optionally copy
# it, and record usage (recency) + state (resume) for the selection.
pick::emit_selection() {
  result=""
  local -a sel_ids; sel_ids=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pick_emit_one "$line"
    pick::split_tail "$line"
    sel_ids+=( "$pick_fields[${pick_id_field:-1}]" )
  done <<< "$pick_selection"

  printf '%s\n' "$result"
  if (( ${pick_copy:-0} )); then
    pick::clipboard "$result"
  fi
  pick::record "${pick_query:-}" "${sel_ids[@]}"
  return 0
}

# Persist resume state (query + first selected id) and update the
# recency list (selected ids prepended, deduped, capped). No-ops for
# whichever of pick_state_file / pick_usage_file is unset.
pick::record() {
  emulate -L zsh
  local q=$1; shift
  local -a sel; sel=( "$@" )

  if [[ -n "${pick_state_file:-}" ]]; then
    { print -r -- "$q"; print -r -- "${sel[1]:-}" } >| "$pick_state_file"
  fi

  [[ -n "${pick_usage_file:-}" ]] || return 0
  local -a old new out; local id; local -A seen
  [[ -s "$pick_usage_file" ]] && old=( ${(f)"$(<$pick_usage_file)"} )
  new=( "${sel[@]}" "${old[@]}" )
  for id in "${new[@]}"; do
    [[ -z "$id" ]] && continue
    (( ${+seen[$id]} )) && continue
    seen[$id]=1; out+=( "$id" )
  done
  print -rl -- "${out[@]:0:50}" >| "$pick_usage_file"
  return 0
}
