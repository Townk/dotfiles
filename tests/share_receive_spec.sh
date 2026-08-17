# Receive. croc REFUSES a stored link on argv (src/cli/cli.go:712) because the
# decryption key would show in `ps`. A wrapper that takes the link on its OWN
# argv reintroduces exactly that leak, so the precedence is clipboard → stdin →
# argv-with-explicit-consent.
#
# A code phrase is the exception: single-use and worthless once consumed, so
# there is nothing to hide from the process list. That asymmetry is upstream's
# own and is reproduced deliberately.

Describe 'share:: receive'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-receive"
    rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/out"
    SHARE_CONFIG_DIR="$SB"
    SHARE_STATE_DIR="$SB/state"
    SHARE_PROFILE=personal
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
{ printf 'argv:%s\n' "$*"; printf 'token:%s\n' "${CROC_STORE_TOKEN:-}"; } >>"$SHARE_CALLS"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SHARE_CALLS="$SB/calls"; export SHARE_CALLS
  }
  BeforeEach 'setup'

  It 'classifies a browser share URL as stored'
    When call share::classify 'https://getcroc.com/s/abc#v1.KEY'
    The output should equal 'stored'
  End

  It 'classifies a CLI token as stored'
    When call share::classify 'croc-store-v1.b64.abc.KEY'
    The output should equal 'stored'
  End

  It 'classifies a code phrase as code'
    When call share::classify '7-truck-mango-basil'
    The output should equal 'code'
  End

  It 'classifies noise as unknown'
    When call share::classify 'hello world this is not a share'
    The output should equal 'unknown'
  End

  It 'classifies a generated live-mode code phrase as code'
    # share::_code_phrase (share/croc.zsh) is the four-group, 32-symbol
    # unambiguous-alphabet phrase this project actually generates for live
    # sends — distinct from croc's own default shape, and worth checking on
    # its own so a future alphabet or grouping change trips this test.
    phrase="$(share::_code_phrase)"
    When call share::classify "$phrase"
    The output should equal 'code'
  End

  It 'refuses a stored value on argv without explicit consent'
    When run share::get 'croc-store-v1.b64.abc.KEY'
    The status should be failure
    The stderr should include '--allow-argv'
  End

  It 'accepts a stored value on argv with --allow-argv'
    share::get --out "$SB/out" --allow-argv 'croc-store-v1.b64.abc.KEY'
    When call cat "$SB/calls"
    The output should include 'token:croc-store-v1.b64.abc.KEY'
  End

  It 'never puts a stored value on crocs argv'
    share::get --out "$SB/out" --allow-argv 'croc-store-v1.b64.abc.KEY'
    When call grep '^argv:' "$SB/calls"
    The output should not include 'croc-store-v1'
  End

  It 'accepts a code phrase on argv without consent, as croc does'
    share::get --out "$SB/out" '7-truck-mango-basil'
    When call grep '^argv:' "$SB/calls"
    The output should include '7-truck-mango-basil'
  End

  It 'reads a stored value from stdin with -'
    printf 'croc-store-v1.b64.abc.KEY\n' | share::get --out "$SB/out" -
    When call cat "$SB/calls"
    The output should include 'token:croc-store-v1.b64.abc.KEY'
  End

  It 'reads the clipboard when given no value at all'
    printf '#!/bin/sh\nprintf "croc-store-v1.from.clip.KEY\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    share::get --out "$SB/out"
    When call cat "$SB/calls"
    The output should include 'token:croc-store-v1.from.clip.KEY'
  End

  It 'fails helpfully when the clipboard holds no share'
    printf '#!/bin/sh\nprintf "just some text\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    When run share::get --out "$SB/out"
    The status should be failure
    The stderr should include 'no croc share'
  End

  # --- additions beyond the brief -------------------------------------------

  It 'classifies a stored URL and a stored token as stored, never code (the leak this task exists to prevent)'
    When call share::classify 'https://getcroc.com/s/abc#v1.b64url-_KEY'
    The output should equal 'stored'
  End

  It 'passes the stored value to CROC_STORE_TOKEN byte-identical, including base64url - and _ characters'
    value='croc-store-v1.b64-origin_abc.id-9x_2.KEY-with_dash-and_underscore'
    share::get --out "$SB/out" --allow-argv "$value"
    When call cat "$SB/calls"
    The output should include "token:$value"
  End

  It 'never lets the base64url stored value reach crocs own argv'
    value='croc-store-v1.b64-origin_abc.id-9x_2.KEY-with_dash-and_underscore'
    share::get --out "$SB/out" --allow-argv "$value"
    When call grep '^argv:' "$SB/calls"
    The output should not include "$value"
  End

  It 'trims a clipboard value carrying trailing whitespace and a trailing newline without corrupting it'
    printf '#!/bin/sh\nprintf "croc-store-v1.b64.abc.KEY   \\n\\n\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    share::get --out "$SB/out"
    When call cat "$SB/calls"
    The output should include 'token:croc-store-v1.b64.abc.KEY'
    The output should not include 'KEY '
  End

  # --- Finding 1 fix: an explicitly-requested source that comes back empty
  # must NOT silently fall back to the clipboard. `-z "$value"` alone cannot
  # distinguish "no source was requested" from "the requested source
  # produced nothing" — a fake pbpaste with a distinctive, never-expected
  # token is planted in every case below so a wrongful fallback would be
  # visible in the assertions.

  It 'fails and never invokes croc when stdin is explicitly requested but empty'
    printf '#!/bin/sh\nprintf "croc-store-v1.SHOULD.NOT.BE.USED\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    Data ''
    When run share::get --out "$SB/out" -
    The status should be failure
    The stderr should include 'no croc share'
    The path "$SB/calls" should not be exist
  End

  It 'fails and never invokes croc when given an explicit empty argument'
    printf '#!/bin/sh\nprintf "croc-store-v1.SHOULD.NOT.BE.USED\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    When run share::get --out "$SB/out" ''
    The status should be failure
    The stderr should include 'no croc share'
    The path "$SB/calls" should not be exist
  End

  It 'still reads the clipboard when no source is requested at all (the fix must not break the primary path)'
    printf '#!/bin/sh\nprintf "croc-store-v1.regression.clip.KEY\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    share::get --out "$SB/out"
    When call cat "$SB/calls"
    The output should include 'token:croc-store-v1.regression.clip.KEY'
  End

  # --- Finding 2: an isolated PATH (no inherited suffix) guarantees pbpaste
  # absence on any host, rather than depending on the platform's toolset.

  It 'fails helpfully when no value is given and pbpaste is unavailable'
    PATH="$SB/bin"
    When run share::get --out "$SB/out"
    The status should be failure
    The stderr should include 'pbpaste is unavailable'
  End
End
