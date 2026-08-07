# Tests for the copy client's over-SSH provenance behavior, against the REAL
# listener in recording mode (spec §11.1) rather than a fake `nc`.
#
# What the conversion changed, beyond the transport: the O and P opcodes are
# gone. `clip.set` carries its own provenance as a field (§6.2's collapse), so
# the two-frame declare-then-set dance — and the origin file, its TTL and its
# hash keying — have nothing left to describe. The local history row is still
# recorded, now as `store.persist.text` over the trusted socket. The old
# "delivers OSC 52 when the O/P temp files cannot be created" case goes with
# them: the client buffers in memory, so there are no secondary temp files to
# fail, and OSC 52 is no longer a co-tier that could cover for one.
#
# Delivery is still two-tier, but the tiers changed meaning (§5.2): the bridge
# first, and OSC 52 **only when nothing is bound**. A bridge that answers
# `unauthorized`, that answers `busy`, or that accepts and stalls, is a failed
# control rather than an absent one, and the copy fails loudly instead of
# quietly downgrading. That rule is the fail-open regression §11.4 calls the
# most important test here, so it is asserted in both directions below.
#
# ASSERTION SHAPE. Every assertion here runs the client and prints what it
# wants to check from *inside* one function, then asserts on that function's
# output. Converting another spec: copy this shape. Two things it buys that the
# shorter `The value "$(recob_op 1)"` does not — a subject shellspec does
# evaluate in the example's own environment, and in place, so both work:
#
#   - the client's exit status. A function whose last command is the client
#     gives it to `The status`; a function that must also read the log prints
#     the status into its tuple. Reaching for `The value` loses it either way.
#   - one failure message carrying every field that was wrong at once, instead
#     of stopping at the first.
#
# The gotcha that is real, and that reads exactly like a stale log: the
# recorder writes a `hello` line per CONNECTION before that connection's first
# operation, so the raw log is not a list of operations. `recob_op 1` answers
# `clip.set` because the helper's accessors index operations and reach the
# handshake through `recob_hello_field`; indexing the file directly answers
# `hello` and looks like a previous example bleeding through.
Describe 'copy: over-SSH provenance'
  Include tests/recob_helper.sh

  setup() {
    export SSH_CONNECTION="x 1 y 22"           # force the over-SSH branch
    # No forced endpoint label: this client uses BOTH endpoints in one copy —
    # the tunnel for the delivery and the trusted socket for its own history
    # row — so each connection has to be judged by the listener that accepted
    # it. Forcing `public` would make the daemon demand a credential on the
    # trusted socket, where the client correctly sends none.
    recob_start
    # The sink stands in for /dev/tty, which always exists; the client opens it
    # for writing and does not create it. So it is truncated, not removed, and
    # "no OSC 52" is asserted as an empty sink rather than an absent file.
    export PBCOPY_OSC52_SINK="$RECOB_DIR/osc52"
    : > "$PBCOPY_OSC52_SINK"
    CLIENT="$(recob_client_bin)"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  copy() { printf '%s' "$1" | "$CLIENT" copy; }

  It 'sets the far clipboard with one clip.set over the tunnel'
    one_set() {
      copy 'hello' >/dev/null 2>&1
      printf '%s|%s|%s|%s|%s' \
        "$(recob_op 1)" "$(recob_field 1 text)" "$(recob_field 1 regtype)" \
        "$(recob_endpoint 1)" "$(recob_connections)"
    }
    When call one_set
    # Provenance is a field now, not a second frame: there is no O exchange to
    # find, and the delivery is one exchange on the public endpoint. Two
    # connections in total — this one and the local row's below — is §6.3's
    # budget for a copy, down from five.
    The output should equal 'clip.set|hello|v|public|2'
    # OSC 52 is the fallback tier, so a bridge delivery must not also write it
    # (the no-OSC52-vs-bridge race the T opcode used to exist for).
    The contents of file "$PBCOPY_OSC52_SINK" should equal ''
  End

  It 'declares this machine as the origin rather than leaving it to be inferred'
    origin() { copy 'hello' >/dev/null 2>&1; recob_field 1 origin_host; }
    When call origin
    # The helper pins the sandbox's identity, so this is exact rather than
    # merely non-empty: a client that stopped declaring an origin and one that
    # declared the wrong machine are different bugs.
    The output should equal 'recob-spec-host'
  End

  It 'records the local row as store.persist.text over the trusted socket'
    persisted() {
      copy 'hello' >/dev/null 2>&1
      printf '%s|%s|%s|%s' \
        "$(recob_op 2)" "$(recob_endpoint 2)" \
        "$(recob_field 2 host)" "$(recob_field 2 text)"
    }
    When call persisted
    # The row is this machine's own history and never crosses the tunnel, which
    # is the whole reason it is a second connection rather than a second frame.
    The output should equal 'store.persist.text|trusted|recob-spec-host|hello'
  End

  It 'sends a linewise regtype for text that ends in a newline'
    linewise() { copy 'hello
' >/dev/null 2>&1; recob_field 1 regtype; }
    When call linewise
    The output should equal 'l'
  End

  It 'keeps the payload byte-exact through an embedded NUL'
    # The recorder logs hex precisely so this case is assertable at all; a
    # fake transport that round-tripped through a shell variable could not
    # carry it (§11.1).
    nul_payload() {
      printf 'a\000b' | "$CLIENT" copy >/dev/null 2>&1
      recob_field_hex 1 text
    }
    When call nul_payload
    The output should equal '610062'
  End

  It 'keeps a payload larger than one read block byte-exact'
    # §11.4 names this as a case distinct from the NUL: a client that framed
    # only what its first read returned truncates here and nowhere else.
    big_payload() {
      head -c 131072 /dev/zero | tr '\000' 'x' > "$RECOB_DIR/sent"
      "$CLIENT" copy < "$RECOB_DIR/sent" >/dev/null 2>&1
      recob_field 1 text > "$RECOB_DIR/received"
      cmp -s "$RECOB_DIR/sent" "$RECOB_DIR/received" && echo identical || echo differs
    }
    When call big_payload
    The output should equal 'identical'
  End

  It 'falls back to OSC 52 only when nothing is bound'
    # A refused connect is the one observation §5.2 admits as "no bridge here".
    absent() { recob_stop; copy 'hello'; }
    When call absent
    The status should be success
    The contents of file "$PBCOPY_OSC52_SINK" should include "]52;c;"
  End

  # §11.4's fail-open regression, and the reason the connect result is the only
  # admitted signal: a listener that refuses is a control doing its job, and
  # treating that as an absent bridge would let anyone who can make the bridge
  # refuse also make the copy unauthenticated.
  It 'fails loudly and emits no OSC 52 when the bridge refuses the credential'
    denied() { recob_script 'deny-auth'; copy 'secret'; }
    When call denied
    The status should not equal 0
    The stderr should include 'unauthorized'
    The contents of file "$PBCOPY_OSC52_SINK" should equal ''
  End

  It 'fails loudly and emits no OSC 52 when the bridge answers busy'
    # The other arm §11.4 names: an overloaded bridge is still a reachable one,
    # and a downgrade here would make load the way to strip the copy's controls.
    refused() { recob_script 'err busy too many connections'; copy 'secret'; }
    When call refused
    The status should not equal 0
    The stderr should include 'busy'
    The contents of file "$PBCOPY_OSC52_SINK" should equal ''
  End

  It 'sends nothing and emits no OSC 52 when the endpoint will not prove itself'
    # A squatter that authenticates the client but cannot answer its challenge:
    # the payload must never reach it (§9.2). `leaked` counts log lines carrying
    # the hex of `secret`, because what this closes is a leak of the payload
    # rather than of the credential — asserting only that no `clip.set` was
    # dispatched would miss a client that sent it on some other operation.
    unproven() {
      recob_script 'no-proof'
      copy 'secret' 2>/dev/null
      _status=$?
      printf 'status=%s ops=[%s] leaked=%s' \
        "$_status" "$(recob_ops | tr '\n' ',')" "$(recob_raw | grep -c 736563726574)"
    }
    When call unproven
    The output should equal 'status=1 ops=[] leaked=0'
    The contents of file "$PBCOPY_OSC52_SINK" should equal ''
  End

  It 'fails loudly when neither the bridge nor the sink can deliver'
    # No listener, and a sink that cannot be opened — the headless run-shell
    # case, where /dev/tty exists but open(2) returns ENXIO.
    nowhere() {
      recob_stop
      PBCOPY_OSC52_SINK="$RECOB_DIR/no-such-dir/sink" copy 'hello'
    }
    When call nowhere
    The status should eq 1
    The stderr should include "cannot deliver the copy"
  End
End
