# recob_helper.sh — spec support for driving the RECOB bridge (§11.1).
#
# The old shape was a fake `nc` on PATH that logged the bytes a client wrote
# and invented the reply. This replaces it with the REAL listener in recording
# mode: `recobd --record`, the shipped binary, bound to a per-example socket or
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
#     When run script ...
#     The value "$(recob_op 1)" should equal 'clip.set'
#     The value "$(recob_field 1 text)" should equal 'hello'
#   End
#
# `The value "$(...)"` rather than a bare subject: the log is written by the
# listener while the example runs, so the assertion has to read it after the
# `When`, not before.
#
# Values are logged hex-encoded so NUL and binary payloads survive exactly;
# `recob_field` decodes one so assertions stay readable.

# The binary under test. Built by `make -C custom-builds/recob build`; the
# helper fails loudly rather than silently skipping, because a spec that
# quietly tests nothing is worse than one that fails.
recob_bin() {
  printf '%s' "${RECOB_BIN:-$SHELLSPEC_PROJECT_ROOT/custom-builds/recob/target/release/recobd}"
}

recob_client_bin() {
  printf '%s' "${SYSTEM_CLIP_BIN:-$SHELLSPEC_PROJECT_ROOT/custom-builds/recob/target/release/system-clip}"
}

# recob_start [public|trusted] — start a recording listener for this example.
#
# Both endpoints are always served: a spec that exercises the trusted socket
# and one that exercises the tunnel differ only in which address the client is
# pointed at, and RECOB_RECORD_ENDPOINT decides which label policy follows
# (§11.1), so one listener covers both.
recob_start() {
  RECOB_DIR="${SHELLSPEC_TMPBASE}/recob.$$"
  rm -rf "$RECOB_DIR"
  mkdir -p "$RECOB_DIR/state" "$RECOB_DIR/data"

  export RECOB_RECORD_LOG="$RECOB_DIR/record.log"
  : > "$RECOB_RECORD_LOG"
  export RECOB_RECORD_SCRIPT="$RECOB_DIR/script"
  : > "$RECOB_RECORD_SCRIPT"

  # A per-example store and state dir: no spec may read or write the human's
  # real clipboard history, and the daemon must never find the real token.
  export XDG_STATE_HOME="$RECOB_DIR/state"
  export XDG_DATA_HOME="$RECOB_DIR/data"

  export CLIPBOARD_BRIDGE_LOCAL_SOCKET="$RECOB_DIR/cb.sock"
  # Port 0 is not an option (the daemon binds a fixed port), so take one from
  # the ephemeral range keyed to the pid, and let the readiness poll below
  # catch a collision as a start failure rather than a mystery.
  RECOB_PORT=$(( 30000 + ($$ % 20000) ))
  export CLIPBOARD_BRIDGE_PORT="$RECOB_PORT"

  # A uniquely-named PRIVATE pasteboard, so a capture-enabled daemon in a spec
  # can never read or write the real clipboard.
  export RECOB_CAPTURE_PASTEBOARD="org.chezmoi.recob.spec.$$"

  [ -x "$(recob_bin)" ] || {
    echo "recob_helper: $(recob_bin) is missing -- run make -C custom-builds/recob build" >&2
    return 1
  }

  if [ "${1:-trusted}" = "public" ]; then
    export RECOB_RECORD_ENDPOINT=public
  else
    export RECOB_RECORD_ENDPOINT=trusted
  fi

  "$(recob_bin)" --record --port "$RECOB_PORT" --socket "$CLIPBOARD_BRIDGE_LOCAL_SOCKET" \
    >"$RECOB_DIR/daemon.log" 2>&1 &
  RECOB_PID=$!

  # Wait for the socket rather than sleeping: a spec that races the listener
  # fails intermittently, which is the worst kind of red.
  i=0
  while [ ! -S "$CLIPBOARD_BRIDGE_LOCAL_SOCKET" ] && [ $i -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -S "$CLIPBOARD_BRIDGE_LOCAL_SOCKET" ] || {
    echo "recob_helper: listener never came up:" >&2
    cat "$RECOB_DIR/daemon.log" >&2
    return 1
  }
  return 0
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
  return 0
}

# The credential a client needs to reach the public endpoint, installed the way
# ssh-prepare-connection installs it: owner-keyed, mode 0600 (§9.2).
recob_install_token() {
  _owner="${1:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
  _dir="$XDG_STATE_HOME/clipboard/tunnel-tokens"
  mkdir -p "$_dir"
  chmod 700 "$_dir"
  i=0
  while [ ! -s "$XDG_STATE_HOME/clipboard/accepted-token" ] && [ $i -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  cp "$XDG_STATE_HOME/clipboard/accepted-token" "$_dir/$_owner"
  chmod 600 "$_dir/$_owner"
}

# recob_script <directive>... — queue scripted replies, one per exchange
# (§11.1): `ok <field>=<hex>`, `err <code> <message>`, `stream <file>`,
# `close`, `deny-auth`, `no-proof`, `bad-proof`, `hello proto=<n>`.
recob_script() {
  for _d in "$@"; do
    printf '%s\n' "$_d" >> "$RECOB_RECORD_SCRIPT"
  done
}

# recob_lines — how many exchanges were recorded.
recob_lines() {
  [ -f "$RECOB_RECORD_LOG" ] || { echo 0; return 0; }
  wc -l < "$RECOB_RECORD_LOG" | tr -d ' '
}

# recob_op <n> — the operation of the nth recorded exchange (1-based).
recob_op() {
  sed -n "${1}p" "$RECOB_RECORD_LOG" | cut -f2
}

# recob_endpoint <n> — which endpoint policy followed for that exchange.
recob_endpoint() {
  sed -n "${1}p" "$RECOB_RECORD_LOG" | cut -f1
}

# recob_field <n> <name> — the decoded value of one field of the nth exchange.
# Empty output when the field is absent, which is itself assertable.
recob_field() {
  sed -n "${1}p" "$RECOB_RECORD_LOG" |
    tr '\t' '\n' |
    sed -n "s/^${2}=//p" |
    head -1 |
    _recob_unhex
}

# recob_field_hex <n> <name> — the raw hex, for a payload whose bytes are the
# point (an embedded NUL, a binary blob) and where decoding would obscure them.
recob_field_hex() {
  sed -n "${1}p" "$RECOB_RECORD_LOG" |
    tr '\t' '\n' |
    sed -n "s/^${2}=//p" |
    head -1
}

# recob_ops — every recorded operation, newline-separated, so a spec can assert
# the whole sequence at once. This is the assertion that catches an operation
# the client stopped sending, which a per-line check does not.
recob_ops() {
  [ -f "$RECOB_RECORD_LOG" ] || return 0
  cut -f2 "$RECOB_RECORD_LOG"
}

_recob_unhex() {
  # Portable hex → bytes: printf's \x escapes are not universal in /bin/sh, so
  # build the escape string and let printf's %b handle it.
  _h=$(cat)
  [ -n "$_h" ] || return 0
  printf '%b' "$(printf '%s' "$_h" | sed 's/../\\x&/g')"
}
