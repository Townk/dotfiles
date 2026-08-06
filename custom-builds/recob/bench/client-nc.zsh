#!/usr/bin/env zsh
# The SAME exchange as client-ztcp.zsh, but through `nc` — isolates the cost of
# spawning the transport binary from the cost of the server's launch shape.
setopt nomultibyte
printf 'H\000\000\000\000' | nc -w 2 127.0.0.1 ${1:?port} >/dev/null 2>&1
