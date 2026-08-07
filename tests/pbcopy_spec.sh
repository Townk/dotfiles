# Tests for the copy client's over-SSH provenance behavior, against the REAL
# listener in recording mode (spec §11.1) rather than a fake `nc`.
#
# What the conversion changed, beyond the transport: the O and P opcodes are
# gone. `clip.set` carries its own provenance as a field (§6.2's collapse), so
# the two-frame declare-then-set dance — and the origin file, its TTL and its
# hash keying — have nothing left to describe. The local history row is still
# recorded, now as `store.persist.text` over the trusted socket.
#
# Delivery is still two-tier, but the tiers changed meaning (§5.2): the bridge
# first, and OSC 52 **only when nothing is bound**. A bridge that answers
# `unauthorized`, or accepts and stalls, is a failed control rather than an
# absent one, and the copy fails loudly instead of quietly downgrading. That
# rule is the fail-open regression §11.4 calls the most important test here, so
# it is asserted in both directions below.
#
# ASSERTION SHAPE, and why it is not the obvious one. The recorder writes its
# log while the example runs, and shellspec expands a `The value "$(...)"`
# subject outside the example's environment — where `$RECOB_RECORD_LOG` is
# unset, so the read silently falls back to stdin and "passes" against the
# wrong thing. Every assertion here therefore runs the client and prints what
# it wants to check from *inside* one function, and asserts on that output.
# Converting another spec: copy this shape, not the shorter one.
Describe 'copy: over-SSH provenance'
  Include tests/recob_helper.sh

  setup() {
    export SSH_CONNECTION="x 1 y 22"           # force the over-SSH branch
    export PBCOPY_OSC52_SINK="$SHELLSPEC_TMPBASE/osc52"
    rm -f "$PBCOPY_OSC52_SINK"
    recob_start public
    recob_install_token
    CLIENT="$(recob_client_bin)"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  copy() { printf '%s' "$1" | "$CLIENT" copy; }

  # The local history row goes out on its own connection after the delivery,
  # so poll for it rather than asserting against a snapshot.
  wait_for_op() {
    i=0
    while [ "$i" -lt 150 ]; do
      recob_ops | grep -qx "$1" && return 0
      sleep 0.02
      i=$((i + 1))
    done
    return 1
  }

  It 'sets the far clipboard with one clip.set carrying its own origin'
    one_set() {
      copy 'hello' >/dev/null 2>&1
      printf '%s|%s|%s|%s' \
        "$(recob_op 1)" "$(recob_field 1 text)" \
        "$(recob_field 1 regtype)" "$(recob_endpoint 1)"
    }
    When call one_set
    # Provenance is a field now, not a second frame: there is no O exchange to
    # find, and the whole copy is one exchange on the public endpoint.
    The output should equal 'clip.set|hello|v|public'
  End

  It 'declares this machine as the origin rather than leaving it to be inferred'
    origin() { copy 'hello' >/dev/null 2>&1; recob_field 1 origin_host; }
    When call origin
    The output should not equal ''
  End

  It 'records the local row as store.persist.text when the bridge delivered'
    persisted() { copy 'hello' >/dev/null 2>&1; wait_for_op 'store.persist.text'; }
    When call persisted
    The status should be success
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
    The path "$PBCOPY_OSC52_SINK" should not be exist
  End

  It 'sends nothing and emits no OSC 52 when the endpoint will not prove itself'
    # A squatter that authenticates the client but cannot answer its challenge:
    # the payload must never reach it (§9.2).
    unproven() {
      recob_script 'no-proof'
      copy 'secret' 2>/dev/null
      printf 'ops=[%s]' "$(recob_ops | tr '\n' ',')"
    }
    When call unproven
    The status should not equal 0
    The output should equal 'ops=[]'
    The path "$PBCOPY_OSC52_SINK" should not be exist
  End

  It 'fails loudly when neither the bridge nor the sink can deliver'
    # No listener, and a sink that cannot be opened — the headless run-shell
    # case, where /dev/tty exists but open(2) returns ENXIO.
    nowhere() {
      recob_stop
      PBCOPY_OSC52_SINK="$SHELLSPEC_TMPBASE/no-such-dir/sink" copy 'hello'
    }
    When call nowhere
    The status should eq 1
    The stderr should include "cannot deliver the copy"
  End
End
