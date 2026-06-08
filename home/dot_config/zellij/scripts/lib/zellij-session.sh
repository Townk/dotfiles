# zellij-session.sh — resolve which Zellij session a client process is wired to
# by reading the unix-domain sockets it holds. No `--session` needed, so it
# tracks live session switches and cute auto-names. Sourced (not executed) by
# both zellij-open (file:// link router) and quick-launch-window (session →
# WezTerm window focus). Pure shell functions; safe to source in bash or zsh.

# resolve_session <client_pid>
#   Echo the session name the given Zellij client PID is attached to, or return
#   non-zero. A Zellij client holds a socket whose peer is its session server's
#   listening socket, bound at .../<contract>/<session_name>; we find that one
#   external peer and read the owning server's bound path.
#
#   Session names may contain spaces (e.g. "Home MacMini M4 Pro"), and lsof
#   prints the bound path unquoted in its trailing NAME column — so the path is
#   reconstructed from fields 8..NF, NOT `$NF` (which would yield just "Pro").
resolve_session() {
  local client_pid="$1" pids lsof_out cl locals peers external e spath
  pids=$(ps -axww -o pid=,command= | awk '/\/zellij( |$)/ {print $1}' | paste -sd, -)
  [ -n "$pids" ] || return 1
  lsof_out=$(lsof -nP -U -a -p "$pids" 2>/dev/null | grep "unix" || true)
  cl=$(printf '%s\n' "$lsof_out" | awk -v p="$client_pid" '$2==p')
  [ -n "$cl" ] || return 1
  locals=$(printf '%s\n' "$cl" | awk '{print $6}' | grep '^0x' | sort -u)
  peers=$(printf '%s\n' "$cl" | grep -oE '\->0x[0-9a-f]+' | sed 's/->//' | sort -u)
  external=$(comm -23 <(printf '%s\n' "$peers") <(printf '%s\n' "$locals"))
  for e in $external; do
    spath=$(printf '%s\n' "$lsof_out" \
      | awk -v p="$client_pid" -v a="$e" '$2!=p && $6==a {
          path=""; for (i = 8; i <= NF; i++) path = path (i > 8 ? " " : "") $i
          if (path ~ /\//) { print path; exit }
        }')
    [ -n "$spath" ] && { printf '%s\n' "${spath##*/}"; return 0; }
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
  local wez tty wid pane cpid s
  wez="${WEZTERM_BIN:-/opt/homebrew/bin/wezterm}"
  command -v "$wez" >/dev/null 2>&1 || wez=wezterm
  env -u WEZTERM_UNIX_SOCKET -u WEZTERM_PANE "$wez" cli --no-auto-start list --format json 2>/dev/null \
    | jq -r '.[] | [(.tty_name // ""), (.window_id|tostring), (.pane_id|tostring)] | @tsv' 2>/dev/null \
    | while IFS="$(printf '\t')" read -r tty wid pane; do
        [ -n "$tty" ] && [ "$tty" != null ] || continue
        cpid=$(ps -t "${tty#/dev/}" -o pid=,comm= 2>/dev/null | awk '$2 ~ /zellij/ {print $1; exit}')
        [ -n "$cpid" ] || continue
        s=$(resolve_session "$cpid" 2>/dev/null) || continue
        printf '%s\t%s\t%s\n' "$s" "$wid" "$pane"
      done
}
