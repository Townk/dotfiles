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
# Each picker keeps "layer 1": acquiring its data and producing its
# colour-formatted lines (via a jq emitter that uses pick.jq's emit_line
# contract, or by streaming straight from SQLite).
#
# Three optional UX features are wired through pick::start flags:
#   * Recency        — `--cache-usage` floats recently-picked rows to the
#                      top on the next launch (most-recent first; cold rows
#                      keep their order). This is the sanctioned file-based
#                      recency for non-DB pickers — pickers should opt in
#                      rather than hand-roll their own (the glyph/gitmoji
#                      pickers are the exception: they record recency in
#                      their SQLite store via --on-items-picked).
#   * Resume         — `--cache-state` saves the final query + cursor
#                      item on exit; a `--resume` launch restores both
#                      (query via --query, cursor via `start:pos(N)`
#                      computed with a `fzf --filter` pass so it's robust
#                      to reordering).
#   * Selector mode  — `--selector` starts in a browse-only UI.
#                      `--selector-shortcuts` adds 1-9 row shortcuts and
#                      `--selector-nav` adds j/k movement; slash enters
#                      search and ctrl-u clears/hides search by default.
#
# Insert-without-dismiss is wired through `--key-background` (see the
# option list below): the sink is the originating zellij pane when
# PICK_INJECT_PANE / PICK_INJECT_ZELLIJ are exported (the zellij-modal
# embed), else the system clipboard.
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
#   # 5. Emit a different column per accept key. Enter uses --output; the
#   #    mapped keys emit their own spec; unmapped keys are ignored so the
#   #    picker stays open. --copy-only sends the result to the clipboard
#   #    instead of stdout.
#   pick::line "$host  $ip" "$host" "$ip" \
#     | pick::start --output field:1 \
#         --key-output ctrl-n:field:2 --copy-only
#
#   # Statefulness is opt-in. Pickers with no backing store get file-based
#   # recency + resume from --cache-usage / --cache-state; DB-backed pickers
#   # record recency themselves via --on-items-picked (e.g. UPDATE last_used):
#   #   ... | pick::start --output field:1 --cache-usage    # float recents
#   #   ... | pick::start --output field:1 \
#   #           --on-items-picked record_recency   # record_recency "$@" = ids
#
#   # Supported pick::start options:
#   #   --output raw|visible|tail|field:N
#   #   --key-output KEY:SPEC (repeatable; SPEC uses the --output grammar; the
#   #     key resolves to SPEC on accept, Enter to --output)
#   #   --multi[=SEP] (allow selecting multiple; SEP joins them on output,
#   #     default newline; e.g. --multi='' to concatenate, --multi=', ' for CSV)
#   #   --copy-only (send the joined result to the clipboard INSTEAD of stdout)
#   #   --field-id=N (which hidden tail field is the recency/cursor id; default 1)
#   #   --cache-usage[=PATH] (opt-in file recency: float recently-picked rows
#   #     to the top and record the pick; default
#   #     ${XDG_CACHE_HOME}/pick/<PICK_NAME>/usage)
#   #   --cache-state[=PATH] (opt-in resume state, restored by --resume;
#   #     default ${XDG_CACHE_HOME}/pick/<PICK_NAME>/laststate)
#   #   --resume (restore saved query + cursor; needs --cache-state)
#   #   --on-items-picked CMD (after accept, run `CMD id...` with the picked ids;
#   #     hook for DB recency and other side effects)
#   #   --key-background KEY:SPEC (repeatable; on KEY, emit SPEC of the current
#   #     row to the sink WITHOUT dismissing the picker — insert-and-stay)
#   #   --on-key-background FUNC (in-process zsh function run with each background
#   #     emission; default sink injects into the zellij pane / clipboard)
#   #   --header TEXT, --hints TEXT, --query TEXT, --height N, --margin SPEC,
#   #   --padding SPEC, --input-border LABEL, --no-border, --no-hints
#   #   --selector, --selector-shortcuts, --selector-nav,
#   #   --selector-hints TEXT, --search-hints TEXT,
#   #   --selector-search-key KEY, --selector-back-key KEY
#   #
#   # --padding follows fzf's geometry. Left/right padding visually occupy
#   # one extra cell on each side to leave room for the input-border gutter;
#   # this remains true when --input-border is 0/none.
#
# Layer-1 helpers for pickers that assemble a cached lines file:
# pick::cache_stale tells the picker whether to rebuild its LINES_CACHE,
# and pick::line emits one structured line in the wire format below.
#
# Wire format is defined in pick.jq — see pick::split_tail for the
# shell side of the same contract.

# --- diagnostics ---------------------------------------------------
# Logging (die), help-token dispatch, and require_cmd come from the shared
# base. Source it relative to THIS file.
_pick_common_self="${(%):-%x}"
source "$(dirname "$_pick_common_self")/common.zsh"
unset _pick_common_self

require_cmd fzf

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

# Echo the first available clipboard-copy command (for the key-background
# clipboard sink), or nothing if none is found.
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
  else die "no clipboard helper found (pbcopy / wl-copy / xclip)"
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

# --- recency sort --------------------------------------------------

# Stream the lines cache to stdout, floating recently-picked items to the top
# (in recency order); "cold" lines keep their original order, so the picker's
# own sort stays the fallback once fzf's --tiebreak=index kicks in. The recency
# id is tail field `pick_id_field` (default 1), matched against the usage file
# (1 id per line, most-recent first) that pick::record maintains.
#
# This is the SANCTIONED file-based recency for non-DB pickers: opt in with
# `pick::start --cache-usage[=PATH]` instead of hand-rolling per-picker recency.
# (DB-backed pickers like glyph/gitmoji are the exception — they record recency
# in their store via --on-items-picked and don't set a usage file.)
pick::recency_order_cache() {
  local cache=$1
  awk -v idf="${pick_id_field:-1}" '
    FNR==NR { rank[$0]=FNR; nu=FNR; next }   # usage file: 1 id/line, most-recent first
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
}

# Float recents when --cache-usage is active and non-empty; else stream as-is.
pick::ordered_cache() {
  local cache=$1
  if [[ -n "${pick_usage_file:-}" && -s "$pick_usage_file" ]]; then
    pick::recency_order_cache "$cache"
  else
    cat -- "$cache"
  fi
}

# The full producer side of the fzf pipeline: the (optionally recency-ordered)
# lines cache piped through the picker's input filter (source filter, or cat),
# with optional selector-mode display decoration at the end.
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
  # In a pty-frame modal the hints live in the (static) footer pty-frame draws,
  # so the selector/search toggle must NOT also push them into fzf's header — that
  # header is the input→list blank, and change-header would surface the old hints
  # there. Suppress the header swaps (like --no-hints) when pty-frame owns the
  # chrome; the display-view swaps below still run. (use_pty_frame is a build_fzf_args
  # local, visible here via zsh's dynamic function scope.)
  if (( ${pick_ui[no_hints]:-0} )) || (( ${use_pty_frame:-0} )); then
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

# --- hint assembly + colorizing -----------------------------------

# pick::hints KEY LABEL [KEY LABEL ...] — assemble a keybind-hint line from
# key/label PAIRS in the canonical "KEY : label" shape, joined by the narrow
# " · " separator. This is THE single place dialog hints are formatted, so every
# picker (glyph, gitmoji, quick-launch, zj::pick consumers) renders identically:
# callers pass structured pairs and never hand-roll separators/spacing. A key may
# be a chord ("󰘴 U", "󰘵 󰌑"); quote it as one arg. pick::colorize_hints then
# paints the keys (key role) and the labels/separators (hint role) for the footer.
pick::hints() {
  local out="" first=1 key label
  while (( $# >= 2 )); do
    key="$1"; label="$2"; shift 2
    (( first )) || out+=" · "
    first=0
    out+="${key} : ${label}"
  done
  print -rn -- "$out"
}

# "#rrggbb" -> a 24-bit set-foreground SGR.
pick::_sgr_fg() {
  local h="${1#\#}"
  printf '\e[38;2;%d;%d;%dm' "$(( 0x${h:0:2} ))" "$(( 0x${h:2:2} ))" "$(( 0x${h:4:2} ))"
}

# Colorize a keybind-hint line for pty-frame's footer: the key chord(s) before
# each ':' in the bright key color, the labels + separators in the hint color.
# Sets only the foreground, so pty-frame's mantle footer background shows through.
# Hints follow the `KEY : label  ·  KEY : label` shape pick::start emits.
pick::colorize_hints() {
  local s="$1"
  [[ -n "$s" ]] || return 0
  local key_sgr lbl_sgr
  key_sgr="$(pick::_sgr_fg "$C_ROLE_UI_KEY")"
  lbl_sgr="$(pick::_sgr_fg "$C_ROLE_UI_HINT")"
  # Split on the middle-dot separator itself (the surrounding spaces stay inside
  # each item), so this is robust to BOTH the wide "  ·  " and the tight " · "
  # separators different pickers use (e.g. the workspace picker's long selector
  # line). Splitting on the spaced form instead would treat such a line as one
  # item and only whiten its first key.
  local -a items; items=( "${(@ps:·:)s}" )
  local out="" first=1 item k l
  for item in "${items[@]}"; do
    (( first )) || out+="${lbl_sgr}·"
    first=0
    if [[ "$item" == *:* ]]; then
      k="${item%%:*}"; l="${item#*:}"
      out+="${key_sgr}${k}${lbl_sgr}:${l}"
    else
      out+="${lbl_sgr}${item}"
    fi
  done
  out+=$'\e[39m'
  print -rn -- "$out"
}

# --- fzf argument construction ------------------------------------

# Build the standardized fzf argument list into the global `fzf_args`
# from `pick_ui`. Keys (all optional unless noted):
#   height/margin/padding   fzf geometry (defaults 45% / 0,0,0,0). Left/right
#                            padding occupy one extra cell on each side for
#                            the input-border gutter, even when input_border=0.
#   no_border               1 → --no-border, else --border
#   input_border            0/none disables; 1 = rounded; else passthrough
#   multi                   1 → --multi + select-all/toggle binds + green check marker
#   query                   seed query (omitted when empty)
#   header                  border title
#   hints                   keybind-hint line (required for a useful UI)
#   selector_hints          selector-mode keybind-hint line
#   search_hints            search-mode keybind-hint line
#   expect                  comma-separated --expect keys
#
# The palette and structural flags are identical across pickers and
# baked in. --print-query is always set so pick::run can capture the
# final query for the resume feature; it's consumed internally and
# never leaks to the picker's stdout.
pick::build_fzf_args() {
  local NBSP=$'\u00a0'
  # Every picker is a mantle dialog — the same neutral dark modal on host and
  # remote alike (mantle is shared across machines under one theme). The remote
  # identity is carried by the window tint and the zj-hud bar, never the dialog.
  local pick_bg="$C_ROLE_UI_DIALOG_BG"  # modal canvas = dialog_bg (mantle)
  typeset -gA pick_ui
  # "fzf owns the box": a borderless zellij modal (zellij-modal --no-chrome)
  # exports ZJ_MODAL_TITLE. fzf then renders the WHOLE modal — full-screen, its
  # own rounded --border as the (mantle) outer box, with "▓▓▓ <title>" on the
  # border label — instead of leaning on a zellij frame + a script title block
  # (zellij can't tint a floating frame's border background per-pane).
  # A borderless zellij modal (zellij-modal --no-chrome) exports ZJ_MODAL_TITLE.
  # Two ways to render it:
  #   * pty-frame (preferred): a tiny compositor draws the outer box + "▓▓▓ title"
  #     + rule and runs fzf in a sub-pty composited inside, so fzf's single header
  #     is free to be the input→list blank — the full dialog spec. fzf draws
  #     borderless and fills the sub-pty inline (--height=100%).
  #   * fallback (no pty-frame on PATH): fzf owns the whole box full-screen, with
  #     the title block on --header --header-first (so no input→list blank).
  local fzf_owns=0 use_pty_frame=0
  local PTY_FRAME="$HOME/.local/libexec/pty-frame"
  if [[ -n "${ZJ_MODAL_TITLE:-}" ]]; then
    fzf_owns=1
    unset 'pick_ui[header]'    # title comes from the chrome/▓▓▓ block, not a border-label
    if [[ -x "$PTY_FRAME" ]]; then
      use_pty_frame=1
      pick_ui[no_border]=1     # pty-frame draws the outer box; fzf is borderless
      pick_ui[height]="100%"   # fzf fills the sub-pty inline
    else
      pick_ui[no_border]=0     # fzf's own --border is the (mantle) outer box
      pick_ui[height]="full"   # full-screen: fill the borderless pane edge-to-edge
    fi
  fi
  typeset -ga pick_finder_prefix; pick_finder_prefix=()  # wraps fzf (pty-frame …  --) in modal mode
  pick_selector_wrap=0
  pick_display_fields=1
  fzf_args=(
    --color=bg:"$pick_bg"
    --color=bg+:"$C_ROLE_UI_SURFACE"
    --color=fg:"$C_ROLE_UI_FG"
    --color=fg+:"regular:$C_ROLE_UI_FG"
    --color=hl:"$C_HEX_YELLOW"
    --color=hl+:"regular:$C_HEX_YELLOW"
    --color=prompt:"$C_ROLE_UI_ACCENT"
    --color=pointer:"$C_ROLE_UI_CURSOR"
    --color=marker:"$C_HEX_LAVENDER"
    --color=info:"$C_ROLE_UI_ACCENT"
    --color=gutter:"$pick_bg"
    # fzf 0.5x+ renders the input/header/list/preview/footer as SEPARATE windows;
    # `bg` only covers the main/list area, so each section bg (and thus its border,
    # label, and separators) must be set too or they fall back to the terminal bg.
    --color=list-bg:"$pick_bg"
    --color=input-bg:"$pick_bg"
    --color=header-bg:"$pick_bg"
    --color=preview-bg:"$pick_bg"
    --color=footer-bg:"$pick_bg"
    --color=header:"$C_ROLE_UI_HINT"
    --color=label:"$C_ROLE_UI_ACCENT"
    --color=spinner:"$C_ROLE_UI_CURSOR"
    --color=border:"$C_ROLE_UI_BORDER"
    --filepath-word
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

  # --height: inline by default; "full" (fzf-owns-the-box modal) omits it so fzf
  # runs full-screen and fills the borderless pane edge-to-edge.
  [[ "${pick_ui[height]:-}" == "full" ]] || fzf_args+=( --height="${pick_ui[height]:-45%}" )

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
  if (( ${pick_ui[multi]:-0} )); then
    fzf_args+=(
      --multi
      --bind 'ctrl-a:select-all'
      # Toggle the marker in place (Tab also moves down; this doesn't).
      --bind 'ctrl-space:toggle'
      # Marked rows get a green check; unmarked rows stay blank in the marker
      # column (fzf has no "unselected marker"). These override the base
      # --marker/--color above since fzf honours the last occurrence.
      --marker=$'\u2713 '
      --color=marker:"$C_HEX_GREEN"
    )
  fi
  # Header/footer.
  #  - normal: the keybind hints are fzf's --header (a single line).
  #  - fzf-owns (borderless modal): the "▓▓▓ <title>" + a ━ rule become the
  #    --header with --header-first, so they sit at the very top like the old
  #    script title block; the hints move to the --footer. Together with the
  #    outer --border and the inner --input-border this reproduces the framed
  #    modal's layout (outer box → title+rule → inner box → list → hints) fully
  #    in fzf, all on the mantle dialog background.
  if (( use_pty_frame )); then
    # pty-frame draws the box + ▓▓▓ title + rule AND the bottom hints (so it owns
    # their padding + per-key coloring). fzf draws only the inside: the input box,
    # the freed --header as the input→list blank, and the list. pick_finder_prefix
    # wraps fzf in pty-frame with the title, theme colors, and colorized hints.
    fzf_args+=(
      # Inner separators (the title rule + this input box border) share the
      # separator color; only the outer box uses the focus border (blue).
      --color=input-border:"$C_ROLE_UI_SEPARATOR"
      --header=' '
      --no-separator
    )
    pick_finder_prefix=(
      "$PTY_FRAME"
      --title        "$ZJ_MODAL_TITLE"
      --bg           "$pick_bg"
      --fg           "$C_ROLE_UI_FG"
      --border-color "$C_ROLE_UI_BORDER_FOCUS"
      --title-color  "$C_ROLE_UI_ACCENT"
      --rule-color   "$C_ROLE_UI_SEPARATOR"
    )
    (( ${pick_ui[no_hints]:-0} )) || pick_finder_prefix+=( --hints "$(pick::colorize_hints "$hints")" )
    pick_finder_prefix+=( -- )
  elif (( fzf_owns )); then
    local _cols
    _cols=$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}')
    [[ -n "$_cols" ]] || _cols="${COLUMNS:-80}"
    # fzf draws the header inside the border and aligns it with the list (past
    # the pointer/gutter), so the usable width is well under the pane width;
    # keep the rule a few cells short so fzf doesn't truncate it with "··".
    local _rw=$(( _cols - 8 )); (( _rw < 1 )) && _rw=1
    local _fill=""
    local _rule="${(l:_rw::━:)_fill}"
    # Outer box = the focus border (blue), like the old active modal frame.
    # Header block (--header-first): a blank line, the accented ▓▓▓ title, the
    # rule. Hints stay in the footer (fzf's one header is spent on the title).
    fzf_args+=(
      --color=border:"$C_ROLE_UI_BORDER_FOCUS"
      --color=input-border:"$C_ROLE_UI_HINT"
      --header=$'\n'"▓▓▓ ${ZJ_MODAL_TITLE}"$'\n'"$_rule"
      --header-first
      --color=header:"$C_ROLE_UI_ACCENT"
    )
    (( ${pick_ui[no_hints]:-0} )) || fzf_args+=( --footer="$hints" --color=footer:"$C_ROLE_UI_HINT" )
  else
    # Single hint line for every mode; --multi folds its keys into the hints
    # (see pick::start's default), so fzf never adds a second header row.
    (( ${pick_ui[no_hints]:-0} )) || fzf_args+=( --header="$hints"$'\n'"$NBSP" )
  fi

  pick::add_selector_mode_binds

  # `if` (not `&&`) so an empty query doesn't make a failing test the
  # last statement and trip the caller's `set -e`.
  if [[ -n "${pick_ui[query]:-}" ]]; then
    fzf_args+=( --query "${pick_ui[query]}" )
  fi

  # --preview CMD: pass straight through to fzf. The command runs in fzf's
  # preview window with fzf's placeholders ({1}, {q}, {n}, ...) available;
  # pick-clipboard uses it to show a clip's full multi-line text by id.
  # Additive: callers that don't pass --preview are unaffected.
  if [[ -n "${pick_ui[preview]:-}" ]]; then
    fzf_args+=( "--preview=${pick_ui[preview]}" )
  fi
  # --preview-window SPEC: fzf preview-window geometry (e.g. "right:40%").
  # Additive; callers that don't pass it get fzf's default.
  if [[ -n "${pick_ui[preview_window]:-}" ]]; then
    fzf_args+=( "--preview-window=${pick_ui[preview_window]}" )
  fi
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
  # In a borderless modal with pty-frame present, pick_finder_prefix is
  # (pty-frame … --) so the run becomes `… | pty-frame … -- fzf "${fzf_args[@]}"`;
  # otherwise it's empty and this is a plain `fzf "${fzf_args[@]}"`.
  out=$(pick::feed "$cache" | "${pick_finder_prefix[@]}" fzf "${fzf_args[@]}") || exit 130

  # Output layout: line 1 = query (--print-query), line 2 = --expect
  # key, remaining lines = selection.
  pick_query="${out%%$'\n'*}";     out="${out#*$'\n'}"
  pick_key="${out%%$'\n'*}";       pick_selection="${out#*$'\n'}"
  # Selector digit shortcuts use fzf's `print()+accept` to move to row N and
  # accept it in one keystroke. With --print-query/--expect, fzf emits one extra
  # empty record before the printed row; drop that transport blank so downstream
  # output parsing sees the selected item itself.
  pick_selection="${pick_selection#$'\n'}"
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
      die "invalid --output: $output (expected visible, tail, or field:N)"
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
  die "missing arg for $1"
}

# Parse one `KEY:OUTPUT` pair for --key-output into the caller's `key_output`
# assoc + `expect_keys` array (zsh dynamic scope makes pick::start's locals
# visible here). Split on the FIRST colon so `ctrl-n:field:2` -> KEY=ctrl-n,
# SPEC=field:2. OUTPUT uses the same grammar as --output.
pick::start_add_key_output() {
  local pair="$1"
  local k="${pair%%:*}" spec="${pair#*:}"
  [[ -n "$k" && "$k" != "$pair" ]] || \
    die "invalid --key-output: $pair (expected KEY:OUTPUT)"
  case "$spec" in
    raw|visible|tail|field:<->) ;;
    *) die "invalid --key-output spec: $spec (expected raw, visible, tail, or field:N)" ;;
  esac
  key_output[$k]="$spec"
  expect_keys+=( "$k" )
}

# --- key-background (insert-without-dismiss via a FIFO broker) -------
#
# fzf's execute-silent runs in a fresh child shell that has none of our
# functions, so a background keypress can't call an in-process hook directly.
# Instead we fork a broker FROM THIS shell (it inherits pick::* + the user's
# hook), and the bind's child only writes "SPEC\tLINE" to a FIFO. The broker
# formats the line with pick::start_format_line and calls the hook — all while
# fzf stays open. Globals pick_background_fifo / pick_background_broker drive teardown.

# Default sink when --on-key-background is omitted: inject the formatted text
# into the originating zellij pane (embed mode) or, failing that, the clipboard.
pick::background_sink() {
  local text=$1
  if [[ -n "${PICK_INJECT_PANE:-}" && -n "${PICK_INJECT_ZELLIJ:-}" ]]; then
    ${(z)PICK_INJECT_ZELLIJ} action write-chars --pane-id "$PICK_INJECT_PANE" -- "$text"
    return 0
  fi
  local clip; clip="$(pick::detect_clip)"
  [[ -n "$clip" ]] && printf '%s' "$text" | ${(z)clip}
  return 0
}

# Stand up the FIFO + reader broker and append one execute-silent bind per
# KEY:SPEC. `hook` is the in-process function to run with each formatted line.
pick::background_setup() {
  local hook="$1"; shift
  local -a binds=( "$@" )
  (( ${#binds[@]} )) || return 0

  pick_background_fifo="$(mktemp -u "${TMPDIR:-/tmp}/pick-background.XXXXXX")"
  mkfifo -m 600 "$pick_background_fifo" || die "could not create background FIFO"

  # The broker is a background subshell of THIS process, so it sees pick::* and
  # $hook. Holding the FIFO open read-write keeps the read loop alive across the
  # transient open/close of each keypress writer (otherwise it would hit EOF).
  {
    local bfd key spec line
    exec {bfd}<>"$pick_background_fifo"
    # FIFO record is KEY\tSPEC\tLINE: the KEY is forwarded to the hook as a
    # 2nd arg so a picker can bind different background keys to different
    # actions (pick-clipboard's ctrl-d delete / ctrl-p pin / ctrl-y copy).
    # Existing hooks read $1 (the formatted value) and ignore the extra arg,
    # so this is backward-compatible.
    while IFS=$'\t' read -r key spec line <&$bfd; do
      "$hook" "$(pick::start_format_line "$line" "$spec")" "$key"
    done
  } &!
  pick_background_broker=$!

  local b key spec
  for b in "${binds[@]}"; do
    key="${b%%:*}"; spec="${b#*:}"
    [[ -n "$key" && "$key" != "$b" ]] || \
      die "invalid --key-background: $b (expected KEY:SPEC)"
    case "$spec" in
      raw|visible|tail|field:<->) ;;
      *) die "invalid --key-background spec: $spec (expected raw, visible, tail, or field:N)" ;;
    esac
    # The child only writes; one small printf is an atomic FIFO write. The FIFO
    # path is single-quoted so a TMPDIR with spaces can't word-split the
    # redirection target in fzf's child shell ({} is already fzf-quoted; spec is
    # a validated token; key is a validated chord). The record is KEY\tSPEC\t{}
    # so the broker can forward the key to the hook (see pick::background_setup).
    # fzf input is newline-delimited, so {} is always one line and each printf is
    # exactly one broker record.
    fzf_args+=( --bind "${key}:execute-silent(printf '%s\t%s\t%s\n' ${key} ${spec} {} >> '${pick_background_fifo}')" )
  done
  return 0
}

pick::background_teardown() {
  [[ -n "${pick_background_broker:-}" ]] && kill "$pick_background_broker" 2>/dev/null
  [[ -n "${pick_background_fifo:-}" ]] && rm -f -- "$pick_background_fifo"
  pick_background_broker=""; pick_background_fifo=""
  return 0
}

pick::selector_shortcut_count() {
  local source="$1"
  pick::feed "$source" | awk '
    NR >= 9 { n = 9; next }
    { n = NR }
    END { print n + 0 }
  '
}

# High-level picker entrypoint for simple scripts. It builds default UI,
# accepts either stdin or one file argument as input, runs fzf, and prints the
# selected line exactly as fzf returned it unless --output requests US/RS
# parsing. --key-output maps accept keys to their own output spec; --multi[=SEP]
# joins a multi-selection (default newline); --copy-only sends the result to the
# clipboard instead of stdout. Statefulness is opt-in: --cache-usage (file
# recency), --cache-state + --resume (file resume), and --on-items-picked CMD
# (a post-accept hook for DB recency etc.). --key-background
# KEY:SPEC + --on-key-background FUNC add insert-without-dismiss (a FIFO broker
# bridges fzf's child-shell binds back to an in-process hook).
pick::start() {
  local output="raw"
  local source="/dev/stdin"
  local tmp_source=""
  local do_copy="${pick_copy:-0}"
  local do_resume=0
  local join_sep=$'\n'
  local on_picked=""
  local on_background=""
  local pick_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/pick/${PICK_NAME:-pick}"
  local -A key_output
  local -a expect_keys
  local -a background_binds
  local -a key_reload_binds
  local reload_cmd=""
  local start_reload=0
  # pick_ui is the global UI scratch read by pick::build_fzf_args et al. Clear it
  # so each pick::start call is self-contained (flags-only): no UI state leaks in
  # from a prior call in the same process.
  typeset -gA pick_ui
  pick_ui=()

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
      --multi=*)
        pick_ui[multi]=1; join_sep="${1#--multi=}"; shift
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
      --key-output)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick::start_add_key_output "$2"; shift 2
        ;;
      --key-output=*)
        pick::start_add_key_output "${1#--key-output=}"; shift
        ;;
      --copy-only)
        do_copy=1; shift
        ;;
      --resume)
        do_resume=1; shift
        ;;
      --field-id)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_id_field="$2"; shift 2
        ;;
      --field-id=*)
        pick_id_field="${1#--field-id=}"; shift
        ;;
      --cache-state)
        pick_state_file="$pick_cache_dir/laststate"; shift
        ;;
      --cache-state=*)
        pick_state_file="${1#--cache-state=}"; shift
        ;;
      --cache-usage)
        pick_usage_file="$pick_cache_dir/usage"; shift
        ;;
      --cache-usage=*)
        pick_usage_file="${1#--cache-usage=}"; shift
        ;;
      --on-items-picked)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        on_picked="$2"; shift 2
        ;;
      --on-items-picked=*)
        on_picked="${1#--on-items-picked=}"; shift
        ;;
      --key-background)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        background_binds+=( "$2" ); shift 2
        ;;
      --key-background=*)
        background_binds+=( "${1#--key-background=}" ); shift
        ;;
      --on-key-background)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        on_background="$2"; shift 2
        ;;
      --on-key-background=*)
        on_background="${1#--on-key-background=}"; shift
        ;;
      --reload-cmd)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        reload_cmd="$2"; shift 2
        ;;
      --reload-cmd=*)
        reload_cmd="${1#--reload-cmd=}"; shift
        ;;
      --key-reload)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        key_reload_binds+=( "$2" ); shift 2
        ;;
      --key-reload=*)
        key_reload_binds+=( "${1#--key-reload=}" ); shift
        ;;
      --start-reload)
        start_reload=1; shift
        ;;
      --preview)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[preview]="$2"; shift 2
        ;;
      --preview=*)
        pick_ui[preview]="${1#--preview=}"; shift
        ;;
      --preview-window)
        [[ $# -ge 2 ]] || pick::start_missing_arg "$1"
        pick_ui[preview_window]="$2"; shift 2
        ;;
      --preview-window=*)
        pick_ui[preview_window]="${1#--preview-window=}"; shift
        ;;
      --)
        shift
        if (( $# > 0 )); then
          source="$1"; shift
        fi
        break
        ;;
      -*)
        die "unknown arg for pick::start: $1"
        ;;
      *)
        source="$1"; shift
        break
        ;;
    esac
  done
  (( $# == 0 )) || die "pick::start accepts at most one input file"

  # Opt-in file state: --cache-state (resume) and --cache-usage (recency) are
  # written by pick::record; make sure their parent dirs exist first.
  if [[ -n "${pick_state_file:-}" ]]; then mkdir -p -- "${pick_state_file:h}" 2>/dev/null || true; fi
  if [[ -n "${pick_usage_file:-}" ]]; then mkdir -p -- "${pick_usage_file:h}" 2>/dev/null || true; fi

  # Default hint lines are assembled from structured key/label pairs via
  # pick::hints, so spacing/separators are identical across every dialog.
  if [[ -z "${pick_ui[hints]:-}" ]]; then
    local -a hb=( 󰌑 open 󱊷 cancel "󰘴 U" clear )
    (( ${pick_ui[multi]:-0} )) && hb+=( "󰘴 󱁐" select ⭾ select-and-next "󰘴 A" select-all )
    pick_ui[hints]="$(pick::hints "${hb[@]}")"
  fi
  if [[ -z "${pick_ui[selector_hints]:-}" ]]; then
    local -a sb=( 󰌑 open 󱊷 cancel )
    (( ${pick_ui[selector_shortcuts]:-0} )) && sb+=( 1-9 open )
    (( ${pick_ui[selector_nav]:-0} )) && sb+=( j/k move )
    sb+=( / search )
    pick_ui[selector_hints]="$(pick::hints "${sb[@]}")"
  fi
  [[ -n "${pick_ui[search_hints]:-}" ]] || pick_ui[search_hints]="$(pick::hints 󰌑 open 󱊷 cancel "󰘴 U" clear/back)"

  case "$output" in
    raw|visible|tail|field:<->) ;;
    *) die "invalid --output: $output (expected raw, visible, tail, or field:N)" ;;
  esac

  # `enter` always rides in --expect so pick::run's 3-line parse (query, key,
  # selection) stays valid. Enter then resolves to the default --output;
  # each --key-output key adds to the list and resolves to its own spec.
  local -a _expect; _expect=( enter "${(@)expect_keys:#enter}" )
  pick_ui[expect]="${(j:,:)_expect}"

  # --resume: restore the saved query before building args (cursor position is
  # restored after the source is materialized, via pick::resume_pos).
  if (( do_resume )); then
    pick::load_state
    [[ -z "${pick_ui[query]:-}" && -n "${pick_resume_query:-}" ]] && \
      pick_ui[query]="$pick_resume_query"
  fi

  pick_input=( cat )

  if [[ "$source" == "/dev/stdin" ]]; then
    tmp_source="$(mktemp "${TMPDIR:-/tmp}/pick-start.XXXXXX")" || die "could not create temp input"
    trap '[[ -n "${tmp_source:-}" ]] && rm -f -- "$tmp_source"' EXIT INT TERM
    cat > "$tmp_source"
    source="$tmp_source"
  fi

  if (( ${pick_ui[selector_shortcuts]:-0} )); then
    pick_ui[selector_shortcut_count]="$(pick::selector_shortcut_count "$source")"
  fi

  pick::build_fzf_args
  if (( do_resume )); then
    pick::resume_pos "$source"
  fi

  # --key-background: stand up the FIFO broker + binds, and ensure the broker and
  # FIFO are reaped on cancel (pick::run does `exit 130`) as well as normal
  # return. The trap also preserves the tmp_source cleanup.
  if (( ${#background_binds[@]} )); then
    [[ -n "$on_background" ]] || on_background="pick::background_sink"
    pick::background_setup "$on_background" "${background_binds[@]}"
    trap 'pick::background_teardown; [[ -n "${tmp_source:-}" ]] && rm -f -- "${tmp_source}"' EXIT INT TERM
  fi

  # --key-reload: binds that run a command AND reload the list (e.g. delete or
  # pin a row, then refresh). The command runs in fzf's child shell with fzf
  # placeholders available ({2} = the 2nd \x1f field = the id here); reload
  # re-runs --reload-cmd to re-stream the rows. execute-silent + reload chain
  # so the picker stays open with a refreshed list. Requires --reload-cmd.
  if (( ${#key_reload_binds[@]} )) && [[ -n "$reload_cmd" ]]; then
    local kr key cmd
    for kr in "${key_reload_binds[@]}"; do
      key="${kr%%:*}"; cmd="${kr#*:}"
      [[ -n "$key" && "$key" != "$kr" ]] || die "invalid --key-reload: $kr (expected KEY:CMD)"
      fzf_args+=( --bind "${key}:execute-silent(${cmd})+reload(${reload_cmd})" )
    done
  fi

  # --start-reload: load the list at fzf start via `start:reload(reload-cmd)`,
  # so the emit command runs with FZF_COLUMNS/FZF_LINES set (exact pane size)
  # instead of the guessed tput-cols width used for the initial stdin stream.
  if (( start_reload )) && [[ -n "$reload_cmd" ]]; then
    fzf_args+=( --bind "start:reload(${reload_cmd})" )
  fi

  pick::run "$source"

  # Resolve the output spec for this acceptance: a mapped --key-output key
  # uses its spec; Enter (key "enter") or any unmapped key uses --output.
  local sel_output="$output"
  if [[ -n "${pick_key:-}" && "$pick_key" != enter && -n "${key_output[$pick_key]:-}" ]]; then
    sel_output="${key_output[$pick_key]}"
  fi

  # A multi-selection is joined with join_sep (the --multi[=SEP] separator,
  # default newline) into a single result. --copy-only then sends that result to
  # the clipboard INSTEAD of stdout; otherwise it's printed (with one trailing
  # newline). Either way, the picked ids are recorded (file recency/resume and/or
  # the on-items-picked hook).
  local line formatted result="" first=1
  local -a sel_ids
  # Harvest the id field (field --field-id) when any consumer wants it: the
  # resume-state recorder or the on-items-picked hook.
  local collect_ids=0
  if [[ -n "${pick_state_file:-}" || -n "${pick_usage_file:-}" || -n "$on_picked" ]]; then
    collect_ids=1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    formatted="$(pick::start_format_line "$line" "$sel_output")"
    if (( first )); then
      result="$formatted"; first=0
    else
      result+="${join_sep}${formatted}"
    fi
    if (( collect_ids )); then
      pick::split_tail "$line"
      sel_ids+=( "${pick_fields[${pick_id_field:-1}]:-}" )
    fi
  done <<< "$pick_selection"

  if (( do_copy )); then
    pick::clipboard "$result"   # printf %s — no trailing newline
  else
    print -r -- "$result"       # one trailing newline
  fi
  # File write-back for non-DB pickers: resume (--cache-state) and/or recency
  # (--cache-usage). pick::record persists whichever file is configured.
  if [[ -n "${pick_state_file:-}" || -n "${pick_usage_file:-}" ]]; then
    pick::record "${pick_query:-}" "${sel_ids[@]}"
  fi
  # on-items-picked hook: hand the picked ids to the caller (e.g. a DB picker
  # recording recency via UPDATE last_used). Runs once with all picked ids.
  if [[ -n "$on_picked" ]]; then
    "$on_picked" "${sel_ids[@]}"
  fi

  pick::background_teardown
  if [[ -n "$tmp_source" ]]; then
    rm -f -- "$tmp_source"
  fi
  trap - EXIT INT TERM
}

# --- output --------------------------------------------------------

# Split one picker line's hidden tail into the global `pick_fields`
# array on \x1e. Empty fields are preserved. By the pick.jq contract
# pick_fields[-1] is the raw character/emoji. Selector-mode wrapped
# lines have two display fields before the tail; plain lines have one.
pick::split_tail() {
  local tail="${1#*$'\x1f'}"
  local extra_fields=$(( ${pick_display_fields:-1} - 1 ))
  # If a selector-wrapped line is parsed where pick_display_fields is still
  # unset, the extra display field is the only place another US separator
  # appears before the RS-delimited tail, so skip it opportunistically.
  if (( extra_fields <= 0 )) && [[ "$tail" == *$'\x1f'* ]]; then
    extra_fields=1
  fi
  local i
  for (( i = 1; i <= extra_fields; i++ )); do
    tail="${tail#*$'\x1f'}"
  done
  pick_fields=( "${(@ps:\x1e:)tail}" )
}

# Persist opt-in file state from a pick: resume (query + first selected id,
# --cache-state) and/or recency (picked ids floated to the front of the usage
# list, deduped, capped, --cache-usage). No-op for whichever file is unset.
pick::record() {
  emulate -L zsh
  local q=$1; shift
  local -a sel; sel=( "$@" )

  if [[ -n "${pick_state_file:-}" ]]; then
    { print -r -- "$q"; print -r -- "${sel[1]:-}" } >| "$pick_state_file"
  fi

  [[ -n "${pick_usage_file:-}" ]] || return 0
  # Prepend the just-picked ids, drop duplicates (keeping the newest position),
  # and keep the most-recent 50 so the usage file can't grow without bound.
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
