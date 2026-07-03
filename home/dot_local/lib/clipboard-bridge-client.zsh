#!/usr/bin/env zsh
# clipboard-bridge-client.zsh — minimal client for the clipboard-bridge framing
# protocol (docs/clipboard-universal-project.md §11). Sends one framed request
#   <1-byte opcode><4-byte BE length><payload>
# to a loopback TCP endpoint and reports whether the server answered 'O' (ok).
#
# TCP, not a unix socket, on purpose: the bridge channel is carried by an SSH
# forward, and macOS's OpenSSH silently ignores StreamLocalBindUnlink for remote
# unix-socket forwards — so an unclean disconnect strands a stale socket file
# that kills every later forward until it's manually removed. A forwarded TCP
# port is owned by the ssh process and freed by the OS when the session ends, so
# there is nothing to go stale. Endpoints: 2490 = reverse-forwarded peer
# clipboard, 2489 = this machine's own bridge (local set / materialize).
#
# Used by pick-clipboard's Ctrl-Y (T set-with-regtype, C ship-rich to the peer).
# Response *payloads* (G/R) are consumed by
# the nvim provider over libuv, not here, so this only needs the status byte.
#
# Byte-safe: runs under `setopt nomultibyte` so the BE-length bytes and any
# binary payload (an image blob) are counted/written as raw bytes; the request
# is assembled in a temp file, never a $(...) capture (which truncates NULs).

# clipbridge::probe <host> <port>
#   0 iff something is accepting on host:port (a live forward). Cheap connect
#   scan — this is the honest "bridge-up" test (a down/stale tunnel refuses).
clipbridge::probe() {
  nc -z -w 1 "$1" "$2" >/dev/null 2>&1
}

# clipbridge::send <host> <port> <opcode> <payload_file>
#   Streams <opcode><BE32 len><payload-bytes> to host:port via `nc` and returns
#   0 iff the response begins with the 'O' status byte. Non-zero on an
#   unreachable endpoint, timeout, or an 'E' error response.
clipbridge::send() {
  emulate -L zsh              # local options: resets the caller's errexit etc.
  setopt nomultibyte          # count/emit bytes, not decoded characters
  local host=$1 port=$2 opcode=$3 payload_file=$4
  [[ -r "$payload_file" ]] || return 1
  local -i plen
  plen=$(wc -c < "$payload_file" | tr -d ' ')
  local reqf respf
  reqf=$(mktemp "${TMPDIR:-/tmp}/clipbridge-req.XXXXXX")   || return 1
  respf=$(mktemp "${TMPDIR:-/tmp}/clipbridge-resp.XXXXXX") || { rm -f "$reqf"; return 1; }
  {
    printf '%s' "$opcode"
    printf "\\$(printf %03o $(( (plen >> 24) & 255 )))\\$(printf %03o $(( (plen >> 16) & 255 )))\\$(printf %03o $(( (plen >> 8) & 255 )))\\$(printf %03o $(( plen & 255 )))"
    cat "$payload_file"
  } > "$reqf"
  nc -w 2 "$host" "$port" < "$reqf" > "$respf" 2>/dev/null
  local status_byte
  status_byte=$(dd if="$respf" bs=1 count=1 2>/dev/null)
  rm -f "$reqf" "$respf"
  [[ "$status_byte" == "O" ]]
}
