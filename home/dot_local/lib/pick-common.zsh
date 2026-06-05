#!/usr/bin/env zsh
# pick-common.zsh — shared scaffolding for the fzf picker scripts
#                   (pick-glyph, pick-gitmoji, …).
#
# Off-PATH internal library, SOURCED (not executed) by the pickers:
#     source "${PICK_COMMON_LIB:-$HOME/.local/lib/pick-common.zsh}"
#
# It owns the picker "layer 2": everything from an assembled lines
# cache onward — the fzf flag/palette block, border handling, the
# NBSP-terminated key-hint line, running fzf, the --expect key split, the
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
#   * Selector mode  — set `pick_ui[selector_mode]=1` to start in a
#                      browse-only UI. Optional `selector_shortcuts`
#                      adds 1-9 row shortcuts and `selector_nav` adds
#                      j/k movement; slash enters search and ctrl-u
#                      clears/hides search by default.
#   * Insert & stay  — set `pick_stay_binds` (+ `pick_self`): bind keys
#                      that inject the current item without dismissing
#                      the picker, via fzf `execute-silent`. The sink is
#                      the originating zellij pane when PICK_INJECT_PANE
#                      / PICK_INJECT_ZELLIJ are exported (the zellij-
#                      modal embed), else the system clipboard.
#
# Simple picker API:
#   PICK_NAME=pick-host source "$HOME/.local/lib/pick-common.zsh"
#
#   # 1. Start with plain lines. The selected line is printed as-is.
#   grep -Ev '^[[:space:]]*#|^[[:space:]]*$' /etc/hosts | pick::start
#
#   # 2. Structure each line when display and output should differ.
#   #    pick::line takes the complete visible display as arg 1. Remaining
#   #    args become hidden tail fields:
#   #      <visible>\x1f<field1>\x1e<field2>...
#   #    US (\x1f) separates visible text from the hidden tail; RS (\x1e)
#   #    separates fields inside the tail.
#   while read -r ip host _; do
#     [[ -z "$ip" || "$ip" == \#* || -z "$host" ]] && continue
#     pick::line "$host" "$ip"
#   done < /etc/hosts | pick::start --output field:1
#
#   # 3. Use a richer display while keeping fields explicit.
#   #    This shows "host  ip"; field:1 is host, field:2 is ip, and
#   #    --output tail prints "host\x1eip".
#   pick::line "${host}  ${ip}" "$host" "$ip"
#
#   # 4. Configure common UI directly on pick::start.
#   pick::start --header "Pick a host" --hints "󰌑 : open  ·  󱊷 : cancel"
#
#   # Supported pick::start options:
#   #   --output raw|visible|tail|field:N
#   #   --header TEXT, --hints TEXT, --multi, --query TEXT, --height N, --margin SPEC,
#   #   --padding SPEC, --input-border LABEL, --no-border, --no-hints
#   #   --selector, --selector-shortcuts, --selector-nav,
#   #   --selector-hints TEXT, --search-hints TEXT,
#   #   --selector-search-key KEY, --selector-back-key KEY
#   #
#   # --padding follows fzf's geometry. Left/right padding visually occupy
#   # one extra cell on each side to leave room for the input-border gutter;
#   # this remains true when --input-border is 0/none.
#
# Advanced picker contract:
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

pick::default_name() {
  local origin="${funcfiletrace[-1]:-${functrace[-1]:-${ZSH_ARGZERO:-$0}}}"
  origin="${origin%:*}"
  print -r -- "pick::${origin:t:r}"
}

typeset -g __pick_name="${PICK_NAME:-$(pick::default_name)}"

pick::die() { print -ru2 -- "${__pick_name:-pick}: $*"; exit 1; }

pick::need() {
  command -v "$1" >/dev/null 2>&1 || pick::die "$1 not found in PATH${2:+ ($2)}"
}

pick::need fzf

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

# Prefix each line with a selector-mode display field when 1-9 shortcuts
# are enabled. The original line format stays the picker contract:
#   <visible>\x1f<tail>
# fzf receives:
#   <selector-visible>\x1f<search-visible>\x1f<tail>
# and can switch views with change-with-nth(1/2). The picker still
# receives the full wrapped line on accept; pick::split_tail skips the
# extra display field.
pick::selector_wrap() {
  if (( ! ${pick_selector_wrap:-0} )); then
    cat
    return 0
  fi

  local US=$'\x1f'
  local SGR_SHORTCUT=$'\e[38;2;166;173;200m'
  local SGR_RESET=$'\e[0m'
  awk -v us="$US" -v shortcut_sgr="$SGR_SHORTCUT" -v reset_sgr="$SGR_RESET" '
    {
      p = index($0, us)
      if (p) {
        visible = substr($0, 1, p - 1)
        tail = substr($0, p + 1)
      } else {
        visible = $0
        tail = ""
      }
      shortcut = (NR <= 9 ? NR : " ")
      selector = shortcut_sgr shortcut reset_sgr "  " visible
      print selector us visible us tail
    }
  '
}

# The full producer side of the fzf pipeline: recency-ordered cache
# piped through the picker's input filter (source filter, or cat), with
# optional selector-mode display decoration at the end.
pick::feed() {
  local -a input; input=( "${pick_input[@]}" ); (( ${#input} )) || input=( cat )
  pick::ordered_cache "$1" | "${input[@]}" | pick::selector_wrap
}

# Append selector-mode fzf options. This is opt-in so the default picker
# behavior and line contract remain unchanged.
pick::add_selector_mode_binds() {
  (( ${pick_ui[selector_mode]:-0} )) || return 0

  local NBSP=$'\u00a0'
  local selector_hints="${pick_ui[selector_hints]:-${pick_ui[hints]:-}}"
  local search_hints="${pick_ui[search_hints]:-${pick_ui[hints]:-}}"
  local selector_payload="$selector_hints"$'\n'"$NBSP"
  local search_payload="$search_hints"$'\n'"$NBSP"
  local selector_header_action="+change-header(${selector_payload})"
  local search_header_action="+change-header(${search_payload})"
  if (( ${pick_ui[no_hints]:-0} )); then
    selector_header_action=""
    search_header_action=""
  fi
  local search_key="${pick_ui[selector_search_key]:-/}"
  local back_key="${pick_ui[selector_back_key]:-ctrl-u}"
  local -a selector_keys digit_binds
  selector_keys=()
  digit_binds=()

  fzf_args+=( --disabled --no-input )

  if (( ${pick_ui[selector_nav]:-0} )); then
    selector_keys+=( j k )
    fzf_args+=( --bind 'j:down,k:up' )
  fi

  local search_display_action=""
  local selector_display_action=""
  if (( ${pick_ui[selector_shortcuts]:-0} )); then
    pick_selector_wrap=1
    pick_display_fields=2
    local shortcut_count="${pick_ui[selector_shortcut_count]:-9}"
    (( shortcut_count > 9 )) && shortcut_count=9
    local n
    for (( n = 1; n <= shortcut_count; n++ )); do
      selector_keys+=( "$n" )
      digit_binds+=( "${n}:pos(${n})+print()+accept" )
    done
    (( ${#digit_binds} )) && fzf_args+=( --bind "${(j:,:)digit_binds}" )
    search_display_action="+change-with-nth(2)"
    selector_display_action="+change-with-nth(1)"
  fi

  selector_keys+=( "$search_key" )
  local selector_keys_csv="${(j:,:)selector_keys}"

  fzf_args+=(
    --bind "${search_key}:show-input+enable-search+change-query()${search_header_action}${search_display_action}+unbind(${selector_keys_csv})+rebind(${back_key})"
    --bind "${back_key}:change-query()${selector_header_action}${selector_display_action}+rebind(${selector_keys_csv})+unbind(${back_key})+hide-input"
    --bind "start:unbind(${back_key})"
  )
  return 0
}

# --- fzf argument construction ------------------------------------

# Build the standardized fzf argument list into the global `fzf_args`
# from `pick_ui`. Keys (all optional unless noted):
#   height/margin/padding   fzf geometry (defaults 45% / 0,0,0,0). Left/right
#                            padding occupy one extra cell on each side for
#                            the input-border gutter, even when input_border=0.
#   no_border               1 → --no-border, else --border
#   input_border            0/none disables; 1 = rounded; else passthrough
#   multi                   1 → --multi + select-all + 2-line hints
#   query                   seed query (omitted when empty)
#   header                  border title
#   hints                   keybind-hint line (required for a useful UI)
#   selector_hints          selector-mode keybind-hint line
#   search_hints            search-mode keybind-hint line
#   multi_help              2nd hint line w/ multi (has a default)
#   expect                  comma-separated --expect keys
#
# The palette and structural flags are identical across pickers and
# baked in. --print-query is always set so pick::run can capture the
# final query for the resume feature; it's consumed internally and
# never leaks to the picker's stdout. Stay-insert binds (pick_stay_binds)
# are appended last.
pick::build_fzf_args() {
  local NBSP=$'\u00a0'
  typeset -gA pick_ui
  pick_selector_wrap=0
  pick_display_fields=1
  fzf_args=(
    --color=bg:'#1e1e2e'
    --color=bg+:'#313244'
    --color=fg:'#cdd6f4'
    --color=fg+:'regular:#cdd6f4'
    --color=hl:'#f9e2af'
    --color=hl+:'regular:#f9e2af'
    --color=prompt:'#cba6f7'
    --color=pointer:'#f5e0dc'
    --color=marker:'#b4befe'
    --color=info:'#cba6f7'
    --color=gutter:'#1e1e2e'
    --color=header:'#585b70'
    --color=label:'#cba6f7'
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
    --bind 'ctrl-f:page-down'
    --bind 'ctrl-b:page-up'
  )

  [[ -n "${pick_ui[expect]:-}" ]] && fzf_args+=( "--expect=${pick_ui[expect]}" )

  if (( ${pick_ui[no_border]:-0} )); then
    fzf_args+=( --no-border )
  else
    fzf_args+=( --border )
    [[ -n "${pick_ui[header]:-}" ]] && fzf_args+=(
      "--border-label= ${pick_ui[header]} "
      "--border-label-pos=${pick_ui[header_pos]:-2}"
    )
  fi

  case "${pick_ui[input_border]:-1}" in
    0|none) ;;
    1)      fzf_args+=( --input-border ) ;;
    *)      fzf_args+=( "--input-border=${pick_ui[input_border]}" ) ;;
  esac

  local hints="${pick_ui[hints]:-}"
  if (( ${pick_ui[selector_mode]:-0} )); then
    hints="${pick_ui[selector_hints]:-$hints}"
  fi
  local multi_help="${pick_ui[multi_help]:-tab: mark  ·  ^A: select-all}"
  if (( ${pick_ui[multi]:-0} )); then
    fzf_args+=(
      --multi
      --bind 'ctrl-a:select-all'
    )
    (( ${pick_ui[no_hints]:-0} )) || fzf_args+=( --header="$hints"$'\n'"$multi_help"$'\n'"$NBSP" )
  elif (( ! ${pick_ui[no_hints]:-0} )); then
    fzf_args+=( --header="$hints"$'\n'"$NBSP" )
  fi

  pick::add_stay_binds
  pick::add_selector_mode_binds

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
            | awk -v idf="${pick_id_field:-1}" -v want="$pick_resume_id" -v display_fields="${pick_display_fields:-1}" '
                {
                  tail = $0;
                  for (i = 0; i < display_fields; i++) {
                    p = index(tail, "\037");
                    if (!p) { tail = ""; break }
                    tail = substr(tail, p + 1);
                  }
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

# Format one selected line for pick::start. By default the line is printed
# exactly as fzf returned it. Structured picker lines may use US (\x1f) to
# separate the visible display from the hidden tail, and RS (\x1e) to split
# tail fields:
#   <visible>\x1f<field1>\x1e<field2>...
pick::start_format_line() {
  local line="$1" output="$2"
  local US=$'\x1f' RS=$'\x1e'
  local visible tail n i

  for (( i = 1; i < ${pick_display_fields:-1}; i++ )); do
    line="${line#*$US}"
  done

  case "$output" in
    raw)
      if (( ${pick_display_fields:-1} > 1 )) && [[ "$line" == *$US && "${line#*$US}" == "" ]]; then
        print -r -- "${line%%$US*}"
      else
        print -r -- "$line"
      fi
      ;;
    visible)
      print -r -- "${line%%$US*}"
      ;;
    tail)
      if [[ "$line" == *$US* ]]; then
        print -r -- "${line#*$US}"
      else
        print -r -- ""
      fi
      ;;
    field:<->)
      n="${output#field:}"
      if [[ "$line" == *$US* ]]; then
        tail="${line#*$US}"
        local -a fields
        fields=( "${(@ps:\x1e:)tail}" )
        print -r -- "${fields[$n]:-}"
      else
        print -r -- ""
      fi
      ;;
    *)
      pick::die "invalid --output: $output (expected visible, tail, or field:N)"
      ;;
  esac
}

# Emit one structured picker line:
#   <visible>\x1f<field1>\x1e<field2>...
# US (\x1f) separates the display text from the hidden tail; RS (\x1e)
# separates fields inside that tail. Use with `pick::start --output field:N`.
pick::line() {
  local visible="$1"; shift
  local US=$'\x1f' RS=$'\x1e'
  print -r -- "$visible$US${(pj:$RS:)@}"
}

pick::start_missing_arg() {
  pick::die "missing arg for $1"
}

pick::selector_shortcut_count() {
  local source="$1"
  pick::feed "$source" | awk '
    NR >= 9 { print 9; exit }
    END { if (NR < 9) print NR }
  '
}

# High-level picker entrypoint for simple scripts. It builds default UI,
# accepts either stdin or one file argument as input, runs fzf, and prints the
# selected line exactly as fzf returned it unless --output requests US/RS parsing.
pick::start() {
  local output="raw"
  local source="/dev/stdin"
  local tmp_source=""
  typeset -gA pick_ui

  while (( $# > 0 )); do
    case "$1" in
      --output)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        output="$2"; shift 2
        ;;
      --output=*)
        output="${1#--output=}"; shift
        ;;
      --header)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[header]="$2"; shift 2
        ;;
      --header=*)
        pick_ui[header]="${1#--header=}"; shift
        ;;
      --hints)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[hints]="$2"; shift 2
        ;;
      --hints=*)
        pick_ui[hints]="${1#--hints=}"; shift
        ;;
      --multi)
        pick_ui[multi]=1; shift
        ;;
      --query)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[query]="$2"; shift 2
        ;;
      --query=*)
        pick_ui[query]="${1#--query=}"; shift
        ;;
      --height)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[height]="$2"; shift 2
        ;;
      --height=*)
        pick_ui[height]="${1#--height=}"; shift
        ;;
      --margin)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[margin]="$2"; shift 2
        ;;
      --margin=*)
        pick_ui[margin]="${1#--margin=}"; shift
        ;;
      --padding)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[padding]="$2"; shift 2
        ;;
      --padding=*)
        pick_ui[padding]="${1#--padding=}"; shift
        ;;
      --input-border)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[input_border]="$2"; shift 2
        ;;
      --input-border=*)
        pick_ui[input_border]="${1#--input-border=}"; shift
        ;;
      --no-border)
        pick_ui[no_border]=1; shift
        ;;
      --no-hints)
        pick_ui[no_hints]=1; shift
        ;;
      --selector)
        pick_ui[selector_mode]=1; shift
        ;;
      --selector-shortcuts)
        pick_ui[selector_shortcuts]=1; shift
        ;;
      --selector-nav)
        pick_ui[selector_nav]=1; shift
        ;;
      --selector-hints)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[selector_hints]="$2"; shift 2
        ;;
      --selector-hints=*)
        pick_ui[selector_hints]="${1#--selector-hints=}"; shift
        ;;
      --search-hints)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[search_hints]="$2"; shift 2
        ;;
      --search-hints=*)
        pick_ui[search_hints]="${1#--search-hints=}"; shift
        ;;
      --selector-search-key)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[selector_search_key]="$2"; shift 2
        ;;
      --selector-search-key=*)
        pick_ui[selector_search_key]="${1#--selector-search-key=}"; shift
        ;;
      --selector-back-key)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[selector_back_key]="$2"; shift 2
        ;;
      --selector-back-key=*)
        pick_ui[selector_back_key]="${1#--selector-back-key=}"; shift
        ;;
      --)
        shift
        if (( $# > 0 )); then
          source="$1"; shift
        fi
        break
        ;;
      -*)
        pick::die "unknown arg for pick::start: $1"
        ;;
      *)
        source="$1"; shift
        break
        ;;
    esac
  done
  (( $# == 0 )) || pick::die "pick::start accepts at most one input file"

  [[ -n "${pick_ui[hints]:-}" ]] || pick_ui[hints]=$'󰌑 : open  ·  󱊷 : cancel  ·  󰘴 U: clear'
  if [[ -z "${pick_ui[selector_hints]:-}" ]]; then
    local selector_hints_default=$'󰌑 : open  ·  󱊷 : cancel'
    (( ${pick_ui[selector_shortcuts]:-0} )) && selector_hints_default+=$'  ·  1-9: open'
    (( ${pick_ui[selector_nav]:-0} )) && selector_hints_default+=$'  ·  j/k: move'
    selector_hints_default+=$'  ·  /: search'
    pick_ui[selector_hints]="$selector_hints_default"
  fi
  [[ -n "${pick_ui[search_hints]:-}" ]] || pick_ui[search_hints]=$'󰌑 : open  ·  󱊷 : cancel  ·  󰘴 U: clear/back'
  [[ -n "${pick_ui[expect]:-}" ]] || pick_ui[expect]="enter"

  pick_input=( cat )

  if [[ "$source" == "/dev/stdin" ]]; then
    tmp_source="$(mktemp "${TMPDIR:-/tmp}/pick-start.XXXXXX")" || pick::die "could not create temp input"
    trap '[[ -n "${tmp_source:-}" ]] && rm -f -- "$tmp_source"' EXIT INT TERM
    cat > "$tmp_source"
    source="$tmp_source"
  fi

  if (( ${pick_ui[selector_shortcuts]:-0} )); then
    pick_ui[selector_shortcut_count]="$(pick::selector_shortcut_count "$source")"
  fi

  pick::build_fzf_args
  pick::run "$source"

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    pick::start_format_line "$line" "$output"
  done <<< "$pick_selection"

  if [[ -n "$tmp_source" ]]; then
    rm -f -- "$tmp_source"
    trap - EXIT INT TERM
  fi
}

# --- output --------------------------------------------------------

# Split one picker line's hidden tail into the global `pick_fields`
# array on \x1e. Empty fields are preserved. By the pick.jq contract
# pick_fields[-1] is the raw character/emoji. Selector-mode wrapped
# lines have two display fields before the tail; plain lines have one.
pick::split_tail() {
  local tail="${1#*$'\x1f'}"
  local extra_fields=$(( ${pick_display_fields:-1} - 1 ))
  # If a selector-wrapped line is parsed in a fresh process (for example a
  # future --emit helper), pick_display_fields may still be unset. The extra
  # display field is the only place another US separator appears before the
  # RS-delimited tail, so skip it opportunistically.
  if (( extra_fields <= 0 )) && [[ "$tail" == *$'\x1f'* ]]; then
    extra_fields=1
  fi
  local i
  for (( i = 1; i <= extra_fields; i++ )); do
    tail="${tail#*$'\x1f'}"
  done
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
