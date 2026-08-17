# The croc backend. Everything here is driven through share::croc_argv (which
# only PRINTS the command) and a fake `croc` on PATH, so no test ever performs a
# real transfer.
#
# The parse target is croc's own output shape: a browser URL
# `<origin>/s/<id>#v1.<key>` and a CLI token `croc-store-v1.<b64origin>.<id>.<key>`.
# The id inside the URL path is what `croc --revoke` takes, which is why it is
# extracted rather than regenerated.

Describe 'share:: croc backend'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-croc"
    rm -rf "$SB"; mkdir -p "$SB/bin"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_STATE_DIR="$SB/state"
    SHARE_PROFILE=personal
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[drop]
store = "https://drop.example.com"
web = true
profiles = ["personal"]

[lab]
relay = "lab.example.com:9009"
pass = "hunter2"
web = false
profiles = ["personal"]
TOML
    printf 'x' >"$SB/Report.pdf"
  }
  BeforeEach 'setup'

  It 'builds a stored-send argv naming the endpoint store'
    When call share::croc_argv drop store 3d 2 "$SB/Report.pdf"
    The output should include '--store'
    The output should include '--store-url'
    The output should include 'https://drop.example.com'
    The output should include '--store-expiration'
    The output should include '3d'
    The output should include '--store-downloads'
    # Regression: `argv` is a zsh SPECIAL VARIABLE (a synonym for the
    # positional parameters). An accumulator locally named `argv` would
    # clobber the function's own "$@" before the path ever got appended —
    # every flag would still print, but the path would silently vanish (or,
    # worse, the flag list would get appended to itself). Asserting the path
    # is present is what catches that class of bug; the flag-only assertions
    # above do not.
    The output should include "$SB/Report.pdf"
    The lines of output should equal 11
  End

  It 'builds a live-send argv with the relay and password, and no store flags'
    When call share::croc_argv lab live '' '' "$SB/Report.pdf"
    The output should include '--relay'
    The output should include 'lab.example.com:9009'
    The output should include '--pass'
    The output should not include '--store'
    The output should include "$SB/Report.pdf"
  End

  It 'resolves a @secret: password from the environment'
    printf '[s]\nrelay = "r:9009"\npass = "@secret:SHARE_TEST_PASS"\nprofiles = ["personal"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    export SHARE_TEST_PASS=frompass
    When call share::croc_argv s live '' '' "$SB/Report.pdf"
    The output should include 'frompass'
    The output should not include '@secret:'
  End

  It 'parses the browser URL, token and id out of croc output'
    out="$(printf 'some noise\nhttps://drop.example.com/s/abc123#v1.KEYKEY\ncroc-store-v1.b64.abc123.KEYKEY\n')"
    When call share::croc_parse_share "$out"
    The output should include 'https://drop.example.com/s/abc123#v1.KEYKEY'
    The output should include 'croc-store-v1.b64.abc123.KEYKEY'
    The output should include 'abc123'
  End

  It 'fails to parse output with no share in it'
    When run share::croc_parse_share 'nothing useful here'
    The status should be failure
  End

  It 'revokes through croc --revoke'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_CROC_CALLS"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SHARE_CROC_CALLS="$SB/calls"
    export SHARE_CROC_CALLS
    share::croc_revoke abc123
    When call cat "$SB/calls"
    The output should include '--revoke abc123'
  End
End
