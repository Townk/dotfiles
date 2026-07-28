#!/usr/bin/env zsh
# mux.zsh — mux-agnostic terminal-multiplexer shim (migration spec §2/§3).
#
# Off-PATH internal library, SOURCED (not executed):
#     source "$HOME/.local/lib/mux.zsh"
#
# Public mux::* API + runtime backend dispatch; zj::* kept as permanent
# aliases (spec §2 — cheap, honors "no loss"). This file replaced
# lib/zellij.zsh as the widget/picker entry point in migration Phase 1;
# zellij.zsh remains as a compat shim sourcing this file, so every existing
# `source ~/.local/lib/zellij.zsh` consumer keeps working unchanged until
# the Phase 6 rewire.
#
# TWO FLAVORS. This one is the full shim: the widget/picker API on top of
# everything in mux-bootstrap.zsh, which holds backend detection and the
# session/screen/pane/tab/info verbs. Sourcing this file therefore gets you
# the whole mux::* surface, exactly as before the split — but it also drags
# in fzf and gum, so a SHELL STARTUP path must source mux-bootstrap.zsh
# instead (pick-common `die`s at source time when fzf is missing, and the
# three *-common libraries cost ~50ms against the bootstrap's ~1.5ms).
# Backend resolution and the mux::backend contract are documented there.
#
# We source pick-common.zsh because the inline pick path IS pick::start;
# input-common gives the input::* inline widgets.

_mux_self="${(%):-%x}"
source "$(dirname "$_mux_self")/mux-bootstrap.zsh"
unset _mux_self

_mux_self="${(%):-%x}"
source "$(dirname "$_mux_self")/pick-common.zsh"
unset _mux_self

_mux_self="${(%):-%x}"
source "$(dirname "$_mux_self")/input-common.zsh"
unset _mux_self

# _mux::widgets_float — true when the current backend renders widgets as
# floating modals (Phase 2: both backends; "none" renders inline).
_mux::widgets_float() { mux::available; }

# Backend-dispatching float primitives (same argv contract both sides).
_mux::float() {
  case "$(mux::backend)" in
    zellij) _mux_zj_float "$@" ;;
    tmux) _mux_tx_float "$@" ;;
    *) return 1 ;;
  esac
}
_mux::pick_float() {
  case "$(mux::backend)" in
    zellij) _mux_zj_pick_float "$@" ;;
    tmux) _mux_tx_pick_float "$@" ;;
    *) return 1 ;;
  esac
}

# mux::pick [pane opts] [pick::start opts...] — read picker rows on stdin,
# print the selection on stdout. Identical contract to pick::start, plus
# optional caller-defined pane geometry:
#
#   --pane-width SPEC / --pane-height SPEC   the floating pane size, a percent
#       ("70%") or an integer cell/row count. Defaults: 70% / 60% (the glyph
#       picker size).
#
#   * Inline (no float backend) -> exactly `pick::start "$@"`; pane opts are
#     ignored.
#   * Zellij -> the fzf UI runs in a floating, pinned, BORDERLESS pane via
#     the shared zellij-modal scaffolding and the chosen value is captured
#     back through a FIFO (see _mux_zj_pick_float).
#
# Caveat: the capture channel returns the *selection*, so --copy-only and the
# insert-without-dismiss background sink are not meaningful through the float
# (their clipboard/cache side effects would land in the pane process, not
# here). Use plain return-value pickers with the floating path.
mux::pick() {
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

  if ! _mux::widgets_float; then
    pick::start "${pick_args[@]}"
    return
  fi

  _mux::pick_float "$pane_w" "$pane_h" "$header" "${pick_args[@]}"
}

# Each public widget: split off --pane-* (consumed by the float backend), keep
# the rest as widget args. Inline backends → the input:: widget. Default
# per-type geometry is supplied here and overridden by any caller --pane-*.
# Title vs content: `--title TEXT` sets the ▓▓▓ header (the dialog title); the
# positional arg is the content (the widget prompt / form title / textarea
# header). When --title is omitted PANE_TITLE is "" — the widget receives no
# header, only the prompt, so the question renders exactly once.
_mux::split_pane_opts() {  # → reply (geom), PANE_TITLE (header), PANE_REST (widget args)
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

# confirm/line/choose: the modal renders the ▓▓▓ header (PANE_TITLE); the
# content (PANE_REST) is the widget/pick prompt. --title is only forwarded when
# non-empty; an omitted --title means no header chrome, only the prompt.
mux::confirm() {
  local -a reply PANE_REST; local PANE_TITLE
  _mux::split_pane_opts "$@"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")
  if ! _mux::widgets_float; then input::confirm "${_topt[@]}" "${PANE_REST[@]}"; return; fi
  local rc=0 ans
  ans=$(_mux::float --type confirm --borderless true --pane-width 54 \
        "${reply[@]}" -- "${_topt[@]}" "${PANE_REST[@]}") || rc=$?
  ((rc == 130)) && return 130
  [[ "$ans" == no ]] && { print -rn -- "no"; return 1; }
  print -rn -- "yes"; return 0
}

mux::line() {
  local -a reply PANE_REST; local PANE_TITLE
  _mux::split_pane_opts "$@"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")
  if ! _mux::widgets_float; then input::line "${_topt[@]}" "${PANE_REST[@]}"; return; fi
  _mux::float --type line --borderless true --pane-width 64 \
    "${reply[@]}" -- "${_topt[@]}" "${PANE_REST[@]}"
}

mux::choose() {
  # Pre-parse --multi and --other before _mux::split_pane_opts so they don't
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
  _mux::split_pane_opts "${_pre_args[@]}"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")

  local -a _extra=()
  (( _multi ))      && _extra+=(--multi)
  [[ -n "$_other" ]] && _extra+=(--other "$_other")

  if ! _mux::widgets_float; then
    input::choose "${_topt[@]}" "${_extra[@]}" "${PANE_REST[@]}"
    return
  fi

  _mux::float --type choose --borderless true "${_topt[@]}" \
    --pane-width 56 \
    "${reply[@]}" -- "${_topt[@]}" "${_extra[@]}" "${PANE_REST[@]}"
}

# text/form: the widget owns its chrome, so the title goes to the widget (not
# the modal) via --title. ai-playbook input / input::form treat an explicit
# --title as authoritative over a positional.
mux::text() {
  local -a reply PANE_REST; local PANE_TITLE
  _mux::split_pane_opts "$@"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")
  if ! _mux::widgets_float; then input::text "${_topt[@]}" "${PANE_REST[@]}"; return; fi
  _mux::float --type text --borderless true --pane-width 57 \
    "${reply[@]}" -- --height 5 "${_topt[@]}" "${PANE_REST[@]}"
}

mux::form() {
  local -a reply PANE_REST; local PANE_TITLE
  _mux::split_pane_opts "$@"
  local -a _topt=(); [[ -n "$PANE_TITLE" ]] && _topt=(--title "$PANE_TITLE")
  if ! _mux::widgets_float; then input::form "${_topt[@]}" "${PANE_REST[@]}"; return; fi
  _mux::float --type form --borderless true --pane-width 64 \
    "${reply[@]}" -- "${_topt[@]}" "${PANE_REST[@]}"
}

# --- zj::* permanent aliases (spec §2) -------------------------------------
zj::available() { [[ "$(mux::backend)" == zellij ]] && _mux_zj_available; }
zj::pick() { mux::pick "$@"; }
zj::confirm() { mux::confirm "$@"; }
zj::line() { mux::line "$@"; }
zj::choose() { mux::choose "$@"; }
zj::text() { mux::text "$@"; }
zj::form() { mux::form "$@"; }
