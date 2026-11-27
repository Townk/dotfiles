#!/usr/bin/env zsh
# mux/rex.zsh — the Rex backend of the mux::* shim.
#
# Off-PATH internal library, SOURCED by mux-bootstrap.zsh beside mux/tmux.zsh
# and mux/zellij.zsh. Like them it only ever shells out — here to the `rex`
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
# NOT here on purpose (later phases): the widget floats (_mux::float /
# _mux::pick_float stay tmux/zellij-only, so pickers and dialogs render inline
# in a Rex pane), the mode stack, and the autostart exec verbs — nothing
# launches INTO Rex from a shell.
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

# Sessions some Rex APP currently shows — the CLI's own short-lived
# connections are clients too, and must not count as "attached".
_mux_rx_attached_sessions() {
  local sessions clients
  sessions="$(_mux_rx_run ls --json 2>/dev/null)" || return 1
  clients="$(_mux_rx_run client ls --json 2>/dev/null)" || return 1
  jq -rn --argjson s "$sessions" --argjson c "$clients" '
    ([$c.clients[]? | select(.info.kind == "app") | .session_ids[]?] | unique) as $ids
    | $s.sessions[]? | select(.session_id as $i | $ids | index($i)) | .label // empty'
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
# Rex splits by ratio, and a cell count has no ratio without knowing the
# anchor's size — dropped rather than guessed, as zellij drops every size.
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

# _mux_rx_window_cells [view-json] — "<cols> <rows>" of the WINDOW our block
# is in. Rex reports cells per block and layout as fractions of the window,
# so the window is the block's cells divided by its share. Used to turn the
# shim's cell-based popup/float geometry into the fractions Rex wants.
_mux_rx_window_cells() {
  [[ -n "${REX_BLOCK:-}" ]] || return 1
  local view="${1:-}" rect size
  [[ -n "$view" ]] || view="$(_mux_rx_view)" || return 1
  rect="$(print -r -- "$view" | jq -r --arg b "$REX_BLOCK" '
    [.. | objects | select(.block_id? == $b and (.rect? | type) == "array") | .rect] | first
    | if . then "\(.[2]) \(.[3])" else empty end' 2>/dev/null)"
  size="$(_mux_rx_block_call "$REX_BLOCK" size | jq -r '"\(.columns) \(.rows)"' 2>/dev/null)"
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

# _mux_rx_new_tab <session> <name> <cwd> <singleton> -- <cmd...>
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

  local -a flags=(-s "$session")
  [[ -n "$cwd" ]] && flags+=(-c "$cwd")
  local -a label=()
  [[ -n "$name" ]] && label=("$name")
  if (($#)); then
    _mux_rx_run window new "${flags[@]}" "${label[@]}" -- "$@" >/dev/null 2>&1
  else
    _mux_rx_run window new "${flags[@]}" "${label[@]}" >/dev/null 2>&1
  fi
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
  _mux_rx_run window focus -s "$s" "$1" >/dev/null 2>&1
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
