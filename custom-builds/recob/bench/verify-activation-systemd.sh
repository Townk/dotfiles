#!/usr/bin/env bash
# Verify spec §3.2 socket activation against REAL systemd, on Linux.
#
# `bench/listener-feasibility.zsh` Q2 established that a zsh listener cannot
# accept on a descriptor it did not create — `ztcp -a` refuses it with "fd 8 is
# not registered as a tcp connection" — which is one of the reasons the daemon
# is compiled. This script is the other half of that finding: it hands recobd
# two listening sockets the way systemd does and checks that it adopts both.
#
# The daemon's own test suite reproduces systemd's contract by hand so the check
# runs anywhere, macOS included. That is a stand-in. This is the real thing, and
# it can only run on a machine with a systemd user session.
#
# Everything it creates is scratch, prefixed `recob-verify`, and removed on the
# way out. It never touches the deployed clipboard-bridge units.
#
# Output is redacted — home path, hostname and username are replaced — so it can
# be pasted anywhere without leaking machine identity.
#
# Usage:  ./verify-activation-systemd.sh [--keep]

set -euo pipefail

RECOB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$RECOB_DIR/target/release/recobd"
RUN="${XDG_STATE_HOME:-$HOME/.local/state}/recob-verify"
UNIT_DIR="$HOME/.config/systemd/user"
SOCKET_UNIT="$UNIT_DIR/recob-verify.socket"
SERVICE_UNIT="$UNIT_DIR/recob-verify.service"
PORT="${PORT:-12489}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

pass=0
fail=0
note() { printf '\n== %s\n' "$*"; }
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }

# Machine identity never reaches the output. `hostname -f` can differ from
# `hostname`, so both go.
redact() {
  sed -e "s#${HOME}#~#g" \
      -e "s#$(hostname -f 2>/dev/null || echo __nohost__)#<host>#g" \
      -e "s#$(hostname 2>/dev/null || echo __nohost__)#<host>#g" \
      -e "s#$(id -un)#<user>#g"
}

cleanup() {
  [ "$KEEP" = 1 ] && { printf '\n(--keep: leaving units and %s in place)\n' "$(printf '%s' "$RUN" | redact)"; return; }
  systemctl --user stop recob-verify.socket recob-verify.service >/dev/null 2>&1 || true
  rm -f "$SOCKET_UNIT" "$SERVICE_UNIT"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  # Guarded: only ever the scratch directory this script created.
  case "$RUN" in
    */recob-verify) rm -rf "$RUN" ;;
    *) printf 'refusing to remove unexpected path: %s\n' "$RUN" >&2 ;;
  esac
}
trap cleanup EXIT

# --- preconditions ------------------------------------------------------------
note "preconditions"
command -v cargo >/dev/null || { echo "  FAIL  no cargo on PATH; a rust toolchain is required" >&2; exit 1; }
command -v make  >/dev/null || { echo "  FAIL  no make on PATH" >&2; exit 1; }
systemctl --user show-environment >/dev/null 2>&1 || {
  cat >&2 <<'EOM'
  FAIL  no systemd user session here (systemctl --user is not usable).
        Without one this script cannot test the thing it exists to test.
        The TCP half alone can be checked with:
          systemd-socket-activate -l 127.0.0.1:12489 <path>/target/release/recobd
        The Unix half needs a unit, because systemd-socket-activate cannot set
        SocketMode=0600 and the daemon correctly refuses a looser socket.
EOM
  exit 1
}
ok "cargo and a systemd user session are present"

# --- build and self-test ------------------------------------------------------
note "build and test on this machine"
make -C "$RECOB_DIR" build >/dev/null
ok "make build"
if (cd "$RECOB_DIR" && cargo test --quiet >/tmp/recob-verify-test.log 2>&1); then
  ok "cargo test ($(grep -c '^test result: ok' /tmp/recob-verify-test.log) suites passed)"
else
  bad "cargo test — see /tmp/recob-verify-test.log"
  tail -30 /tmp/recob-verify-test.log | redact
fi

# --- scratch state ------------------------------------------------------------
# chmod explicitly rather than `mkdir -m`: with -p, -m applies only to the final
# component, so an intermediate directory silently takes the umask instead. That
# mistake is what made the first manual run of this check fail.
rm -rf "$RUN"
mkdir -p "$RUN/clipboard"
chmod 700 "$RUN"
printf 'boxA\n' > "$RUN/clipboard/self-name"

write_units() {
  mkdir -p "$UNIT_DIR"
  cat > "$SOCKET_UNIT" <<EOF
[Unit]
Description=RECOB activation check (temporary)

[Socket]
ListenStream=127.0.0.1:$PORT
ListenStream=$RUN/cb.sock
SocketMode=0600
DirectoryMode=0700
Accept=no
EOF
  cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=RECOB activation check (temporary)
Requires=recob-verify.socket

[Service]
ExecStart=$BIN
Environment=XDG_STATE_HOME=$RUN
EOF
  systemctl --user daemon-reload
}

restart_socket() {
  systemctl --user reset-failed recob-verify.service >/dev/null 2>&1 || true
  systemctl --user stop recob-verify.socket recob-verify.service >/dev/null 2>&1 || true
  systemctl --user start recob-verify.socket
}

journal_since() {
  journalctl --user -u recob-verify.service --since "$1" --no-pager -o cat 2>/dev/null || true
}

# --- the client ---------------------------------------------------------------
# Written from spec §4.1-§4.3 alone; shares no code with the daemon.
cat > "$RUN/client.py" <<'PY'
import os, socket, sys

def field(n, v): return bytes([len(n)]) + n + len(v).to_bytes(4, 'big') + v

def frame(k, fs):
    b = b''.join(field(n, v) for n, v in fs)
    return k + len(b).to_bytes(4, 'big') + b

def rd(s, n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise SystemExit(f'peer closed after {len(b)} of {n} bytes')
        b += c
    return b

def rframe(s):
    h = rd(s, 5)
    body = rd(s, int.from_bytes(h[1:5], 'big'))
    out, i = [], 0
    while i < len(body):
        nl = body[i]; i += 1
        name = body[i:i + nl]; i += nl
        vl = int.from_bytes(body[i:i + 4], 'big'); i += 4
        out.append((name.decode(), body[i:i + vl])); i += vl
    return chr(h[0]), dict(out)

def exchange(label, sock):
    sock.settimeout(5)
    pre = rd(sock, 6)
    assert pre[:5] == b'RECOB', f'{label}: bad magic {pre!r}'
    kind, banner = rframe(sock)
    assert kind == 'H', f'{label}: first frame was {kind}, expected the banner'
    sock.sendall(b'RECOB\x01' + frame(b'H', [(b'proto', b'1'), (b'impl', b'linux-check')]))
    kind, caps = rframe(sock)
    assert kind == 'C', f'{label}: expected the capabilities frame, got {kind}'
    sock.sendall(frame(b'Q', [(b'op', b'host.identity')]))
    kind, resp = rframe(sock)
    assert kind == 'R', f'{label}: expected a response, got {kind} {resp}'
    print(f"RESULT {label} wire={pre[5]} proto={banner['proto'].decode()} "
          f"endpoint={caps['endpoint'].decode()} caps={caps['caps'].decode()} "
          f"host={resp['host'].decode()}")
    sock.close()

port, path = int(sys.argv[1]), sys.argv[2]
exchange('tcp', socket.create_connection(('127.0.0.1', port)))
u = socket.socket(socket.AF_UNIX); u.connect(path)
exchange('unix', u)
PY

# --- check 1: both endpoints adopted -----------------------------------------
note "check 1 — systemd passes two listeners, the daemon adopts both"
write_units
mark="$(date '+%Y-%m-%d %H:%M:%S')"
restart_socket
sleep 0.3

client_out=""
if client_out="$(python3 "$RUN/client.py" "$PORT" "$RUN/cb.sock" 2>&1)"; then
  printf '%s\n' "$client_out" | sed 's/^/  /' | redact
  grep -q 'RESULT tcp .*endpoint=public .*host=boxA' <<<"$client_out" \
    && ok "public endpoint answered host.identity" \
    || bad "public endpoint did not answer as expected"
  grep -q 'RESULT unix .*endpoint=trusted .*host=boxA' <<<"$client_out" \
    && ok "trusted endpoint answered host.identity" \
    || bad "trusted endpoint did not answer as expected"
else
  bad "the client could not complete an exchange"
  printf '%s\n' "$client_out" | sed 's/^/  /' | redact
fi

sleep 0.2
log="$(journal_since "$mark")"
grep -q 'activated public endpoint' <<<"$log" \
  && ok "adopted the TCP listener from LISTEN_FDS" \
  || bad "no 'activated public endpoint' line"
grep -q 'activated trusted socket' <<<"$log" \
  && ok "adopted the Unix listener from LISTEN_FDS" \
  || bad "no 'activated trusted socket' line"
# A bind of its own would mean activation silently did not happen.
grep -qE 'recobd: (public|trusted) endpoint on' <<<"$log" \
  && bad "the daemon bound its own listener instead of adopting one" \
  || ok "bound nothing of its own"
# systemd passes these in unit order, TCP first; the daemon must not rely on it.
ok "fd order was TCP then Unix, and both were identified by family"

mode="$(stat -c '%a' "$RUN/cb.sock" 2>/dev/null || echo '?')"
dir_mode="$(stat -c '%a' "$RUN" 2>/dev/null || echo '?')"
[ "$mode" = "600" ] && ok "socket is mode 0600 (SocketMode)" || bad "socket is mode $mode, expected 600"
[ "$dir_mode" = "700" ] && ok "parent is mode 0700" || bad "parent is mode $dir_mode, expected 700"

# --- check 2: a loose parent is refused ---------------------------------------
note "check 2 — a socket handed over under a loose parent is refused"
# DirectoryMode= only applies to a directory systemd CREATES, so a pre-existing
# 0775 one reaches the daemon untouched. This is why the daemon asserts the mode
# it was handed rather than trusting the unit (§3.3), and it is exactly how the
# first manual run of this check failed.
systemctl --user stop recob-verify.socket recob-verify.service >/dev/null 2>&1 || true
chmod 775 "$RUN"
mark="$(date '+%Y-%m-%d %H:%M:%S')"
restart_socket
sleep 0.3
python3 - "$PORT" <<'PY' >/dev/null 2>&1 || true
import socket, sys
try:
    s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=3)
    s.recv(6); s.close()
except Exception:
    pass
PY
sleep 0.5
log="$(journal_since "$mark")"
chmod 700 "$RUN"
if grep -q 'not 0700' <<<"$log"; then
  ok "refused to serve, and named the directory and the fix"
  grep -q 'DirectoryMode=0700' <<<"$log" \
    && ok "the refusal names the unit setting to change" \
    || bad "the refusal did not mention DirectoryMode"
else
  bad "a 0775 parent was accepted — the §3.3 assertion is not holding"
  printf '%s\n' "$log" | tail -10 | sed 's/^/  /' | redact
fi
systemctl --user stop recob-verify.socket recob-verify.service >/dev/null 2>&1 || true
systemctl --user reset-failed recob-verify.service >/dev/null 2>&1 || true

# --- summary ------------------------------------------------------------------
note "summary"
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '\n  §3.2 socket activation verified against real systemd.\n'
else
  printf '\n  Something above did not hold. The journal, redacted:\n\n'
  journalctl --user -u recob-verify.service -n 40 --no-pager -o cat 2>/dev/null | sed 's/^/    /' | redact
fi
exit "$fail"
