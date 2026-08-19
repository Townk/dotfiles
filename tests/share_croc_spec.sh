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
    # Secret files land in the sandbox, not the real state dir: these examples
    # mint live phrases, and without this they leave 0600 files behind in
    # ~/.local/state/share/live on the dev machine (they did — 44 of them).
    SHARE_LIVE_DIR="$SB/live"; export SHARE_LIVE_DIR
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
    The lines of output should equal 13   # +1 --ignore-stdin, +1 --disable-clipboard
  End

  # F5 fix: the relay PASSWORD never rides argv — a self-hosted endpoint's
  # `pass` used to become a literal `--pass <secret>` token here, and on
  # Linux (a shared corporate box included) /proc/<pid>/cmdline is
  # world-readable for the life of the process. share::croc_send now hands
  # it to croc through CROC_PASS in the child's environment instead (croc's
  # own flag parser supports it: src/cli/cli.go:149 declares EnvVars:
  # []string{"CROC_PASS"}); share::croc_argv builds relay/code/paths only.
  It 'builds a live-send argv with the relay, and NO --code, --pass or store flags'
    When call share::croc_argv lab live '' '' "$SB/Report.pdf"
    The output should include '--relay'
    The output should include 'lab.example.com:9009'
    The output should not include '--pass'
    The output should not include 'hunter2'
    The output should not include '--store'
    The output should include "$SB/Report.pdf"
    # croc REFUSES --code on argv on UNIX ("you need to set the environmental
    # variable CROC_SECRET") because the phrase is the PAKE shared secret and
    # argv is world-readable. Verified live: it aborts before any network I/O.
    The output should not include '--code'
  End

  It 'adds --local for a local_only endpoint, before the subcommand'
    printf '[lan]\nrelay = "127.0.0.1:9009"\nlocal_only = true\nweb = false\nprofiles = ["personal"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    # --local is a GLOBAL croc flag: after `send` it is "flag provided but not
    # defined". Assert it precedes the subcommand, not merely that it appears.
    before_send() { share::croc_argv lan live '' '' "$SB/Report.pdf" | awk '/^send$/{exit} /^--local$/{print "yes"}'; }
    When call before_send
    The output should equal 'yes'
  End

  It 'always passes --ignore-stdin, before the subcommand'
    # Without it, a send with no tty (pueue, yazi, the picker) has croc treat
    # its piped stdin as the payload; stored mode then refuses outright.
    # Reproduced live via `share --background`. Position matters: it is global.
    ignore_before_send() { share::croc_argv drop store 3d 1 "$SB/Report.pdf" | awk '/^send$/{exit} /^--ignore-stdin$/{print "yes"}'; }
    When call ignore_before_send
    The output should equal 'yes'
  End

  It 'omits --local for an endpoint that does not ask for it'
    When call share::croc_argv lab live '' '' "$SB/Report.pdf"
    The output should not include '--local'
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

  # share::croc_pass is the split-out seam F5 introduced: it resolves the
  # @secret: indirection the same way share::croc_argv used to internally,
  # but its result never touches an argv — share::croc_send is the only
  # place it meets the command, via CROC_PASS in the environment.
  It 'resolves a @secret: password from the environment'
    printf '[s]\nrelay = "r:9009"\npass = "@secret:SHARE_TEST_PASS"\nprofiles = ["personal"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    export SHARE_TEST_PASS=frompass
    When call share::croc_pass s
    The output should equal 'frompass'
  End

  It 'never puts the resolved password on the argv share::croc_argv builds'
    printf '[s]\nrelay = "r:9009"\npass = "@secret:SHARE_TEST_PASS"\nprofiles = ["personal"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    export SHARE_TEST_PASS=frompass
    When call share::croc_argv s live '' '' "$SB/Report.pdf"
    The output should not include 'frompass'
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

  # F5 fix, end to end: share::croc_send hands the endpoint's relay password
  # to croc through CROC_PASS in the child's OWN environment, never as a
  # `--pass` token — this drives the real function (not just
  # share::croc_argv/share::croc_pass in isolation) against the `lab`
  # fixture (pass = "hunter2") and inspects both what the fake croc SAW on
  # its argv and what landed in its environment.
  It 'passes the relay password to croc via CROC_PASS, never on argv, end to end'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >"$SHARE_CROC_ARGV_LOG"
printf '%s\n' "$CROC_PASS" >"$SHARE_CROC_ENV_LOG"
echo "Sending 'Report.pdf' (1 B)"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SHARE_CROC_ARGV_LOG="$SB/argv.log"; export SHARE_CROC_ARGV_LOG
    SHARE_CROC_ENV_LOG="$SB/env.log"; export SHARE_CROC_ENV_LOG
    share::croc_send lab live '' '' "$SB/Report.pdf" >/dev/null 2>/dev/null
    check() {
      grep -qxF 'hunter2' "$SHARE_CROC_ENV_LOG" || return 1
      grep -q 'hunter2' "$SHARE_CROC_ARGV_LOG" && return 1
      grep -q -- '--pass' "$SHARE_CROC_ARGV_LOG" && return 1
      return 0
    }
    When call check
    The status should be success
  End

  # Regression caught in re-review: an EARLIER version of the F5 fix set
  # `CROC_PASS="$pass"` unconditionally, including when `$pass` is empty.
  # croc's own env-var lookup (internal/cli/flag.go's flagFromEnvOrFile, via
  # Go's syscall.Getenv) reports ok=true for a PRESENT-but-EMPTY variable —
  # so an unconditional empty CROC_PASS overrides croc's own
  # DEFAULT_PASSPHRASE ("pass123", src/models/constants.go) with "", not
  # "unset". That breaks the handshake against any endpoint that leaves
  # `pass` unset (including the built-in `public` endpoint), which relies on
  # croc's default. The `drop` fixture has no `pass` field at all.
  #
  # `${CROC_PASS-UNSET}` (not `${CROC_PASS:-}`) is the only expansion that
  # distinguishes "the variable was never set" from "it was set to empty" —
  # `:-` treats both the same, which is exactly the distinction this
  # regression hinges on.
  It 'never sets CROC_PASS at all when the endpoint has no configured password'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf '%s\n' "${CROC_PASS-UNSET}" >"$SHARE_CROC_ENV_LOG"
printf 'https://drop.example.com/s/nopass#v1.KEY\ncroc-store-v1.b64.nopass.KEY\n'
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SHARE_CROC_ENV_LOG="$SB/env-nopass.log"; export SHARE_CROC_ENV_LOG
    share::croc_send drop store 3d 2 "$SB/Report.pdf" >/dev/null 2>/dev/null
    When call cat "$SB/env-nopass.log"
    The output should equal 'UNSET'
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

  It 'carries the phrase in CROC_SECRET, never on argv, and blurbs that same phrase'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_CROC_CALLS"
printf '%s' "${CROC_SECRET-}" >"$(dirname "$SHARE_CROC_CALLS")/secret"
echo "Sending 'Report.pdf' (1 B)"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SHARE_CROC_CALLS="$SB/calls"
    export SHARE_CROC_CALLS
    # The phrase now lives in a mode-0600 file rather than being minted inside
    # croc_send, because a backgrounded send has to hand the human the
    # pasteable line BEFORE the job runs (amendment D5). The three properties
    # this example pins are unchanged by that move: argv stays clean, the
    # environment carries the phrase, and the line the recipient is given
    # quotes the SAME phrase — a recipient handed a different one cannot
    # connect at all.
    sf="$(share::croc_secret_file lab)"
    blurb="$(share::emit_live_blurb lab "$sf" "$SB/Report.pdf")"
    share::croc_send --secret-file "$sf" lab live '' '' "$SB/Report.pdf" >/dev/null 2>/dev/null
    argv_has_code="$(grep -c -- '--code' "$SB/calls" || true)"
    env_code="$(cat "$SB/secret" 2>/dev/null)"
    blurb_code="$(printf '%s\n' "$blurb" | awk '{print $NF}')"
    matches() {
      [ "$argv_has_code" = 0 ] && [ -n "$env_code" ] && [ "$env_code" = "$blurb_code" ]
    }
    When call matches
    The status should be success
  End

  It 'writes the live secret file readable only by its owner'
    sf="$(share::croc_secret_file lab)"
    # 0600 from creation (umask inside the subshell), never 0644-then-chmod:
    # this file carries the PAKE shared secret and the relay password.
    When call zsh -c 'zmodload zsh/stat; zstat -H s -- "$1"; print -r -- ${s[mode]}' _ "$sf"
    The output should equal '33152'
  End

  # Reproduces the original finding verbatim: croc's own instruction line
  # quotes --relay/--pass BEFORE the phrase, so the pre-fix
  # `grep -oE 'croc [a-z0-9-]{6,}'` matched "croc --relay" and reported the
  # shared value as literally "--relay".
  #
  # The new design makes that structurally impossible — the phrase is generated
  # by us and never read back out of croc's prose — but the example is kept,
  # and kept pointed at the same observable, because the failure it describes
  # is one a future "just parse the output" shortcut would reintroduce.
  It 'never mistakes --relay in croc'"'"'s own instruction line for the code phrase'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
echo "Sending 'Report.pdf' (1 B)"
echo "Code is: croc --relay lab.example.com:9009 --pass hunter2 8878-salary-courage-roger"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    sf="$(share::croc_secret_file lab)"
    blurb="$(share::emit_live_blurb lab "$sf" "$SB/Report.pdf")"
    share::croc_send --secret-file "$sf" lab live '' '' "$SB/Report.pdf" >/dev/null 2>/dev/null
    blurb_code="$(printf '%s\n' "$blurb" | awk '{print $NF}')"
    # Not croc's phrase either: ours is the only one either side ever uses.
    never_relay_or_empty() {
      [ -n "$blurb_code" ] \
        && [ "$blurb_code" != "--relay" ] \
        && [ "$blurb_code" != "8878-salary-courage-roger" ]
    }
    When call never_relay_or_empty
    The status should be success
  End

  # `job::start` reports a failed enqueue with `die`, which EXITS — the caller
  # never regains control to unlink the file it just minted. Every mint
  # therefore sweeps anything too old to still be waiting for a peer, so live
  # secrets cannot quietly accumulate in the state directory.
  It 'sweeps live secret files too old to still be in use'
    old_swept_new_kept() {
      mkdir -p "$SHARE_LIVE_DIR"
      touch -t 202501010000 "$SHARE_LIVE_DIR/stale.json"
      SHARE_LIVE_DEADLINE=86400 share::croc_secret_file lab >/dev/null || return 1
      [ -e "$SHARE_LIVE_DIR/stale.json" ] && return 1
      # the file this very call minted must survive
      [ "$(ls -1 "$SHARE_LIVE_DIR" | wc -l | tr -d ' ')" = 1 ]
    }
    When call old_swept_new_kept
    The status should be success
  End

  # --- the supervised retry (amendment D7) ---------------------------------
  # A backgrounded live transfer must survive the laptop sleeping: croc's
  # connection dies, croc exits non-zero, and the job re-arms with the SAME
  # phrase on the SAME relay. That reuse is what keeps a line already pasted
  # into someone's chat valid — verified against croc 11.1.1 by killing a
  # waiting sender and reconnecting with the identical phrase.
  #
  # Gated on JOB_ID: only a job supervises. A foreground send has a human
  # watching who can simply run it again.

  It 'retries a failed live transfer and succeeds on a later attempt'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
n=$(cat "$SB_TRIES" 2>/dev/null || echo 0)
n=$((n + 1)); printf '%s' "$n" >"$SB_TRIES"
[ "$n" -lt 3 ] && { echo "connection lost"; exit 1; }
echo "Sending 'Report.pdf' (1 B)"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SB_TRIES="$SB/tries"; export SB_TRIES
    JOB_ID=fake-job SHARE_LIVE_BACKOFF_BASE=0 \
      share::croc_send lab live '' '' "$SB/Report.pdf" >/dev/null 2>/dev/null
    When call cat "$SB/tries"
    The output should equal '3'
  End

  # Retrying a rejected relay password would fail identically for 24 hours,
  # turning a clear error into a silent one. Verified croc 11.1.1 wording:
  # "could not connect to <relay>: bad response: bad password".
  It 'does not retry a failure retrying cannot fix'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
n=$(cat "$SB_TRIES" 2>/dev/null || echo 0)
printf '%s' "$((n + 1))" >"$SB_TRIES"
echo "could not connect to lab.example.com:9009: bad response: bad password"
exit 1
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SB_TRIES="$SB/tries"; export SB_TRIES
    # SHARE_LIVE_DEADLINE is bounded here so a REGRESSION fails fast rather
    # than hanging the suite: without the fatal check this loops until the
    # deadline, and at the 24h default that is not a failing test, it is a
    # wedged one. Confirmed by mutation — removing the check hung the run.
    JOB_ID=fake-job SHARE_LIVE_BACKOFF_BASE=0 SHARE_LIVE_DEADLINE=2 \
      share::croc_send lab live '' '' "$SB/Report.pdf" >/dev/null 2>/dev/null || :
    When call cat "$SB/tries"
    The output should equal '1'
  End

  # FOUND IN LIVE TESTING, and the reason the policy is now duration-based. The
  # original rule retried EVERYTHING and stopped only on one hard-coded string,
  # so an unreachable relay became a 24-hour storm: croc exited in well under a
  # second, we slept 5s, and repeated — measured at 3 attempts in 20s, doing
  # nothing each time, until the deadline a day later.
  It 'stops after a few INSTANT failures instead of retrying for a day'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
n=$(cat "$SB_TRIES" 2>/dev/null || echo 0)
printf '%s' "$((n + 1))" >"$SB_TRIES"
echo "could not connect to relay: connection refused"
exit 1
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SB_TRIES="$SB/tries"; export SB_TRIES
    JOB_ID=fake-job SHARE_LIVE_BACKOFF_BASE=0 SHARE_LIVE_FAST_FAILS=3 SHARE_LIVE_DEADLINE=3 SHARE_LIVE_MIN_RUN=5       share::croc_send lab live '' '' "$SB/Report.pdf" >/dev/null 2>/dev/null || :
    When call cat "$SB/tries"
    The output should equal '3'
  End

  It 'says the relay is unreachable rather than failing silently'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
echo "could not connect to relay: connection refused"
exit 1
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    fast_fail() {
      JOB_ID=fake-job SHARE_LIVE_BACKOFF_BASE=0 SHARE_LIVE_FAST_FAILS=2 SHARE_LIVE_DEADLINE=3 SHARE_LIVE_MIN_RUN=5         share::croc_send lab live '' '' "$SB/Report.pdf"
    }
    When run fast_fail
    The status should be failure
    The stderr should include 'unreachable or misconfigured'
    The stdout should equal ''
  End

  # The other half of the rule, and the one that keeps sleep-recovery working: a
  # croc that RAN for a while before dying was interrupted, not misconfigured,
  # so it must not consume the fast-failure budget. Without this the fix would
  # trade a 24-hour storm for giving up on the case the retry exists for.
  It 'does not count a failure that ran for a while against the budget'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
n=$(cat "$SB_TRIES" 2>/dev/null || echo 0)
n=$((n + 1)); printf '%s' "$n" >"$SB_TRIES"
sleep 2                      # ran a while: an interruption, not a bad config
[ "$n" -ge 3 ] && { echo "Sending 'Report.pdf' (1 B)"; exit 0; }
echo "connection lost"
exit 1
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SB_TRIES="$SB/tries"; export SB_TRIES
    # MIN_RUN=1 so the 2s runs count as "ran a while"; a budget of 2 would have
    # aborted at attempt 2 if these were miscounted as instant failures.
    JOB_ID=fake-job SHARE_LIVE_BACKOFF_BASE=0 SHARE_LIVE_FAST_FAILS=2 SHARE_LIVE_DEADLINE=30 SHARE_LIVE_MIN_RUN=1       share::croc_send lab live '' '' "$SB/Report.pdf" >/dev/null 2>/dev/null || :
    When call cat "$SB/tries"
    The output should equal '3'
  End

  It 'does not retry outside a job — a foreground send has a human watching'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
n=$(cat "$SB_TRIES" 2>/dev/null || echo 0)
printf '%s' "$((n + 1))" >"$SB_TRIES"
echo "connection lost"
exit 1
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SB_TRIES="$SB/tries"; export SB_TRIES
    share::croc_send lab live '' '' "$SB/Report.pdf" >/dev/null 2>/dev/null || :
    When call cat "$SB/tries"
    The output should equal '1'
  End

  It 'gives up once the deadline has passed, rather than looping forever'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
n=$(cat "$SB_TRIES" 2>/dev/null || echo 0)
printf '%s' "$((n + 1))" >"$SB_TRIES"
echo "connection lost"
exit 1
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SB_TRIES="$SB/tries"; export SB_TRIES
    # SHARE_LIVE_DEADLINE=0 puts the deadline at "now", so exactly one attempt
    # runs and the loop then stops instead of re-arming. Driven in-process:
    # a fresh `zsh -c` would not inherit this example's fixture environment.
    deadline_passed() {
      JOB_ID=fake-job SHARE_LIVE_BACKOFF_BASE=0 SHARE_LIVE_DEADLINE=0 \
        share::croc_send lab live '' '' "$SB/Report.pdf"
    }
    When run deadline_passed
    The status should be failure
    The stderr should include 'before the deadline'
    The stdout should equal ''
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

  # --- F7 fix: a live share's ledger row must be revocable-honest ----------
  # Before this fix a live row recorded backend "croc", ref "" (there is no
  # store-side id — live mode has no store) and an `expires` computed from
  # --expiration as if the store would delete it at that time, none of which
  # is true for a peer-to-peer transfer that just dies when croc exits.
  # `share revoke` on that row ran `croc --revoke ''`. Tagging the backend
  # "croc-live" is what lets share::revoke (share.zsh) refuse it up front
  # with a clear message instead.
  It 'tags a live share with the croc-live backend, not croc'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
echo "Sending 'Report.pdf' (1 B)"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    share::croc_send lab live 3d '' "$SB/Report.pdf" >/dev/null 2>/dev/null
    When call share::ledger_list
    The output should include '"backend": "croc-live"'
  End

  It 'records no expires for a live share even when an expiration was passed'
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
echo "Sending 'Report.pdf' (1 B)"
SH
    chmod +x "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    share::croc_send lab live 3d '' "$SB/Report.pdf" >/dev/null 2>/dev/null
    When call share::ledger_list
    The output should include '"expires": 0'
  End
End
