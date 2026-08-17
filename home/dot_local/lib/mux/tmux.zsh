#!/usr/bin/env zsh
# mux/tmux.zsh — tmux backend of the mux::* shim (migration spec §2/§3).
#
# Phase 1 scope: Detect + Session + Screen groups. The widget/modal
# implementations arrive in Phase 2 (until then mux.zsh renders widgets
# inline under tmux — same UX as the no-mux path). MUX_TMUX_BIN overrides
# the binary (test seam, mirroring ZELLIJ_BIN on the zellij side).

# _mux_tx_bin — the tmux binary, or non-zero when there is none. $PATH first,
# then the known install locations: .zshrc's autostart calls this BEFORE it
# extends $PATH and before mise activates (both happen further down the file),
# so at that point a login $PATH may not carry tmux at all. In-session callers
# hit the $PATH branch and never walk the list.
_mux_tx_bin() {
  [[ -n "${MUX_TMUX_BIN:-}" ]] && { print -r -- "$MUX_TMUX_BIN"; return; }
  local b
  b=$(command -v tmux 2>/dev/null) && { print -r -- "$b"; return; }
  for b in /opt/homebrew/bin/tmux /usr/local/bin/tmux \
    "$HOME/.local/share/mise/shims/tmux" "$HOME/.local/bin/tmux" /usr/bin/tmux; do
    [[ -x "$b" ]] && { print -r -- "$b"; return; }
  done
  return 1
}

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

# --- autostart halves (spec §2, D17) ---------------------------------------
# tmux tears a session down as soon as its last process exits, so there is no
# EXITED record to sweep the way zellij needs — has-session is the entire
# liveness test. `-t=` anchors an exact match; a bare `-t Main` prefix-matches,
# so a session called "Main2" would answer for "Main".

_mux_tx_session_state() {
  local name="$1" bin
  bin="$(_mux_tx_bin)" || return 1
  "$bin" has-session -t="$name" 2>/dev/null || { print -r -- missing; return; }
  if "$bin" list-clients -t="$name" 2>/dev/null | grep -q .; then
    print -r -- busy
  else
    print -r -- idle
  fi
}

_mux_tx_exec_attach() {
  local bin
  bin="$(_mux_tx_bin)" || return 1
  exec "$bin" attach-session -t="$1"
}

_mux_tx_exec_new() {
  local bin
  bin="$(_mux_tx_bin)" || return 1
  exec "$bin" new-session -s "$1"
}

_mux_tx_exec_anonymous() {
  local bin
  bin="$(_mux_tx_bin)" || return 1
  exec "$bin" new-session
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

# _mux_tx_kill_session <name> — `=` anchors an exact match, so killing "Main"
# cannot take "Main2" with it. No resurrectable record to sweep afterwards:
# tmux drops the session the moment it dies.
_mux_tx_kill_session() {
  _mux_tx_run kill-session -t "=$1" 2>/dev/null
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
# so callers degrade gracefully; the pane probe is mux::wezterm_panes.
_mux_tx_client_sessions() {
  local clients
  clients=$("$(_mux_tx_bin)" list-clients -F '#{client_tty}	#{session_name}' 2>/dev/null)
  [[ -n "$clients" ]] || return 0
  local tty wid pane ctty sess
  mux::wezterm_panes |
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

# _mux_tx_pane_count — panes across every window of the session (-s), the
# twin of _mux_zj_pane_count. awk rather than `wc -l` because wc pads its
# output with leading blanks on BSD, and the caller compares the result
# numerically. No output at all (no server, not in a session) reads as 0.
_mux_tx_pane_count() {
  "$(_mux_tx_bin)" list-panes -s -F '#{pane_id}' 2>/dev/null | awk 'END { print NR }'
}
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
# popup (-B: troupe frame/fzf draw the chrome, matching the zellij pickers),
# result captured through a FIFO.
_mux_tx_pick_float() {
  local pane_w="$1" pane_h="$2" header="$3"
  shift 3
  local -a pick_args=("$@")
  local modal="$HOME/.config/mux/scripts/tmux-modal"
  local picklist="$HOME/.local/libexec/pick-list"

  local tmp fifo out
  tmp=$(mktemp "${TMPDIR:-/tmp}/txpick.XXXXXX") || return 1
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/txpick-fifo.XXXXXX")
  if ! mkfifo -m 600 "$fifo" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/txpick-out.XXXXXX") || { rm -f -- "$tmp" "$fifo"; return 1; }
  # Clean up on an interrupt mid-run, when these locals are still in scope. (An
  # EXIT trap is no help here: these float helpers are always called inside a
  # `$(...)`, so an EXIT trap fires only when that command substitution exits —
  # after the function has returned and its locals are gone. Each return path
  # below therefore removes the temps explicitly.)
  trap 'rm -f -- "$fifo" "$tmp" "$out"' INT TERM

  # Stage rows to a file: the popup child cannot read our stdin pipe.
  cat >"$tmp"

  # HI-7: the popup MUST be backgrounded (display-popup -E blocks until the
  # popup closes, and the modal only writes the capture FIFO once a reader has
  # opened it), so the read runs concurrently in a background reader while we
  # wait on the popup. If the popup fails to launch (no client, a client that
  # already owns a popup, …) no writer ever opens the FIFO; without the wait,
  # `cat "$fifo"` would block on open(2) forever and leak these temps.
  cat "$fifo" >"$out" 2>/dev/null &
  local reader_pid=$!

  "$(_mux_tx_bin)" display-popup -E -B -w "$pane_w" -h "$pane_h" \
    -e "COLORTERM=${COLORTERM:-truecolor}" -e "TMUX_PANE=${TMUX_PANE:-}" \
    "$modal" --origin "${TMUX_PANE:-}" --title "$header" --no-chrome --capture "$fifo" \
    -- "$picklist" "${pick_args[@]}" --no-border --height -1 --margin 0,0,0,0 --padding 0,2,0,2 -- "$tmp" \
    >/dev/null 2>&1 &
  local popup_pid=$!

  wait "$popup_pid"
  local rc=$?
  if (( rc != 0 )); then
    # Launch failed: no writer will ever come, so unblock and reap the reader.
    kill "$reader_pid" 2>/dev/null
    wait "$reader_pid" 2>/dev/null
    rm -f -- "$fifo" "$tmp" "$out"
    return "$rc"
  fi
  wait "$reader_pid"

  local result
  result=$(cat "$out")
  rm -f -- "$fifo" "$tmp" "$out"

  [[ -n "$result" ]] || return 130
  print -r -- "$result"
}

# _mux_tx_float --type T [--title TITLE] [--pane-width W] [--pane-height H] -- <widget args...>
# tmux twin of _mux_zj_float: sized popup running input-widget, answer via
# FIFO. Geometry parity: the zellij floats are borderless panes whose
# width/height ARE the interior; a tmux popup's DEFAULT frame eats 2 cells
# each way, so +2 keeps the widgets rendering at identical interior sizes —
# but that padding only applies when a border is actually drawn. --borderless
# true (-B below) makes the popup ITSELF the pane with no frame to eat cells,
# same as the zellij twin, so the +2 must not apply then either: pinning it
# unconditionally handed the widget's own self-drawn box (e.g. troupe jobs'
# ▓▓▓ frame) a pty 2 rows/cols larger than its content, a visible empty gap
# band around it (ledgered latent, surfaced live under the Ctrl+C confirm).
_mux_tx_float() {
  local type="line" title="" pane_w="" pane_h="" pane_x="" pane_y="" borderless=""
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

  local modal="$HOME/.config/mux/scripts/tmux-modal"
  local widget="$HOME/.local/libexec/input-widget"

  local fifo out
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/txinput-fifo.XXXXXX")
  mkfifo -m 600 "$fifo" 2>/dev/null || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/txinput-out.XXXXXX") || { rm -f -- "$fifo"; return 1; }
  # See _mux_tx_pick_float: EXIT traps don't fire until the enclosing `$(...)`
  # ends, so clean up explicitly on each return and trap only INT/TERM.
  trap 'rm -f -- "$fifo" "$out"' INT TERM

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

  # The +2 padding compensates for display-popup's own default border — it
  # must NOT apply when --borderless true asks for no frame at all (see the
  # doc comment above): pad is 2 for the normal framed popup, 0 borderless.
  local pad=2
  [[ "$borderless" == true ]] && pad=0

  local -a geom=(-h $(( _measured_h + pad )))
  # --borderless true (the widget wrappers pass it; zellij vocabulary for
  # "the pane draws no frame"): on tmux the popup IS the pane, so honor it
  # with -B — the widget's own box is then the single frame, matching the
  # zellij float exactly. Discarding it stacked the themed popup border
  # AROUND the widget's box: the double-border caught live in Mode B.
  [[ "$borderless" == true ]] && geom+=(-B)
  [[ -n "$pane_w" && "$pane_w" != *% ]] && geom+=(-w $(( pane_w + pad )))
  [[ -n "$pane_w" && "$pane_w" == *% ]] && geom+=(-w "$pane_w")
  [[ -n "$pane_x" ]] && geom+=(-x "$pane_x")
  [[ -n "$pane_y" ]] && geom+=(-y "$pane_y")

  # Mirror the zellij twin (_mux_zj_float): forward --title to tmux-modal so it
  # renders the ▓▓▓ header block; omit it entirely when no title was given so no
  # empty --title reaches the modal.
  local -a modal_args=(--capture "$fifo")
  [[ -n "$title" ]] && modal_args=(--title "$title" "${modal_args[@]}")

  # HI-7: read concurrently via a background reader and wait on the popup, so a
  # failed launch returns promptly instead of blocking forever on `cat "$fifo"`
  # (see _mux_tx_pick_float for the full rationale).
  cat "$fifo" >"$out" 2>/dev/null &
  local reader_pid=$!

  "$(_mux_tx_bin)" display-popup -E "${geom[@]}" \
    -e "COLORTERM=${COLORTERM:-truecolor}" -e "TMUX_PANE=${TMUX_PANE:-}" \
    "$modal" --origin "${TMUX_PANE:-}" "${modal_args[@]}" \
    -- "$widget" --type "$type" -- "${wargs[@]}" \
    >/dev/null 2>&1 &
  local popup_pid=$!

  wait "$popup_pid"
  local rc=$?
  if (( rc != 0 )); then
    kill "$reader_pid" 2>/dev/null
    wait "$reader_pid" 2>/dev/null
    rm -f -- "$fifo" "$out"
    return "$rc"
  fi
  wait "$reader_pid"

  local result
  result=$(cat "$out")
  rm -f -- "$fifo" "$out"
  [[ -n "$result" ]] || return 130
  print -rn -- "$result"
}

# ---------------------------------------------------------------------------
# job-runner design §6 rev 4 (2026-08-16): the floating-PANE host.
#
# tmux 3.7b's `new-pane` (upstream #5135) makes a REAL pane — floating,
# independently sized/positioned (-x/-y/-X/-Y), but a genuine pane: it
# survives a tab/window switch (unlike a popup, which is client-level and
# dies with the client's modal state) and resize-pane works on it LIVE, no
# relaunch. This is upstream-evolving (still marked so at 3.7b), so per the
# spec every `new-pane` call in this tree lives in EXACTLY the one function
# below — nothing else may call it.
#
# Verified live on a scratch socket (`tmux -L jobtest new-session -d -x 200
# -y 50`; never the real session — see the repo's "never probe the live
# server" rule) before writing this — including a re-verification pass for
# the centered-placement fix below (geometry audit, 2026-08-16 — the
# original top-right placement was a controller-spec error, corrected to
# centered before this landed):
#   - `new-pane -x 57 -y 15 -X 71 -Y 17 -P -F '#{pane_id}'` (71/17 ==
#     `(200-57)/2`/`(50-15)/2`, zsh integer truncation) returns the new
#     pane's id immediately (does NOT block on the wrapped command, unlike
#     `display-popup -E`) and the pane reports `pane_floating_flag` 1, and
#     `list-panes -F '#{pane_width} #{pane_left} #{pane_top}'` echoes back
#     exactly `57 71 17` — `-x`/`-y` size, `-X`/`-Y` position, no mixup, and
#     tmux applies the requested geometry verbatim (no auto-clamping of
#     either the size or the position).
#   - This box's scratch socket has no attached client (`display -p
#     '#{client_width}'`/`'#{client_height}'` both return empty on a
#     client-less session), so the centering math itself only exercises
#     this function's own `[[ "$cw" == <-> && "$ch" == <-> ]]` fallback-to-0
#     guard here, not the real division — the geometry math is pinned by
#     the argv-capturing spec in tests/mux_float_launch_spec.sh instead
#     (STUB_CLIENT_WIDTH/STUB_CLIENT_HEIGHT), and the pane's own on-screen
#     border rendering could not be visually confirmed from this socket
#     either way (no attached client to render it for).
#   - Close-on-exit is tmux's DEFAULT for new-pane (no -k): a pane running a
#     command that exits at once is gone from `list-panes` moments later.
#   - Omitting -d makes the new pane the client's ACTIVE pane at once
#     (`pane_active` 1) — "foreground focus" needs no extra flag.
#   - `$TMUX_PANE` READ FROM INSIDE the new pane's own command resolves to
#     THAT pane's id (not the caller's) — confirmed by a command that wrote
#     `$TMUX_PANE` to a file from inside the float. This is what makes
#     `TROUPE_RESIZE_CMD='tmux resize-pane -t "$TMUX_PANE" -y %h'` work
#     without the launcher needing to inject the id after the fact.
#   - `resize-pane -t <pane_id> -y <n>` on a floating pane resizes it live,
#     in place, with no flicker/relaunch — the whole premise of hosting the
#     dashboard this way instead of through a popup.
#
# Border styling (job-runner design §6 rev 4, pane-styling item): `new-pane`
# takes `-S active-border-style -R inactive-border-style` to override the
# border THIS pane draws with, but this function passes neither. custom-
# builds/theme/templates/tmux-theme.conf.tmpl already sets the SERVER-WIDE
# `pane-border-style`/`pane-active-border-style` from the theme's
# ui.border_inactive/ui.border_focus (lines ~84-85), and per `new-pane`'s
# own man page ("-S sets the border style when the pane is active and -R
# sets the border style when the pane is inactive") those two flags are
# PER-PANE OVERRIDES of exactly those global options — every pane, floating
# or split, already inherits the live global style when -S/-R are omitted.
# Querying `show-options -g pane-active-border-style` here and re-passing it
# as a literal -S value would (a) duplicate a value tmux already applies for
# free, (b) freeze a one-time snapshot that goes stale if the theme
# reloads live (`tmux source-file` on the rendered conf), and (c) still
# route through this shell layer rather than the theme silo's own
# rendering — no cleaner than the default. Left at the default deliberately;
# no hex, literal or queried, is hardcoded here.

# _mux_tx_has_float_pane — capability probe: does the resolved tmux binary
# understand `new-pane` at all (3.7b+)? `list-commands` enumerates every
# command name the running server/binary supports; match the line ANCHORED
# at the command name (not a bare substring) so nothing else can false-
# positive. Cached per call site (module-global, one probe per process) —
# job::watch's host-selection call and any other caller in the same run
# share one `list-commands` round trip instead of paying for it twice.
_mux_tx_has_float_pane() {
  if [[ -n "${_MUX_TX_HAS_FLOAT_PANE:-}" ]]; then
    [[ "$_MUX_TX_HAS_FLOAT_PANE" == 1 ]]
    return
  fi
  local bin
  bin="$(_mux_tx_bin)" || { _MUX_TX_HAS_FLOAT_PANE=0; return 1; }
  if "$bin" list-commands 2>/dev/null | grep -q '^new-pane '; then
    _MUX_TX_HAS_FLOAT_PANE=1
  else
    _MUX_TX_HAS_FLOAT_PANE=0
  fi
  [[ "$_MUX_TX_HAS_FLOAT_PANE" == 1 ]]
}

# _mux_tx_float_pane <width> <height> -- <cmd...>
# Launch a floating pane sized <width>x<height> CELLS (no percent form —
# every caller sizes this from its own computed value, unlike mux::popup's
# viewport-relative geometry), CENTERED on the client's viewport: X =
# (client_width - width) / 2, Y = (client_height - height) / 2, both
# integer-truncated and floored at 0. (The original spec called for
# top-right, mirroring the Hammerspoon HUD's corner — a controller-spec
# error caught before this landed; centered is the actual contract.) Since
# TROUPE_RESIZE_CMD's live resize-pane hook only ever changes -y (height;
# width is fixed at 57 for the whole run), X stays correct across a resize
# automatically, but Y is computed ONCE at spawn time against the FIRST
# height and never recomputed — a later shrink drifts the pane slightly off
# vertical center instead of re-centering. Accepted for now (repositioning a
# LIVE pane is a separate, not-yet-built feature; resize-pane has no
# reposition flag of its own). Foreground-focused (no -d), close-on-exit
# (tmux's default — no -k), and prints the new pane's id (-P -F) for the
# caller to track (job.zsh's re-summon state file). Size is `-x`/`-y`
# (lowercase), position is `-X`/`-Y` (uppercase) — confirmed against this
# box's `tmux list-commands new-pane` (3.7b): `[-x width] [-y height]
# [-X x-position] [-Y y-position]`; this function's flags already matched
# that mapping (the audited bug, if any, was the placement FORMULA, not a
# size/position flag mixup). <cmd...> is joined into ONE shell-command
# string, same convention as _mux_tx_split's tail invocation (tmux's
# new-pane/split-window/new-window family all take a single "shell-command
# [argument ...]" positional, not an argv array).
_mux_tx_float_pane() {
  local w="$1" h="$2"
  shift 2
  [[ "${1-}" == "--" ]] && shift

  local bin cw ch x=0 y=0
  bin="$(_mux_tx_bin)" || return 1
  cw=$("$bin" display -p '#{client_width}' 2>/dev/null)
  ch=$("$bin" display -p '#{client_height}' 2>/dev/null)
  if [[ "$cw" == <-> && "$w" == <-> ]]; then
    (( x = (cw - w) / 2 ))
    (( x < 0 )) && x=0
  fi
  if [[ "$ch" == <-> && "$h" == <-> ]]; then
    (( y = (ch - h) / 2 ))
    (( y < 0 )) && y=0
  fi

  local pane
  pane=$("$bin" new-pane -x "$w" -y "$h" -X "$x" -Y "$y" -P -F '#{pane_id}' \
    ${1+"${(j: :)${(@q)@}}"} 2>/dev/null) || return 1
  print -r -- "$pane"
}
