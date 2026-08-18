# The relay half of phase 2: `@self` resolution and the croc-relay service
# wrapper. Spec: docs/superpowers/specs/2026-08-18-share-phase2-relay-service-design.md
#
# `@self` exists so endpoints.toml stays byte-identical on every machine — the
# `profiles` allowlist is what differentiates hosts, and a literal hostname
# would break that AND put a host name in writing in a file that is copied
# around. Resolution happens at SEND time, through ONE function, so the address
# croc dials, the host echoed before sending, and the address the recipient is
# told to use cannot disagree.

Describe 'share:: relay (@self + the service wrapper)'
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
[worklan]
relay    = "@self:9009"
pass     = "@secret:TEST_RELAY_PASS"
web      = false
profiles = ["work"]
default_for = ["work"]

[fixed]
relay    = "relay.example.com:9009"
web      = false
profiles = ["work"]

[drop]
store    = "https://d.example.com"
web      = true
profiles = ["work"]

[lan]
relay      = ""
local_only = true
web        = false
profiles   = ["work"]
TOML
    printf 'x' >"$SB/Report.pdf"

    # A fake tailscale reporting a MagicDNS name WITH the trailing dot real
    # tailscale emits — stripping it is part of the contract.
    cat >"$SB/bin/tailscale" <<'SH'
#!/bin/sh
printf '{"Self":{"DNSName":"lappy.example-tailnet.ts.net."}}\n'
SH
    chmod +x "$SB/bin/tailscale"
    SHARE_TAILSCALE_BIN="$SB/bin/tailscale"; export SHARE_TAILSCALE_BIN
  }
  BeforeEach 'setup'

  # --- share::self_host -----------------------------------------------------

  # The FQDN is preferred over the short name because it resolves for EVERY
  # tailnet member, while the short name needs the recipient's client to carry
  # this tailnet as a search domain. That failure lands at the far end, where
  # the sender cannot see it, so the robust form wins.
  It 'prefers the Tailscale MagicDNS name and strips its trailing dot'
    When call share::self_host
    The output should equal 'lappy.example-tailnet.ts.net'
  End

  It 'falls back to the short hostname when tailscale is unavailable'
    fallback() {
      SHARE_TAILSCALE_BIN="$SB/bin/no-such-tailscale" share::self_host
    }
    When call fallback
    The output should equal "$(hostname -s)"
  End

  # A tailscale that runs but reports nothing useful (logged out, still coming
  # up) must not yield an empty relay address — that would advertise ":9009".
  It 'falls back when tailscale answers with no name'
    printf '#!/bin/sh\nprintf "{}\\n"\n' >"$SB/bin/tailscale"
    chmod +x "$SB/bin/tailscale"
    When call share::self_host
    The output should equal "$(hostname -s)"
  End

  # --- share::relay_address -------------------------------------------------

  It 'resolves @self:port to this machine and keeps the port'
    When call share::relay_address worklan
    The output should equal 'lappy.example-tailnet.ts.net:9009'
  End

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

  # --- the three consumers must agree ---------------------------------------
  # A sender dialling one relay while advertising another is invisible until a
  # recipient cannot connect, so all three read the same resolver.

  It 'dials the resolved address, never the @self literal'
    When call share::croc_argv worklan live '' '' "$SB/Report.pdf"
    The output should include 'lappy.example-tailnet.ts.net:9009'
    The output should not include '@self'
  End

  It 'advertises the resolved address in the pasteable line'
    When call share::blurb worklan live 'R.pdf (1 B)' 'aaaa-bbbb-cccc-dddd' '' ''
    The output should equal 'R.pdf (1 B) — receive with:  croc --relay lappy.example-tailnet.ts.net:9009 aaaa-bbbb-cccc-dddd'
  End

  It 'echoes the resolved host before a byte leaves'
    When call share::destination_host worklan
    The output should equal 'lappy.example-tailnet.ts.net'
  End

  # --- share::relay_endpoint ------------------------------------------------
  # The service wrapper finds its endpoint by the @self marker rather than by a
  # name in the PUBLIC service manifest.

  It 'finds the endpoint this machine relays for'
    When call share::relay_endpoint
    The output should equal 'worklan'
  End

  It 'fails when no endpoint on this profile declares @self'
    SHARE_PROFILE=personal
    When run share::relay_endpoint
    The status should be failure
    The stderr should include '@self'
  End

  # Picking one silently would start the relay with the WRONG password, which
  # presents as "the recipient cannot connect" a long way from the cause.
  It 'refuses to guess when two endpoints declare @self'
    printf '\n[second]\nrelay = "@self:9109"\nweb = false\nprofiles = ["work"]\n' \
      >>"$SHARE_ENDPOINTS_FILE"
    When run share::relay_endpoint
    The status should be failure
    The stderr should include 'SHARE_RELAY_ENDPOINT'
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

  # --- the service gate -----------------------------------------------------
  # The relay is a launchd SERVICE, not a job:: task: a live transfer waits up
  # to 24h for its recipient and re-arms against the same relay the whole time,
  # so it has to be up whenever the laptop is. And it is gated at TEMPLATE
  # level, so a machine with no use for a relay renders no plist at all —
  # nothing to disable, nothing listening.
  Describe 'the croc-relay service entry'
    render_profile() {  # render_profile <profile>
      local out="$SHELLSPEC_TMPBASE/relay-render-$1"
      rm -rf "$out"
      "$SHELLSPEC_PROJECT_ROOT/tests/render-matrix.sh" \
        --source "$SHELLSPEC_PROJECT_ROOT/home" --profile "$1" --out "$out" >/dev/null || return $?
      grep -c '^\[croc-relay\]' "$out/rendered/dot_config__packages__services.toml.tmpl" || true
    }

    It 'renders on the work profile, which is the only one with no other rendezvous'
      When call render_profile work
      The output should equal '1'
    End

    # Personal live transfers rendezvous through croc's own public relay, which
    # is what lets them reach someone on no tailnet at all. No relay needed.
    It 'renders nothing on personal'
      When call render_profile personal
      The output should equal '0'
    End

    It 'renders nothing on dev-shell'
      When call render_profile dev-shell
      The output should equal '0'
    End

    It 'renders nothing on server'
      When call render_profile server
      The output should equal '0'
    End
  End

  # --- the wrapper ----------------------------------------------------------

  Describe 'libexec/croc-relay'
    wrapper_setup() {
      cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
{ printf 'argv:%s\n' "$*"; printf 'pass:%s\n' "${CROC_PASS-UNSET}"; } > "$CROC_FAKE_LOG"
SH
      chmod +x "$SB/bin/croc"
      export CROC_FAKE_LOG="$SB/croc.log"
      export PATH="$SB/bin:$PATH"
      export SHARE_CONFIG_DIR SHARE_ENDPOINTS_FILE SHARE_PROFILE SHARE_TAILSCALE_BIN
      export TEST_RELAY_PASS='pw-from-the-secret-slot'
      "$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_croc-relay" >/dev/null 2>&1
    }

    # The whole reason the wrapper exists: services.toml.tmpl is PUBLIC, so the
    # password cannot live there. It is resolved here, at exec time, from the
    # chezmoiignored endpoint manifest through the same @secret: indirection
    # `share` uses — so relay and sender read it from one line of one file.
    It 'resolves the password from the @secret: slot and hands it over in CROC_PASS'
      wrapper_setup
      When call grep '^pass:' "$SB/croc.log"
      The output should equal 'pass:pw-from-the-secret-slot'
    End

    # A relay is long-lived, so a --pass token would sit in `ps` all day.
    It 'never puts the password on croc'"'"'s argv'
      wrapper_setup
      When call grep '^argv:' "$SB/croc.log"
      The output should not include 'pw-from-the-secret-slot'
      The output should not include '--pass'
    End

    # 9009 is the rendezvous the pasted line names; the rest carry the
    # transfer. Advertising 9009 alone and firewalling the others fails only
    # once a real transfer starts, which is the worst time to find out.
    It 'opens croc'"'"'s full port spread, not just the rendezvous port'
      wrapper_setup
      When call grep '^argv:' "$SB/croc.log"
      The output should equal 'argv:relay --ports 9009,9010,9011,9012,9013'
    End
  End
End
