#!/usr/bin/env zsh
# RECOB audit feasibility probe #2 — throwaway, untracked (.git/).
# Q1: warm zsh listener, accept in a loop, fork a handler per connection.
# Q2: can `ztcp -a` accept on a listening fd this process did NOT create
#     (the systemd Accept=no / LISTEN_FDS inherited-fd shape)?
# Q3: zsocket Unix-domain listen/accept + socket mode.
# NOTE: after `ztcp -l -d N <port>`, $REPLY is the FD, not the port.

zmodload zsh/net/tcp
zmodload zsh/net/socket
zmodload zsh/system
setopt nomultibyte

PORT1=24891
PORT2=24892
sock=/tmp/recob-probe.$$.sock
rm -f $sock

# --- Q1: warm listener, fork per connection ---------------------------------
ztcp -l -d 7 $PORT1 || { print "ztcp listen FAILED"; exit 1 }
print -r -- "Q1 listening on $PORT1 (fd $REPLY)"

serve() {
  local -i n=$1 i cfd
  for (( i = 0; i < n; i++ )); do
    ztcp -a 7 || break
    cfd=$REPLY
    (
      local chunk
      sysread -s 5 -i $cfd -t 2 chunk
      syswrite -o $cfd -- "OK$chunk"
      exec {cfd}>&-
    ) &
    ztcp -c $cfd
  done
  wait
}

serve 16 &
server_pid=$!
sleep 0.3

client() {
  ztcp 127.0.0.1 $PORT1 || return 1
  local fd=$REPLY chunk
  syswrite -o $fd -- "hello"
  sysread -s 7 -i $fd -t 2 chunk
  ztcp -c $fd
  print -rn -- "$chunk"
}

print -r -- "Q1 single exchange: [$(client)]"

start=$EPOCHREALTIME
for i in {1..15}; do client >/dev/null; done
end=$EPOCHREALTIME
printf 'Q4 warm accept+fork: %.2f ms/conn (client is in-process ztcp)\n' \
  $(( (end - start) * 1000 / 15 ))

wait $server_pid 2>/dev/null
ztcp -c 7 2>/dev/null

# --- Q2: accept on an INHERITED listening fd --------------------------------
ztcp -l -d 8 $PORT2 || { print "Q2 listen FAILED"; exit 1 }
childscript=/tmp/recob-probe-child.$$.zsh
cat > $childscript <<'CHILD'
#!/usr/bin/env zsh
zmodload zsh/net/tcp
zmodload zsh/system
setopt nomultibyte
# fd 8 is a listening socket created by the PARENT. This process never ran
# `ztcp -l`, so ztcp has no internal record of it -- exactly the systemd
# Accept=no situation where the listener arrives as fd 3.
if ztcp -a 8 2>/tmp/recob-q2.err; then
  cfd=$REPLY
  syswrite -o $cfd -- "INHERITED-OK"
  exec {cfd}>&-
  print -r -- "Q2 accept-on-inherited-fd: WORKS"
else
  print -r -- "Q2 accept-on-inherited-fd: FAILED -- $(< /tmp/recob-q2.err)"
fi
CHILD
zsh $childscript &
child=$!
sleep 0.3
if ztcp 127.0.0.1 $PORT2 2>/dev/null; then
  fd=$REPLY
  sysread -s 12 -i $fd -t 2 c
  ztcp -c $fd
  print -r -- "Q2 client got: [$c]"
else
  print -r -- "Q2 client could not connect"
fi
wait $child 2>/dev/null
ztcp -c 8 2>/dev/null
rm -f $childscript /tmp/recob-q2.err

# --- Q3: Unix-domain listen/accept ------------------------------------------
if zsocket -l -d 9 $sock 2>/dev/null; then
  print -r -- "Q3 zsocket -l: ok (mode $(stat -f '%Lp' $sock 2>/dev/null))"
  (
    zsocket -a 9 && { cfd=$REPLY; syswrite -o $cfd -- "UNIX-OK"; exec {cfd}>&- }
  ) &
  ua=$!
  sleep 0.3
  if zsocket $sock 2>/dev/null; then
    fd=$REPLY
    sysread -s 7 -i $fd -t 2 c
    exec {fd}>&-
    print -r -- "Q3 unix client got: [$c]"
  else
    print -r -- "Q3 unix client could not connect"
  fi
  wait $ua 2>/dev/null
else
  print -r -- "Q3 zsocket -l: FAILED"
fi
rm -f $sock
print -r -- "probe done"
