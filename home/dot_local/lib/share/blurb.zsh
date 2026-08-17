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
SHARE_TEMPLATE_LIVE="%name → run: croc %code · I'm holding it open · get croc: %crocurl"

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

# share::label <path…> — "Report.pdf (4.2 MB)" or "3 files (12.0 MB)".
share::label() {
  zmodload zsh/stat 2>/dev/null
  local -a sizes
  local total=0 path
  for path in "$@"; do
    zstat -A sizes +size -- "$path" 2>/dev/null || sizes=(0)
    (( total += sizes[1] ))
  done
  if (( $# == 1 )); then
    printf '%s (%s)\n' "${1:t}" "$(share::human_size $total)"
  else
    printf '%d files (%s)\n' "$#" "$(share::human_size $total)"
  fi
}

# share::blurb <endpoint> <kind> <label> <value> <expires> <downloads>
#   kind: web (value = URL) | cli (value = token) | live (value = code phrase)
share::blurb() {
  local endpoint="${1:?share::blurb: endpoint required}"
  local kind="${2:?share::blurb: kind required}"
  local label="$3" value="$4" expires="$5" downloads="$6"

  local template
  template="$(share::field "$endpoint" message)" || return 1
  if [[ -z "$template" ]]; then
    case "$kind" in
      web)  template="$SHARE_TEMPLATE_WEB" ;;
      cli)  template="$SHARE_TEMPLATE_CLI" ;;
      live) template="$SHARE_TEMPLATE_LIVE" ;;
      *)    log_error "share: unknown blurb kind: $kind"; return 1 ;;
    esac
  fi

  local out="$template"
  out="${out//\%name/$label}"
  out="${out//\%url/$value}"
  out="${out//\%token/$value}"
  out="${out//\%code/$value}"
  out="${out//\%expires/$expires}"
  out="${out//\%downloads/$downloads}"
  out="${out//\%crocurl/$SHARE_CROC_URL}"
  # Belt and braces: a template edited by hand must never inject a newline.
  printf '%s\n' "${out//$'\n'/ }"
}
