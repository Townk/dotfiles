# `share status` — per-endpoint reachability. Spec: R6 of
# docs/superpowers/specs/2026-08-18-share-phase2-relay-service-design.md
#
# It earns its place because sending is BACKGROUNDED by default: a live send
# against a relay that is down fails inside a job, so the human sees a failure
# toast rather than a connection error. One command that says "your relay is not
# listening" is the difference between a fact and a puzzle.
#
# Hermetic: nc and curl are both stubbed (SHARE_NC_BIN / SHARE_CURL_BIN), so no
# example ever touches the network — including getcroc.com.

Describe 'share:: status'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-status"
    rm -rf "$SB"; mkdir -p "$SB/bin"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_STATE_DIR="$SB/state"
    SHARE_PROFILE=work
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[myrelay]
relay    = "@self:9409"
web      = false
profiles = ["work"]
default_for = ["work"]

[theirs]
relay    = "relay.example.com:9009"
web      = false
profiles = ["work"]

[store1]
store    = "https://store.example.com"
web      = true
profiles = ["work"]

[lan]
relay      = ""
local_only = true
web        = false
profiles   = ["work"]

[nowhere]
web      = true
profiles = ["work"]

[elsewhere]
store    = "https://other.example.com"
web      = true
profiles = ["personal"]
TOML
    cat >"$SB/bin/tailscale" <<'SH'
#!/bin/sh
printf '{"Self":{"DNSName":"lappy.example-tailnet.ts.net."}}\n'
SH
    chmod +x "$SB/bin/tailscale"
    SHARE_TAILSCALE_BIN="$SB/bin/tailscale"; export SHARE_TAILSCALE_BIN

    # Stub nc: open only for the hosts named in SB_NC_OPEN.
    cat >"$SB/bin/nc" <<'SH'
#!/bin/sh
host=""; for a in "$@"; do case "$a" in -*|[0-9]*) ;; *) host="$a" ;; esac; done
case " ${SB_NC_OPEN:-} " in *" $host "*) exit 0 ;; esac
exit 1
SH
    # Stub curl: prints the code in SB_HTTP_CODE for any URL in SB_HTTP_OK.
    cat >"$SB/bin/curl" <<'SH'
#!/bin/sh
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case " ${SB_HTTP_OK:-} " in *" $url "*) printf '%s' "${SB_HTTP_CODE:-200}"; exit 0 ;; esac
printf '000'; exit 0
SH
    chmod +x "$SB/bin/nc" "$SB/bin/curl"
    SHARE_NC_BIN="$SB/bin/nc";     export SHARE_NC_BIN
    SHARE_CURL_BIN="$SB/bin/curl"; export SHARE_CURL_BIN
    # EXPORTED, all three: the stubs are separate processes. SB_HTTP_CODE set
    # as a plain shell variable was invisible to them, so the 503 example
    # silently asserted against a 200.
    SB_NC_OPEN=""; SB_HTTP_OK=""; SB_HTTP_CODE=200
    export SB_NC_OPEN SB_HTTP_OK SB_HTTP_CODE
    # No job runner in these examples: the jobs line is not what is under test.
    JOB_STATE_ROOT="$SB/jobs"; export JOB_STATE_ROOT
  }
  BeforeEach 'setup'

  It 'reports a listening relay as listening'
    SB_NC_OPEN="lappy.example-tailnet.ts.net"
    When call share::_status_row myrelay
    The output should include 'listening'
    The output should include 'lappy.example-tailnet.ts.net:9409'
  End

  # The actionable half: OUR relay being down is fixable with a named command.
  It 'names the command to start OUR OWN relay when it is not listening'
    When call share::_status_row myrelay
    The output should include 'NOT LISTENING'
    The output should include 'system-service start croc-relay'
  End

  # Somebody else's relay being down is not something system-service can fix,
  # so suggesting it would be actively misleading.
  It 'does not suggest starting a service for somebody else'"'"'s relay'
    When call share::_status_row theirs
    The output should include 'NOT REACHABLE'
    The output should not include 'system-service'
  End

  It 'reports a reachable store with its status code'
    SB_HTTP_OK="https://store.example.com"
    When call share::_status_row store1
    The output should include 'store.example.com'
    The output should include 'ok (200)'
  End

  # A server that answers 503 is up but not serving — "reachable" would be a lie
  # and "unreachable" would send you looking at the network.
  It 'distinguishes an unhealthy store from an unreachable one'
    SB_HTTP_OK="https://store.example.com"; SB_HTTP_CODE=503
    When call share::_status_row store1
    The output should include 'answered 503'
  End

  It 'reports an unreachable store'
    When call share::_status_row store1
    The output should include 'NOT REACHABLE'
  End

  # A LAN endpoint has nothing to probe: croc's multicast IS the rendezvous.
  # Probing it would always fail and always be meaningless.
  It 'reports a LAN endpoint as having nothing to reach'
    When call share::_status_row lan
    The output should include 'n/a'
    The output should include 'multicast'
  End

  It 'calls out an endpoint with no store, relay or remote'
    When call share::_status_row nowhere
    The output should include 'MISCONFIGURED'
  End

  # --- the table -------------------------------------------------------------

  It 'lists only the endpoints this profile may use'
    When call share::status
    The output should include 'myrelay'
    The output should include 'store1'
    The output should not include 'elsewhere'
  End

  It 'marks the default endpoint'
    When call share::status
    The output should include 'myrelay*'
  End

  # Regression: the endpoint list was built by stripping " (default)" off
  # share::endpoints_for_profile's DISPLAY output with ${name%% (default)},
  # which silently does nothing — zsh reads `(default)` as a glob GROUP, so the
  # literal parentheses never match. Rows then carried "myrelay (default)" as a
  # name and every field lookup logged "unknown endpoint".
  It 'never carries a display decoration into an endpoint name'
    When call share::status
    The output should not include '(default)'
    The stderr should not include 'unknown endpoint'
  End

  # A hardcoded 11-character name column shunted a longer name out of
  # alignment, so widths are computed from the data now.
  #
  # This asserts the real invariant: the STATE text begins at the SAME column on
  # every row. An earlier version of this example only checked that the header's
  # STATE offset held non-blank content on each row — which a shunted row
  # satisfies by accident, with destination text sitting there. It passed
  # against a deliberately broken width, i.e. it tested nothing. Counting
  # DISTINCT state offsets is what actually catches it: one means aligned.
  #
  # In zsh, not awk: macOS awk indexes by BYTES, and one destination cell is an
  # em dash (3 bytes, 1 column), so awk read a correct table as broken. zsh
  # string subscripts are character-based, the unit a terminal aligns in.
  It 'aligns the state column no matter how long the endpoint names are'
    printf '\n[an-endpoint-with-a-very-long-name]\nstore = "https://long.example.com"\nweb = true\nprofiles = ["work"]\n' \
      >>"$SHARE_ENDPOINTS_FILE"
    distinct_state_offsets() {
      local out; out="$(share::status 2>/dev/null)"
      local -a toks=('NOT LISTENING' 'NOT REACHABLE' 'MISCONFIGURED' 'listening' 'ok (' 'n/a')
      local -A offs=()
      local line tok
      for line in "${(f)out}"; do
        [[ "$line" == ENDPOINT* ]] && continue
        [[ -z "${line// /}" ]] && continue
        [[ "$line" == *'share jobs'* || "$line" == '* default'* ]] && continue
        for tok in "${toks[@]}"; do
          # "$tok" quoted INSIDE the pattern so `ok (` is matched literally
          # rather than as a glob group.
          if [[ "$line" == *"$tok"* ]]; then
            offs[$(( ${#line%%"$tok"*} + 1 ))]=1
            break
          fi
        done
      done
      print -r -- "${#offs}"
    }
    When call distinct_state_offsets
    The output should equal '1'
  End
End
