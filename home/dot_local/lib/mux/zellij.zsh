#!/usr/bin/env zsh
# mux/zellij.zsh — Zellij backend of the mux::* shim (migration spec §2/§3).
#
# MOVED code, not new code (Phase 1 extraction): the float/widget mechanics
# came from lib/zellij.zsh (the old zj::* library, now a compat shim over
# mux.zsh) and the session resolvers came verbatim from
# ~/.config/zellij/scripts/lib/zellij-session.zsh (also now a compat shim
# sourcing this file). The resolver names (resolve_session,
# zellij_wezterm_sessions, zellij_attached_sessions) are a public contract
# (silo map: consumed by tab-edit, and by mux-open / quick-launch-window
# through the mux:: names) and are KEPT; mux.zsh layers mux::* on top.
#
# Sourcing modes:
#   - via mux.zsh (the full stack: pick-common + input-common already loaded);
#   - standalone by the zellij-session.zsh compat shim (resolvers only — the
#     float helpers degrade gracefully: the input::* --measure calls are
#     2>/dev/null-guarded and fall back to per-type default heights).

# _mux_zj_available — true when inside a Zellij session AND a zellij binary
# is usable (so we can actually spawn the floating pane). ZELLIJ_BIN overrides
# the lookup; otherwise PATH resolution keeps this portable across the
# homebrew / dev-shell split instead of hardcoding /opt/homebrew.
_mux_zj_available() {
  [[ -n "${ZELLIJ:-}" ]] || return 1
  local bin="${ZELLIJ_BIN:-$(command -v zellij 2>/dev/null)}"
  [[ -n "$bin" && -x "$bin" ]]
}

# _mux_zj_pick_float <pane_w> <pane_h> <header> [pick args...]
# The in-Zellij half of mux::pick: render the picker in a floating, pinned,
# BORDERLESS pane via the shared zellij-modal scaffolding (--no-chrome, so
# pty-frame draws the box + ▓▓▓ title + rule around fzf — the same chrome as
# the glyph/gitmoji pickers), and capture the chosen value back through a
# FIFO. Rows are read on stdin (staged to a file: the float child is a
# separate process and cannot read our stdin pipe).
_mux_zj_pick_float() {
  local pane_w="$1" pane_h="$2" header="$3"
  shift 3
  local -a pick_args=("$@")

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
  # stdout. mux::pick's stdout IS its return channel (a caller does
  # `sel=$(mux::pick ...)`), so that id must be discarded here — otherwise it is
  # prepended to the FIFO selection and the caller receives "terminal_<n>\n<sel>".
  "$bin" action new-pane --floating --close-on-exit \
    --name "" --borderless true --pinned true \
    --width "$pane_w" --height "$pane_h" --cwd "$PWD" \
    -- "$modal" --title "$header" --no-chrome --capture "$fifo" \
    -- "$picklist" "${pick_args[@]}" --no-border --height -4 --margin 0,0,0,0 --padding 0,2,0,2 -- "$tmp" >/dev/null

  # Block until the modal writes the captured selection (exactly as long as the
  # user browses); empty means the user cancelled.
  local result
  result=$(cat "$fifo")
  rm -f -- "$fifo" "$tmp"

  [[ -n "$result" ]] || return 130
  print -r -- "$result"
}

# _mux_zj_float --type T [--title TITLE] [--pane-width W] [--pane-height H]
#               [--pane-x X] [--pane-y Y] -- <input-widget args...>
# Spawn a sized floating modal running input-widget and capture the answer via
# FIFO. Echoes the captured answer on stdout; returns 130 on empty (cancel).
# Height is derived via `input::"$type" --measure --width "$pane_w"` so panes
# always fit exactly (no more hardcoded row counts).
_mux_zj_float() {
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

  # Measure the exact rendered height from the binary (fast, TTY-less).
  # Stdin is redirected from /dev/null so any shim that reads stdin (e.g.
  # input::form without --spec) receives EOF immediately and never hangs.
  # Fall back to pane_h if provided (legacy override), or a sane per-type default.
  local _measured_h=""
  if [[ -n "$pane_w" ]] && [[ "$pane_w" != *% ]]; then
    _measured_h="$(input::"$type" --measure --width "$pane_w" "${wargs[@]}" </dev/null 2>/dev/null)"
  fi
  # Accept only a plain integer; otherwise use the caller-supplied or per-type default.
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

  local -a pane_geom=()
  [[ -n "$pane_w" ]] && pane_geom+=(--width "$pane_w")
  pane_geom+=(--height "$_measured_h")
  [[ -n "$pane_x" ]] && pane_geom+=(--x "$pane_x")
  [[ -n "$pane_y" ]] && pane_geom+=(--y "$pane_y")

  local -a modal_args=(--capture "$fifo")
  [[ -n "$title" ]] && modal_args=(--title "$title" "${modal_args[@]}")

  # `zellij action new-pane` does NOT propagate COLORTERM into the spawned pane
  # (it inherits TERM but not COLORTERM), so gum/lipgloss fall back to 256-color
  # and the Catppuccin truecolor hex are approximated — mauve lands on ~gum's
  # default pink, reading as "unthemed". Carry our own COLORTERM through
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

# _mux_zj_dump_screen <full> — Screen group (spec §3): zellij dumps to a file
# argument; normalize to stdout like tmux's capture-pane -p. full=1 asks for
# the whole scrollback (--full), matching tmux's `capture-pane -S -`; the
# default is the viewport.
_mux_zj_dump_screen() {
  local bin="${ZELLIJ_BIN:-$(command -v zellij)}" f
  local -a hist=()
  [[ "${1:-0}" == 1 ]] && hist=(--full)
  f=$(mktemp "${TMPDIR:-/tmp}/muxdump.XXXXXX") || return 1
  "$bin" action dump-screen "${hist[@]}" "$f" 2>/dev/null || { rm -f -- "$f"; return 1; }
  cat -- "$f"
  rm -f -- "$f"
}

# ---------------------------------------------------------------------------
# Phase 6.0: panes / tabs / info (spec §3 Panes+Info, D19)
#
# mux.zsh parses every flag and hands both backends the same normalized
# positionals — see the tmux twins in mux/tmux.zsh.
# ---------------------------------------------------------------------------

_mux_zj_bin() { print -r -- "${ZELLIJ_BIN:-$(command -v zellij)}"; }

# _mux_zj_split <dir> <size> <name> <close> <cwd> -- <cmd...>
# <size> is IGNORED here: `zellij run` cannot size the pane it creates, so a
# caller that needs a width drives `action resize` afterwards (backup-tm's
# convergence loop — the resize step is coarser than one column). The tmux
# twin sizes at split time and needs no loop.
_mux_zj_split() {
  local dir="$1" size="$2" name="$3" close="$4" cwd="$5"
  shift 5
  [[ "${1-}" == "--" ]] && shift

  local -a flags=(run)
  (( close )) && flags+=(--close-on-exit)
  flags+=(--direction "$dir")
  [[ -n "$name" ]] && flags+=(--name "$name")
  [[ -n "$cwd" ]] && flags+=(--cwd "$cwd")
  "$(_mux_zj_bin)" "${flags[@]}" -- "$@"
}

# _mux_zj_popup <width> <height> <title> <cwd> -- <cmd...>
# The zellij float: borderless + pinned, the geometry vocabulary passed
# through unchanged (zellij accepts both "90%" and a cell count).
_mux_zj_popup() {
  local w="$1" h="$2" title="$3" cwd="$4" session="$5" frame="${6:-0}"
  shift 6
  [[ "${1-}" == "--" ]] && shift

  local -a pre=()
  [[ -n "$session" ]] && pre=(--session "$session")
  # Default float: borderless + pinned (the modal/picker convention, where
  # pty-frame draws the chrome). --frame flips both for the image preview,
  # which wants zellij's own rounded frame and no pin decoration.
  local border=true pinned=true
  (( frame )) && { border=false; pinned=false; }
  local -a flags=(action new-pane --floating --close-on-exit
                  --name "$title" --borderless "$border" --pinned "$pinned"
                  --width "$w" --height "$h")
  [[ -n "$cwd" ]] && flags+=(--cwd "$cwd")
  "$(_mux_zj_bin)" "${pre[@]}" "${flags[@]}" -- "$@"
}

# _mux_zj_new_tab <session> <name> <cwd> <singleton> -- <cmd...>
#
# Singleton on zellij is CLOSE-then-open, not respawn: zellij has no verb that
# swaps a tab's running command (tmux's respawn-window -k does), so the tab is
# focused, closed, and recreated with the new command. The consequence is that
# it moves to the end of the tab bar, which tmux's does not — a documented
# divergence rather than a hidden one.
_mux_zj_new_tab() {
  local session="$1" name="$2" cwd="$3" singleton="${4:-0}"
  shift 4
  [[ "${1-}" == "--" ]] && shift

  if (( singleton )) && [[ -n "$name" ]]; then
    local -a pre_q=()
    [[ -n "$session" ]] && pre_q=(--session "$session")
    if "$(_mux_zj_bin)" "${pre_q[@]}" action query-tab-names 2>/dev/null |
         grep -Fxq -- "$name"; then
      "$(_mux_zj_bin)" "${pre_q[@]}" action go-to-tab-name "$name" 2>/dev/null &&
        "$(_mux_zj_bin)" "${pre_q[@]}" action close-tab 2>/dev/null
    fi
  fi

  local -a pre=()
  [[ -n "$session" ]] && pre=(--session "$session")
  local -a flags=(action new-tab --close-on-exit)
  [[ -n "$name" ]] && flags+=(--name "$name")
  [[ -n "$cwd" ]] && flags+=(--cwd "$cwd")
  if (($#)); then
    "$(_mux_zj_bin)" "${pre[@]}" "${flags[@]}" -- "$@"
  else
    "$(_mux_zj_bin)" "${pre[@]}" "${flags[@]}"
  fi
}

# _mux_zj_send_text <text> [pane] — pane is zellij's own id spelling
# ("terminal_N"), passed through verbatim; empty writes to the focused pane.
_mux_zj_send_text() {
  local -a target=()
  [[ -n "${2:-}" ]] && target=(--pane-id "$2")
  "$(_mux_zj_bin)" action write-chars "${target[@]}" -- "$1"
}

# _mux_zj_send_key <neutral-key-name> — zellij has no key vocabulary, only
# bytes: write the terminal's own encoding for the key.
_mux_zj_send_key() {
  local seq
  case "$1" in
    up) seq=$'\e[A' ;; down) seq=$'\e[B' ;;
    left) seq=$'\e[D' ;; right) seq=$'\e[C' ;;
    enter) seq=$'\r' ;; s-up) seq=$'\e[1;2A' ;; s-down) seq=$'\e[1;2B' ;;
    *) return 1 ;;
  esac
  "$(_mux_zj_bin)" action write-chars -- "$seq"
}

# _mux_zj_current_tab — 1-based index of the active tab, the same number
# _mux_zj_focus_tab takes (list-tabs -s reports a 0-based position).
_mux_zj_current_tab() {
  local pos
  pos=$("$(_mux_zj_bin)" action list-tabs -s 2>/dev/null |
    awk -F'  +' 'NR > 1 && $4 == "true" { print $2; exit }')
  [[ -n "$pos" ]] || return 1
  print -r -- $(( pos + 1 ))
}

_mux_zj_focus_tab() { "$(_mux_zj_bin)" action go-to-tab "$1" 2>/dev/null; }

# _mux_zj_pane_cwd <pid> — zellij exposes no pane cwd, so it comes from the
# kernel via the pane's root PID (the same resolution copy-pwd uses).
_mux_zj_pane_cwd() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 1
  /usr/sbin/lsof -a -p "$pid" -d cwd -Fn 2>/dev/null |
    awk '/^n/ { print substr($0, 2); exit }'
}

# _mux_zj_terminal_size — usable cols/rows of the focused tab: the extent of
# its non-floating terminal panes (zellij has no client-size query). Falls
# back to the controlling tty. MOVED from quick-launch's ql_terminal_size.
_mux_zj_terminal_size() {
  local bin tab_id size
  bin="$(_mux_zj_bin)"
  if [[ -x "$bin" ]]; then
    tab_id="$("$bin" action list-tabs -s 2>/dev/null |
      awk -F'  +' 'NR > 1 && $4 == "true" { print $1; exit }')" || tab_id=""
    size="$(
      "$bin" action list-panes -a 2>/dev/null | awk -F'  +' -v tab="$tab_id" '
        NR == 1 { next }
        tab != "" && $1 != tab { next }
        $5 != "terminal" || $10 != "false" || $11 != "false" { next }
        { right = $12 + $15; bottom = $13 + $14 }
        right > cols { cols = right }
        bottom > rows { rows = bottom }
        END { if (cols > 0 && rows > 0) print cols, rows }
      '
    )" || size=""
    if [[ -n "$size" ]]; then
      printf '%s\n' "$size"
      return
    fi
  fi
  { stty size </dev/tty 2>/dev/null || printf '24 80\n'; } | awk '{ print $2, $1 }'
}

# _mux_zj_focused_command [client_pid] — command of the focused TILED pane.
# Floating panes are excluded on purpose: our modals keep their own focus
# while the originating tile stays focused in the tiled axis, so a transient
# picker must never read as the pane's context (terminal-location's rule).
_mux_zj_focused_command() {
  local pid="${1:-}" session
  if [[ -n "$pid" ]]; then
    session=$(resolve_session "$pid") || return 1
  else
    session="${ZELLIJ_SESSION_NAME:-}"
  fi
  [[ -n "$session" ]] || return 1
  "$(_mux_zj_bin)" -s "$session" action list-panes -a -j 2>/dev/null |
    jq -r '[.[] | select(.is_plugin == false and .is_focused == true and .is_floating == false)] | .[0].pane_command // empty' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Session resolvers — moved VERBATIM from zellij/scripts/lib/zellij-session.zsh
# (see that file's compat shim). Names kept: public contract.
# ---------------------------------------------------------------------------

# resolve_session <client_pid> [snapshot]
#   Echo the session name the given Zellij client PID is attached to, or return
#   non-zero. A Zellij client holds a socket whose peer is its session server's
#   listening socket, bound at .../<contract>/<session_name>; we find that one
#   external peer and read the owning server's bound path.
#
#   Session names may contain spaces (e.g. "Home MacMini M4 Pro"), and lsof
#   prints the bound path unquoted in its trailing NAME column — so the path is
#   reconstructed from fields 8..NF, NOT `$NF` (which would yield just "Pro").
#
#   The ps+lsof socket snapshot is the slow part. Callers that resolve many
#   clients (zellij_wezterm_sessions) capture it ONCE via _zj_socket_snapshot
#   and pass it as $2, so the lsof cost is paid a single time instead of per
#   client; omit $2 for a standalone single lookup.
resolve_session() {
  local snap="${2:-}"
  [ -n "$snap" ] || snap="$(_zj_socket_snapshot)" || return 1
  _resolve_session_in "$snap" "$1"
}

# Capture the unix-socket lsof lines for every live Zellij client in ONE ps+lsof
# pass (lsof is the expensive call). Non-zero when no Zellij process is running.
_zj_socket_snapshot() {
  local pids
  pids=$(ps -axww -o pid=,command= | awk '/\/zellij( |$)/ {print $1}' | paste -sd, -)
  [ -n "$pids" ] || return 1
  lsof -nP -U -a -p "$pids" 2>/dev/null | grep "unix" || true
}

# Resolve one client PID ($2) against a captured snapshot ($1 = lsof unix lines).
_resolve_session_in() {
  local lsof_out="$1" client_pid="$2" cl locals peers external e spath
  cl=$(printf '%s\n' "$lsof_out" | awk -v p="$client_pid" '$2==p')
  [ -n "$cl" ] || return 1
  locals=$(printf '%s\n' "$cl" | awk '{print $6}' | grep '^0x' | sort -u)
  peers=$(printf '%s\n' "$cl" | grep -oE '\->0x[0-9a-f]+' | sed 's/->//' | sort -u)
  external=$(comm -23 <(printf '%s\n' "$peers") <(printf '%s\n' "$locals"))
  for e in ${(f)external}; do
    spath=$(printf '%s\n' "$lsof_out" |
      awk -v p="$client_pid" -v a="$e" '$2!=p && $6==a {
          path=""; for (i = 8; i <= NF; i++) path = path (i > 8 ? " " : "") $i
          if (path ~ /\//) { print path; exit }
        }')
    [ -n "$spath" ] && {
      printf '%s\n' "${spath##*/}"
      return 0
    }
  done
  return 1
}

# zellij_wezterm_sessions
#   Print "<session>\t<window_id>\t<pane_id>" (TAB-separated) for every WezTerm
#   pane running a Zellij client — i.e. which sessions are live in their own OS
#   window, and which WezTerm window/pane hosts each. The pane's tty (from
#   `wezterm cli list`) leads to its zellij client PID via `ps -t`, which
#   resolve_session maps to a session name. Prints nothing when WezTerm isn't
#   reachable (e.g. on Ghostty), so callers degrade gracefully. WEZTERM_BIN
#   overrides the binary.
zellij_wezterm_sessions() {
  local wez tty wid pane cpid s snap
  wez="${WEZTERM_BIN:-/opt/homebrew/bin/wezterm}"
  command -v "$wez" >/dev/null 2>&1 || wez=wezterm
  # One ps+lsof pass shared across every pane (the lsof is what's slow); without
  # this, resolve_session would re-snapshot per pane and cost N× as much.
  snap="$(_zj_socket_snapshot)" || return 0
  env -u WEZTERM_UNIX_SOCKET -u WEZTERM_PANE "$wez" cli --no-auto-start list --format json 2>/dev/null |
    jq -r '.[] | [(.tty_name // ""), (.window_id|tostring), (.pane_id|tostring)] | @tsv' 2>/dev/null |
    while IFS="$(printf '\t')" read -r tty wid pane; do
      [ -n "$tty" ] && [ "$tty" != null ] || continue
      cpid=$(ps -t "${tty#/dev/}" -o pid=,comm= 2>/dev/null | awk '$2 ~ /zellij/ {print $1; exit}')
      [ -n "$cpid" ] || continue
      s=$(resolve_session "$cpid" "$snap" 2>/dev/null) || continue
      printf '%s\t%s\t%s\n' "$s" "$wid" "$pane"
    done
}

# zellij_attached_sessions
#   Print the name of every Zellij session that currently has a connected client
#   (i.e. is "attached" — on this host that means it owns an OS window), one per
#   line. Resolved from a SINGLE ps+lsof snapshot with no `wezterm cli` and no
#   per-pane `ps`, so it's far cheaper than zellij_wezterm_sessions — used to tag
#   the session picker's rows "(other window)" vs "(detached)" without paying the
#   window-mapping cost on the menu's critical path. A session's server binds a
#   socket at .../<session_name>; it is attached when that socket's address shows
#   up as a connection peer (->addr) from some client. The trade-off vs
#   zellij_wezterm_sessions is that it can't distinguish a WezTerm window from any
#   other client attachment (equivalent here; the raise path resolves the real
#   window lazily at dispatch time).
zellij_attached_sessions() {
  local snap
  snap="$(_zj_socket_snapshot)" || return 0
  printf '%s\n' "$snap" | awk '
    # Server listening socket: field 6 is its address, and the bound path
    # (fields 8..NF) carries the session name as its basename.
    $6 ~ /^0x/ {
      path = ""; for (i = 8; i <= NF; i++) path = path (i > 8 ? " " : "") $i
      if (path ~ /\//) { name = path; sub(/.*\//, "", name); addr2name[$6] = name }
    }
    # Any "->addr" anywhere marks that address as connected-to (has a client).
    {
      s = $0
      while (match(s, /->0x[0-9a-f]+/)) {
        connected[substr(s, RSTART + 2, RLENGTH - 2)] = 1
        s = substr(s, RSTART + RLENGTH)
      }
    }
    END { for (a in addr2name) if (a in connected) print addr2name[a] }
  '
}
