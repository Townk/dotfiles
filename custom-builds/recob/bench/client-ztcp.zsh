#!/usr/bin/env zsh
# One full exchange over ztcp: connect, send a 5-byte frame, read the 5-byte
# reply, close. Identical for both server arms so only the SERVER differs.
zmodload zsh/net/tcp
zmodload zsh/system
setopt nomultibyte
ztcp 127.0.0.1 ${1:?port} || exit 1
fd=$REPLY
syswrite -o $fd -- $'H\0\0\0\0'
sysread -s 5 -i $fd -t 2 chunk
ztcp -c $fd
[[ ${chunk[1,1]} == O ]]
