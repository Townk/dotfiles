#!/usr/bin/env zsh
# share/blurb.zsh — compose the one-line message that gets injected or copied.
# SOURCED by share.zsh, never executed.
#
# ONE LINE, always: the injection target is the originating shell pane, where a
# newline executes. Fields are separated by " · ".
#
# Template choice is driven by endpoint CAPABILITY, not profile: a self-hosted
# croc-web serves its own browser page, so a recipient there needs no CLI even
# on a profile that cannot use the public store. What forces an install is
# `web = false`, or live mode.

SHARE_CROC_URL="github.com/schollz/croc"

SHARE_TEMPLATE_WEB='%name → %url · expires %expires, %downloads'
SHARE_TEMPLATE_CLI='%name → %token · get croc: %crocurl · expires %expires'

# Live is the DEFAULT mode (amendment D1) and this line is the product: it is
# what gets pasted into a chat message, so it has to serve four readers at
# once — `share get` parses it, a croc-only recipient runs it verbatim, a human
# reads a filename and a size, and the sender recognises what they just sent.
#
# The old template ("run: croc %code · I'm holding it open") was both wrong and
# too late: it printed AFTER croc had exited, i.e. after the transfer it claimed
# to be holding open had already closed. The blurb is now emitted before the
# transfer starts (share::send), which is the only time it is any use.
SHARE_TEMPLATE_LIVE='%name — receive with:  croc %code'

# A self-hosted relay MUST be named. The phrase alone suffices only on croc's
# built-in relay and on a multicast LAN (`local_only`); for any other relay the
# recipient has no way to find the sender, and the transfer simply never
# happens. Selected automatically by share::blurb on the endpoint's `relay`.
SHARE_TEMPLATE_LIVE_RELAY='%name — receive with:  croc --relay %relay %code'

# share::human_size <bytes>
share::human_size() {
  local bytes="${1:-0}"
  if (( bytes < 1024 )); then
    printf '%d B\n' "$bytes"
  elif (( bytes < 1024 ** 2 )); then
    printf '%.1f KB\n' "$(( bytes / 1024.0 ))"
  elif (( bytes < 1024 ** 3 )); then
    printf '%.1f MB\n' "$(( bytes / 1024.0 ** 2 ))"
  else
    printf '%.1f GB\n' "$(( bytes / 1024.0 ** 3 ))"
  fi
}

# share::label <path…> — "Report.pdf (4.2 MB)" or "3 files (12.0 MB)". Fails
# closed on a missing path rather than reporting "0 B": callers such as
# Task 9's job-title builder do not re-validate paths themselves, so a typo
# must be visible here, not silently rendered as an empty file.
share::label() {
  zmodload zsh/stat 2>/dev/null
  local -a sizes
  # `p`, deliberately NOT `path`: in zsh the lowercase `path` array is TIED to
  # `$PATH` (same storage), so `local path` followed by scalar assignment in
  # a loop replaces the whole tied array — see share::send in share.zsh for
  # the verified failure this caused elsewhere. Currently harmless in THIS
  # function (nothing after the loop needs `$PATH`, and the shadow is
  # discarded on return), but the pattern is the same landmine.
  local total=0 p
  for p in "$@"; do
    [[ -e "$p" ]] || { log_error "share: no such file: $p"; return 1; }
    zstat -A sizes +size -- "$p" 2>/dev/null || sizes=(0)
    (( total += sizes[1] ))
  done
  if (( $# == 1 )); then
    printf '%s (%s)\n' "${1:t}" "$(share::human_size $total)"
  else
    printf '%d files (%s)\n' "$#" "$(share::human_size $total)"
  fi
}

# share::_render <template> <token> <value> [<token> <value> …]
#
# Single left-to-right pass, appending only: text already emitted into `out`
# is never re-scanned, so a value that itself contains a %-token (e.g. a
# filename literally named "%url") can never be re-substituted by a later
# replacement in the chain. Splitting on `%` and walking the resulting parts
# achieves that in one pass, unlike a chain of `${out//...}` global replaces
# which each rescan the whole (growing) string.
share::_render() {
  local template="$1"; shift
  local -A vals=("$@")
  # Longest-first: guards against a shorter token name being a prefix of a
  # longer one (none currently collide, but the check is cheap insurance).
  local -a order=(%downloads %crocurl %expires %relay %token %name %code %url)
  # `(@s:%:)` splits on literal `%` and preserves empty fields, so a template
  # that STARTS with a token (parts[1] == "") does not shift every other
  # field down by one.
  local -a parts=("${(@s:%:)template}")
  local out="${parts[1]}" p tok bare
  local -i i matched
  for (( i = 2; i <= ${#parts[@]}; i++ )); do
    p="${parts[i]}"; matched=0
    for tok in "${order[@]}"; do
      bare="${tok#%}"
      if [[ "$p" == "$bare"* ]]; then
        out+="${vals[$tok]}${p#$bare}"; matched=1; break
      fi
    done
    # No known token matched: the `%` was literal (e.g. "100%"). Put it back.
    (( matched )) || out+="%$p"
  done
  # Belt and braces: a template edited by hand must never inject a newline.
  printf '%s\n' "${out//$'\n'/ }"
}

# share::blurb <endpoint> <kind> <label> <value> <expires> <downloads>
#   kind: web (value = URL) | cli (value = token) | live (value = code phrase)
share::blurb() {
  local endpoint="${1:?share::blurb: endpoint required}"
  local kind="${2:?share::blurb: kind required}"
  local label="$3" value="$4" expires="$5" downloads="$6"

  # The relay is read from the endpoint rather than passed in: every caller
  # already knows the endpoint, and threading a relay argument through each of
  # them for one template's benefit would be the same mistake %size would have
  # been (see below).
  local relay=""
  [[ "$kind" == live ]] && relay="$(share::relay_address "$endpoint")"

  local template
  template="$(share::field "$endpoint" message)" || return 1
  if [[ -z "$template" ]]; then
    case "$kind" in
      web)  template="$SHARE_TEMPLATE_WEB" ;;
      cli)  template="$SHARE_TEMPLATE_CLI" ;;
      live)
        if [[ -n "$relay" ]]; then
          template="$SHARE_TEMPLATE_LIVE_RELAY"
        else
          template="$SHARE_TEMPLATE_LIVE"
        fi
        ;;
      *)    log_error "share: unknown blurb kind: $kind"; return 1 ;;
    esac
  fi

  share::_render "$template" \
    %name "$label" %url "$value" %token "$value" %code "$value" \
    %expires "$expires" %downloads "$downloads" %crocurl "$SHARE_CROC_URL" \
    %relay "$relay"
}
