#!/usr/bin/env zsh
# mux/tmux.zsh — tmux backend of the mux::* shim (migration spec §2/§3).
#
# Phase 1 scope: Detect + Session + Screen groups. The widget/modal
# implementations arrive in Phase 2 (until then mux.zsh renders widgets
# inline under tmux — same UX as the no-mux path). MUX_TMUX_BIN overrides
# the binary (test seam, mirroring ZELLIJ_BIN on the zellij side).

_mux_tx_bin() { print -r -- "${MUX_TMUX_BIN:-tmux}"; }

_mux_tx_available() {
  [[ -n "${TMUX:-}" ]] || return 1
  command -v "$(_mux_tx_bin)" >/dev/null 2>&1
}

# _mux_tx_resolve_session [client_pid] — session of the given CLIENT pid
# (list-clients), or of the current pane when no pid is given. The zellij
# twin needs a ps+lsof unix-socket dance; tmux just asks the server
# (spec §3: "simpler").
_mux_tx_resolve_session() {
  local pid="${1:-}"
  if [[ -z "$pid" ]]; then
    "$(_mux_tx_bin)" display -p '#{session_name}' 2>/dev/null
    return
  fi
  "$(_mux_tx_bin)" list-clients -F '#{client_pid} #{session_name}' 2>/dev/null |
    awk -v p="$pid" '$1==p { $1=""; sub(/^ /,""); print; exit }'
}

# _mux_tx_attached_sessions — sessions with a connected client, one per line
# (contract of zellij_attached_sessions).
_mux_tx_attached_sessions() {
  "$(_mux_tx_bin)" list-sessions -F '#{session_attached} #{session_name}' 2>/dev/null |
    awk '$1>0 { $1=""; sub(/^ /,""); print }'
}

# _mux_tx_client_sessions — "<session>\t<window_id>\t<pane_id>" for every
# WezTerm pane hosting a tmux client (output contract mirrors
# zellij_wezterm_sessions). Mapping: tmux client tty (list-clients) ↔ WezTerm
# pane tty (wezterm cli list). Prints nothing when WezTerm isn't reachable,
# so callers degrade gracefully; WEZTERM_BIN overrides.
_mux_tx_client_sessions() {
  local wez="${WEZTERM_BIN:-/opt/homebrew/bin/wezterm}"
  command -v "$wez" >/dev/null 2>&1 || wez=wezterm
  local clients
  clients=$("$(_mux_tx_bin)" list-clients -F '#{client_tty}	#{session_name}' 2>/dev/null)
  [[ -n "$clients" ]] || return 0
  local tty wid pane ctty sess
  env -u WEZTERM_UNIX_SOCKET -u WEZTERM_PANE "$wez" cli --no-auto-start list --format json 2>/dev/null |
    jq -r '.[] | [(.tty_name // ""), (.window_id|tostring), (.pane_id|tostring)] | @tsv' 2>/dev/null |
    while IFS=$'\t' read -r tty wid pane; do
      [[ -n "$tty" && "$tty" != null ]] || continue
      printf '%s\n' "$clients" | while IFS=$'\t' read -r ctty sess; do
        [[ "$ctty" == "$tty" ]] && printf '%s\t%s\t%s\n' "$sess" "$wid" "$pane"
      done
    done
}

# _mux_tx_dump_screen — full scrollback + screen to stdout (spec §3 Screen).
_mux_tx_dump_screen() { "$(_mux_tx_bin)" capture-pane -p -S - 2>/dev/null; }

# ---------------------------------------------------------------------------
# Phase 2: floating modal paths (display-popup + tmux-modal)
# ---------------------------------------------------------------------------

# NB on blocking: `display-popup -E` can block the issuing client until the
# popup closes, while tmux-modal's --capture writes the FIFO from an EXIT
# trap. Running the popup in the FOREGROUND would deadlock (writer waits for
# a reader that never starts), so the popup is backgrounded and the FIFO read
# is the synchronization point — the same shape as the zellij float.

# _mux_tx_pick_float <pane_w> <pane_h> <header> [pick args...]
# tmux twin of _mux_zj_pick_float: fzf-owns-the-box picker in a borderless
# popup (-B: pty-frame/fzf draw the chrome, matching the zellij pickers),
# result captured through a FIFO.
_mux_tx_pick_float() {
  local pane_w="$1" pane_h="$2" header="$3"
  shift 3
  local -a pick_args=("$@")
  local modal="$HOME/.config/mux/scripts/tmux-modal"
  local picklist="$HOME/.local/libexec/pick-list"

  local tmp fifo
  tmp=$(mktemp "${TMPDIR:-/tmp}/txpick.XXXXXX") || return 1
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/txpick-fifo.XXXXXX")
  if ! mkfifo -m 600 "$fifo" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi

  # Stage rows to a file: the popup child cannot read our stdin pipe.
  cat >"$tmp"

  "$(_mux_tx_bin)" display-popup -E -B -w "$pane_w" -h "$pane_h" \
    -e "COLORTERM=${COLORTERM:-truecolor}" -e "TMUX_PANE=${TMUX_PANE:-}" \
    "$modal" --origin "${TMUX_PANE:-}" --title "$header" --no-chrome --capture "$fifo" \
    -- "$picklist" "${pick_args[@]}" --no-border --height -1 --margin 0,0,0,0 --padding 0,2,0,2 -- "$tmp" \
    >/dev/null 2>&1 &

  local result
  result=$(cat "$fifo")
  rm -f -- "$fifo" "$tmp"

  [[ -n "$result" ]] || return 130
  print -r -- "$result"
}

# _mux_tx_float --type T [--title TITLE] [--pane-width W] [--pane-height H] -- <widget args...>
# tmux twin of _mux_zj_float: sized popup running input-widget, answer via
# FIFO. Geometry parity: the zellij floats are borderless panes whose
# width/height ARE the interior; a tmux popup border eats 2 cells each way,
# so +2 keeps the widgets rendering at identical interior sizes.
_mux_tx_float() {
  local type="line" title="" pane_w="" pane_h="" pane_x="" pane_y=""
  local -a wargs
  while (($#)); do
    case "$1" in
      --type)        type="${2:-line}"; shift 2 ;;
      --title)       title="${2-}"; shift 2 ;;
      --borderless)  shift 2 ;;   # zellij vocabulary; popups always own their border
      --pane-width)  pane_w="${2-}"; shift 2 ;;
      --pane-height) pane_h="${2-}"; shift 2 ;;
      --pane-x)      pane_x="${2-}"; shift 2 ;;
      --pane-y)      pane_y="${2-}"; shift 2 ;;
      --) shift; wargs+=("$@"); break ;;
      *) shift ;;
    esac
  done

  local modal="$HOME/.config/mux/scripts/tmux-modal"
  local widget="$HOME/.local/libexec/input-widget"

  local fifo
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/txinput-fifo.XXXXXX")
  mkfifo -m 600 "$fifo" 2>/dev/null || return 1

  # Same measured-height contract as the zellij float (input-common's
  # --measure); fall back to the per-type defaults.
  local _measured_h=""
  if [[ -n "$pane_w" ]] && [[ "$pane_w" != *% ]]; then
    _measured_h="$(input::"$type" --measure --width "$pane_w" "${wargs[@]}" </dev/null 2>/dev/null)"
  fi
  if [[ "$_measured_h" != <-> ]]; then
    if [[ -n "$pane_h" ]]; then
      _measured_h="$pane_h"
    else
      case "$type" in
        confirm) _measured_h=12 ;;
        line)    _measured_h=12 ;;
        text)    _measured_h=16 ;;
        choose)  _measured_h=14 ;;
        form)    _measured_h=18 ;;
        *)       _measured_h=14 ;;
      esac
    fi
  fi

  local -a geom=(-h $(( _measured_h + 2 )))
  [[ -n "$pane_w" && "$pane_w" != *% ]] && geom+=(-w $(( pane_w + 2 )))
  [[ -n "$pane_w" && "$pane_w" == *% ]] && geom+=(-w "$pane_w")
  [[ -n "$pane_x" ]] && geom+=(-x "$pane_x")
  [[ -n "$pane_y" ]] && geom+=(-y "$pane_y")

  "$(_mux_tx_bin)" display-popup -E "${geom[@]}" \
    -e "COLORTERM=${COLORTERM:-truecolor}" -e "TMUX_PANE=${TMUX_PANE:-}" \
    "$modal" --origin "${TMUX_PANE:-}" --capture "$fifo" \
    -- "$widget" --type "$type" -- "${wargs[@]}" \
    >/dev/null 2>&1 &

  local result
  result=$(cat "$fifo")
  rm -f -- "$fifo"
  [[ -n "$result" ]] || return 130
  print -rn -- "$result"
}
