#!/usr/bin/env zsh
# mux/rex.zsh — the Rex backend of the mux::* shim.
#
# Off-PATH internal library, SOURCED by mux-bootstrap.zsh beside mux/tmux.zsh.
# Like it this only ever shells out — here to the `rex`
# CLI — so it stays cheap enough to load from a shell startup path.
#
# Rex is a terminal AND a multiplexer, so the vocabulary shifts: a tmux
# WINDOW (our "tab") is a Rex window, a tmux PANE is a Rex BLOCK, and a tmux
# popup is a floating LAYER. Every pane Rex starts carries $REX_SESSION and
# $REX_BLOCK, which is how these functions know where "here" is; $REX_SERVER
# (also set in every pane) is read by the CLI itself.
#
# One `_mux_rx_*` per `_mux_tx_*`, in the same order as mux/tmux.zsh, so a
# diff of the two files shows what Rex does not answer yet. A verb Rex cannot
# answer returns 1 rather than guessing — the callers that can degrade test
# mux::available and take their own inline path.
#
# NOT here on purpose: the mode stack (Rex modes nest natively), and the
# autostart exec verbs — nothing launches INTO Rex from a shell.
#
# Lessons that cost a spike (docs/mux-parity.md has the full table):
#   * a unix socket path is capped near 104 bytes — a scratch server's socket
#     cannot live in a deep temp directory;
#   * `rex wait` on a block that closed before the wait attached returns 1,
#     so nothing here infers a command's status from it;
#   * a Lua `rex.session.*` call is scoped to the session the script is
#     attached to — hence the explicit `-s` on every call below;
#   * panes inherit the SERVER's birth environment, not the client's.

# _mux_rx_bin — absolute path to rex, or non-zero. $MUX_REX_BIN is the test
# seam (mirrors $MUX_TMUX_BIN); $REX_BIN_DIR is exported by Rex into every
# pane and is the one location guaranteed to match the running server.
_mux_rx_bin() {
  if [[ -n "${MUX_REX_BIN:-}" ]]; then
    print -r -- "$MUX_REX_BIN"
    return 0
  fi
  local c
  c="$(command -v rex 2>/dev/null)" && [[ -n "$c" ]] && { print -r -- "$c"; return 0; }
  # The Mac app ships the CLI inside its server bundle and only puts it on
  # PATH in the panes it starts — a script run by `rex.exec`, a launchd job
  # or a chezmoi hook finds it at this path or not at all.
  local app="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  for c in "${REX_BIN_DIR:+$REX_BIN_DIR/rex}" "$app" /opt/homebrew/bin/rex \
           /usr/local/bin/rex "$HOME/.local/bin/rex"; do
    [[ -n "$c" && -x "$c" ]] && { print -r -- "$c"; return 0; }
  done
  return 1
}

# _mux_rx_run <args...> — one rex call that can never START a server. A
# query from a shell with a stale $REX_SERVER must fail, not quietly spawn a
# second, empty server and answer for that one.
_mux_rx_run() {
  local bin
  bin="$(_mux_rx_bin)" || return 1
  "$bin" --autostart=false "$@"
}

_mux_rx_available() {
  [[ -n "${REX_SESSION:-}" || "${MUX_BACKEND:-}" == rex ]] || return 1
  _mux_rx_bin >/dev/null 2>&1
}

# _mux_rx_session — the session these verbs act on: ours. Fails outside a
# Rex pane, where there is no "current" session to mean.
_mux_rx_session() {
  [[ -n "${REX_SESSION:-}" ]] || return 1
  print -r -- "$REX_SESSION"
}

# _mux_rx_view [session] — the session's full layout as JSON (windows →
# layers → blocks). The one read every tab/pane question below is answered
# from, so each verb costs exactly one round trip.
_mux_rx_view() {
  local s="${1:-}"
  [[ -n "$s" ]] || s="$(_mux_rx_session)" || return 1
  _mux_rx_run api call -s "$s" session.view 2>/dev/null
}

# _mux_rx_block_call <block> <method> — a terminal block method (process,
# size) as JSON.
_mux_rx_block_call() {
  local s
  s="$(_mux_rx_session)" || return 1
  _mux_rx_run block call -s "$s" -b "$1" "$2" 2>/dev/null
}

# --- session / screen -------------------------------------------------------

# With no pid: the LABEL of the session we are in (labels are what the user
# sees and what every other session verb takes). With a client pid: the Rex
# app is one process attached to many sessions, so "the session of pid N" has
# no single answer — non-zero, and the caller keeps its own fallback.
_mux_rx_resolve_session() {
  [[ -z "${1:-}" ]] || return 1
  local s
  s="$(_mux_rx_session)" || return 1
  _mux_rx_run ls --json 2>/dev/null |
    jq -r --arg s "$s" '.sessions[]? | select(.session_id == $s) | .label // empty'
}

_mux_rx_list_sessions() {
  _mux_rx_run ls --json 2>/dev/null | jq -r '.sessions[]? | .label // empty'
}

_mux_rx_kill_session() {
  _mux_rx_run kill "$1" >/dev/null 2>&1
}

# _mux_rx_rename_session <new> [target] — target defaults to OUR session, by
# id, so a label that happens to match another session cannot redirect it.
_mux_rx_rename_session() {
  local new_name="$1" target="${2:-}"
  [[ -n "$target" ]] || target="$(_mux_rx_session)" || return 1
  _mux_rx_run session rename "$target" "$new_name" >/dev/null 2>&1
}

# _mux_rx_attached_sessions [--flat] — the labels of the sessions some Rex APP
# currently shows, one per line. Only a CONNECTED app counts: the CLI's own
# short-lived connections are clients too, and an app that lost its
# connection stays listed for a while. Both calls carry a timeout and neither
# needs $REX_SESSION, because this also runs under gpg-agent (mux/pinentry.zsh).
# --flat is for a caller that puts the label in a `|`-separated line: `|`, tab
# and newline become spaces.
_mux_rx_attached_sessions() {
  local flat=false sessions clients
  [[ "${1:-}" == --flat ]] && flat=true
  sessions="$(_mux_rx_run --timeout 3s ls --json 2>/dev/null)" || return 1
  clients="$(_mux_rx_run --timeout 3s client ls --json 2>/dev/null)" || return 1
  jq -rn --argjson s "$sessions" --argjson c "$clients" --argjson flat "$flat" '
    [ ($c.clients // $c)[]?
      | select(.info.kind? == "app" and .connection_state? == "connected")
      | .session_ids[]? ] as $ids
    | $s.sessions[]? | select(.session_id as $i | $ids | index($i))
    | if $flat then (.label // "" | gsub("[|\\t\\n]"; " ")) else (.label // empty) end' 2>/dev/null
}

# The WezTerm-pane ↔ session join has no meaning here: Rex is its own
# terminal, so there is no outer pane to map. Empty and successful, which is
# what the join's callers already treat as "nothing to map".
_mux_rx_client_sessions() { return 0; }

# _mux_rx_dump_screen <full> — `rex capture` always returns screen PLUS
# scrollback, so the viewport default is cut from its tail using the block's
# own row count.
_mux_rx_dump_screen() {
  local s rows
  s="$(_mux_rx_session)" || return 1
  [[ -n "${REX_BLOCK:-}" ]] || return 1
  if [[ "${1:-0}" == 1 ]]; then
    _mux_rx_run capture -s "$s" -b "$REX_BLOCK" 2>/dev/null
    return
  fi
  rows="$(_mux_rx_block_call "$REX_BLOCK" size | jq -r '.rows // empty' 2>/dev/null)"
  [[ "$rows" == <-> ]] || rows=0
  if (( rows > 0 )); then
    _mux_rx_run capture -s "$s" -b "$REX_BLOCK" 2>/dev/null | tail -n "$rows"
  else
    _mux_rx_run capture -s "$s" -b "$REX_BLOCK" 2>/dev/null
  fi
}

# --- panes / tabs / info ----------------------------------------------------

# _mux_rx_split <dir> <size> <name> <close> <cwd> -- <cmd...>
# Prints the new block id. --size is honoured only as a PERCENTAGE (`30%`):
# Rex splits by ratio: a size is honoured as a percentage (the NEW pane's
# share) and a cell count is dropped rather than guessed — it has no ratio
# without knowing the anchor's size. A caller that knows it converts.
# <close> is accepted and ignored, as on tmux: a block closes with its command.
_mux_rx_split() {
  local dir="$1" size="$2" name="$3" close="$4" cwd="$5"
  shift 5
  [[ "${1-}" == "--" ]] && shift

  local s
  s="$(_mux_rx_session)" || return 1
  local -a flags=(-s "$s")
  [[ -n "${REX_BLOCK:-}" ]] && flags+=(-b "$REX_BLOCK")
  case "$dir" in
    left)  flags+=(--split=left) ;;
    down)  flags+=(--split=below) ;;
    up)    flags+=(--split=above) ;;
    *)     flags+=(--split=right) ;;
  esac
  [[ "$size" == <->% ]] && flags+=(--ratio "${size%\%}")
  [[ -n "$cwd" ]] && flags+=(-c "$cwd")
  [[ -n "$name" ]] && flags+=(--label "$name")

  local out
  if (($#)); then
    out="$(_mux_rx_run run "${flags[@]}" --json -- "$@" 2>/dev/null)" || return 1
  else
    out="$(_mux_rx_run split "${flags[@]}" --json 2>/dev/null)" || return 1
  fi
  print -r -- "$out" | jq -r '[.. | .block_id? // empty, (.block_ids? // [])[]] | first // empty'
}

# _mux_rx_window_cells [view-json] — "<cols> <rows>" of the session's ACTIVE
# window, which is where a layer opens. Rex reports cells per block and
# layout as fractions of the window, so the window is a tiled pane's cells
# divided by its share. Used to turn the shim's cell-based popup/float
# geometry into the fractions Rex wants.
#
# The pane measured is ours when it is tiled in the active window, otherwise
# any tiled pane there: a caller in a background tab may never have been laid
# out (it still reports the 80x24 it was born with), and a float's rect is a
# share of its own layer. Our own pane, wherever it is, is the last resort.
_mux_rx_window_cells() {
  [[ -n "${REX_BLOCK:-}" ]] || return 1
  local view="${1:-}" ref rect size
  [[ -n "$view" ]] || view="$(_mux_rx_view)" || return 1
  ref="$(print -r -- "$view" | jq -r --arg b "$REX_BLOCK" '
    def panes: [.. | objects | select(.block_id? and (.rect? | type) == "array")];
    .active_window_id as $aw
    | ([.windows[]? | select(.window_id == $aw) | .layers[]? | select(.kind == "tiled")] | panes) as $active
    | ([$active[] | select(.block_id == $b)] | first)
      // ($active | first)
      // ([panes[] | select(.block_id == $b)] | first)
    | if . then "\(.block_id) \(.rect[2]) \(.rect[3])" else empty end' 2>/dev/null)"
  [[ -n "$ref" ]] || return 1
  rect="${ref#* }"
  size="$(_mux_rx_block_call "${ref%% *}" size | jq -r '"\(.columns) \(.rows)"' 2>/dev/null)"
  [[ -n "$rect" && -n "$size" ]] || return 1
  local -a r=(${=rect}) z=(${=size})
  [[ "${z[1]}" == <-> && "${z[2]}" == <-> ]] || return 1
  awk -v c="${z[1]}" -v l="${z[2]}" -v w="${r[1]}" -v h="${r[2]}" 'BEGIN {
    if (w <= 0 || h <= 0) exit 1
    printf "%d %d\n", int(c / w + 0.5), int(l / h + 0.5)
  }'
}

# _mux_rx_fraction <size> <window-cells> — one popup dimension as a fraction
# of the window: `80%` → 0.8, a bare cell count → cells/window. Clamped to
# (0, 1]: a layer must fit inside its window or Rex refuses it.
_mux_rx_fraction() {
  local v="$1" total="${2:-0}"
  awk -v v="${v%\%}" -v pct="$([[ "$v" == *% ]] && print 1 || print 0)" -v t="$total" 'BEGIN {
    if (v !~ /^[0-9]+$/) { print "0.8"; exit }
    f = pct ? v / 100 : (t > 0 ? v / t : 0.8)
    if (f > 1) f = 1
    if (f <= 0) f = 0.8
    printf "%.4f\n", f
  }'
}

# _mux_rx_layer <w> <h> <title> <cwd> <session> -- <cmd...> — a centered
# floating layer running <cmd> (or a shell). Prints the new block id.
# $_MUX_RX_LAYER_INTERACTIVE=1 runs <cmd> through an INTERACTIVE shell (the
# block option behind `rex run --interactive`), for a caller whose command
# expects what ~/.zshrc sets up. $_MUX_RX_LAYER_FOCUS=0 creates the layer
# without giving it focus (default: focused), for a caller that moves the
# focus itself.
_mux_rx_layer() {
  local w="$1" h="$2" title="$3" cwd="$4" session="$5"
  shift 5
  [[ "${1-}" == "--" ]] && shift

  [[ -n "$session" ]] || session="$(_mux_rx_session)" || return 1
  local cells="" cw=0 ch=0
  if [[ "$w" != *% || "$h" != *% ]]; then
    cells="$(_mux_rx_window_cells 2>/dev/null)" && { cw="${cells%% *}"; ch="${cells##* }"; }
  fi
  local fw fh
  fw="$(_mux_rx_fraction "$w" "$cw")"
  fh="$(_mux_rx_fraction "$h" "$ch")"

  local req
  req="$(jq -cn --arg fw "$fw" --arg fh "$fh" --arg title "$title" --arg cwd "$cwd" \
    --arg inter "${_MUX_RX_LAYER_INTERACTIVE:-0}" --arg focus "${_MUX_RX_LAYER_FOCUS:-1}" \
    '$ARGS.positional as $cmd
     | ($fw | tonumber) as $w | ($fh | tonumber) as $h
     | { bounds: [((1 - $w) / 2), ((1 - $h) / 2), $w, $h],
         focus: ($focus != "0"),
         layout: { block: (
           { flavor: "com.superlogical.terminal.shell",
             options: ( {}
               + (if ($cmd | length) > 0 then { command: $cmd } else {} end)
               + (if ($cmd | length) > 0 and $inter == "1" then { interactive: true } else {} end)
               + (if $cwd != "" then { cwd: $cwd } else {} end) ) }
           + (if $title != "" then { label: $title } else {} end) ) } }' \
    --args -- "$@")" || return 1
  print -r -- "$req" | _mux_rx_run api call -s "$session" session.new_layer - 2>/dev/null |
    jq -r '.block_ids[0] // empty'
}

# _mux_rx_popup <w> <h> <title> <cwd> <session> -- <cmd...>
# Fire-and-forget, as on tmux (whose popup is launched with `run-shell -b`):
# the caller does not get the command's status. Callers that need one carry
# it through a file themselves — `rex wait` cannot be trusted for it.
_mux_rx_popup() {
  _mux_rx_layer "$@" >/dev/null
}

# --- widget floats ----------------------------------------------------------
# The Rex twins of _mux_tx_pick_float / _mux_tx_float (same argv, same
# contract): the widget runs in a floating layer whose command is rex-modal,
# and the answer comes back through a capture FIFO.
#
# What differs from tmux is how a float ENDS without answering. A tmux popup
# is a process this shell waits on. A Rex layer is a real pane created by an
# API call that returns at once, and it can be closed by hand — its command is
# then killed before it ever opens the FIFO, and a bare `cat "$fifo"` would
# block forever. So the reader runs in the background and is abandoned once
# the layer's block is gone.

# _mux_rx_modal_layer <w> <h> <title> -- <rex-modal args and target…> — open
# the layer over OUR block, in OUR directory (a layer's command otherwise
# starts in the server's, and a picker's preview of a relative path misses).
# Prints the layer's block id; empty on failure.
_mux_rx_modal_layer() {
  local w="$1" h="$2" title="$3"
  shift 3
  [[ "${1-}" == "--" ]] && shift
  local modal="${MUX_REX_MODAL:-$HOME/.config/mux/scripts/rex-modal}"
  # A height in cells is a promise to the target: it drew, or will draw, for
  # exactly that many rows. rex-modal makes the layer keep it.
  local -a rows=()
  [[ "$h" == <-> ]] && rows=("MUX_REX_MODAL_ROWS=$h")
  _mux_rx_layer "$w" "$h" "$title" "$PWD" "" -- \
    env "COLORTERM=${COLORTERM:-truecolor}" "${rows[@]}" "$modal" --origin "${REX_BLOCK:-}" "$@"
}

# _mux_rx_close_block <block> — close a layer we opened; quiet either way.
_mux_rx_close_block() {
  [[ -n "${1:-}" ]] || return 0
  _mux_rx_run --timeout 3s block close -s "$1" "$1" >/dev/null 2>&1
  return 0
}

# The floats below share one way of being interrupted. An INT/TERM handler
# cannot return from the function it interrupts, so it only closes the layer
# (and notes that it ran, for a signal that lands before the layer exists);
# the wait then sees the layer gone and the function leaves by its usual
# path, temp files removed, with 130. Without it the float outlived its
# caller, and answering that orphan found nobody listening.

# _mux_rx_await_modal <layer block> <reader pid> — wait for the reader to
# finish (the modal answered). Returns 1 after abandoning it because nobody
# will ever write the answer. The wait is BOUNDED whatever the server says:
#   * `block inspect` exits 3 for a block the server no longer knows — the
#     layer is gone — and 4 when no server is running, which takes every
#     layer with it. Either ends the wait at once.
#   * any other failure (a timeout, a hiccup) is not proof, so it is counted,
#     and a run of them — $_MUX_RX_AWAIT_MISSES, default 25 polls, about 5 s —
#     ends the wait too. A check that succeeds resets the count: a float that
#     is simply taking its time is never abandoned.
_mux_rx_await_modal() {
  local block="$1" reader="$2" rc=0 misses=0
  local limit="${_MUX_RX_AWAIT_MISSES:-25}"
  while kill -0 "$reader" 2>/dev/null; do
    rc=0
    _mux_rx_run --timeout 3s block inspect -s "$block" "$block" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) misses=0 ;;
      3 | 4) misses=$limit ;;
      *) (( misses += 1 )) ;;
    esac
    if (( misses >= limit )); then
      # The modal writes its answer as it exits, so give a reader that is
      # mid-read a moment before calling it abandoned.
      sleep 0.3
      kill -0 "$reader" 2>/dev/null || break
      kill "$reader" 2>/dev/null
      wait "$reader" 2>/dev/null
      return 1
    fi
    sleep 0.2
  done
  wait "$reader" 2>/dev/null
  return 0
}

# _mux_rx_pick_float <pane_w> <pane_h> <header> <pick::start args…>  (rows on stdin)
_mux_rx_pick_float() {
  local pane_w="$1" pane_h="$2" header="$3"
  shift 3
  local -a pick_args=("$@")
  local picklist="$HOME/.local/libexec/pick-list"

  local tmp fifo out
  tmp=$(mktemp "${TMPDIR:-/tmp}/rxpick.XXXXXX") || return 1
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/rxpick-fifo.XXXXXX")
  if ! mkfifo -m 600 "$fifo" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/rxpick-out.XXXXXX") || { rm -f -- "$tmp" "$fifo"; return 1; }
  # As in the tmux twin: these helpers run inside `$(…)`, where an EXIT trap
  # fires too late, so every return path removes the temps itself.
  setopt localoptions localtraps
  local block="" interrupted=0
  trap 'interrupted=1; _mux_rx_close_block "$block"' INT TERM

  # Stage rows to a file: the layer's command cannot read our stdin pipe.
  cat >"$tmp"

  cat "$fifo" >"$out" 2>/dev/null &
  local reader_pid=$!

  block="$(_mux_rx_modal_layer "$pane_w" "$pane_h" "$header" -- \
    --title "$header" --no-chrome --capture "$fifo" \
    -- "$picklist" "${pick_args[@]}" --no-border --height -1 --margin 0,0,0,0 --padding 0,2,0,2 -- "$tmp")"
  if [[ -z "$block" ]]; then
    # No layer: no writer will ever come, so unblock and reap the reader,
    # then pick inline — the picker the caller asked for, without the float.
    kill "$reader_pid" 2>/dev/null
    wait "$reader_pid" 2>/dev/null
    rm -f -- "$fifo" "$out"
    local rc=0
    (( interrupted )) && rc=130
    (( rc )) || pick::start "${pick_args[@]}" <"$tmp" || rc=$?
    rm -f -- "$tmp"
    return $rc
  fi
  (( interrupted )) && _mux_rx_close_block "$block"

  local answered=0
  _mux_rx_await_modal "$block" "$reader_pid" && answered=1

  local result=""
  (( answered )) && result=$(cat "$out")
  rm -f -- "$fifo" "$tmp" "$out"

  [[ -n "$result" ]] || return 130
  print -r -- "$result"
}

# _mux_rx_float --type T [--title TITLE] [--pane-width W] [--pane-height H] -- <widget args…>
# The layer IS the pane and draws no frame of its own around the widget, so —
# as with tmux's borderless popup — the measured height is used as it is.
# --borderless and --pane-x/-y are accepted and ignored: a layer is always
# centered over the window.
_mux_rx_float() {
  local type="line" title="" pane_w="" pane_h=""
  local -a wargs
  while (($#)); do
    case "$1" in
      --type)        type="${2:-line}"; shift 2 ;;
      --title)       title="${2-}"; shift 2 ;;
      --borderless)  shift 2 ;;
      --pane-width)  pane_w="${2-}"; shift 2 ;;
      --pane-height) pane_h="${2-}"; shift 2 ;;
      --pane-x | --pane-y) shift 2 ;;
      --) shift; wargs+=("$@"); break ;;
      *) shift ;;
    esac
  done

  local widget="$HOME/.local/libexec/input-widget"

  local fifo out
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/rxinput-fifo.XXXXXX")
  mkfifo -m 600 "$fifo" 2>/dev/null || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/rxinput-out.XXXXXX") || { rm -f -- "$fifo"; return 1; }
  setopt localoptions localtraps
  local block="" interrupted=0
  trap 'interrupted=1; _mux_rx_close_block "$block"' INT TERM

  # Same measured-height contract as the other floats (input-common's
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
  [[ -n "$pane_w" ]] || pane_w="60%"

  # --no-chrome, and no --title for the modal: the input widgets draw their
  # own box and title. On tmux the modal's header scrolls out of a popup that
  # is exactly as tall as the widget; a layer is sized as a fraction of the
  # window and is rarely that exact, so the header would stay above the
  # widget's own. The title still labels the layer.
  local -a modal_args=(--no-chrome --capture "$fifo")

  cat "$fifo" >"$out" 2>/dev/null &
  local reader_pid=$!

  block="$(_mux_rx_modal_layer "$pane_w" "$_measured_h" "$title" -- \
    "${modal_args[@]}" -- "$widget" --type "$type" -- "${wargs[@]}")"
  if [[ -z "$block" ]]; then
    # No layer: ask inline, as outside a multiplexer.
    kill "$reader_pid" 2>/dev/null
    wait "$reader_pid" 2>/dev/null
    rm -f -- "$fifo" "$out"
    (( interrupted )) && return 130
    input::"$type" "${wargs[@]}"
    return
  fi
  (( interrupted )) && _mux_rx_close_block "$block"

  local answered=0
  _mux_rx_await_modal "$block" "$reader_pid" && answered=1

  local result=""
  (( answered )) && result=$(cat "$out")
  rm -f -- "$fifo" "$out"
  [[ -n "$result" ]] || return 130
  print -rn -- "$result"
}

# _mux_rx_show_window <session> <window id> — make the app show that tab.
#
# A window made (or focused) on the server becomes the session's active
# window there, and the app goes on showing the tab it was on: measured on
# app 0.1.0-preview.37 for `window new`, `window focus` and `focus <block>`
# alike. Only a client action moves the app, so this runs the app's own
# `session.select` on it — on $REX_CLIENT when the caller knows which app
# asked, otherwise on every connected app that has the session open (tmux's
# rule: a new window shows on every client attached to the session). Best
# effort: an app that does not allow remote control stays where it is.
_mux_rx_show_window() {
  local session="$1" window="$2" sid clients c
  [[ -n "$window" ]] || return 1
  [[ -n "$session" ]] || session="$(_mux_rx_session)" || return 1
  sid="$(_mux_rx_view "$session" | jq -r '.session_id // empty' 2>/dev/null)"
  [[ -n "$sid" ]] || return 1
  if [[ -n "${REX_CLIENT:-}" ]]; then
    clients="$REX_CLIENT"
  else
    clients="$(_mux_rx_run --timeout 3s client ls --json 2>/dev/null | jq -r --arg s "$sid" '
      (.clients // .)[]?
      | select(.info.kind? == "app" and .connection_state? == "connected")
      | select((.session_ids // []) | index($s))
      | .client_id' 2>/dev/null)"
  fi
  [[ -n "$clients" ]] || return 1
  for c in ${(f)clients}; do
    _mux_rx_run --timeout 3s -C "$c" do -s "$sid" session.select \
      "session_id=$sid" "window_id=$window" >/dev/null 2>&1 || :
  done
  return 0
}

# _mux_rx_label_arg <label> — the label as `rex window new` can take it. The
# label is positional there (no --label flag, and `--` already starts the
# command), so one that starts with a dash would be read as flags: `-logs` is
# `-l -o -g -s`. A leading space keeps it a label.
_mux_rx_label_arg() {
  if [[ "$1" == -* ]]; then print -r -- " $1"; else print -r -- "$1"; fi
}

# _mux_rx_new_tab <session> <name> <cwd> <singleton> -- <cmd...>
# The new tab is shown (_mux_rx_show_window), as tmux's new-window does.
# Singleton: an existing window of that label is closed and re-created, the
# equivalent of tmux's `respawn-window -k` (a stale `tm` tab is replaced, not
# stacked). Rex has no respawn, so the window id changes; the label does not.
_mux_rx_new_tab() {
  local session="$1" name="$2" cwd="$3" singleton="${4:-0}"
  shift 4
  [[ "${1-}" == "--" ]] && shift

  [[ -n "$session" ]] || session="$(_mux_rx_session)" || return 1
  if (( singleton )) && [[ -n "$name" ]]; then
    local old
    for old in "${(@f)$(_mux_rx_view "$session" |
        jq -r --arg n "$name" '.windows[]? | select(.label == $n) | .window_id')}"; do
      [[ -n "$old" ]] && _mux_rx_run window close -s "$session" "$old" >/dev/null 2>&1
    done
  fi

  local -a flags=(-s "$session" --json)
  [[ -n "$cwd" ]] && flags+=(-c "$cwd")
  local -a label=()
  [[ -n "$name" ]] && label=("$(_mux_rx_label_arg "$name")")
  local out
  if (($#)); then
    out="$(_mux_rx_run window new "${flags[@]}" "${label[@]}" -- "$@" 2>/dev/null)" || return 1
  else
    out="$(_mux_rx_run window new "${flags[@]}" "${label[@]}" 2>/dev/null)" || return 1
  fi
  _mux_rx_show_window "$session" "$(print -r -- "$out" | jq -r '.window_id // empty' 2>/dev/null)" || :
  return 0
}

# _mux_rx_send_text <text> [block] — literal text, no trailing newline.
_mux_rx_send_text() {
  local s b="${2:-${REX_BLOCK:-}}"
  s="$(_mux_rx_session)" || return 1
  [[ -n "$b" ]] || return 1
  _mux_rx_run send -s "$s" -b "$b" -- "$1" >/dev/null 2>&1
}

_mux_rx_send_key() {
  local key s
  case "$1" in
    up | down | left | right | enter) key="$1" ;;
    s-up) key=shift+up ;;
    s-down) key=shift+down ;;
    *) return 1 ;;
  esac
  s="$(_mux_rx_session)" || return 1
  [[ -n "${REX_BLOCK:-}" ]] || return 1
  _mux_rx_run send-key -s "$s" -b "$REX_BLOCK" "$key" >/dev/null 2>&1
}

# _mux_rx_window_of_block — "<1-based position>\t<label>" of the window our
# block lives in. NOT the session's active window: a script running in a
# background tab must name its own tab, as tmux's pane-relative `display -p`
# does.
_mux_rx_window_of_block() {
  [[ -n "${REX_BLOCK:-}" ]] || return 1
  _mux_rx_view | jq -r --arg b "$REX_BLOCK" '
    .windows // [] | to_entries[]
    | select([.value.layers[]?.blocks[]?.block_id] | index($b))
    | "\(.key + 1)\t\(.value.label // "")"' 2>/dev/null | head -n 1
}

_mux_rx_current_tab() {
  local row
  row="$(_mux_rx_window_of_block)" && [[ -n "$row" ]] || return 1
  print -r -- "${row%%$'\t'*}"
}

_mux_rx_current_tab_name() {
  local row
  row="$(_mux_rx_window_of_block)" && [[ -n "$row" ]] || return 1
  print -r -- "${row#*$'\t'}"
}

# _mux_rx_focus_tab <position> — 1-based, the number _mux_rx_current_tab
# prints.
_mux_rx_focus_tab() {
  local s
  s="$(_mux_rx_session)" || return 1
  _mux_rx_run window focus -s "$s" "$1" >/dev/null 2>&1 || return 1
  # And the app, which does not follow the server's active window.
  [[ "$1" == <-> ]] && _mux_rx_show_window "$s" "$(_mux_rx_view "$s" |
    jq -r --argjson n "$1" '.windows[$n - 1].window_id // empty' 2>/dev/null)"
  return 0
}

# Session-wide, as on tmux (`list-panes -s`).
_mux_rx_pane_count() {
  local s
  s="$(_mux_rx_session)" || return 1
  _mux_rx_run block ls -s "$s" --json 2>/dev/null | jq -r '.blocks // [] | length'
}

# The FOREGROUND process's directory — Rex tracks it natively, so this is
# right even in a shell that never reported its cwd.
_mux_rx_pane_cwd() {
  [[ -n "${REX_BLOCK:-}" ]] || return 1
  _mux_rx_block_call "$REX_BLOCK" process | jq -r '.foreground.cwd // empty' 2>/dev/null
}

# "<cols> <rows>" of the window, the nearest thing to tmux's client size.
_mux_rx_terminal_size() {
  _mux_rx_window_cells
}

# _mux_rx_focused_command [pid] — the foreground command NAME of our block.
# A client pid cannot be answered, for the reason in _mux_rx_resolve_session.
_mux_rx_focused_command() {
  [[ -z "${1:-}" ]] || return 1
  [[ -n "${REX_BLOCK:-}" ]] || return 1
  _mux_rx_block_call "$REX_BLOCK" process | jq -r '.foreground.name // empty' 2>/dev/null
}

# Floating layers are core Rex, not a version-gated extra as on tmux.
_mux_rx_has_float_pane() { _mux_rx_available; }

# _mux_rx_float_pane <w> <h> -- <cmd...> — a persistent, centered floating
# block; prints its id. Same geometry rules as the popup.
_mux_rx_float_pane() {
  local w="$1" h="$2"
  shift 2
  [[ "${1-}" == "--" ]] && shift
  _mux_rx_layer "$w" "$h" "" "" "" -- "$@"
}
