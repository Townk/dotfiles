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
{ printf 'argv:%s\n' "$*"
  printf 'token:%s\n' "${CROC_STORE_TOKEN:-}"
  printf 'secret:%s\n' "${CROC_SECRET:-}"; } >>"$SHARE_CALLS"
SH
    chmod +x "$SB/bin/croc"

    # HOUSE RULE: a test must never touch a live service. Receiving is
    # backgrounded BY DEFAULT since the live-first amendment, so without these
    # an example enqueues real work against the running pueued — it did, twice
    # per run — and share::clip would overwrite the user's clipboard.
    cat >"$SB/bin/pueue" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${SHARE_PUEUE_CALLS:-/dev/null}"
case "$1" in
  add) printf '1\n' ;;
  *)   : ;;
esac
SH
    cat >"$SB/bin/tmux" <<'SH'
#!/bin/sh
exit 0
SH
    chmod +x "$SB/bin/pueue" "$SB/bin/tmux"
    JOB_PUEUE_BIN="$SB/bin/pueue"; export JOB_PUEUE_BIN
    JOB_TMUX_BIN="$SB/bin/tmux";   export JOB_TMUX_BIN
    JOB_STATE_ROOT="$SB/jobs";     export JOB_STATE_ROOT
    SHARE_PUEUE_CALLS="$SB/pueue-calls"; export SHARE_PUEUE_CALLS
    SHARE_LIVE_DIR="$SB/live";     export SHARE_LIVE_DIR

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

  # --- the pasted chat line (amendment D3) --------------------------------
  # What share now puts on the clipboard is a sentence, not a bare value, and
  # it comes back through a chat client with whatever text people wrapped
  # around it. So the live branch SCANS, unlike the stored branch which matches
  # a bare value end to end.

  It 'classifies the line share puts on the clipboard as live'
    When call share::classify 'Report.pdf (4.2 MB) — receive with:  croc f6n4-e36v-tjpj-s93k'
    The output should equal 'live'
  End

  It 'pulls the phrase out of a line buried in chat prose'
    When call share::parse_live 'hey! sending the deck: Deck.key (18 MB) — receive with:  croc f6n4-e36v-tjpj-s93k  — shout if it stalls'
    The output should equal 'f6n4-e36v-tjpj-s93k	'
  End

  It 'pulls BOTH the relay and the phrase when the sender named one'
    When call share::parse_live 'R.pdf (1 B) — receive with:  croc --relay 192.168.1.50:9009 f6n4-e36v-tjpj-s93k'
    The output should equal 'f6n4-e36v-tjpj-s93k	192.168.1.50:9009'
  End

  # THE regression this project has already paid for once. The phase-1 live
  # extraction used `grep -oE 'croc [a-z0-9-]{6,}'`, which has `-` inside the
  # character class, so it matched "croc --relay" and reported the shared value
  # as literally "--relay" — the recipient was told to run `croc --relay`.
  # A phrase here must be hyphen-joined groups of unreserved characters, so no
  # flag can satisfy it no matter where it sits in the line.
  It 'never returns --relay as the phrase'
    parsed_phrase() {
      share::parse_live 'R.pdf — receive with:  croc --relay lab.example.com:9009 8878-salary-courage-roger' \
        | cut -f1
    }
    When call parsed_phrase
    The output should equal '8878-salary-courage-roger'
  End

  # A stored blurb also contains the word "croc" (in "get croc: github.com/…").
  # It must not be mistaken for a live share.
  It 'does not read a stored CLI blurb as a live share'
    When call share::classify 'R.pdf (1 B) → croc-store-v1.b64.abc.KEY · get croc: github.com/schollz/croc · expires Aug 20'
    The output should equal 'unknown'
  End

  It 'passes the sender'"'"'s relay to croc, without which the recipient cannot connect'
    share::get --foreground --out "$SB/out" \
      'R.pdf (1 B) — receive with:  croc --relay 192.168.1.50:9009 f6n4-e36v-tjpj-s93k'
    When call grep '^argv:' "$SB/calls"
    The output should include '--relay 192.168.1.50:9009'
  End

  # Backgrounded by default: a live receive blocks until the sender is
  # reachable, which can be minutes. The phrase reaches the job through the
  # same mode-0600 file the send half uses — never pueue's argv, which pueued
  # records into state.json, and never its environment, which job::start now
  # strips of exactly these names (commit 7e72661c).
  It 'receives in the background, carrying the phrase in a secret file'
    share::get --out "$SB/out" \
      'R.pdf (1 B) — receive with:  croc --relay 192.168.1.50:9009 f6n4-e36v-tjpj-s93k' >/dev/null 2>&1
    off_argv() {
      grep -q -- '--secret-file' "$SB/pueue-calls" || return 1
      grep -q -- 'f6n4-e36v-tjpj-s93k' "$SB/pueue-calls" && return 1
      # croc itself is never invoked by the enqueuing process.
      [ -s "$SB/calls" ] && return 1
      return 0
    }
    When call off_argv
    The status should be success
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

  # A code phrase still needs NO --allow-argv consent (it is single-use and
  # worthless once consumed, unlike a stored link's long-lived key) — but it no
  # longer lands on croc's argv either: share::_croc_receive hands it over in
  # CROC_SECRET. "Permitted on argv" was never a reason to put it there.
  It 'accepts a code phrase without consent, and keeps it off croc'"'"'s argv'
    share::get --foreground --out "$SB/out" '7-truck-mango-basil'
    phrase_via_env() {
      grep -q '^secret:7-truck-mango-basil$' "$SB/calls" || return 1
      grep '^argv:' "$SB/calls" | grep -q '7-truck-mango-basil' && return 1
      return 0
    }
    When call phrase_via_env
    The status should be success
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

  # --- Finding 1 round 2: `--` must hand its following value to the SAME
  # path as a plain positional argument (source_requested=1, from_argv=1),
  # never silently discard it and fall through to the clipboard. Each of the
  # first three plants a distinctive clipboard token so a wrongful fallback
  # would be visible in the assertions.

  It 'uses a code phrase after -- (exempt from consent, carried in CROC_SECRET)'
    printf '#!/bin/sh\nprintf "croc-store-v1.SHOULD.NOT.BE.USED\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    share::get --foreground --out "$SB/out" -- '7-truck-mango-basil'
    When call grep '^secret:' "$SB/calls"
    The output should include '7-truck-mango-basil'
  End

  It 'refuses a stored token after -- without --allow-argv, and never invokes croc'
    printf '#!/bin/sh\nprintf "croc-store-v1.SHOULD.NOT.BE.USED\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    When run share::get --out "$SB/out" -- 'croc-store-v1.b64.abc.KEY'
    The status should be failure
    The stderr should include '--allow-argv'
    The path "$SB/calls" should not be exist
  End

  It 'accepts a stored token after -- with --allow-argv, via CROC_STORE_TOKEN and never on argv'
    printf '#!/bin/sh\nprintf "croc-store-v1.SHOULD.NOT.BE.USED\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    share::get --out "$SB/out" --allow-argv -- 'croc-store-v1.b64.abc.KEY'
    When call cat "$SB/calls"
    The output should include 'token:croc-store-v1.b64.abc.KEY'
  End

  It 'never puts the -- stored value on crocs own argv'
    printf '#!/bin/sh\nprintf "croc-store-v1.SHOULD.NOT.BE.USED\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    share::get --out "$SB/out" --allow-argv -- 'croc-store-v1.b64.abc.KEY'
    When call grep '^argv:' "$SB/calls"
    The output should not include 'croc-store-v1'
  End

  It 'falls back to the clipboard when a bare trailing -- has nothing after it (no source was requested)'
    printf '#!/bin/sh\nprintf "croc-store-v1.after.bare.dashdash.KEY\\n"\n' >"$SB/bin/pbpaste"
    chmod +x "$SB/bin/pbpaste"
    share::get --out "$SB/out" --
    When call cat "$SB/calls"
    The output should include 'token:croc-store-v1.after.bare.dashdash.KEY'
  End
End
