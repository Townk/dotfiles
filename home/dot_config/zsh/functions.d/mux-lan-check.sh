# mux-lan-check.sh — warn when this tmux server has lost Local Network access.
#
# macOS ties Local Network access to the app that started a process (its
# "responsible process"). A tmux server started from a terminal app borrows
# that app's grant, and keeps it only while that app process lives. Once the
# terminal quits (Cmd+Q, an update, a crash) the server and everything it
# spawns become their own responsible process, and macOS answers every LAN
# connection from a non-Apple binary (python, adb, Homebrew's curl) with
# "No route to host". Apple's own binaries (/usr/bin/curl, ssh, nc) and the
# default gateway are exempt, which is what makes the fault look random.
# Re-attaching from a new terminal does not repair it: only a new server does.
# Measured 2026-11-14 on macOS 27.0.1 with a throwaway server (-L).
#
# The check is one fork of Apple's python3 (~20 ms), only inside tmux on
# macOS; the server's pid is read from $TMUX, so tmux is never asked. The
# warning is throttled per server (MUX_LAN_WARN_HOURS, default 4) so opening
# panes does not repeat it. Called from .zshrc beside the welcome screen.

# The pid macOS holds responsible for pid $1, on stdout. Fails when it cannot
# tell. /usr/bin/python3 is a shim that opens an install dialog on a Mac
# without the Command Line Tools, so it is only run when they are present.
_mux_lan_responsible() {
  [[ -x /Library/Developer/CommandLineTools/usr/bin/python3 ]] || return 1
  /usr/bin/python3 -c 'import ctypes, sys
print(ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid(int(sys.argv[1])))' "$1" 2>/dev/null
}

mux_lan_check() {
  [[ "$OSTYPE" == darwin* && -n "${TMUX:-}" ]] || return 0
  local server="${${(s:,:)TMUX}[2]}" owner
  [[ "$server" == <-> ]] || return 0
  owner="$(_mux_lan_responsible "$server")" || return 0
  [[ "$owner" == "$server" ]] || return 0

  local stamp="${TMPDIR:-/tmp}/mux-lan-orphan.$server"
  local -a recent=( "$stamp"(Nmh-${MUX_LAN_WARN_HOURS:-4}) )
  (( $#recent )) && return 0
  : >| "$stamp"
  # A stamp outlives its server otherwise: drop those whose server is gone.
  local old
  for old in "${TMPDIR:-/tmp}"/mux-lan-orphan.<->(N); do
    [[ "$old" == "$stamp" ]] || kill -0 "${old##*.}" 2>/dev/null || rm -f -- "$old"
  done

  print -P -- "%F{yellow}⚠ This tmux server (pid $server) outlived the terminal app that started it.%f"
  print -r -- "  macOS now blocks LAN connections from non-Apple tools here (python, adb: \"No route to host\")."
  print -r -- "  Fix: run 'tmux kill-server' and open tmux again. That ends every session in this server."
  return 0
}
