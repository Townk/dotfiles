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

# share::croc_argv <endpoint> <mode> <expiration> <downloads> <path…>
#   mode: store | live
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
  local store relay pass
  store="$(share::field "$endpoint" store)" || return 1
  relay="$(share::field "$endpoint" relay)"
  pass="$(share::_secret "$(share::field "$endpoint" pass)")"

  local -a cmd=(croc)
  [[ -n "$relay" ]] && cmd+=(--relay "$relay")
  [[ -n "$pass" ]] && cmd+=(--pass "$pass")
  cmd+=(--yes send)
  if [[ "$mode" == store ]]; then
    cmd+=(--store)
    [[ -n "$store" ]] && cmd+=(--store-url "$store")
    [[ -n "$expiration" ]] && cmd+=(--store-expiration "$expiration")
    [[ -n "$downloads" ]] && cmd+=(--store-downloads "$downloads")
  fi
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

  local tmp out rc
  tmp="$(common::tmpfile)" || return 1
  "${cmd[@]}" 2>&1 | tee "$tmp" >&2
  rc=${pipestatus[1]}
  out="$(<"$tmp")"
  rm -f -- "$tmp"
  if (( rc != 0 )); then
    log_error "share: croc exited $rc"
    return 1
  fi

  local kind value ref parsed
  if [[ "$mode" == live ]]; then
    kind=live
    value="$(printf '%s\n' "$out" | grep -oE 'croc [a-z0-9-]{6,}' | head -1)"
    value="${value#croc }"
    ref=""
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

  local id expires_epoch=0
  id="$(share::gen_id)"
  [[ -n "$expiration" ]] && expires_epoch=$(( EPOCHSECONDS + $(share::_duration_seconds "$expiration") ))
  share::ledger_add "$id" croc "$endpoint" "$label" "$ref" "$value" "$expires_epoch"

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
