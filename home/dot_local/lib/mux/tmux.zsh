#!/usr/bin/env zsh
# mux/tmux.zsh — tmux backend of the mux::* shim (migration spec §2/§3).
#
# Phase 1 scope: Detect + Session + Screen groups. The widget/modal
# implementations arrive in Phase 2 (until then mux.zsh renders widgets
# inline under tmux — same UX as the no-mux path). MUX_TMUX_BIN overrides
# the binary (test seam, mirroring ZELLIJ_BIN on the zellij side).

_mux_tx_bin() { print -r -- "${MUX_TMUX_BIN:-tmux}"; }

# _mux_tx_run <tmux args...> — invoke this backend's server. The socket
# override is needed by out-of-session callers such as after-new-session hooks
# on isolated/non-default servers; normal in-session calls inherit $TMUX.
_mux_tx_run() {
  local -a cmd=("${MUX_TMUX_BIN:-tmux}")
  [[ -n "${MUX_TMUX_SOCKET:-}" ]] && cmd+=(-S "$MUX_TMUX_SOCKET")
  "${cmd[@]}" "$@"
}

_mux_tx_available() {
  # $TMUX means we are INSIDE a session. MUX_BACKEND means a caller
  # resolved the backend for us from OUTSIDE one — mux-open does exactly
  # that from WezTerm's GUI, where no session variable exists. Honouring
  # only the former made mux::available disagree with mux::backend, which
  # already honours the pin: term-quick-view then took its "no mux" arm and
  # rendered inline into a terminal nobody was looking at, on BOTH backends
  # (zellij pass, 2026-07-27).
  [[ -n "${TMUX:-}" || "${MUX_BACKEND:-}" == tmux ]] || return 1
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

# _mux_tx_list_sessions — every live session, one name per line. tmux has no
# equivalent of zellij's exited-but-resurrectable sessions, so this is simply
# what is running.
_mux_tx_list_sessions() {
  _mux_tx_run list-sessions -F '#{session_name}' 2>/dev/null
}

# _mux_tx_rename_session <new-name> [target-session] — target omitted means
# the caller's current session. Refresh every attached client so status-right's
# session-name-dependent #() command is rerun immediately.
_mux_tx_rename_session() {
  local new_name="$1" target="${2:-}" client
  local -a t=()
  [[ -n "$target" ]] && t=(-t "=$target")
  _mux_tx_run rename-session "${t[@]}" "$new_name" || return
  for client in "${(@f)$(_mux_tx_run list-clients -t "=$new_name" -F '#{client_tty}' 2>/dev/null)}"; do
    [[ -n "$client" ]] && _mux_tx_run refresh-client -S -t "$client" 2>/dev/null || true
  done
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

# _mux_tx_dump_screen <full> — pane text to stdout (spec §3 Screen).
# full=1 prepends the whole scrollback (-S -); the default is the VIEWPORT
# only, which is what zellij's `dump-screen` has always returned. The two
# backends disagreed here until a consumer (ai-playbook's scrollback capture)
# needed them to mean the same thing.
_mux_tx_dump_screen() {
  local -a hist=()
  [[ "${1:-0}" == 1 ]] && hist=(-S -)
  "$(_mux_tx_bin)" capture-pane -p "${hist[@]}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Phase 6.0: panes / tabs / info (spec §3 Panes+Info, D19)
#
# Argument contract: mux.zsh does ALL flag parsing and hands each backend the
# same normalized positionals, so the two bodies can never disagree about a
# flag's meaning.
# ---------------------------------------------------------------------------

# _mux_tx_split <dir> <size> <name> <close> <cwd> -- <cmd...>
# tmux sizes a split AT CREATION (-l), so there is no resize-convergence loop
# here — the zellij twin needs one because its resize step is coarser than a
# column. <close> is accepted and ignored: remain-on-exit is off by default,
# which IS close-on-exit.
_mux_tx_split() {
  local dir="$1" size="$2" name="$3" close="$4" cwd="$5"
  shift 5
  [[ "${1-}" == "--" ]] && shift

  local -a flags
  case "$dir" in
    right) flags=(-h) ;;
    left)  flags=(-h -b) ;;
    down)  flags=(-v) ;;
    up)    flags=(-v -b) ;;
    *)     flags=(-h) ;;
  esac
  [[ -n "$size" ]] && flags+=(-l "$size")
  [[ -n "$cwd" ]] && flags+=(-c "$cwd")

  local pane
  pane=$("$(_mux_tx_bin)" split-window "${flags[@]}" -P -F '#{pane_id}' \
    ${1+"${(j: :)${(@q)@}}"} 2>/dev/null) || return 1
  # Pane TITLE is tmux's nearest equivalent of a zellij pane name (the border
  # renders it when pane-border-status is on).
  [[ -n "$name" && -n "$pane" ]] &&
    "$(_mux_tx_bin)" select-pane -t "$pane" -T "$name" 2>/dev/null
  print -r -- "$pane"
}

# _mux_tx_popup <width> <height> <title> <cwd> -- <cmd...>
# Geometry vocabulary (both backends): a bare integer is CELLS, an integer
# with % is a percentage. Percentages go through tmux-popup, which owns the
# zellij-viewport parity math (client rows − 2 chrome rows, floored); cells
# need no conversion and go straight to display-popup.
#
# Both forms are deferred to the SERVER with `run-shell -b`: a popup started
# from our own client dies with the caller (yazi runs quick-look as a task
# that exits immediately), and a foreground run-shell + -E popup deadlocks.
_mux_tx_popup() {
  local w="$1" h="$2" title="$3" cwd="$4" session="$5"
  shift 5
  [[ "${1-}" == "--" ]] && shift

  local -a popup_args=(-E -B)
  [[ -n "$session" ]] && popup_args+=(-t "=$session:")
  [[ -n "$title" ]] && popup_args+=(-T "$title")
  [[ -n "$cwd" ]] && popup_args+=(-d "$cwd")
  popup_args+=(-e "COLORTERM=${COLORTERM:-truecolor}")

  # Single-quote everything ((qq), not (q)): the result is re-parsed by the
  # tmux command parser, where a backslash-escaped `=Session:` would not
  # survive but a quoted one does.
  local cmdline="${(j: :)${(@qq)@}}"
  local flags="${(j: :)${(@qq)popup_args}}"
  local line
  if [[ "$w" == *% || "$h" == *% ]]; then
    # Percentages: tmux-popup owns the zellij-viewport parity math.
    local popup="$HOME/.config/mux/scripts/tmux-popup"
    line="${(qq)popup} ${w%\%} ${h%\%} $flags ${(qq)cmdline}"
  else
    line="${(qq)${MUX_TMUX_BIN:-tmux}} display-popup -w $w -h $h $flags ${(qq)cmdline}"
  fi
  # `display-popup -E` exits with the COMMAND's status, and run-shell paints any
  # non-zero one over the client as `… returned N`. 130 is our clean-cancel
  # convention (pick-common; ESC and Ctrl+C both land there), so dismissing a
  # modal papered the pane with an error overlay. Swallow exactly 130 and let
  # every other status through — a popup whose command genuinely broke should
  # still say so, and tmux failures are hard enough to see already.
  # zellij needs none of this: closing a float reports nothing.
  "$(_mux_tx_bin)" run-shell -b "$line || [ \$? -eq 130 ]"
}

# _mux_tx_new_tab <session> <name> <cwd> -- <cmd...>
# A tmux window IS a zellij tab. `-t =NAME:` targets a session by exact name.
_mux_tx_new_tab() {
  local session="$1" name="$2" cwd="$3" singleton="${4:-0}"
  shift 4
  [[ "${1-}" == "--" ]] && shift

  local cmdline=""
  (($#)) && cmdline="${(j: :)${(@q)@}}"

  # Singleton: if a window of this name is already open, replace what it is
  # running and focus it. respawn-window -k keeps the window (and its name,
  # index and any @options) and swaps the command — which is what "reuse the
  # tab" means; a kill-and-create would move it to the end and lose them.
  if (( singleton )) && [[ -n "$name" ]]; then
    local target="=$name"
    [[ -n "$session" ]] && target="=$session:=$name"
    # An ARRAY, not ${session:+-t "…"}: zsh does not word-split a substitution,
    # so that form hands tmux a single argument `-t =Main:` and the lookup
    # fails silently — which reads exactly like "no such window" and stacks a
    # second one (Mode B 2026-07-27).
    local -a wsel=()
    [[ -n "$session" ]] && wsel=(-t "=$session:")
    if "$(_mux_tx_bin)" list-windows "${wsel[@]}" -F '#{window_name}' 2>/dev/null |
         grep -Fxq -- "$name"; then
      "$(_mux_tx_bin)" respawn-window -k -t "$target" ${cmdline:+"$cmdline"} 2>/dev/null || return 1
      "$(_mux_tx_bin)" select-window -t "$target" 2>/dev/null
      return 0
    fi
  fi

  local -a flags
  [[ -n "$session" ]] && flags+=(-t "=$session:")
  [[ -n "$name" ]] && flags+=(-n "$name")
  [[ -n "$cwd" ]] && flags+=(-c "$cwd")
  "$(_mux_tx_bin)" new-window "${flags[@]}" ${cmdline:+"$cmdline"}
}

# _mux_tx_send_text <text> [pane] — pane is a tmux pane id (%N); empty writes
# to the focused pane.
_mux_tx_send_text() {
  local -a target=()
  [[ -n "${2:-}" ]] && target=(-t "$2")
  "$(_mux_tx_bin)" send-keys "${target[@]}" -l -- "$1"
}

# _mux_tx_send_key <neutral-key-name> — the shim's small key vocabulary
# (mux.zsh validates the name; here it is just spelled tmux's way).
_mux_tx_send_key() {
  local key
  case "$1" in
    up) key=Up ;; down) key=Down ;; left) key=Left ;; right) key=Right ;;
    enter) key=Enter ;; s-up) key=S-Up ;; s-down) key=S-Down ;;
    *) return 1 ;;
  esac
  "$(_mux_tx_bin)" send-keys "$key"
}

_mux_tx_current_tab() { "$(_mux_tx_bin)" display -p '#{window_index}' 2>/dev/null; }
_mux_tx_current_tab_name() { "$(_mux_tx_bin)" display -p '#{window_name}' 2>/dev/null; }
_mux_tx_focus_tab() { "$(_mux_tx_bin)" select-window -t ":$1" 2>/dev/null; }
_mux_tx_pane_cwd() { "$(_mux_tx_bin)" display -p '#{pane_current_path}' 2>/dev/null; }
_mux_tx_terminal_size() {
  "$(_mux_tx_bin)" display -p '#{client_width} #{client_height}' 2>/dev/null
}

# _mux_tx_focused_command [client_pid] — foreground command of the active
# pane (of that client's session when a pid is given).
_mux_tx_focused_command() {
  local pid="${1:-}" tty
  if [[ -z "$pid" ]]; then
    "$(_mux_tx_bin)" display -p '#{pane_current_command}' 2>/dev/null
    return
  fi
  tty=$("$(_mux_tx_bin)" list-clients -F '#{client_pid} #{client_tty}' 2>/dev/null |
    awk -v p="$pid" '$1==p { print $2; exit }')
  [[ -n "$tty" ]] || return 1
  "$(_mux_tx_bin)" display -p -c "$tty" '#{pane_current_command}' 2>/dev/null
}

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
