# recob_helper.sh — spec support for driving the RECOB bridge (§11.1).
#
# The old shape was a fake `nc` on PATH that logged the bytes a client wrote
# and invented the reply. This replaces it with the REAL listener in recording
# mode: `recobd --record`, the shipped binary, bound to a per-example socket and
# port that the existing CLIPBOARD_BRIDGE_LOCAL_SOCKET / CLIPBOARD_BRIDGE_PORT
# overrides point at.
#
# That is strictly stronger, and the difference matters when a test regresses:
# the fake recorded whatever the client emitted, so a client that framed a
# request wrongly was recorded as wrong and the assertion still passed. The
# recorder decodes with the production decoder, so the same client now fails
# the example instead.
#
# Usage:
#
#   Include tests/recob_helper.sh
#   BeforeEach 'recob_start'
#   AfterEach  'recob_stop'
#
#   It '...'
#     asserted() { printf '%s' "$1" | "$(recob_client_bin)" copy; recob_op 1; }
#     When call asserted hello
#     The output should equal 'clip.set'
#   End
#
# ASSERTION SHAPE — drive the client AND print what you want to assert from
# *inside one function*, and put the expectation on that function's output.
# A `The value "$(recob_op 1)"` subject does work (shellspec evaluates it in the
# example's own environment, where the exports below are live, and in place, so
# after the `When`), but it throws away the client's exit status and reports one
# wrong field at a time. Copying is a two-connection action; asserting the wire
# and the status separately is how a half-done copy passes.
#
# Values are logged hex-encoded so NUL and binary payloads survive exactly;
# `recob_field` decodes one so assertions stay readable. No accessor ever falls
# back to reading stdin when the log is missing — an unset RECOB_RECORD_LOG
# reads as "nothing recorded", never as whatever the example's stdin held.

# The binaries under test. Built by `make -C custom-builds/recob build`; the
# helper fails loudly rather than silently skipping, because a spec that
# quietly tests nothing is worse than one that fails.
recob_bin() {
  printf '%s' "${RECOB_BIN:-$SHELLSPEC_PROJECT_ROOT/custom-builds/recob/target/release/recobd}"
}

recob_client_bin() {
  printf '%s' "${SYSTEM_CLIP_BIN:-$SHELLSPEC_PROJECT_ROOT/custom-builds/recob/target/release/system-clip}"
}

recob_bridge_bin() {
  printf '%s' "${SYSTEM_BRIDGE_BIN:-$SHELLSPEC_PROJECT_ROOT/custom-builds/recob/target/release/system-bridge}"
}

# The identity every sandboxed daemon and client answers with. Deterministic on
# purpose: `origin_host` and the `host` of a persisted row are then assertable
# by value instead of merely "not empty", and the suite reads the same on a
# laptop and on a build host. Override by setting RECOB_SELF_NAME before
# `recob_start`.
RECOB_SELF_NAME="${RECOB_SELF_NAME:-recob-spec-host}"

# recob_start [public|trusted] — start a recording listener for this example.
#
# Both endpoints are served by the one daemon, and by default each connection
# is labelled by the listener that actually accepted it: TCP is `public` and
# demands the §9.2 credential, the Unix socket is `trusted` and does not. That
# is what a client exercising both in one run (`pbcopy` over SSH delivers on
# one and records its local row on the other) needs.
#
# The optional argument sets RECOB_RECORD_ENDPOINT, which forces the label for
# *every* connection — the seam a spec uses when it has only one address to
# point at and still wants the other endpoint's policy. Do not pass it from a
# spec that also uses the trusted socket: forcing `public` makes the daemon
# demand a credential the trusted client never sends.
recob_start() {
  # A fresh directory per example, not one keyed on `$$`: `$$` is the same for
  # every example in a file, so a previous example's log and socket would bleed
  # into the next one and a stale recorded exchange would read as this one's.
  RECOB_DIR=$(mktemp -d "${SHELLSPEC_TMPBASE:-${TMPDIR:-/tmp}}/recob.XXXXXX") || return 1
  export RECOB_DIR

  # A per-example store, state and config: no spec may read or write the
  # human's real clipboard history, the daemon must never find the real token,
  # and §9.6's exposure file must never be picked up from the real config.
  export XDG_STATE_HOME="$RECOB_DIR/state"
  export XDG_DATA_HOME="$RECOB_DIR/data"
  export XDG_CONFIG_HOME="$RECOB_DIR/config"
  mkdir -p "$XDG_STATE_HOME/clipboard" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
  chmod 700 "$XDG_STATE_HOME/clipboard"
  printf '%s\n' "$RECOB_SELF_NAME" > "$XDG_STATE_HOME/clipboard/self-name"

  export RECOB_RECORD_LOG="$RECOB_DIR/record.log"
  : > "$RECOB_RECORD_LOG"
  export RECOB_RECORD_SCRIPT="$RECOB_DIR/script"
  : > "$RECOB_RECORD_SCRIPT"

  export CLIPBOARD_BRIDGE_LOCAL_SOCKET="$RECOB_DIR/cb.sock"

  # The zsh wrapper (clipbridge::) resolves the invoker through this seam, so
  # every example drives the suite's own build rather than the installed one.
  export SYSTEM_BRIDGE_BIN="$(recob_bridge_bin)"

  # A uniquely-named PRIVATE pasteboard, so a daemon in a spec can never read
  # or write the real clipboard — this covers `clip.set`'s write path, not just
  # the `--capture` loop.
  export RECOB_CAPTURE_PASTEBOARD="org.chezmoi.recob.spec.${RECOB_DIR##*/}"

  if [ -n "${1:-}" ]; then
    export RECOB_RECORD_ENDPOINT="$1"
  else
    unset RECOB_RECORD_ENDPOINT
  fi

  [ -x "$(recob_bin)" ] || {
    echo "recob_helper: $(recob_bin) is missing -- run make -C custom-builds/recob build" >&2
    return 1
  }

  # Port 0 is not an option (the daemon binds a fixed port) and a port keyed to
  # the pid collides with the previous example's daemon if it outlived its
  # kill. Draw one at random and retry on a bind failure, so a collision costs a
  # retry rather than an unexplained red.
  # 6c sandboxing: the visited-direction port defaults CLOSED (nothing binds
  # :1) so no test's copy can ever pointer-push to a REAL peer session that
  # happens to be live on the machine running the suite. Examples that test
  # the push point this at the recorder's own port explicitly.
  export CLIPBOARD_BRIDGE_VISITED_PORT=1
  _attempt=0
  while [ "$_attempt" -lt 8 ]; do
    _attempt=$((_attempt + 1))
    export CLIPBOARD_BRIDGE_PORT="$(_recob_pick_port)"
    rm -f "$CLIPBOARD_BRIDGE_LOCAL_SOCKET" "$RECOB_DIR/daemon.log"
    "$(recob_bin)" --record \
      --port "$CLIPBOARD_BRIDGE_PORT" \
      --socket "$CLIPBOARD_BRIDGE_LOCAL_SOCKET" \
      >"$RECOB_DIR/daemon.log" 2>&1 &
    RECOB_PID=$!
    _recob_await_ready && return 0
    kill "$RECOB_PID" 2>/dev/null
    wait "$RECOB_PID" 2>/dev/null
    RECOB_PID=""
  done

  echo "recob_helper: listener never came up:" >&2
  cat "$RECOB_DIR/daemon.log" >&2
  return 1
}

# The daemon logs `wire <v> proto <n> impl <id> host <h>` only after both
# listeners are bound AND the §11.1 credential fixture is on disk, so it is the
# one readiness signal that covers the whole handshake a client needs. Waiting
# on the socket file alone races the fixture: the socket exists from bind, the
# token is written later, and a client that dials in between is refused.
_recob_await_ready() {
  _i=0
  while [ "$_i" -lt 200 ]; do
    grep -q '^recobd: wire ' "$RECOB_DIR/daemon.log" 2>/dev/null && return 0
    kill -0 "$RECOB_PID" 2>/dev/null || return 1
    sleep 0.02
    _i=$((_i + 1))
  done
  return 1
}

# Two bytes of /dev/urandom rather than $RANDOM, which is not POSIX and which a
# forked shell can repeat. Below the ephemeral range, so an outgoing connection
# cannot be holding the port we are about to bind.
_recob_pick_port() {
  _n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
  printf '%s' "$(( 30000 + (_n % 16000) ))"
}

recob_stop() {
  # Guarded: an empty or non-numeric pid must never reach `kill`, and the
  # example's own shell must never be a target — a spec that terminates itself
  # reports as an abort, which is far harder to read than an assertion.
  case "${RECOB_PID:-}" in
    '' | *[!0-9]*) RECOB_PID=""; return 0 ;;
  esac
  [ "$RECOB_PID" = "$$" ] && { RECOB_PID=""; return 0; }
  kill "$RECOB_PID" 2>/dev/null
  wait "$RECOB_PID" 2>/dev/null
  RECOB_PID=""
  # The port must be *refused*, not silent, for §5.2's fallback to be the thing
  # under test, so wait for the listener to actually be gone before returning.
  _i=0
  while [ -S "$CLIPBOARD_BRIDGE_LOCAL_SOCKET" ] && [ "$_i" -lt 100 ]; do
    rm -f "$CLIPBOARD_BRIDGE_LOCAL_SOCKET" 2>/dev/null
    sleep 0.02
    _i=$((_i + 1))
  done
  return 0
}

# recob_close_peer_port — express "this machine is NOT the far end of an SSH
# session" for a client that decides that by PROBING the peer port.
#
# pick-clipboard gates its live-peer features on `clipbridge::probe
# 127.0.0.1 $CLIPBOARD_BRIDGE_PORT` ALONE — an SSH_CONNECTION/SSH_CLIENT/
# SSH_TTY check would be a lie in the environments that matter (Hammerspoon's
# hs.task, pueue), so the reverse forward's existence IS the signal. In
# production the sitting machine has nothing on 2490 and the probe refuses;
# in a spec, `recob_start`'s daemon binds the very port it exported as
# CLIPBOARD_BRIDGE_PORT, so a picker started under it would see a "peer" that
# is really its own store. A spec whose subject is the SITTING machine
# therefore points the peer port at one nothing can be listening on: port 1 is
# privileged and unbindable by an unprivileged test daemon, and a loopback
# connect there refuses instantly (no timeout, no network).
#
# Call it AFTER recob_start (which exports the daemon's real port). The
# trusted Unix socket is untouched, so this machine's own bridge still works —
# which is exactly the local shape: own store yes, peer clipboard no.
recob_close_peer_port() {
  export CLIPBOARD_BRIDGE_PORT=1
}

# The credential a client needs to reach the public endpoint. `--record`
# installs one for this machine's own identity at startup (§11.1's fixture), so
# a spec needs this only to install a *second* one under another owner's name —
# §11.4's "a token belonging to a different owner" case.
recob_install_token() {
  _owner="${1:-$RECOB_SELF_NAME}"
  _dir="$XDG_STATE_HOME/clipboard/tunnel-tokens"
  mkdir -p "$_dir"
  chmod 700 "$_dir"
  cp "$XDG_STATE_HOME/clipboard/accepted-token" "$_dir/$_owner"
  chmod 600 "$_dir/$_owner"
}

# recob_script <directive>... — queue scripted replies, one per exchange
# (§11.1): `ok <field>=<hex>`, `err <code> <message>`, `stream <file>`,
# `close`, `deny-auth`, `no-proof`, `bad-proof`, `hello proto=<n>`.
#
# The script is re-read from the start on every CONNECTION, so a reply
# directive queued for the copy is also the first directive the client's next
# connection sees. The four connection-level directives above are not consumed
# per exchange and therefore apply to every connection in the example.
recob_script() {
  for _d in "$@"; do
    printf '%s\n' "$_d" >> "$RECOB_RECORD_SCRIPT"
  done
}

# --- reading the log --------------------------------------------------------
#
# Every connection records a `hello` line before its first operation, so the
# raw log is not a list of operations. The accessors below index OPERATIONS,
# 1-based, and `hello` is reachable through its own accessors — otherwise every
# spec would have to know how many connections a client happened to open to
# find the exchange it cares about. No registry operation is named `hello`
# (§6.1's names are all dotted), so the filter cannot hide a real one.

_recob_op_lines() {
  [ -f "${RECOB_RECORD_LOG:-}" ] || return 0
  awk -F'\t' '$2 != "hello"' "$RECOB_RECORD_LOG"
}

_recob_hello_lines() {
  [ -f "${RECOB_RECORD_LOG:-}" ] || return 0
  awk -F'\t' '$2 == "hello"' "$RECOB_RECORD_LOG"
}

# recob_ops — every recorded operation, newline-separated, so a spec can assert
# the whole sequence at once. This is the assertion that catches an operation
# the client stopped sending, which a per-line check does not.
recob_ops() {
  _recob_op_lines | cut -f2
}

# recob_count — how many operations were recorded.
recob_count() {
  _recob_op_lines | wc -l | tr -d ' '
}

# recob_connections — how many connections were opened. §6.3 budgets these, and
# "one user action, one connection" is only assertable if they are countable.
recob_connections() {
  _recob_hello_lines | wc -l | tr -d ' '
}

# recob_op <n> — the operation name of the nth recorded operation.
recob_op() {
  _recob_op_lines | sed -n "${1}p" | cut -f2
}

# recob_endpoint <n> — which endpoint policy followed for that operation.
recob_endpoint() {
  _recob_op_lines | sed -n "${1}p" | cut -f1
}

# recob_field <n> <name> — the decoded value of one field of the nth operation.
# Empty output when the field is absent, which is itself assertable.
recob_field() {
  _recob_op_lines | sed -n "${1}p" | _recob_pick_field "$2" | _recob_unhex
}

# recob_field_hex <n> <name> — the raw hex, for a payload whose bytes are the
# point (an embedded NUL, a binary blob) and where decoding would obscure them.
recob_field_hex() {
  _recob_op_lines | sed -n "${1}p" | _recob_pick_field "$2"
}

# recob_hello_field <n> <name> — one field of the nth connection's hello, for
# the §5.1/§9.2 assertions that are about the handshake rather than an
# operation.
recob_hello_field() {
  _recob_hello_lines | sed -n "${1}p" | _recob_pick_field "$2" | _recob_unhex
}

# recob_hello_fields <n> — the nth hello's field names, space-separated. §11.4
# asserts over the *set*, so that a field added to the handshake fails a test
# rather than passing review.
recob_hello_fields() {
  _recob_hello_lines | sed -n "${1}p" | cut -f3- | tr '\t' '\n' |
    sed -n 's/=.*//p' | tr '\n' ' ' | sed 's/ $//'
}

# recob_raw — the log exactly as written, for the assertions that are about the
# whole stream rather than one exchange ("the token appears nowhere in it").
recob_raw() {
  [ -f "${RECOB_RECORD_LOG:-}" ] && cat "$RECOB_RECORD_LOG"
  return 0
}

# recob_wait_op <op> [tries] — block until an operation is recorded, for the
# exchanges a client does not wait on itself. Returns non-zero on timeout, so a
# spec asserts on the status rather than on a sleep that might be too short.
recob_wait_op() {
  _i=0
  while [ "$_i" -lt "${2:-150}" ]; do
    recob_ops | grep -qx "$1" && return 0
    sleep 0.02
    _i=$((_i + 1))
  done
  return 1
}

_recob_pick_field() {
  cut -f3- | tr '\t' '\n' | sed -n "s/^${1}=//p" | head -1
}

_recob_unhex() {
  # Portable hex → bytes: printf's \x escapes are not universal in /bin/sh, so
  # build the escape string and let printf's %b handle it.
  _h=$(cat)
  [ -n "$_h" ] || return 0
  printf '%b' "$(printf '%s' "$_h" | sed 's/../\\x&/g')"
}
