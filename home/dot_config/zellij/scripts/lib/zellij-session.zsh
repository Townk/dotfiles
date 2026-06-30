#!/usr/bin/env zsh
# zellij-session.zsh — resolve which Zellij session a client process is wired to
# by reading the unix-domain sockets it holds. No `--session` needed, so it
# tracks live session switches and cute auto-names. Sourced (not executed) by
# both zellij-open (file:// link router) and quick-launch-window (session →
# WezTerm window focus). Pure zsh functions.

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
