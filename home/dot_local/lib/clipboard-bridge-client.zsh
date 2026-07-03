#!/usr/bin/env zsh
# clipboard-bridge-client.zsh — minimal client for the clipboard-bridge framing
# protocol (docs/clipboard-universal-project.md §11). Sends one framed request
#   <1-byte opcode><4-byte BE length><payload>
# to the reverse-tunnel unix socket and reports whether the server (the laptop's
# clipboard-bridge-dispatch) answered with an 'O' (ok) status byte.
#
# Used by pick-clipboard's origin-aware Ctrl-Y for the reverse-channel copy-back
# (S restore-by-id, C ship-rich). The G/R response *payloads* are consumed by
# the nvim provider over libuv, not from zsh, so this client only needs the
# status byte — it never has to parse a framed response body.
#
# Byte-safe: like the dispatcher, it runs under `setopt nomultibyte` so the
# BE-length bytes and any binary payload (an image blob) are counted and written
# as raw bytes, never mangled by the UTF-8 locale's character semantics. The
# length bytes and payload are assembled in a temp file (never a $(...) capture,
# which truncates embedded NULs).

# clipbridge::send <sock> <opcode> <payload_file>
#   Streams <opcode><BE32 len><payload-bytes> to <sock> via `nc -U` and returns
#   0 iff the response begins with the 'O' status byte. Returns non-zero on a
#   missing socket, connection failure, timeout, or an 'E' error response.
clipbridge::send() {
  emulate -L zsh              # local options: resets the caller's errexit etc.
  setopt nomultibyte          # count/emit bytes, not decoded characters
  local sock=$1 opcode=$2 payload_file=$3
  [[ -S "$sock" && -r "$payload_file" ]] || return 1
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
  nc -U -w 2 "$sock" < "$reqf" > "$respf" 2>/dev/null
  local status_byte
  status_byte=$(dd if="$respf" bs=1 count=1 2>/dev/null)
  rm -f "$reqf" "$respf"
  [[ "$status_byte" == "O" ]]
}
