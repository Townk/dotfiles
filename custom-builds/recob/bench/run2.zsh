#!/usr/bin/env zsh
# What the warm listener amortizes: the REAL dispatcher's startup. `H`
# (get-host) is read-only -- it exercises source+init+dispatch+reply without
# touching the store or the pasteboard (brief: "prefer read-only opcodes").
set -u
B=${0:A:h}
REPO=${0:A:h:h:h}
DISPATCH="$REPO/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

print -r -- "dispatcher: $DISPATCH"
printf 'H\000\000\000\000' | zsh "$DISPATCH" | od -c | head -2

cat > "$B/floor.zsh" <<'EOF'
#!/usr/bin/env zsh
zmodload zsh/net/tcp
zmodload zsh/system
EOF
cat > "$B/dispatch-direct.zsh" <<EOF
#!/usr/bin/env zsh
printf 'H\000\000\000\000' | zsh "$DISPATCH" > /dev/null
EOF
chmod +x "$B/floor.zsh" "$B/dispatch-direct.zsh"

print -r -- "\n=== floor (client interpreter + modules, no socket) ==="
hyperfine -w 5 -m 30 -N -n 'floor' "zsh $B/floor.zsh"

print -r -- "\n=== real dispatcher, spawned per frame (what socat EXECs today) ==="
hyperfine -w 3 -m 20 -N -n 'dispatch-direct' "zsh $B/dispatch-direct.zsh"
hyperfine -w 3 -m 20 -N -n 'dispatch-direct (repeat)' "zsh $B/dispatch-direct.zsh"
