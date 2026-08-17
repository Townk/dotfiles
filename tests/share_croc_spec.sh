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

  It 'builds a live-send argv with the relay, password and a --code phrase, and no store flags'
    When call share::croc_argv lab live '' '' "$SB/Report.pdf"
    The output should include '--relay'
    The output should include 'lab.example.com:9009'
    The output should include '--pass'
    The output should not include '--store'
    The output should include "$SB/Report.pdf"
    The output should include '--code'
  End

  It 'puts the --code phrase on the line right after the flag'
    code_line() { share::croc_argv lab live '' '' "$SB/Report.pdf" | awk '/^--code$/{getline; print; exit}'; }
    When call code_line
    The output should match pattern '????-????-????-????'
  End

  It 'generates a code phrase from an unambiguous 32-symbol alphabet (no l, 1, 0, o)'
    When call share::_code_phrase
    The output should match pattern '????-????-????-????'
    The output should not include 'l'
    The output should not include '1'
    The output should not include '0'
    The output should not include 'o'
  End

  It 'draws code phrases from a CSPRNG, so two consecutive calls differ'
    a="$(share::_code_phrase)"; b="$(share::_code_phrase)"
    When call test "$a" != "$b"
    The status should be success
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

  # --- share::croc_send: the store path, end to end ---------------------
  # No example anywhere else in this file drives share::croc_send itself
  # (everything above stops at the argv/parse/revoke seams) — closing that
  # gap here, since it is exactly the function the --code regression below
  # lived in.

  It 'sends via the store path end-to-end and records a receipt'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
echo "uploading..." >&2
printf 'https://drop.example.com/s/e2e01#v1.KEYE2E\ncroc-store-v1.b64.e2e01.KEYE2E\n'
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    When call share::croc_send drop store 3d 2 "$SB/Report.pdf"
    The output should include 'drop.example.com/s/e2e01'
    The stderr should include 'uploading'
    The status should be success
  End

  It 'fails closed when croc exits non-zero on the store path'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
echo "boom" >&2
exit 9
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    When run share::croc_send drop store 3d 2 "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'croc exited 9'
  End

  # --- share::croc_send: the live path's code phrase ----------------------
  # Finding: the ORIGINAL live-mode extraction grepped croc's own printed
  # instruction line for `croc [a-z0-9-]{6,}`. croc prepends --relay/--pass to
  # that line whenever they are non-default (every self-hosted endpoint,
  # including this file's own `lab` fixture), so the regex matched
  # "croc --relay" long before it reached the real phrase — the recipient
  # would be told to run `croc --relay`. Fixed by generating the phrase
  # ourselves and reading it back out of OUR OWN argv (share::croc_argv),
  # never out of croc's prose. These two examples pin that down.

  It 'shares the exact phrase passed to --code in the live blurb'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_CROC_CALLS"
echo "Sending 'Report.pdf' (1 B)"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SHARE_CROC_CALLS="$SB/calls"
    export SHARE_CROC_CALLS
    out="$(share::croc_send lab live '' '' "$SB/Report.pdf" 2>/dev/null)"
    invoked_code="$(awk '{for (i=1;i<=NF;i++) if ($i == "--code") print $(i+1)}' "$SB/calls")"
    blurb_code="$(printf '%s\n' "$out" | grep -oE 'run: croc [^ ]+' | awk '{print $3}')"
    matches() { [ -n "$invoked_code" ] && [ "$invoked_code" = "$blurb_code" ]; }
    When call matches
    The status should be success
  End

  # Reproduces the finding verbatim: croc's own instruction line quotes
  # --relay/--pass before the phrase. This example FAILS against the
  # pre-fix grep-based extraction (verified: it reported the shared value as
  # literally "--relay").
  It 'never mistakes --relay in croc'"'"'s own instruction line for the code phrase'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
echo "Sending 'Report.pdf' (1 B)"
echo "Code is: croc --relay lab.example.com:9009 --pass hunter2 8878-salary-courage-roger"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    out="$(share::croc_send lab live '' '' "$SB/Report.pdf" 2>/dev/null)"
    blurb_code="$(printf '%s\n' "$out" | grep -oE 'run: croc [^ ]+' | awk '{print $3}')"
    never_relay_or_empty() { [ -n "$blurb_code" ] && [ "$blurb_code" != "--relay" ]; }
    When call never_relay_or_empty
    The status should be success
  End

  It 'fails closed with an error when the code phrase cannot be generated'
    share::_code_phrase() { printf '\n'; }
    When run share::croc_send lab live '' '' "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'code phrase'
  End

  It 'writes no ledger row when the code phrase cannot be generated'
    share::_code_phrase() { printf '\n'; }
    share::croc_send lab live '' '' "$SB/Report.pdf" >/dev/null 2>&1 || :
    ledger_is_empty() { [ ! -s "$SHARE_STATE_DIR/ledger.jsonl" ]; }
    When call ledger_is_empty
    The status should be success
  End
End
