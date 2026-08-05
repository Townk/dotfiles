#!/usr/bin/env zsh
# clipboard-bridge-client.zsh — minimal client for the clipboard-bridge framing
# protocol (docs/clipboard-universal-project.md §11). Sends one framed request
#   <1-byte opcode><4-byte BE length><payload>
# to a loopback TCP endpoint and reports whether the server answered 'O' (ok).
#
# Cross-machine transport stays TCP: macOS OpenSSH silently ignores
# StreamLocalBindUnlink for remote Unix-socket forwards, so an unclean
# disconnect strands a stale socket file. Endpoints: 2490 = reverse-forwarded
# peer, 2489 = public local listener. Privileged local file operations are the
# deliberate exception: they use the service-owned mode-0600 cb.sock, which is
# never forwarded and whose lifecycle is controlled by socat/systemd.
#
# Used by pick-clipboard's Ctrl-Y (T set-with-regtype, C ship-rich to the peer).
# Response *payloads* (G/R) are consumed by
# the nvim provider over libuv, not here, so this only needs the status byte.
#
# Byte-safe: runs under `setopt nomultibyte` so the BE-length bytes and any
# binary payload (an image blob) are counted/written as raw bytes, and no payload
# ever passes through a $(...) capture (which truncates NULs).
zmodload zsh/stat    2>/dev/null   # zstat: payload length without spawning wc
zmodload zsh/system  2>/dev/null   # sysread: byte-exact copy without spawning cat

# CLIPBRIDGE_TIMEOUT_S overrides the wire timeout (default 2s). Two seconds
# is right for a clipboard read — the far end answers from memory — but an op
# that makes the ORIGIN DO something can legitimately take longer: a window
# animation, or a first-use macOS Automation consent dialog that blocks the
# AppleScript until a human clicks it. Timing out there reports "refused" for
# an action that actually happened, which is worse than waiting (observed on
# the very first `W fullscreen-toggle`).

# clipbridge::probe <host> <port>
#   0 iff something is accepting on host:port (a live forward). Cheap connect
#   scan — this is the honest "bridge-up" test (a down/stale tunnel refuses).
clipbridge::probe() {
  nc -z -w 1 "$1" "$2" >/dev/null 2>&1
}

# clipbridge::local_socket -> trusted endpoint path. This socket is owned by
# socat/systemd, mode 0600, and is never an SSH forwarding endpoint.
clipbridge::local_socket() {
  print -rn -- "${CLIPBOARD_BRIDGE_LOCAL_SOCKET:-$HOME/.local/state/cb.sock}"
}

# clipbridge::send <host> <port> <opcode> <payload_file>
#   Streams <opcode><BE32 len><payload-bytes> to host:port via `nc` and returns
#   0 iff the response begins with the 'O' status byte. Non-zero on an
#   unreachable endpoint, timeout, or an 'E' error response.
#
#   Assembled with BUILTINS only: zstat for the length, arithmetic expansion for
#   the four BE bytes, and a sysread loop to move the payload. Every one of those
#   used to be a process — wc, four `$(printf %03o)` subshells, two mktemps, cat,
#   dd and rm, eleven of them to send one frame — which measured 133ms against a
#   91ms floor for the bare nc exchange through socat. The frame now goes
#   straight into nc's stdin and the status byte is read straight back out, so
#   the filesystem is not involved at all.
#
#   Returning on the status BYTE rather than on nc's exit is deliberate: the
#   contract is "the far end answered O", and waiting for the connection to
#   finish tearing down afterwards buys the caller nothing.
clipbridge::send() {
  emulate -L zsh              # local options: resets the caller's errexit etc.
  setopt nomultibyte          # count/emit bytes, not decoded characters
  local host=$1 port=$2 opcode=$3 payload_file=$4
  [[ -r "$payload_file" ]] || return 1
  local -a pstat
  zstat -A pstat +size "$payload_file" || return 1
  local -i plen=$pstat[1]
  # `read -k` takes its input from the TERMINAL unless handed an explicit fd,
  # so the reply arrives on a named descriptor rather than plain stdin.
  local byte="" rfd
  exec {rfd}< <(
    {
      printf '%s' "$opcode"
      printf '%b%b%b%b' \
        "\\0$(( [##8] (plen >> 24) & 255 ))" \
        "\\0$(( [##8] (plen >> 16) & 255 ))" \
        "\\0$(( [##8] (plen >> 8) & 255 ))" \
        "\\0$(( [##8] plen & 255 ))"
      while sysread -o 1; do :; done
    } < "$payload_file" |
      nc -w "${CLIPBRIDGE_TIMEOUT_S:-2}" "$host" "$port" 2>/dev/null
  )
  read -t "${CLIPBRIDGE_TIMEOUT_S:-2}" -k 1 -u $rfd byte 2>/dev/null
  exec {rfd}<&-
  [[ "$byte" == "O" ]]
}

# clipbridge::send_unix <socket> <opcode> <payload_file>
# Trusted-local sibling of clipbridge::send. The framing is identical; only
# the transport differs, so no secret or caller-asserted trust bit crosses
# the wire.
clipbridge::send_unix() {
  emulate -L zsh
  setopt nomultibyte
  local sock=$1 opcode=$2 payload_file=$3
  [[ -r "$payload_file" ]] || return 1
  local -i plen
  plen=$(wc -c < "$payload_file" | tr -d ' ')
  local reqf respf
  reqf=$(mktemp "${TMPDIR:-/tmp}/clipbridge-req.XXXXXX") || return 1
  respf=$(mktemp "${TMPDIR:-/tmp}/clipbridge-resp.XXXXXX") ||
    { rm -f "$reqf"; return 1; }
  {
    printf '%s' "$opcode"
    printf "\\$(printf %03o $(( (plen >> 24) & 255 )))\\$(printf %03o $(( (plen >> 16) & 255 )))\\$(printf %03o $(( (plen >> 8) & 255 )))\\$(printf %03o $(( plen & 255 )))"
    cat "$payload_file"
  } > "$reqf"
  nc -U -w "${CLIPBRIDGE_TIMEOUT_S:-2}" "$sock" < "$reqf" > "$respf" 2>/dev/null
  local status_byte
  status_byte=$(dd if="$respf" bs=1 count=1 2>/dev/null)
  rm -f "$reqf" "$respf"
  [[ "$status_byte" == "O" ]]
}

# clipbridge::request <host> <port> <opcode> [payload_file]
#   Like clipbridge::send, but on an 'O' response it writes the response
#   PAYLOAD bytes to stdout (byte-exact via head/tail, never a $(...) capture,
#   so embedded NULs and any trailing newline survive) and returns 0. Non-zero
#   on an unreachable endpoint, timeout, or an 'E' response. This is the read
#   counterpart used by the G/R/H ops whose payload the caller needs (the live
#   peer-clipboard entry, §22); clipbridge::send stays the write/status-only path.
#
#   Extraction is header-length-agnostic: the response is exactly one frame
#   (<status><BE32 len><payload>) followed by EOF, so the payload is simply
#   "everything after the 5-byte header" — `tail -c +6`. No per-byte dd, so a
#   large clip doesn't pay a byte-at-a-time read.
clipbridge::request() {
  emulate -L zsh
  setopt nomultibyte
  local host=$1 port=$2 opcode=$3 payload_file=${4:-}
  local -i plen=0
  [[ -n "$payload_file" && -r "$payload_file" ]] && plen=$(wc -c < "$payload_file" | tr -d ' ')
  local reqf respf
  reqf=$(mktemp "${TMPDIR:-/tmp}/clipbridge-req.XXXXXX")   || return 1
  respf=$(mktemp "${TMPDIR:-/tmp}/clipbridge-resp.XXXXXX") || { rm -f "$reqf"; return 1; }
  {
    printf '%s' "$opcode"
    printf "\\$(printf %03o $(( (plen >> 24) & 255 )))\\$(printf %03o $(( (plen >> 16) & 255 )))\\$(printf %03o $(( (plen >> 8) & 255 )))\\$(printf %03o $(( plen & 255 )))"
    (( plen > 0 )) && cat "$payload_file"
  } > "$reqf"
  nc -w "${CLIPBRIDGE_TIMEOUT_S:-2}" "$host" "$port" < "$reqf" > "$respf" 2>/dev/null
  local st; st=$(head -c 1 "$respf" 2>/dev/null)
  if [[ "$st" != "O" ]]; then rm -f "$reqf" "$respf"; return 1; fi
  tail -c +6 "$respf" 2>/dev/null
  rm -f "$reqf" "$respf"
  return 0
}

# clipbridge::get <host> <port>      -> peer clipboard text (op G) on stdout.
# clipbridge::get_host <host> <port> -> peer hostname (op H) on stdout.
# clipbridge::get_ts <host> <port>   -> peer's CURRENT-clip copy-time (op S,
#   decimal last_ts or empty) on stdout -- lets a consumer sort a live peer
#   entry chronologically instead of always pinning it to the top (X9,
#   pick-clipboard §22). See clip::op_get_ts in the dispatcher for the exact
#   resolution/fallback chain.
clipbridge::get()      { clipbridge::request "$1" "$2" G; }
clipbridge::get_host() { clipbridge::request "$1" "$2" H; }
clipbridge::get_ts()   { clipbridge::request "$1" "$2" S; }
