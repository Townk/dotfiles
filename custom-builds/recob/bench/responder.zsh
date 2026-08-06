#!/usr/bin/env zsh
# Arm A responder: what socat EXECs per accepted connection. Mirrors the real
# dispatcher's shape (read a 5-byte header, write a framed reply) but with NO
# library sourcing, so this arm measures socat's accept+fork+exec ALONE.
zmodload zsh/system
setopt nomultibyte
sysread -s 5 -t 2 chunk
syswrite -- $'O\0\0\0\0'
