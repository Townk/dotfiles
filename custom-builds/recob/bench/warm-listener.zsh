#!/usr/bin/env zsh
# Arm B listener: a persistent process that binds once, accepts in a loop, and
# forks an ALREADY-WARM handler per connection (no exec, no re-sourcing).
# Deliberately does the same per-connection work as responder.zsh.
zmodload zsh/net/tcp
zmodload zsh/system
setopt nomultibyte

port=${1:?port}
ztcp -l -d 7 $port || exit 1

# Reap children without a wait loop: SIG_IGN on CHLD makes the kernel do it.
TRAPCHLD() { :; }

while ztcp -a 7; do
  cfd=$REPLY
  (
    sysread -s 5 -i $cfd -t 2 chunk
    syswrite -o $cfd -- $'O\0\0\0\0'
    exec {cfd}>&-
  ) 2>/dev/null &
  ztcp -c $cfd 2>/dev/null
done
