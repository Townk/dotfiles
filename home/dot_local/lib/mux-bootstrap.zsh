#!/usr/bin/env zsh
# mux-bootstrap.zsh — the dependency-free half of the mux::* shim.
#
# Off-PATH internal library, SOURCED (not executed):
#     source "$HOME/.local/lib/mux-bootstrap.zsh"
#
# This is mux.zsh minus the widgets: backend detection plus every
# session / screen / pane / tab / info verb — the ones that only ever shell
# out to `tmux` or `zellij`. It exists because the full shim cannot be loaded
# from a shell startup path:
#
#   * pick-common.zsh runs `require_cmd fzf` at SOURCE time, and require_cmd
#     calls die → `exit 1`. Sourcing mux.zsh from .zshrc on a box without fzf
#     would kill the login shell outright.
#   * pick/input/theme-common cost ~50ms to source; the two backend files
#     below cost ~1.5ms together.
#
# mux.zsh sources THIS file and then layers the widget API (mux::pick,
# mux::confirm, …) on top, so mux::backend has exactly one definition and the
# two flavors cannot drift. Consumers that want a picker keep sourcing
# mux.zsh; consumers that only need to ask the multiplexer a question — the
# .zshrc welcome screen, status-line helpers — source this.
#
# Backend resolution (§2): INSIDE a session, runtime detection wins — never
# the knob — so a Zellij session and a tmux session work correctly side by
# side on the same machine. $ZELLIJ is checked first: a real Zellij nested
# in a tmux pane re-exports it, while plain tmux panes never carry a stale
# copy (tmux.conf scrubs ZELLIJ* — the cross-mux hygiene block). The knob
# (mux::default_backend) only decides what the Phase 7 autostart LAUNCHES
# outside any session.

_mux_self="${(%):-%x}"
source "$(dirname "$_mux_self")/mux/zellij.zsh"
unset _mux_self

_mux_self="${(%):-%x}"
source "$(dirname "$_mux_self")/mux/tmux.zsh"
unset _mux_self

# $MUX_BACKEND is an explicit override for callers that are NOT in a session
# and know better: WezTerm's hooks (mux-open, nested-session-check) and
# tab-edit resolve the backend from the client PROCESS (mux::backend_for_pid)
# and then set this so every mux::* call they make dispatches that way.
mux::backend() {
  case "${MUX_BACKEND:-}" in
    zellij | tmux) print -r -- "$MUX_BACKEND"; return ;;
  esac
  if [[ -n "${ZELLIJ:-}" ]]; then
    print -r -- zellij
  elif [[ -n "${TMUX:-}" ]]; then
    print -r -- tmux
  else
    print -r -- none
  fi
}

mux::available() {
  case "$(mux::backend)" in
    zellij) _mux_zj_available ;;
    tmux) _mux_tx_available ;;
    *) return 1 ;;
  esac
}

# Knob (§2): the default backend for OUTSIDE-a-session launches. The loose,
# untracked per-machine file wins (theme-override pattern). Runtime detection
# above always beats this inside a session.
#
# The fallback below duplicates chezmoi's .muxBackend (home/.chezmoidata/mux.yaml),
# which .zshrc's autostart bakes in directly — this file is sourced by tests
# that Include it raw, so it cannot be a template. tests/mux_autostart_spec.sh
# fails if the two drift: disagreeing halves show up as the picker thinking
# you are on one backend while you are sitting in the other.
mux::default_backend() {
  local f="${XDG_CONFIG_HOME:-$HOME/.config}/mux/backend" b=""
  [[ -r "$f" ]] && b="$(<"$f")"
  b="${b//[[:space:]]/}"
  case "$b" in
    zellij | tmux) print -r -- "$b" ;;
    *) print -r -- tmux ;;
  esac
}

# --- session / screen (spec §3) --------------------------------------------
# With a client PID the backend is read from that PROCESS (mux::backend_for_pid):
# the callers that pass one — WezTerm's open-uri / nested-session hooks,
# tab-edit — run outside any session, where our own env says nothing.
mux::resolve_session() {
  local b
  if [[ -n "${1:-}" ]]; then b="$(mux::backend_for_pid "$1")"; else b="$(mux::backend)"; fi
  case "$b" in
    tmux) _mux_tx_resolve_session "$@" ;;
    *) resolve_session "$@" ;;   # zellij impl also serves "none" (socket scan)
  esac
}

mux::attached_sessions() {
  case "$(mux::backend)" in
    tmux) _mux_tx_attached_sessions ;;
    *) zellij_attached_sessions ;;
  esac
}

# mux::current_session — the name of the session we are IN, one line. Distinct
# from mux::resolve_session, which answers for someone else's client pid: this
# one reads our own context, which is the only thing a picker running inside a
# pane can trust.
mux::current_session() {
  case "$(mux::backend)" in
    tmux) _mux_tx_resolve_session ;;
    zellij) [[ -n "${ZELLIJ_SESSION_NAME:-}" ]] && print -r -- "$ZELLIJ_SESSION_NAME" ;;
    *) return 1 ;;
  esac
}

# mux::list_sessions — every session the backend knows about, one per line.
# NOT the same set on both sides, and deliberately so: zellij also lists
# EXITED sessions, because it can resurrect them, while tmux only has live
# ones. Callers that mean "sessions I could switch to" want exactly that.
mux::list_sessions() {
  case "$(mux::backend)" in
    tmux) _mux_tx_list_sessions ;;
    zellij) _mux_zj_list_sessions ;;
    *) return 1 ;;
  esac
}

# mux::rename_session <new-name> [target-session] — rename the current session
# when target is omitted, or a specific session when supplied. Backend syntax,
# socket routing, and redraw behavior stay behind this boundary.
mux::rename_session() {
  [[ -n "${1:-}" ]] || return 2
  case "$(mux::backend)" in
    tmux) _mux_tx_rename_session "$1" "${2:-}" ;;
    zellij) _mux_zj_rename_session "$1" "${2:-}" ;;
    *) return 1 ;;
  esac
}

mux::client_sessions() {
  case "$(mux::backend)" in
    tmux) _mux_tx_client_sessions ;;
    *) zellij_wezterm_sessions ;;
  esac
}

# mux::dump_screen [--full] — pane text to stdout. Default is the VIEWPORT on
# both backends; --full prepends the scrollback. Until this had a consumer the
# two sides disagreed silently (zellij returned the viewport, tmux the whole
# history), so the flag exists to make the contract say which one you meant.
mux::dump_screen() {
  local full=0
  [[ "${1:-}" == --full ]] && full=1
  case "$(mux::backend)" in
    tmux) _mux_tx_dump_screen "$full" ;;
    zellij) _mux_zj_dump_screen "$full" ;;
    *) return 1 ;;
  esac
}

# --- panes / tabs / info (spec §3, D19) ------------------------------------
#
# ONE parser per call, here: each backend receives the same normalized
# positionals, so the two implementations cannot drift on what a flag means.
# Every call returns non-zero outside a session rather than guessing a
# backend — a consumer that can degrade (yazi-quick-look, tm-tab) tests
# `mux::available` first and takes its own inline path.

# mux::split <direction> [--size N] [--name NAME] [--close-on-exit]
#            [--cwd DIR] -- <cmd...>
#   direction: right | left | down | up
#   --size is honoured natively by tmux (-l) and IGNORED by zellij, whose
#   `run` cannot size a pane; a zellij caller resizes afterwards.
mux::split() {
  local dir="${1:-right}"; shift 2>/dev/null || :
  local size="" name="" cwd="" close=0
  while (($#)); do
    case "$1" in
      --size) size="${2-}"; shift 2 ;;
      --name) name="${2-}"; shift 2 ;;
      --cwd) cwd="${2-}"; shift 2 ;;
      --close-on-exit) close=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  case "$(mux::backend)" in
    zellij) _mux_zj_split "$dir" "$size" "$name" "$close" "$cwd" -- "$@" ;;
    tmux)   _mux_tx_split "$dir" "$size" "$name" "$close" "$cwd" -- "$@" ;;
    *) return 1 ;;
  esac
}

# mux::popup <width> <height> [--title T] [--name N] [--cwd DIR] -- <cmd...>
#   Geometry: a bare integer is CELLS, an integer with % is a percentage of
#   the tab viewport (both backends agree; the tmux side converts, since
#   display-popup percentages measure the full client).
#   --name and --title are the same thing (zellij pane name ↔ popup title);
#   both spellings are accepted so call sites read naturally.
#   --frame asks for a bordered, unpinned float (the image preview): on
#   zellij it overrides the global `pane_frames false`; on tmux it is a
#   no-op, since popups always own their border.
mux::popup() {
  local w="${1:-80%}" h="${2:-80%}"
  shift 2 2>/dev/null || :
  local title="" cwd="" session="" frame=0
  while (($#)); do
    case "$1" in
      --title|--name) title="${2-}"; shift 2 ;;
      --cwd) cwd="${2-}"; shift 2 ;;
      --session) session="${2-}"; shift 2 ;;
      --frame) frame=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  case "$(mux::backend)" in
    zellij) _mux_zj_popup "$w" "$h" "$title" "$cwd" "$session" "$frame" -- "$@" ;;
    tmux)   _mux_tx_popup "$w" "$h" "$title" "$cwd" "$session" -- "$@" ;;
    *) return 1 ;;
  esac
}

# mux::new_tab [--session S] [--name N] [--cwd DIR] [-- <cmd...>]
#   A tmux window IS a zellij tab. --session targets another session by name
#   (tab-edit dispatches into the session its client is attached to).
#   --singleton reuses a tab of the same NAME when one is already open,
#   instead of stacking a second. tmux respawns the command in place (the tab
#   keeps its index); zellij has no such verb, so it closes and reopens, which
#   moves the tab to the end. Same guarantee — one tab — either way.
mux::new_tab() {
  local session="" name="" cwd="" singleton=0
  while (($#)); do
    case "$1" in
      --session) session="${2-}"; shift 2 ;;
      --name) name="${2-}"; shift 2 ;;
      --cwd) cwd="${2-}"; shift 2 ;;
      --singleton) singleton=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  case "$(mux::backend)" in
    zellij) _mux_zj_new_tab "$session" "$name" "$cwd" "$singleton" -- "$@" ;;
    tmux)   _mux_tx_new_tab "$session" "$name" "$cwd" "$singleton" -- "$@" ;;
    *) return 1 ;;
  esac
}

# mux::send_text [--pane P] <text> — inject literal text into a pane. Without
# --pane the write lands in the FOCUSED pane, which is wrong whenever a float
# is up: the id keeps the write on the pane the caller meant even while a
# closing modal owns focus. P is the backend's own id spelling (zellij
# "terminal_N", tmux "%N") — the caller already has one or the other.
mux::send_text() {
  local pane=""
  [[ "${1:-}" == --pane ]] && { pane="${2-}"; shift 2; }
  case "$(mux::backend)" in
    zellij) _mux_zj_send_text "$1" "$pane" ;;
    tmux)   _mux_tx_send_text "$1" "$pane" ;;
    *) return 1 ;;
  esac
}

# mux::send_key <key> — the shim's key vocabulary, deliberately small (only
# what consumers write back): up down left right enter s-up s-down.
mux::send_key() {
  case "$1" in
    up|down|left|right|enter|s-up|s-down) ;;
    *) return 2 ;;
  esac
  case "$(mux::backend)" in
    zellij) _mux_zj_send_key "$1" ;;
    tmux)   _mux_tx_send_key "$1" ;;
    *) return 1 ;;
  esac
}

# mux::current_tab / mux::focus_tab <n> — 1-based tab index, both backends
# (zellij's list-tabs is 0-based; the +1 lives in the backend, not in
# callers — that arithmetic was duplicated at every zellij call site).
mux::current_tab() {
  case "$(mux::backend)" in
    zellij) _mux_zj_current_tab ;;
    tmux)   _mux_tx_current_tab ;;
    *) return 1 ;;
  esac
}

# mux::current_tab_name — the active tab's TITLE, not its index. Quick-launch
# scopes tab-nested entries by title, so the index cannot stand in for it.
mux::current_tab_name() {
  case "$(mux::backend)" in
    zellij) _mux_zj_current_tab_name ;;
    tmux)   _mux_tx_current_tab_name ;;
    *) return 1 ;;
  esac
}

mux::focus_tab() {
  [[ -n "${1:-}" ]] || return 2
  case "$(mux::backend)" in
    zellij) _mux_zj_focus_tab "$1" ;;
    tmux)   _mux_tx_focus_tab "$1" ;;
    *) return 1 ;;
  esac
}

# mux::pane_count — how many panes the CURRENT SESSION holds, summed across
# every one of its tabs/windows. Session-wide rather than tab-wide because
# the question it answers is "did I just open this terminal": a second tab is
# as much evidence of an existing session as a second pane. The .zshrc
# welcome screen shows itself only when this reads 1.
mux::pane_count() {
  case "$(mux::backend)" in
    zellij) _mux_zj_pane_count ;;
    tmux)   _mux_tx_pane_count ;;
    *) return 1 ;;
  esac
}

# mux::pane_cwd [pid] — working directory of the focused pane. tmux answers
# from its own format; zellij has no such query, so there the pane's root
# PID is required and the kernel answers (copy-pwd's resolution).
mux::pane_cwd() {
  case "$(mux::backend)" in
    zellij) _mux_zj_pane_cwd "${1:-}" ;;
    tmux)   _mux_tx_pane_cwd ;;
    *) return 1 ;;
  esac
}

# mux::terminal_size — "<cols> <rows>" usable by a new pane/float.
mux::terminal_size() {
  case "$(mux::backend)" in
    tmux) _mux_tx_terminal_size ;;
    *) _mux_zj_terminal_size ;;   # zellij impl also serves "none" (tty fallback)
  esac
}

# mux::backend_for_pid <pid> — the backend a CLIENT process speaks, read
# from the process itself. Our env says nothing here: the callers are
# outside any session (WezTerm's tint/open-uri/nested-session hooks run in
# the terminal, not in a pane). Falls back to env detection when the pid
# tells us nothing, so an in-session caller still gets an answer.
mux::backend_for_pid() {
  local comm=""
  [[ -n "${1:-}" ]] && comm=$(ps -p "$1" -o comm= 2>/dev/null)
  case "$comm" in
    *zellij*) print -r -- zellij ;;
    *tmux*)   print -r -- tmux ;;
    *) mux::backend ;;
  esac
}

# mux::focused_command [client_pid] — foreground command of the focused
# TILED pane (floats excluded: a transient modal is not the pane's context).
mux::focused_command() {
  case "$(mux::backend_for_pid "${1:-}")" in
    zellij) _mux_zj_focused_command "${1:-}" ;;
    tmux)   _mux_tx_focused_command "${1:-}" ;;
    *) return 1 ;;
  esac
}
