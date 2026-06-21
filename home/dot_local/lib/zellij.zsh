#!/usr/bin/env zsh
# zellij.zsh — zj::* helpers for driving Zellij from the scripts stdlib.
#
# Off-PATH internal library, SOURCED (not executed):
#     source "$HOME/.local/lib/zellij.zsh"
#
# Today it provides one feature: zj::pick, a drop-in replacement for
# pick::start (the fzf picker engine in pick-common.zsh) that renders the
# picker in a floating Zellij pane — with the same catppuccin chrome as the
# glyph/gitmoji pickers — whenever we're inside a Zellij session, and falls
# back to an ordinary inline picker otherwise. A consumer adopts it by swapping
# `pick::start` for `zj::pick`; nothing else about its call site changes.
#
# We source pick-common.zsh because the no-Zellij path IS pick::start; that in
# turn pulls in the shared base (common.zsh).

_zj_self="${(%):-%x}"
source "$(dirname "$_zj_self")/pick-common.zsh"
unset _zj_self

# input-common gives us the input::* fallbacks for the no-Zellij path.
_zj_self2="${(%):-%x}"
source "$(dirname "$_zj_self2")/input-common.zsh"
unset _zj_self2

# zj::available — true when we're inside a Zellij session AND a zellij binary
# is usable (so we can actually spawn the floating pane). ZELLIJ_BIN overrides
# the lookup; otherwise PATH resolution keeps this portable across the
# homebrew / dev-shell split instead of hardcoding /opt/homebrew.
zj::available() {
  [[ -n "${ZELLIJ:-}" ]] || return 1
  local bin="${ZELLIJ_BIN:-$(command -v zellij 2>/dev/null)}"
  [[ -n "$bin" && -x "$bin" ]]
}

# zj::pick [zj opts] [pick::start opts...] — read picker rows on stdin, print
# the selection on stdout. Identical contract to pick::start, plus optional
# caller-defined pane geometry:
#
#   --pane-width SPEC / --pane-height SPEC   the floating pane size, a percent
#       ("70%") or an integer cell/row count. Both go straight to zellij, which
#       accepts either. Defaults: 70% / 60% (the glyph picker size).
#
#   * No Zellij  -> exactly `pick::start "$@"` (inline, unchanged); pane opts
#                   are ignored.
#   * In Zellij  -> the fzf UI runs in a floating, pinned, rounded-frame pane
#                   via the shared zellij-modal scaffolding (catppuccin title
#                   block + focus-quirk handling), and the chosen value is
#                   captured back here through a FIFO.
#
# The modal title block reuses the picker's own --header text. The float fzf
# geometry (--no-border --height -4 ...) is injected after the caller's options
# so it wins, reproducing the glyph UX without the caller repeating it.
#
# Caveat: the capture channel returns the *selection*, so --copy-only and the
# insert-without-dismiss background sink are not meaningful through the float
# (their clipboard/cache side effects would land in the pane process, not
# here). Use plain return-value pickers with the floating path.
zj::pick() {
  local pane_w="70%" pane_h="60%"
  local header=""
  local -a pick_args=()
  while (($#)); do
    case "$1" in
      --pane-width)
        pane_w="${2:-}"
        shift 2
        ;;
      --pane-width=*)
        pane_w="${1#*=}"
        shift
        ;;
      --pane-height)
        pane_h="${2:-}"
        shift 2
        ;;
      --pane-height=*)
        pane_h="${1#*=}"
        shift
        ;;
      --header)
        header="${2:-}"
        pick_args+=("$1" "${2:-}")
        shift 2
        ;;
      --header=*)
        header="${1#--header=}"
        pick_args+=("$1")
        shift
        ;;
      *)
        pick_args+=("$1")
        shift
        ;;
    esac
  done

  if ! zj::available; then
    pick::start "${pick_args[@]}"
    return
  fi

  local bin="${ZELLIJ_BIN:-$(command -v zellij)}"
  local modal="$HOME/.config/zellij/scripts/zellij-modal"
  local picklist="$HOME/.local/libexec/pick-list"

  local tmp fifo
  tmp=$(mktemp "${TMPDIR:-/tmp}/zjpick.XXXXXX") || return 1
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/zjpick-fifo.XXXXXX")
  if ! mkfifo -m 600 "$fifo" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi

  # Stage the picker rows to a file: the float child is a separate process and
  # cannot read our stdin pipe, so it takes the rows as a file argument.
  cat >"$tmp"

  # NB: `zellij action new-pane` prints the created pane id ("terminal_<n>") to
  # stdout. zj::pick's stdout IS its return channel (a caller does
  # `sel=$(zj::pick ...)`), so that id must be discarded here — otherwise it is
  # prepended to the FIFO selection and the caller receives "terminal_<n>\n<sel>".
  "$bin" action new-pane --floating --close-on-exit \
    --name "" --borderless false --pinned true \
    --width "$pane_w" --height "$pane_h" --cwd "$PWD" \
    -- "$modal" --title "$header" --capture "$fifo" \
    -- "$picklist" "${pick_args[@]}" --no-border --height -4 --margin 0,0,0,0 --padding 0,2,0,2 -- "$tmp" >/dev/null

  # Block until the modal writes the captured selection (exactly as long as the
  # user browses); empty means the user cancelled.
  local result
  result=$(cat "$fifo")
  rm -f -- "$fifo" "$tmp"

  [[ -n "$result" ]] || return 130
  print -r -- "$result"
}

# _zj::float --type T [--title TITLE] [--pane-width W] [--pane-height H]
#            [--pane-x X] [--pane-y Y] -- <input-widget args...>
# Spawn a sized floating modal running input-widget and capture the answer via
# FIFO. Echoes the captured answer on stdout; returns 130 on empty (cancel).
_zj::float() {
  local type="line" title="" borderless="false" pane_w="" pane_h="" pane_x="" pane_y=""
  local -a wargs
  while (($#)); do
    case "$1" in
      --type)        type="${2:-line}"; shift 2 ;;
      --title)       title="${2-}"; shift 2 ;;
      --borderless)  borderless="${2-}"; shift 2 ;;
      --pane-width)  pane_w="${2-}"; shift 2 ;;
      --pane-height) pane_h="${2-}"; shift 2 ;;
      --pane-x)      pane_x="${2-}"; shift 2 ;;
      --pane-y)      pane_y="${2-}"; shift 2 ;;
      --) shift; wargs+=("$@"); break ;;
      *) shift ;;
    esac
  done

  local bin="${ZELLIJ_BIN:-$(command -v zellij)}"
  local modal="$HOME/.config/zellij/scripts/zellij-modal"
  local widget="$HOME/.local/libexec/input-widget"

  local fifo
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/zjinput-fifo.XXXXXX")
  mkfifo -m 600 "$fifo" 2>/dev/null || return 1

  local -a pane_geom=()
  [[ -n "$pane_w" ]] && pane_geom+=(--width "$pane_w")
  [[ -n "$pane_h" ]] && pane_geom+=(--height "$pane_h")
  [[ -n "$pane_x" ]] && pane_geom+=(--x "$pane_x")
  [[ -n "$pane_y" ]] && pane_geom+=(--y "$pane_y")

  local -a modal_args=(--capture "$fifo")
  [[ -n "$title" ]] && modal_args=(--title "$title" "${modal_args[@]}")

  # `zellij action new-pane` does NOT propagate COLORTERM into the spawned pane
  # (it inherits TERM but not COLORTERM), so gum/lipgloss fall back to 256-color
  # and the Catppuccin truecolor hex are approximated — mauve #cba6f7 lands on
  # ~gum's default pink, reading as "unthemed". Carry our own COLORTERM through
  # `env` so the dialog renders true 24-bit color, matching the keybind-spawned
  # quit pane (which inherits COLORTERM). Default to truecolor if we somehow lack
  # it (these are GUI terminals).
  "$bin" action new-pane --floating --close-on-exit \
    --name "" --borderless "$borderless" --pinned true "${pane_geom[@]}" --cwd "$PWD" \
    -- env "COLORTERM=${COLORTERM:-truecolor}" "$modal" "${modal_args[@]}" \
    -- "$widget" --type "$type" -- "${wargs[@]}" >/dev/null

  local result
  result=$(cat "$fifo")
  rm -f -- "$fifo"
  [[ -n "$result" ]] || return 130
  print -rn -- "$result"
}

# Each public drop-in: split off --pane-* (consumed by _zj::float), keep the
# rest as widget args. Off-Zellij → the inline input:: widget. Default per-type
# geometry is supplied here and overridden by any caller --pane-*.
# Title vs content: `--title TEXT` sets the ▓▓▓ header (the dialog title); the
# positional arg is the content (the widget prompt / form title / textarea header).
# When --title is omitted PANE_TITLE is "" — the widget receives no header, only
# the prompt, so the question renders exactly once. _zj::split_pane_opts pulls
# --pane-* into `reply` and --title into PANE_TITLE, leaving content in PANE_REST.
_zj::split_pane_opts() {  # → reply (geom), PANE_TITLE (header), PANE_REST (widget args)
  reply=(); PANE_REST=(); PANE_TITLE=""
  local _ht=0
  while (($#)); do
    case "$1" in
      --pane-width|--pane-height|--pane-x|--pane-y) reply+=("$1" "${2-}"); shift 2 ;;
      --title) PANE_TITLE="${2-}"; _ht=1; shift 2 ;;
      *) PANE_REST+=("$1"); shift ;;
    esac
  done
  # PANE_TITLE is only set when --title was explicitly passed; we no longer default
  # to the first positional so that a no-title call forwards --prompt only (no
  # --title), preventing the question from rendering twice (header AND prompt).
}

# confirm/line/choose: zellij-modal renders the ▓▓▓ header (PANE_TITLE); the
# content (PANE_REST) is the widget/pick prompt. --title is only forwarded when
# non-empty; an omitted --title means no header chrome, only the prompt.
zj::confirm() {
  local -a reply PANE_REST; local PANE_TITLE
  _zj::split_pane_opts "$@"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")
  if ! zj::available; then input::confirm "${_topt[@]}" "${PANE_REST[@]}"; return; fi
  # Height = prompt lines + 11 (border 2 + padding 2 + title/rule 2 + 3 insets +
  # buttons 1 + hint 1), assuming default --padding 1 / --inset 1.
  local -a _cl=("${(@f)PANE_REST[1]}"); local cl=${#_cl}; ((cl < 1)) && cl=1
  local rc=0 ans
  ans=$(_zj::float --type confirm --borderless true --pane-width 54 --pane-height $((cl + 11)) \
        "${reply[@]}" -- "${_topt[@]}" "${PANE_REST[@]}") || rc=$?
  ((rc == 130)) && return 130
  [[ "$ans" == no ]] && { print -rn -- "no"; return 1; }
  print -rn -- "yes"; return 0
}

zj::line() {
  local -a reply PANE_REST; local PANE_TITLE
  _zj::split_pane_opts "$@"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")
  if ! zj::available; then input::line "${_topt[@]}" "${PANE_REST[@]}"; return; fi
  _zj::float --type line --borderless true --pane-width 64 --pane-height 12 \
    "${reply[@]}" -- "${_topt[@]}" "${PANE_REST[@]}"
}

zj::choose() {
  # Pre-parse --multi and --other before _zj::split_pane_opts so they don't
  # corrupt PANE_TITLE (split_pane_opts puts unknown args into PANE_REST).
  local _multi=0 _other="" _skip=0
  local -a _pre_args=()
  local -a _args=("$@")
  local _j
  for (( _j = 1; _j <= ${#_args}; _j++ )); do
    local _a="${_args[$_j]}"
    case "$_a" in
      --multi) _multi=1 ;;
      --other) (( _j++ )); _other="${_args[$_j]:-}" ;;
      *) _pre_args+=("$_a") ;;
    esac
  done

  local -a reply PANE_REST; local PANE_TITLE
  _zj::split_pane_opts "${_pre_args[@]}"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")

  local -a _extra=()
  (( _multi ))      && _extra+=(--multi)
  [[ -n "$_other" ]] && _extra+=(--other "$_other")

  if ! zj::available; then
    input::choose "${_topt[@]}" "${_extra[@]}" "${PANE_REST[@]}"
    return
  fi

  # Count the actual choice items (PANE_REST minus the first positional/prompt).
  local n=0 _i
  for (( _i = 2; _i <= ${#PANE_REST}; _i++ )); do
    case "${PANE_REST[$_i]}" in
      --) ;;
      *) (( n++ )) ;;
    esac
  done
  (( n < 1 )) && n=1
  # Height: min(n,8) visible items + 9 chrome rows (title/rule/prompt/padding/hint)
  local vis=$(( n < 8 ? n : 8 ))
  _zj::float --type choose --borderless true "${_topt[@]}" \
    --pane-width 56 --pane-height $(( vis + 9 )) \
    "${reply[@]}" -- "${_topt[@]}" "${_extra[@]}" "${PANE_REST[@]}"
}

# text/form: the widget owns its chrome, so the title goes to the widget (not the
# modal) via --title. ai-assist-input / input::form treat an explicit --title as
# authoritative over a positional.
zj::text() {
  local -a reply PANE_REST; local PANE_TITLE
  _zj::split_pane_opts "$@"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")
  if ! zj::available; then input::text "${_topt[@]}" "${PANE_REST[@]}"; return; fi
  _zj::float --type text --borderless true --pane-width 57 --pane-height 16 \
    "${reply[@]}" -- --height 5 "${_topt[@]}" "${PANE_REST[@]}"
}

zj::form() {
  local -a reply PANE_REST; local PANE_TITLE
  _zj::split_pane_opts "$@"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")
  if ! zj::available; then input::form "${_topt[@]}" "${PANE_REST[@]}"; return; fi
  _zj::float --type form --borderless true --pane-width 64 --pane-height 18 \
    "${reply[@]}" -- "${_topt[@]}" "${PANE_REST[@]}"
}
