# Relays in endpoints: a literal `relay = "host:port"` is dialled, advertised
# and echoed through ONE resolver (share::relay_address), so those three cannot
# disagree. Spec: docs/superpowers/specs/2026-08-18-share-phase2-relay-service-design.md
#
# `@self` (a relay on THIS machine, served by a croc-relay launchd service) was
# RETIRED on 2026-09-29 — see that spec's retirement note. These examples pin
# that a leftover @self entry is refused rather than dialled as a hostname.

Describe 'share:: relays (literal addresses; @self retired)'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-relay"
    rm -rf "$SB"; mkdir -p "$SB/bin"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_STATE_DIR="$SB/state"
    SHARE_LIVE_DIR="$SB/live"; export SHARE_LIVE_DIR
    SHARE_PROFILE=work
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[mine]
relay    = "lappy.example-tailnet.ts.net:9009"
pass     = "@secret:TEST_RELAY_PASS"
web      = false
profiles = ["work"]

[fixed]
relay    = "relay.example.com:9009"
web      = false
profiles = ["work"]

[stale]
relay    = "@self:9009"
web      = false
profiles = ["work"]

[lan]
relay      = ""
local_only = true
web        = false
profiles   = ["work"]
TOML
    printf 'x' >"$SB/Report.pdf"
  }
  BeforeEach 'setup'

  # --- share::relay_address -------------------------------------------------

  It 'passes a literal relay through untouched'
    When call share::relay_address fixed
    The output should equal 'relay.example.com:9009'
  End

  # A LAN endpoint has no relay at all — croc's multicast IS the rendezvous.
  # Absent must be empty and SUCCESSFUL, not an error.
  It 'yields empty and succeeds for an endpoint with no relay'
    When call share::relay_address lan
    The output should equal ''
    The status should be success
  End

  # `@self` (a relay on THIS machine, phase 2) was retired on 2026-09-29: the
  # work network cannot route to a laptop, so it could never serve colleagues.
  # A leftover entry must fail with the reason, not reach croc as a hostname.
  It 'refuses a leftover @self relay, saying it was retired'
    When run share::relay_address stale
    The status should be failure
    The stderr should include 'retired'
  End

  It 'refuses to send through a leftover @self relay'
    When run share::croc_argv stale live '' '' "$SB/Report.pdf"
    The status should be failure
    The output should not include '@self'
    The stderr should include 'retired'
  End

  # --- the three consumers must agree ---------------------------------------
  # A sender dialling one relay while advertising another is invisible until a
  # recipient cannot connect, so all three read the same resolver.

  It 'dials the relay'
    When call share::croc_argv fixed live '' '' "$SB/Report.pdf"
    The output should include 'relay.example.com:9009'
  End

  It 'advertises the same relay in the pasteable line'
    When call share::blurb fixed live 'R.pdf (1 B)' 'aaaa-bbbb-cccc-dddd' '' ''
    The output should equal 'R.pdf (1 B) — receive with: croc --relay relay.example.com:9009 aaaa-bbbb-cccc-dddd'
  End

  It 'echoes the relay host before a byte leaves'
    When call share::destination_host fixed
    The output should equal 'relay.example.com'
  End

  # --- the receive side's relay password (found by live test) ---------------
  # The SEND path takes `pass` from the endpoint it sends through. The receive
  # path starts from a pasted LINE, not an endpoint, so it had nothing to take
  # it from and passed no CROC_PASS at all. Against a password-protected relay
  # that produced `could not connect to <relay>: bad response: bad password` at
  # the receiver while the sender sat happily connected — an asymmetry no unit
  # test was looking for, because both halves were individually correct.
  Describe 'receiving through a relay that has a password'
    rx_setup() {
      cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
{ printf 'argv:%s\n' "$*"; printf 'pass:%s\n' "${CROC_PASS-UNSET}"; } > "$SB_RX_LOG"
SH
      chmod +x "$SB/bin/croc"
      SB_RX_LOG="$SB/rx.log"; export SB_RX_LOG
      PATH="$SB/bin:$PATH"
      TEST_RELAY_PASS='pw-from-the-secret-slot'; export TEST_RELAY_PASS
    }

    It 'supplies the password for a relay this machine owns'
      rx_setup
      share::_croc_receive 'aaaa-bbbb' 'lappy.example-tailnet.ts.net:9009' "$SB/out"
      When call grep '^pass:' "$SB/rx.log"
      The output should equal 'pass:pw-from-the-secret-slot'
    End

    # An address we do not recognise belongs to somebody else's relay; croc
    # falls back to its own default rather than offering ours. Setting an empty
    # CROC_PASS would be worse than setting none — croc reads a
    # present-but-empty variable as set and would override its own default.
    It 'sets no CROC_PASS for a relay it does not recognise'
      rx_setup
      share::_croc_receive 'aaaa-bbbb' 'someone-else.example.com:9009' "$SB/out"
      When call grep '^pass:' "$SB/rx.log"
      The output should equal 'pass:UNSET'
    End

    It 'never puts the relay password on croc'"'"'s argv'
      rx_setup
      share::_croc_receive 'aaaa-bbbb' 'lappy.example-tailnet.ts.net:9009' "$SB/out"
      When call grep '^argv:' "$SB/rx.log"
      The output should not include 'pw-from-the-secret-slot'
      The output should not include '--pass'
    End
  End
End
