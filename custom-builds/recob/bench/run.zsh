#!/usr/bin/env zsh
# RECOB launch-shape A/B. Isolates ONE variable: what the listener does per
# accepted connection. Both arms run the identical client and the identical
# per-connection work; arm A pays socat's accept+fork+exec, arm B forks an
# already-warm handler.
#
# Per docs/recob-audit-brief.md#how-to-measure: both arms in ONE session, in
# BOTH orders, never interleaved inside a loop.
set -u
B=${0:A:h}
PORT_A=24901   # socat, fork+EXEC per connection (today's shape)
PORT_B=24902   # warm persistent listener, fork-only per connection

cleanup() {
  [[ -n ${socat_pid:-} ]] && kill $socat_pid 2>/dev/null
  [[ -n ${warm_pid:-} ]] && kill $warm_pid 2>/dev/null
  pkill -f 'recob-bench/warm-listener' 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM

socat TCP-LISTEN:$PORT_A,bind=127.0.0.1,fork,reuseaddr EXEC:"$B/responder.zsh" &
socat_pid=$!
zsh "$B/warm-listener.zsh" $PORT_B &
warm_pid=$!
sleep 1

for p in $PORT_A $PORT_B; do
  if zsh "$B/client-ztcp.zsh" $p; then
    print -r -- "port $p: up"
  else
    print -r -- "port $p: DOWN -- aborting"; exit 1
  fi
done

print -r -- "\n=== ztcp client. order: socat-fork-exec, then warm-fork ==="
hyperfine -w 5 -m 30 -N \
  -n 'A socat fork+exec' "zsh $B/client-ztcp.zsh $PORT_A" \
  -n 'B warm accept+fork' "zsh $B/client-ztcp.zsh $PORT_B"

print -r -- "\n=== ztcp client. order REVERSED: warm-fork, then socat-fork-exec ==="
hyperfine -w 5 -m 30 -N \
  -n 'B warm accept+fork' "zsh $B/client-ztcp.zsh $PORT_B" \
  -n 'A socat fork+exec' "zsh $B/client-ztcp.zsh $PORT_A"

print -r -- "\n=== client transport, against the SAME warm listener: nc vs ztcp ==="
hyperfine -w 5 -m 30 -N \
  -n 'nc client' "zsh $B/client-nc.zsh $PORT_B" \
  -n 'ztcp client' "zsh $B/client-ztcp.zsh $PORT_B"
hyperfine -w 5 -m 30 -N \
  -n 'ztcp client' "zsh $B/client-ztcp.zsh $PORT_B" \
  -n 'nc client' "zsh $B/client-nc.zsh $PORT_B"
