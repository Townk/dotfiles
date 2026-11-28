#!/usr/bin/env zsh
# mux-bootstrap.zsh — the dependency-free half of the mux::* shim.
#
# Off-PATH internal library, SOURCED (not executed):
#     source "$HOME/.local/lib/mux-bootstrap.zsh"
#
# This is mux.zsh minus the widgets: backend detection plus every
# session / screen / pane / tab / info verb — the ones that only ever shell
# out to `tmux` or `rex`. It exists because the full shim cannot be loaded
# from a shell startup path:
#
#   * pick-common.zsh runs `require_cmd fzf` at SOURCE time, and require_cmd
#     calls die → `exit 1`. Sourcing mux.zsh from .zshrc on a box without fzf
#     would kill the login shell outright.
#   * pick/input/theme-common cost ~50ms to source; the backend files
#     below cost ~1.5ms together.
#
# mux.zsh sources THIS file and then layers the widget API (mux::pick,
# mux::confirm, …) on top, so mux::backend has exactly one definition and the
# two flavors cannot drift. Consumers that want a picker keep sourcing
# mux.zsh; consumers that only need to ask the multiplexer a question — the
# .zshrc welcome screen, status-line helpers — source this.
#
# Backend resolution (§2): INSIDE a session, runtime detection wins — never
# the knob — so a tmux session and a Rex session work correctly side by side
# on the same machine. The knob (mux::default_backend) only decides what the
# Phase 7 autostart LAUNCHES outside any session.
#
# Zellij was a third backend until 2026-11-27, when its support was removed.

_mux_self="${(%):-%x}"
source "$(dirname "$_mux_self")/mux/tmux.zsh"
unset _mux_self

_mux_self="${(%):-%x}"
source "$(dirname "$_mux_self")/mux/rex.zsh"
unset _mux_self

# Rex server 0.1.0-preview.25 stopped exporting $REX_SESSION into panes; only
# $REX_BLOCK is left. Everything here (the .zshrc autostart guard, mux::backend,
# the dispatch scripts, nvim) keys on $REX_SESSION, so restore it. A pane's
# full block ID is accepted wherever Rex takes a session (`-s "$REX_BLOCK"`),
# so it stands in for the session ID.
if [[ -z "${REX_SESSION:-}" && -n "${REX_BLOCK:-}" ]]; then
  export REX_SESSION="$REX_BLOCK"
fi

# $MUX_BACKEND is an explicit override for callers that are NOT in a session
# and know better: WezTerm's hooks (mux-open, nested-session-check) and
# tab-edit resolve the backend from the client PROCESS (mux::backend_for_pid)
# and then set this so every mux::* call they make dispatches that way.
#
# Rex is detected LAST: $REX_SESSION is inherited by everything started in a
# Rex pane, including a tmux launched there by hand, and inside that inner
# multiplexer it is the inner one whose panes we are in.
mux::backend() {
  case "${MUX_BACKEND:-}" in
    tmux | rex) print -r -- "$MUX_BACKEND"; return ;;
  esac
  if [[ -n "${TMUX:-}" ]]; then
    print -r -- tmux
  elif [[ -n "${REX_SESSION:-}" ]]; then
    print -r -- rex
  else
    print -r -- none
  fi
}

# _mux::unknown_backend <verb> — the ONE way a dispatch `case` ends for a
# backend it has no arm for. Loud on purpose: these arms used to be `*)` →
# one backend's implementation, so another backend silently ran the wrong
# multiplexer's binary and reported ITS sessions. "none" stays quiet
# — being outside any session is an ordinary state, not a mistake.
_mux::unknown_backend() {
  local b
  b="$(mux::backend)"
  [[ "$b" == none ]] || print -ru2 -- "mux::${1:-?}: no implementation for backend '$b'"
  return 1
}

# mux::available is the gate CONSUMERS test before taking a mux-driven path
# (a popup preview, a scrub tab) instead of their inline one. (Rex was held
# shut here behind $MUX_REX_CONSUMERS while its consumers were ported; they
# are, and the knob is gone.)
mux::available() {
  case "$(mux::backend)" in
    tmux) _mux_tx_available ;;
    rex) _mux_rx_available ;;
    *) return 1 ;;
  esac
}

# mux::in_session — true when this shell is running INSIDE a mux pane.
#
# Deliberately NOT `[[ "$(mux::backend)" != none ]]`: mux::backend honours
# $MUX_BACKEND, which callers outside any session export to say which mux they
# want driven (mux-open, from the terminal's GUI). Such a shell is not nested,
# and reading it as nested would make .zshrc's autostart gate refuse to launch
# a multiplexer at all. This asks only the question the env vars can answer.
mux::in_session() { [[ -n "${TMUX:-}" ]]; }

# mux::in_rex — true when this shell is in a Rex pane and NOT inside a tmux
# started there (the inner multiplexer wins, as in mux::backend). The one
# spelling of a test that scripts make before deciding anything else, so it
# is pure environment: no fork, and no $MUX_BACKEND — like mux::in_session it
# asks where we ARE, not what the caller wants driven.
# $REX_BLOCK on purpose, not $REX_SESSION: the block is what the server
# exports into a pane (the session variable is restored from it above, and a
# Rex Lua action can name a session with no pane at all — callers that mean
# "a session to drive", quick-launch's ql_on_rex, test that themselves).
mux::in_rex() { [[ -z "${TMUX:-}" && -n "${REX_BLOCK:-}" ]]; }

# Knob (§2): the default backend for OUTSIDE-a-session launches, in priority
# order — the loose, untracked per-machine file (theme-override pattern), then
# the caller's baked default, then tmux. Runtime detection always beats this
# inside a session.
#
# .zshrc's autostart passes chezmoi's .muxBackend (home/.chezmoidata/mux.yaml)
# as the fallback, so the data file stays the single source of the baked
# default and only ONE copy of the loose-pin parsing exists. This file is
# sourced by tests that Include it raw, so it cannot be a template and cannot
# read the chezmoi value itself; the no-argument literal below is the last
# resort, and tests/mux_autostart_spec.sh pins it against the data file.
mux::default_backend() {
  local f="${XDG_CONFIG_HOME:-$HOME/.config}/mux/backend" b=""
  [[ -r "$f" ]] && b="$(<"$f")"
  b="${b//[[:space:]]/}"
  case "$b" in
    tmux) print -r -- "$b"; return ;;
  esac
  # An unrecognised value in either place is IGNORED rather than obeyed: a typo
  # must not leave the login shell with no multiplexer at all.
  case "${1:-}" in
    tmux) print -r -- "$1" ;;
    *) print -r -- tmux ;;
  esac
}

# --- remote detection (spec §3, C3) ----------------------------------------
#
# The one canonical "am I remote?" pair, replacing 12+ scattered copies. Two
# distinct questions, deliberately kept apart:
#
#   mux::is_remote          — was THIS process reached over SSH? Read from the
#                             process env. Used by callers whose own env is the
#                             truth (a login shell, a one-shot tool).
#   mux::session_is_remote  — is the tmux SESSION being driven by a remote
#                             client right now? Read from the session env, the
#                             attach-time truth. Used by callers that run in the
#                             tmux server context (status bar, alert hooks, a
#                             popup) where the process env is the server's stale
#                             BIRTH env.

# mux::is_remote — true when the process env says this shell was reached over
# SSH: ANY of SSH_TTY / SSH_CONNECTION / SSH_CLIENT non-empty. All three are
# checked on purpose — a non-interactive `ssh -T host cmd` can leave a subset
# set, and three call sites that dropped SSH_TTY misclassified those as local.
mux::is_remote() {
  [[ -n "${SSH_TTY:-}${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]
}

# mux::session_is_remote [target] — true when the tmux SESSION env reports an
# SSH client. update-environment refreshes SSH_CONNECTION from each attaching
# client, so the session env is the ATTACH-TIME truth — unlike a tmux server
# born over ssh, which carries SSH_CONNECTION in its process env forever.
#
# Target resolution is the HARDENED, pane-pinned form from quick-launch-window
# (it "fixed Mode B twice"): an explicit [target] — a session name OR a pane id,
# which tmux resolves to its containing session — wins; else the origin pane a
# modal captured in $MUX_MODAL_TARGET_PANE before any build; else `display -p
# '#{session_name}'` (the most-recently-used session, the last resort that right
# after a workspace build names the freshly created session, hence the pin).
#
# With no explicit target this must run inside tmux (an out-of-session caller
# has no "current" session to ask about); WITH one it also serves callers in
# the server context — a #() status job or a hook — that resolved the session
# some other way (e.g. `list-clients`) and just want the SSH verdict.
mux::session_is_remote() {
  local tx sess v
  local -a t=()
  tx="$(_mux_tx_bin)" || return 1
  if [[ -n "${1:-}" ]]; then
    t=(-t "$1")
  elif [[ -n "${MUX_MODAL_TARGET_PANE:-}" ]]; then
    t=(-t "$MUX_MODAL_TARGET_PANE")
  elif [[ -n "${TMUX:-}" ]]; then
    sess="$("$tx" display -p '#{session_name}' 2>/dev/null)" || sess=""
    [[ -n "$sess" ]] && t=(-t "$sess")
  else
    return 1
  fi
  v="$("$tx" show-environment "${t[@]}" SSH_CONNECTION 2>/dev/null)" || v=""
  [[ "$v" == SSH_CONNECTION=* ]]
}

# --- binary resolution & wezterm probe (spec §3, C4) -----------------------
#
# The ONE public entry to the backend resolvers, replacing the hand-rolled
# install-dir searches that had drifted across standalone scripts
# (quick-launch's command.zsh, edit-terminal-config — the last of which was
# DEGRADED, missing the mise-shim and /usr/local tiers).

# mux::bin <tmux|rex> — absolute path to that multiplexer binary, or non-zero
# when none is found. Delegates to the backend resolvers; tmux's honours
# $MUX_TMUX_BIN, then $PATH (command -v), then the known install dirs
# (homebrew, /usr/local, the mise shim, ~/.local/bin, /usr/bin). That last-resort list is why the .zshrc autostart can find its binary
# BEFORE it extends $PATH or activates mise.
mux::bin() {
  case "${1:-}" in
    tmux)   _mux_tx_bin ;;
    rex)    _mux_rx_bin ;;
    *) return 2 ;;
  esac
}

# mux::wezterm_panes — one TSV row per WezTerm pane: "<tty>\t<window_id>\t<pane_id>".
# Backend-neutral: a client-session mapper (_mux_tx_client_sessions)
# enumerates WezTerm panes this way, then joins the tty against its own client
# list. The `env -u WEZTERM_UNIX_SOCKET -u WEZTERM_PANE`
# scrub is REQUIRED — a `cli list` made from inside a WezTerm pane targets that
# pane's own mux domain, returning just the local pane, unless those vars are
# cleared so it addresses the GUI. Prints nothing when WezTerm is unreachable
# (Ghostty, headless), so callers degrade gracefully. WEZTERM_BIN overrides.
#
# Its caller lives in mux/tmux.zsh, which is sourced by THIS file above
# mux::* — and is only ever reached through mux::client_sessions (defined
# here), so mux::wezterm_panes is always defined by the time it fires.
mux::wezterm_panes() {
  local wez="${WEZTERM_BIN:-/opt/homebrew/bin/wezterm}"
  command -v "$wez" >/dev/null 2>&1 || wez=wezterm
  env -u WEZTERM_UNIX_SOCKET -u WEZTERM_PANE "$wez" cli --no-auto-start list --format json 2>/dev/null |
    jq -r '.[] | [(.tty_name // ""), (.window_id|tostring), (.pane_id|tostring)] | @tsv' 2>/dev/null
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
    rex) _mux_rx_resolve_session "$@" ;;
    *) _mux::unknown_backend resolve_session ;;
  esac
}

mux::attached_sessions() {
  case "$(mux::backend)" in
    tmux) _mux_tx_attached_sessions ;;
    rex) _mux_rx_attached_sessions ;;
    none) return 0 ;;   # outside any session: nothing attached, not an error
    *) _mux::unknown_backend attached_sessions ;;
  esac
}

# --- autostart (spec §2, D17) ----------------------------------------------
#
# The four verbs .zshrc's autostart needs, and the highest-consequence code
# here: they run on every interactive shell, and a mistake locks the user out
# of the terminal they would need to fix it.
#
# Split into a QUERY plus three EXEC verbs rather than one do-everything call,
# for two reasons: the caller needs to act between the two (it records "Main"
# in the quick-launch recency cache on the paths that land in Main, but not on
# the anonymous one), and a single verb would have to re-probe the server to
# rediscover what the query already established.
#
# The three-way reuse policy is the caller's; the backend merely implements
# it. The knob is meant to change which mux starts, never how the system
# behaves.

# _mux::launch_backend [backend] — which mux these verbs drive. The caller
# resolves it ONCE via mux::default_backend and passes it to each verb, so the
# loose pin file is read a single time per login rather than four times; an
# omitted or unrecognised value resolves it here instead.
_mux::launch_backend() {
  case "${1:-}" in
    tmux) print -r -- "$1" ;;
    *) mux::default_backend ;;
  esac
}

# mux::session_state <name> [backend] — missing | idle | busy.
#   missing  no live session by that name
#   idle     the session is live with no client attached → reattach it
#   busy     the session already has a client → the caller wants its own
mux::session_state() {
  [[ -n "${1:-}" ]] || return 2
  case "$(_mux::launch_backend "${2:-}")" in
    *) _mux_tx_session_state "$1" ;;
  esac
}

# mux::exec_attach <name> [backend] — reattach a live, idle session.
# mux::exec_new <name> [backend]    — create that session and attach to it.
# mux::exec_anonymous [backend]     — create an unnamed session (so a second
#                                     window gets its own mux, not a mirror).
#
# All three REPLACE the shell and do not return. Anything that must happen
# first — the quick-launch recency seed — happens in the caller.
mux::exec_attach() {
  [[ -n "${1:-}" ]] || return 2
  case "$(_mux::launch_backend "${2:-}")" in
    *) _mux_tx_exec_attach "$1" ;;
  esac
}

mux::exec_new() {
  [[ -n "${1:-}" ]] || return 2
  case "$(_mux::launch_backend "${2:-}")" in
    *) _mux_tx_exec_new "$1" ;;
  esac
}

mux::exec_anonymous() {
  case "$(_mux::launch_backend "${1:-}")" in
    *) _mux_tx_exec_anonymous ;;
  esac
}

# mux::current_session — the name of the session we are IN, one line. Distinct
# from mux::resolve_session, which answers for someone else's client pid: this
# one reads our own context, which is the only thing a picker running inside a
# pane can trust.
mux::current_session() {
  case "$(mux::backend)" in
    tmux) _mux_tx_resolve_session ;;
    rex) _mux_rx_resolve_session ;;
    *) _mux::unknown_backend current_session ;;
  esac
}

# mux::list_sessions — every session the backend knows about, one per line.
# Callers mean "sessions I could switch to".
mux::list_sessions() {
  case "$(mux::backend)" in
    tmux) _mux_tx_list_sessions ;;
    rex) _mux_rx_list_sessions ;;
    *) _mux::unknown_backend list_sessions ;;
  esac
}

# mux::kill_session <name> — end that session for good. "For good" is the
# contract, not just "kill": after this returns, mux::list_sessions must no
# longer report the name, so the session picker's row can clear.
mux::kill_session() {
  [[ -n "${1:-}" ]] || return 2
  case "$(mux::backend)" in
    tmux) _mux_tx_kill_session "$1" ;;
    rex) _mux_rx_kill_session "$1" ;;
    *) _mux::unknown_backend kill_session ;;
  esac
}

# mux::rename_session <new-name> [target-session] — rename the current session
# when target is omitted, or a specific session when supplied. Backend syntax,
# socket routing, and redraw behavior stay behind this boundary.
mux::rename_session() {
  [[ -n "${1:-}" ]] || return 2
  case "$(mux::backend)" in
    tmux) _mux_tx_rename_session "$1" "${2:-}" ;;
    rex) _mux_rx_rename_session "$1" "${2:-}" ;;
    *) _mux::unknown_backend rename_session ;;
  esac
}

mux::client_sessions() {
  case "$(mux::backend)" in
    tmux) _mux_tx_client_sessions ;;
    rex) _mux_rx_client_sessions ;;
    none) return 0 ;;   # outside any session: no clients, not an error
    *) _mux::unknown_backend client_sessions ;;
  esac
}

# mux::dump_screen [--full] — pane text to stdout. Default is the VIEWPORT on
# every backend; --full prepends the scrollback. Until this had a consumer the
# backends disagreed silently (one returned the viewport, tmux the whole
# history), so the flag exists to make the contract say which one you meant.
mux::dump_screen() {
  local full=0
  [[ "${1:-}" == --full ]] && full=1
  case "$(mux::backend)" in
    tmux) _mux_tx_dump_screen "$full" ;;
    rex) _mux_rx_dump_screen "$full" ;;
    *) _mux::unknown_backend dump_screen ;;
  esac
}

# --- panes / tabs / info (spec §3, D19) ------------------------------------
#
# ONE parser per call, here: each backend receives the same normalized
# positionals, so the implementations cannot drift on what a flag means.
# Every call returns non-zero outside a session rather than guessing a
# backend — a consumer that can degrade (yazi-quick-look, tm-tab) tests
# `mux::available` first and takes its own inline path.

# mux::split <direction> [--size N] [--name NAME] [--close-on-exit]
#            [--cwd DIR] -- <cmd...>
#   direction: right | left | down | up
#   --size is honoured natively by tmux (-l).
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
    tmux)   _mux_tx_split "$dir" "$size" "$name" "$close" "$cwd" -- "$@" ;;
    rex)    _mux_rx_split "$dir" "$size" "$name" "$close" "$cwd" -- "$@" ;;
    *) _mux::unknown_backend split ;;
  esac
}

# mux::popup <width> <height> [--title T] [--name N] [--cwd DIR] -- <cmd...>
#   Geometry: a bare integer is CELLS, an integer with % is a percentage of
#   the tab viewport (the tmux side converts, since display-popup
#   percentages measure the full client).
#   --name and --title are the same thing; both spellings are accepted so
#   call sites read naturally.
#   --frame asks for a bordered, unpinned float (the image preview). It is
#   accepted and ignored: tmux popups always own their border.
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
    tmux)   _mux_tx_popup "$w" "$h" "$title" "$cwd" "$session" -- "$@" ;;
    rex)    _mux_rx_popup "$w" "$h" "$title" "$cwd" "$session" -- "$@" ;;
    *) _mux::unknown_backend popup ;;
  esac
}

# mux::new_tab [--session S] [--name N] [--cwd DIR] [-- <cmd...>]
#   A "tab" is a tmux window. --session targets another session by name
#   (tab-edit dispatches into the session its client is attached to).
#   --singleton reuses a tab of the same NAME when one is already open,
#   instead of stacking a second. tmux respawns the command in place (the tab
#   keeps its index).
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
    tmux)   _mux_tx_new_tab "$session" "$name" "$cwd" "$singleton" -- "$@" ;;
    rex)    _mux_rx_new_tab "$session" "$name" "$cwd" "$singleton" -- "$@" ;;
    *) _mux::unknown_backend new_tab ;;
  esac
}

# mux::float_pane <width> <height> -- <cmd...>
#   A REAL pane (tmux `new-pane`, 3.7b+, upstream #5135) — not a popup: live-
#   resizable in place via resize-pane, genuinely persistent (survives a
#   tab/window switch), unlike mux::popup's client-level modal (job-runner
#   design §6 rev 4). Width/height are CELL counts only — no percent form,
#   since every caller sizes this from a value it already computed (troupe's
#   own --measure), unlike mux::popup's viewport-relative use. Fails outside a
#   session, so the driver gates on mux::has_float_pane first rather than
#   discovering the gap via a failed launch.
mux::float_pane() {
  case "$(mux::backend)" in
    tmux) _mux_tx_float_pane "$@" ;;
    rex) _mux_rx_float_pane "$@" ;;
    *) return 1 ;;
  esac
}

# mux::has_float_pane — capability probe for mux::float_pane: does the
# resolved backend/binary actually support it? "none" always fails (no
# backend); tmux delegates to the real `list-commands`
# probe (3.7b+ carries `new-pane`, older builds don't).
mux::has_float_pane() {
  case "$(mux::backend)" in
    tmux) _mux_tx_has_float_pane ;;
    rex) _mux_rx_has_float_pane ;;
    *) return 1 ;;
  esac
}

# mux::send_text [--pane P] <text> — inject literal text into a pane. Without
# --pane the write lands in the FOCUSED pane, which is wrong whenever a float
# is up: the id keeps the write on the pane the caller meant even while a
# closing modal owns focus. P is the backend's own id spelling (tmux "%N") —
# the caller already has it.
mux::send_text() {
  local pane=""
  [[ "${1:-}" == --pane ]] && { pane="${2-}"; shift 2; }
  case "$(mux::backend)" in
    tmux)   _mux_tx_send_text "$1" "$pane" ;;
    rex)    _mux_rx_send_text "$1" "$pane" ;;
    *) _mux::unknown_backend send_text ;;
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
    tmux)   _mux_tx_send_key "$1" ;;
    rex)    _mux_rx_send_key "$1" ;;
    *) _mux::unknown_backend send_key ;;
  esac
}

# mux::current_tab / mux::focus_tab <n> — 1-based tab index on every backend.
mux::current_tab() {
  case "$(mux::backend)" in
    tmux)   _mux_tx_current_tab ;;
    rex)    _mux_rx_current_tab ;;
    *) _mux::unknown_backend current_tab ;;
  esac
}

# mux::current_tab_name — the active tab's TITLE, not its index. Quick-launch
# scopes tab-nested entries by title, so the index cannot stand in for it.
mux::current_tab_name() {
  case "$(mux::backend)" in
    tmux)   _mux_tx_current_tab_name ;;
    rex)    _mux_rx_current_tab_name ;;
    *) _mux::unknown_backend current_tab_name ;;
  esac
}

mux::focus_tab() {
  [[ -n "${1:-}" ]] || return 2
  case "$(mux::backend)" in
    tmux)   _mux_tx_focus_tab "$1" ;;
    rex)    _mux_rx_focus_tab "$1" ;;
    *) _mux::unknown_backend focus_tab ;;
  esac
}

# mux::pane_count — how many panes the CURRENT SESSION holds, summed across
# every one of its tabs/windows. Session-wide rather than tab-wide because
# the question it answers is "did I just open this terminal": a second tab is
# as much evidence of an existing session as a second pane. The .zshrc
# welcome screen shows itself only when this reads 1.
mux::pane_count() {
  case "$(mux::backend)" in
    tmux)   _mux_tx_pane_count ;;
    rex)    _mux_rx_pane_count ;;
    *) _mux::unknown_backend pane_count ;;
  esac
}

# mux::pane_cwd — working directory of the focused pane, answered by the
# backend itself (tmux from its own format).
mux::pane_cwd() {
  case "$(mux::backend)" in
    tmux)   _mux_tx_pane_cwd ;;
    rex)    _mux_rx_pane_cwd ;;
    *) _mux::unknown_backend pane_cwd ;;
  esac
}

# --- the pane's own tty ------------------------------------------------------

# mux::tty_size — "<rows> <cols>" of the controlling tty, as `stty size`
# orders them; non-zero when there is no tty to ask. The tty is the truth for
# THIS pane on every backend, and it is ahead of $LINES/$COLUMNS and `tput`,
# which answer with the size the process was born with.
mux::tty_size() {
  local sz
  sz="$(stty size </dev/tty 2>/dev/null)" || return 1
  [[ "$sz" == <->" "<-> ]] || return 1
  print -r -- "$sz"
}

# mux::await_tty_size [--stable | --not ROWSxCOLS] [tries] [interval] — wait
# for a NEW pane's pty to reach its real size, then print it ("<rows>
# <cols>"). A pane is born at a default size and resized when the multiplexer
# lays it out, a fraction of a second later; a program that draws for the
# birth size draws wrong. Two ways to know it has settled:
#   --stable (default)  two reads in a row agree — for a pane whose final
#                       size could be anything (a float, a resized layer);
#   --not ROWSxCOLS     it moved off the birth size (`--not 24x80`) — for a
#                       pane that is slow to get its first layout, where two
#                       equal reads would just be the birth size twice.
# Reads at most <tries> times (default 20), <interval> seconds apart (0.05).
# When the tries run out it prints the last size it read: the caller wanted a
# size, and a pane that really is 24x80 has one. Non-zero only when the tty
# cannot be read at all.
mux::await_tty_size() {
  local not="" size="" prev=""
  case "${1:-}" in
    --stable) shift ;;
    --not) not="${${2-}/x/ }"; shift; (($#)) && shift ;;
  esac
  local -i tries="${1:-20}" i
  local interval="${2:-0.05}"
  for (( i = 0; i < tries; i++ )); do
    size="$(mux::tty_size)" || return 1
    if [[ -n "$not" ]]; then
      [[ "$size" == "$not" ]] || break
    else
      [[ -n "$prev" && "$size" == "$prev" ]] && break
      prev="$size"
    fi
    sleep "$interval"
  done
  [[ -n "$size" ]] || return 1
  print -r -- "$size"
}

# _mux::tty_terminal_size — "<cols> <rows>" of the controlling tty, 80x24
# when there is none. What a float is centred against outside a multiplexer,
# and what quick-launch (ql_terminal_size) measures its own floats with.
_mux::tty_terminal_size() {
  { mux::tty_size || print -r -- '24 80'; } | awk '{ print $2, $1 }'
}

# mux::terminal_size — "<cols> <rows>" usable by a new pane/float.
mux::terminal_size() {
  case "$(mux::backend)" in
    tmux) _mux_tx_terminal_size ;;
    rex) _mux_rx_terminal_size ;;
    none) _mux::tty_terminal_size ;;   # the controlling tty
    *) _mux::unknown_backend terminal_size ;;
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
    *tmux*)   print -r -- tmux ;;
    *) mux::backend ;;
  esac
}

# mux::focused_command [client_pid] — foreground command of the focused
# TILED pane (floats excluded: a transient modal is not the pane's context).
mux::focused_command() {
  case "$(mux::backend_for_pid "${1:-}")" in
    tmux)   _mux_tx_focused_command "${1:-}" ;;
    rex)    _mux_rx_focused_command "${1:-}" ;;
    *) _mux::unknown_backend focused_command ;;
  esac
}
