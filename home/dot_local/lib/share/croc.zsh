#!/usr/bin/env zsh
# share/croc.zsh — the croc backend: end-to-end encrypted transfers.
# SOURCED by share.zsh, never executed.
#
# Stored mode uploads client-side-encrypted ciphertext and returns a browser URL
# whose master key lives in the URL FRAGMENT — never transmitted to the server.
# Live mode holds a peer-to-peer transfer open behind a code phrase.
#
# share::croc_argv only BUILDS the command (one token per line) so the whole
# argv is testable without a transfer ever happening.

# share::_secret <value> — resolve an "@secret:NAME" indirection against the
# environment. system-secrets exports every declared slot as an env var, so
# there is nothing to decrypt here; a literal value passes straight through.
#
# The `:-` inside the indirect expansion is load-bearing, not decoration: this
# library can be sourced under `set -u` (system-onboard does exactly that), and
# a BARE `${(P)name}` on a name whose target variable is unset is a reference
# to an unset parameter under nounset — it aborts with "parameter not set"
# instead of yielding empty. `${(P)name:-}` supplies the empty default before
# nounset ever gets a chance to object.
share::_secret() {
  local value="$1"
  if [[ "$value" == @secret:* ]]; then
    printf '%s\n' "${(P)${value#@secret:}:-}"
  else
    printf '%s\n' "$value"
  fi
}

# share::_code_phrase — a fresh live-mode code phrase: 16 characters from a
# 32-symbol unambiguous alphabet (a-z minus l/o, 2-9 minus 0/1 — no character
# a listener could mis-transcribe over a phone), grouped xxxx-xxxx-xxxx-xxxx
# so it stays speakable. This is the PAKE shared secret croc's `--code` uses
# to authenticate the live peer, so its entropy is load-bearing:
#   * drawn from /dev/urandom (a CSPRNG) — never $RANDOM (not
#     cryptographically secure in zsh), $$, or anything time-derived;
#   * 32 symbols is exactly 2^5, and a byte's range (256) is an exact
#     multiple of 32, so `byte % 32` is UNBIASED with no rejection sampling
#     needed — every symbol is equally likely;
#   * 16 chars * 5 bits/char = 80 bits of entropy, comfortably over the 64-bit
#     floor and well above croc's own default phrase (3 words + a number,
#     ≈38.6 bits).
share::_code_phrase() {
  local -a alphabet=(a b c d e f g h i j k m n p q r s t u v w x y z 2 3 4 5 6 7 8 9)
  local raw
  raw="$(od -An -v -tu1 -N16 /dev/urandom 2>/dev/null)" || return 1
  local -a bytes=(${=raw})
  (( ${#bytes[@]} == 16 )) || return 1
  local out="" i idx
  for (( i = 1; i <= 16; i++ )); do
    idx=$(( bytes[i] % 32 + 1 ))
    out+="${alphabet[idx]}"
    (( i < 16 && i % 4 == 0 )) && out+="-"
  done
  printf '%s\n' "$out"
}

# share::croc_pass <endpoint> — the endpoint's resolved relay password (after
# @secret: indirection), or empty. Split out of share::croc_argv so the value
# never has to touch argv to be usable: share::croc_send reads it through
# THIS function and hands it to the child via CROC_PASS in the environment
# (croc's own flag parser supports it — src/cli/cli.go:149 declares
# `&cli.StringFlag{Name: "pass", ..., EnvVars: []string{"CROC_PASS"}}`),
# never as a `--pass` token.
share::croc_pass() {
  local endpoint="${1:?share::croc_pass: endpoint required}"
  share::_secret "$(share::field "$endpoint" pass)"
}

# --- the live-mode secret channel (amendment D5/D5a) -------------------------
# A live transfer has two secrets: the PAKE code phrase and, for a relay that
# has one, the relay password. Both must reach the job that runs croc WITHOUT
# passing through pueue.
#
# Why not the environment, which is the obvious route: pueued snapshots the
# whole client environment into its state file, values included, and keeps it
# past the job (see job.zsh's job::_scrub_env_names and commit 7e72661c).
# job::start now strips exactly these names, so the environment is not merely
# unwise here — it no longer works at all.
#
# Why not argv: croc itself refuses --code on UNIX for this reason, and the
# same objection covers `share`'s own argv.
#
# So: a mode-0600 file, created by whoever is standing in front of the human,
# read by the job, and unlinked when the transfer settles. It doubles as the
# durable record the retry loop (D7) re-arms from — which is why re-running
# croc after a failure reuses the SAME phrase, and therefore why the line
# already pasted into someone's chat stays valid across a laptop sleep.
SHARE_LIVE_DIR="${SHARE_LIVE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/share/live}"

# How long a backgrounded live transfer keeps re-arming before giving up. A
# deliberate choice, not a default to ignore: the phrase stays a working
# capability for exactly this long, so it is also how long an intercepted chat
# message remains useful to someone else. 80 bits of entropy makes guessing
# irrelevant; interception is the reason this is bounded at all.
SHARE_LIVE_DEADLINE="${SHARE_LIVE_DEADLINE:-86400}"

# Retry backoff, in seconds per attempt, capped at 60. A seam as much as a
# knob: set to 0 and the retry loop runs without real sleeps, which is what
# makes it testable at all — the alternative is a suite that waits 15 seconds
# to observe three attempts. The failure being absorbed is "the peer is not
# here yet", so this is about not spinning, not about load.
SHARE_LIVE_BACKOFF_BASE="${SHARE_LIVE_BACKOFF_BASE:-5}"

# share::croc_secret_write <code> [<pass>] [<relay>] — write the file; print
# its path. The receive half uses this too (it already HAS a phrase, from a
# pasted chat line, and needs it carried to a background job the same way).
share::croc_secret_write() {
  local code="${1:?share::croc_secret_write: code required}" pass="${2-}" relay="${3-}" f
  mkdir -p -- "$SHARE_LIVE_DIR" || return 1
  chmod 700 -- "$SHARE_LIVE_DIR" 2>/dev/null || :
  # Sweep stragglers. The normal path unlinks its own file when the transfer
  # settles, but `job::start` reports a failed enqueue with `die`, which EXITS
  # — the caller never gets control back to clean up. Rather than pretend that
  # window does not exist, every mint clears anything older than a transfer
  # could still be waiting for. Self-healing beats a file full of live secrets
  # accumulating unnoticed.
  local stale
  for stale in "$SHARE_LIVE_DIR"/*.json(N.mm+$(( (SHARE_LIVE_DEADLINE / 60) + 1 ))); do
    rm -f -- "$stale"
  done
  f="$SHARE_LIVE_DIR/$(share::gen_id).json"
  # Every value travels through jq's ENVIRONMENT, never --arg: the same rule
  # share::endpoints_json states for the manifest, and it matters more here
  # because these ARE the secrets. umask inside the subshell so the file is
  # 0600 from creation — never briefly 0644 and then chmod'd.
  ( umask 077
    code="$code" pass="$pass" relay="$relay" \
      jq -n '{code: $ENV.code, pass: $ENV.pass, relay: $ENV.relay}' > "$f"
  ) || { log_error "share: cannot write the live secret file"; return 1; }
  printf '%s\n' "$f"
}

# share::croc_secret_file <endpoint> — mint a FRESH phrase for a send.
share::croc_secret_file() {
  local endpoint="${1:?share::croc_secret_file: endpoint required}"
  local code pass
  code="$(share::_code_phrase)" || return 1
  [[ -n "$code" ]] || { log_error "share: failed to generate a code phrase"; return 1; }
  pass="$(share::croc_pass "$endpoint")"
  share::croc_secret_write "$code" "$pass" ""
}

# share::croc_secret_read <file> <code|pass>
share::croc_secret_read() {
  local f="${1:?share::croc_secret_read: file required}" key="${2:?}"
  [[ -f "$f" ]] || { log_error "share: live secret file is missing: $f"; return 1; }
  jq -r --arg k "$key" '.[$k] // ""' "$f"
}

# share::croc_fatal <croc-output> — is this failure worth retrying?
#
# The retry loop exists to absorb "the peer is not here yet" and the connection
# drops a laptop sleep causes. It must NOT sit in a loop against a wall: a
# rejected relay password will fail identically forever, and retrying it for 24
# hours would turn a clear error into a silent one.
#
# This couples to croc's wording, which is a real version dependency and the
# reason it is one small function rather than a condition buried in the loop.
# Verified against croc 11.1.1: a wrong CROC_PASS yields
# "could not connect to <relay>: bad response: bad password".
share::croc_fatal() {
  local text="${1-}"
  case "$text" in
    *"bad password"*|*"incorrect password"*) return 0 ;;
  esac
  return 1
}

# share::croc_argv <endpoint> <mode> <expiration> <downloads> <path…>
#   mode: store | live
#
# Builds argv only — never the relay password. `--pass <secret>` on a
# command line is visible to every other process on the box for the life of
# this one (on Linux, a shared corporate box included, /proc/<pid>/cmdline is
# world-readable); share::croc_pass is the seam that keeps it out, and
# share::croc_send is the only place the value and the command ever meet,
# via CROC_PASS in the environment of that one invocation.
#
# The accumulator below is named `cmd`, NOT `argv`. In zsh, `argv` is not an
# ordinary identifier — it is a built-in SYNONYM for the positional parameters
# (`$@`/`$1`…), sharing the same storage. `local -a argv=(croc)` would not
# create an independent array; it would reassign this function's own `$@` out
# from under it, so the later `argv+=("$@")` — meant to append the caller's
# paths — would instead append the accumulator to itself (verified: it
# silently duplicated the whole flag list and dropped every path). `cmd`
# carries no such collision.
share::croc_argv() {
  local endpoint="$1" mode="$2" expiration="$3" downloads="$4"
  shift 4
  local store relay
  store="$(share::field "$endpoint" store)" || return 1
  relay="$(share::field "$endpoint" relay)"

  local -a cmd=(croc)
  # --ignore-stdin unconditionally: share ALWAYS names explicit paths, so croc
  # must never treat its stdin as the payload. Under pueue (share --background)
  # and from any face with no tty, stdin is a pipe, croc reads that as piped
  # input, and stored mode then refuses it outright:
  #   "stored mode does not accept stdin; pass regular file paths"
  # That broke every backgrounded send. Global flag: precedes the subcommand.
  cmd+=(--ignore-stdin)
  # --disable-clipboard: croc copies the code phrase to the clipboard ITSELF
  # ("Code copied to clipboard!") and would race the richer, pasteable line
  # share writes (amendment D4). Observed on both attempts of the phrase-reuse
  # probe. Global flag: precedes the subcommand.
  cmd+=(--disable-clipboard)
  [[ -n "$relay" ]] && cmd+=(--relay "$relay")
  # local_only: croc's --local forbids every non-LAN path. Without it croc
  # silently falls back to its DEFAULT PUBLIC relay (croc.schollz.com) when
  # multicast finds no peer — egressing a file from an endpoint that exists to
  # keep it on the wire it named. Global flag: must precede the subcommand.
  [[ "$(share::field "$endpoint" local_only false)" == true ]] && cmd+=(--local)
  cmd+=(--yes send)
  if [[ "$mode" == store ]]; then
    cmd+=(--store)
    [[ -n "$store" ]] && cmd+=(--store-url "$store")
    [[ -n "$expiration" ]] && cmd+=(--store-expiration "$expiration")
    [[ -n "$downloads" ]] && cmd+=(--store-downloads "$downloads")
  fi
  # Live mode contributes NOTHING to argv. croc REFUSES --code on the command
  # line on UNIX — "you need to set the environmental variable CROC_SECRET" —
  # for exactly the reason it refuses stored links: the phrase would be visible
  # in the process list, and it IS the PAKE shared secret. share::croc_send
  # generates it and carries it in the child ENVIRONMENT instead.
  cmd+=("$@")
  printf '%s\n' "${cmd[@]}"
}

# share::croc_parse_share <text> → "url\ttoken\tid"
# croc prints the browser URL and the CLI token amongst its normal chatter; the
# id is the /s/<id> path segment, which is what `croc --revoke` takes.
#
# Browser URL shape: https://<host>/s/<id>#v1.<base64url-key> — the trailing
# `[^[:space:]]+` (rather than a base64url-specific class) is deliberate: it
# already covers `-`/`_` (base64url's extra characters over standard base64)
# with no character class to keep in sync with croc's own alphabet choice.
# Same reasoning for the CLI token `croc-store-v1.<b64origin>.<id>.<b64key>`.
share::croc_parse_share() {
  local text="$1" url token id
  url="$(printf '%s\n' "$text" | grep -oE 'https?://[^[:space:]]+/s/[^[:space:]#]+#v1\.[^[:space:]]+' | head -1)"
  token="$(printf '%s\n' "$text" | grep -oE 'croc-store-v1\.[^[:space:]]+' | head -1)"
  [[ -n "$url" || -n "$token" ]] || return 1
  if [[ -n "$url" ]]; then
    id="${url##*/s/}"; id="${id%%#*}"
  else
    id="${${token#croc-store-v1.}#*.}"; id="${id%%.*}"
  fi
  printf '%s\t%s\t%s\n' "$url" "$token" "$id"
}

# share::croc_revoke <ref>
share::croc_revoke() {
  croc --revoke "$1"
}

# share::croc_send <endpoint> <mode> <expiration> <downloads> <path…>
# Runs the transfer, records a receipt, prints the blurb on stdout. croc's own
# progress goes to the terminal untouched, and a non-zero croc exit fails this
# function.
#
# The capture is NOT `out="$(cmd | tee /dev/stderr)"`. That reads naturally but
# is wrong on two counts: this library has no `pipefail` (and must not set one
# process-wide from inside a sourced file), so `$(...)`'s exit status is
# `tee`'s, not croc's — a failed transfer would report success. And the whole
# pipeline runs inside the command-substitution SUBSHELL, so even reading
# `$pipestatus` right after the assignment would not see it: that array lives
# in the subshell that already exited. Running the pipeline directly (writing
# to a temp file instead of through `$(...)`) keeps it in THIS shell, so
# `$pipestatus[1]` is croc's real exit code, and `tee` still mirrors every byte
# to the terminal (>&2) as it happens.
share::croc_send() {
  zmodload zsh/datetime 2>/dev/null
  # --secret-file is a LEADING flag rather than a positional so every existing
  # caller and test keeps its argument order. When present the two live secrets
  # come from that file instead of being minted here — that is the whole point:
  # the process standing in front of the human mints them, and this one (often
  # a job) only consumes them.
  local secret_file=""
  while (( $# )); do
    case "$1" in
      --secret-file)
        [[ $# -ge 2 ]] || { log_error "share: --secret-file requires a path"; return 1; }
        secret_file="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local endpoint="$1" mode="$2" expiration="$3" downloads="$4"
  shift 4

  # Same `cmd`-not-`argv` naming as share::croc_argv, and for the identical
  # reason: this function's own "$@" (the paths) is still needed below for
  # share::label, so overwriting it via a local named `argv` would corrupt it
  # before that read ever happens.
  local -a cmd
  cmd=("${(@f)$(share::croc_argv "$endpoint" "$mode" "$expiration" "$downloads" "$@")}") || return 1

  local label
  label="$(share::label "$@")" || return 1

  # The relay password, resolved here and handed to croc through CROC_PASS in
  # the environment of THIS ONE invocation (a prefix assignment, not an
  # export) — never appended to `cmd`, which is what keeps it off argv. Same
  # scoping idiom as SHARE_FORCE in the CLI's run_send: the assignment is
  # visible to the child process and gone again the moment this command
  # returns.
  #
  # Guarded on non-empty, same as the old `--pass` flag was: croc's env-var
  # lookup (internal/cli/flag.go's flagFromEnvOrFile, via syscall.Getenv)
  # reports ok=true for a PRESENT-but-EMPTY variable, same as Go's Getenv
  # always does — so an unconditional `CROC_PASS=""` would override croc's
  # own DEFAULT_PASSPHRASE ("pass123", src/models/constants.go) with an
  # empty string instead of leaving it unset. That breaks the handshake
  # against the built-in `public` endpoint and any relay endpoint that
  # leaves `pass` unset — precisely the endpoints that rely on croc's
  # default. Only set CROC_PASS when there is an actual password to carry.
  local pass
  if [[ -n "$secret_file" ]]; then
    pass="$(share::croc_secret_read "$secret_file" pass)" || return 1
  else
    pass="$(share::croc_pass "$endpoint")"
  fi

  # Live mode's PAKE shared secret. Generated here, never placed on argv (croc
  # refuses --code on UNIX precisely because argv is world-readable via ps and
  # /proc/<pid>/cmdline); it travels in the child environment as CROC_SECRET.
  # Read (not minted) when a secret file was supplied, so a retry — or a job
  # picking up work its parent prepared — reuses the SAME phrase. Guarded on
  # live: a stored send must never get a CROC_SECRET, which would change how
  # croc treats the transfer entirely.
  local code=""
  if [[ "$mode" == live ]]; then
    if [[ -n "$secret_file" ]]; then
      code="$(share::croc_secret_read "$secret_file" code)" || return 1
    else
      code="$(share::_code_phrase)" || return 1
    fi
    [[ -n "$code" ]] || { log_error "share: failed to generate a code phrase"; return 1; }
  fi

  # `rc=${pipestatus[1]}` is duplicated into BOTH branches, immediately
  # after each pipeline, rather than hoisted to one line after `fi`: zsh
  # resets $pipestatus to reflect the most recently executed command, and an
  # `if`/`fi` wrapper around the pipeline — even taking the branch that runs
  # it — counts as "something ran after the pipeline" by the time control
  # reaches the line after `fi`. Verified: hoisting the read outside the
  # if/else here silently made `rc` always read the if-statement's own exit
  # status (0), so `share::croc_send` never noticed croc failing on the
  # branch with no password. Reading pipestatus as the line immediately
  # following the pipeline, inside each branch, is what the ORIGINAL
  # single-pipeline code already relied on (see the comment above
  # share::croc_send).
  local tmp out rc
  tmp="$(common::tmpfile)" || return 1
  # Both secrets ride the environment, never argv. Each is set only when it
  # has a value: an empty CROC_PASS would override croc's own default (Go's
  # Getenv reports a present-but-empty var as set), and an empty CROC_SECRET
  # would suppress croc's own phrase generation in a mode that needs one.
  local -a envp=()
  [[ -n "$pass" ]] && envp+=("CROC_PASS=$pass")
  [[ -n "$code" ]] && envp+=("CROC_SECRET=$code")
  # The supervised retry (amendment D7). Live mode only, and only inside a
  # job:: job: a foreground send has a human watching who can just run it
  # again, while a backgrounded one is exactly the case where nobody is
  # looking. Re-arming reuses the SAME phrase on the SAME relay — verified
  # possible against croc 11.1.1 by killing a waiting sender and reconnecting
  # — which is what keeps a line already pasted into someone's chat valid
  # across a laptop sleep. Switching either is forbidden (D8): we cannot edit
  # a message that has already been sent.
  local -i deadline=0 attempt=0 wait_s=0
  if [[ "$mode" == live && -n "${JOB_ID:-}" ]]; then
    deadline=$(( EPOCHSECONDS + SHARE_LIVE_DEADLINE ))
  fi

  while :; do
    # `attempt=$(( ... ))`, never `(( attempt++ ))`: post-increment EVALUATES
    # to the old value, so on the first pass the arithmetic command yields 0 —
    # which as a standalone command is exit status 1, and this library is
    # sourced by a CLI running under `set -e`. It aborted every live send.
    attempt=$(( attempt + 1 ))
    if (( ${#envp} )); then
      env "${envp[@]}" "${cmd[@]}" 2>&1 | tee "$tmp" >&2
      rc=${pipestatus[1]}
    else
      "${cmd[@]}" 2>&1 | tee "$tmp" >&2
      rc=${pipestatus[1]}
    fi
    out="$(<"$tmp")"
    (( rc == 0 )) && break
    (( deadline > 0 )) || break
    # A rejected relay password fails identically forever; looping on it for a
    # day would turn a clear error into a silent one.
    if share::croc_fatal "$out"; then
      log_error "share: croc failed in a way retrying cannot fix"
      break
    fi
    if (( EPOCHSECONDS >= deadline )); then
      log_error "share: nobody collected this transfer before the deadline"
      break
    fi
    wait_s=$(( attempt * SHARE_LIVE_BACKOFF_BASE ))
    (( wait_s > 60 )) && wait_s=60
    share::_progress -1 "waiting for the recipient (attempt $attempt)"
    sleep "$wait_s"
  done
  rm -f -- "$tmp"
  if (( rc != 0 )); then
    log_error "share: croc exited $rc"
    return 1
  fi

  local kind value ref parsed
  if [[ "$mode" == live ]]; then
    kind=live
    ref=""
    # NOT parsed from croc's output. Its instruction line reads e.g.
    # "croc --relay host:port --pass secret abcd-efgh-ijkl-mnop" whenever
    # --relay/--pass are non-default — every self-hosted endpoint — and a naive
    # `grep -oE 'croc [a-z0-9-]{6,}'` matches "croc --relay" long before the
    # phrase. We generated it ourselves, so we simply already know it.
    value="$code"
  else
    parsed="$(share::croc_parse_share "$out")" || {
      log_error "share: croc produced no share link"
      return 1
    }
    local url token
    url="${parsed%%$'\t'*}"
    token="${${parsed#*$'\t'}%%$'\t'*}"
    ref="${parsed##*$'\t'}"
    if [[ "$(share::field "$endpoint" web false)" == true && -n "$url" ]]; then
      kind=web; value="$url"
    else
      kind=cli; value="$token"
    fi
  fi

  # Fail closed rather than record a bogus receipt or print a bogus blurb:
  # this is what the store branch already gets for free from
  # share::croc_parse_share's own guard; the live branch needs it stated
  # explicitly since there is no parse step left to fail on its behalf.
  [[ -n "$value" ]] || { log_error "share: no share value to record"; return 1; }

  local id expires_epoch=0
  id="$(share::gen_id)"
  # `expires` means "the store will delete this at T" — a promise store mode
  # can make and live mode cannot: a live transfer has no store, it just dies
  # the moment croc exits, so computing an expires_epoch from --expiration
  # for it would record a real-looking deadline for something that was never
  # actually scheduled to end there. Only the store branch computes one.
  local ledger_backend=croc
  if [[ "$mode" == live ]]; then
    ledger_backend=croc-live
  else
    [[ -n "$expiration" ]] && expires_epoch=$(( EPOCHSECONDS + $(share::_duration_seconds "$expiration") ))
  fi
  # Live rows are tagged with the distinct backend "croc-live", not "croc":
  # a live transfer has no store-side id to revoke — `ref` is empty by
  # construction above — so `share revoke` on a plain "croc" row would call
  # `croc --revoke ''`, which is neither a real revoke nor an honest error.
  # Tagging the backend is what lets share::revoke refuse it up front with a
  # clear message (see share.zsh) and lets `share list` render it as what it
  # is instead of a store link that can be revoked.
  share::ledger_add "$id" "$ledger_backend" "$endpoint" "$label" "$ref" "$value" "$expires_epoch"

  # Live mode prints NOTHING here. Its blurb went out BEFORE the transfer
  # started (share::send), which is the only moment it is any use — the
  # recipient needs the phrase in order to connect at all. Re-printing it on
  # completion would be redundant, and as the retired "I'm holding it open"
  # template showed, actively false by then.
  [[ "$mode" == live ]] && return 0

  share::blurb "$endpoint" "$kind" "$label" "$value" \
    "$(share::_expires_human "$expires_epoch")" "${downloads:-1} download(s)"
}

# share::_duration_seconds <90m|12h|3d|2w> — croc's own expiration grammar.
share::_duration_seconds() {
  local spec="$1" n="${1%[mhdw]}" unit="${1: -1}"
  case "$unit" in
    m) printf '%d\n' $(( n * 60 )) ;;
    h) printf '%d\n' $(( n * 3600 )) ;;
    d) printf '%d\n' $(( n * 86400 )) ;;
    w) printf '%d\n' $(( n * 604800 )) ;;
    *) printf '0\n' ;;
  esac
}

share::_expires_human() {
  local epoch="${1:-0}"
  (( epoch > 0 )) || { printf 'never\n'; return 0; }
  strftime '%b %d' "$epoch"
}
