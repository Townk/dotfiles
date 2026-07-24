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
