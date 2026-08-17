#!/usr/bin/env zsh
# share.zsh — async file sharing: put bytes somewhere a named person can fetch
# them, hand back a link. SOURCED, never executed.
# Spec: docs/superpowers/specs/2026-08-11-croc-file-sharing-design.md
#
# Two backends behind one interface: `croc` (end-to-end encrypted, personal)
# and `rclone` (custodial, work/OneDrive). Which one an endpoint uses is a
# property of the endpoint, never of the command line.

[ -n "${__SHARE_ZSH_LOADED:-}" ] && return 0
__SHARE_ZSH_LOADED=1

# Capture the library directory ONCE, at source time. `${(%):-%x}` names the
# file currently being sourced, which is what we want here — but evaluating it
# again inside a function is fragile, so every later child-source and the
# job.zsh lookup in share::_load_jobs read this constant instead.
SHARE_LIB_SELF_DIR="${${(%):-%x}:A:h}"

source "$SHARE_LIB_SELF_DIR/common.zsh"
source "$SHARE_LIB_SELF_DIR/share/blurb.zsh"
source "$SHARE_LIB_SELF_DIR/share/ledger.zsh"
source "$SHARE_LIB_SELF_DIR/share/croc.zsh"

: "${SHARE_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/share}"
: "${SHARE_ENDPOINTS_FILE:=$SHARE_CONFIG_DIR/endpoints.toml}"
: "${SHARE_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/share}"

# The built-in endpoint. It lives in CODE, not the manifest, so a machine that
# has never been configured can still share a file. getcroc.com is safe as a
# default precisely because croc's store is zero-knowledge: it holds ciphertext
# and the master key never leaves the URL fragment.
SHARE_BUILTIN_JSON='{
  "public": {
    "description": "Public croc store (getcroc.com)",
    "backend": "croc",
    "store": "https://getcroc.com",
    "web": true,
    "profiles": ["personal"],
    "default_for": ["personal"]
  }
}'

# share::profile — this machine's chezmoi profile. `chezmoi data` costs a
# process, so memoize it; SHARE_PROFILE is both the override and the test seam.
share::profile() {
  if [ -z "${SHARE_PROFILE:-}" ]; then
    SHARE_PROFILE="$(chezmoi data 2>/dev/null | yq -r '.profile // "personal"' 2>/dev/null)"
    [ -n "$SHARE_PROFILE" ] || SHARE_PROFILE=personal
  fi
  printf '%s\n' "$SHARE_PROFILE"
}

# share::endpoints_json — every endpoint as one JSON object. Manifest entries
# win over the built-in, so `public` can be redefined locally.
# `yq -p toml -o json` is the house TOML idiom (cf. svc::toml_json).
#
# Returns 1 (after logging) on a malformed manifest rather than calling `die`:
# every call site here runs inside a pipe or `$(...)`, both subshells in zsh,
# so `exit 1` would only kill the subshell and the caller would see success
# with empty/partial output. Callers must capture into a variable and check
# the status before piping onward — see share::endpoint_names and
# share::field below.
share::endpoints_json() {
  local manifest='{}'
  if [[ -f "$SHARE_ENDPOINTS_FILE" ]]; then
    manifest="$(yq -p toml -o json '.' "$SHARE_ENDPOINTS_FILE" 2>/dev/null)" || {
      log_error "share: cannot parse $SHARE_ENDPOINTS_FILE"
      return 1
    }
  fi
  jq -n --argjson builtin "$SHARE_BUILTIN_JSON" --argjson manifest "$manifest" \
    '$builtin * $manifest'
}

share::endpoint_names() {
  local json
  json="$(share::endpoints_json)" || return 1
  printf '%s' "$json" | jq -r 'keys[]'
}

# share::_progress <pct> <msg> — progress reporting that is safe everywhere.
# The backends call this unconditionally; it does nothing unless we are actually
# inside a job:: job (JOB_ID is injected by job::start) AND job.zsh has been
# sourced. Without the guard a foreground send would hit "job::progress: command
# not found" mid-pipeline.
share::_progress() {
  [ -n "${JOB_ID:-}" ] || return 0
  (( $+functions[job::progress] )) || return 0
  job::progress "$@" 2>/dev/null || return 0
}

# share::field <endpoint> <key> [default] — one scalar. Arrays come back as a
# newline-joined list so callers can iterate without a second jq. A missing key
# always yields the caller's [default] — uniformly, for every key including
# `backend`. (The built-in `public` endpoint still carries an explicit
# "backend": "croc" in SHARE_BUILTIN_JSON; callers that want croc as the
# fallback for endpoints that omit it pass it explicitly, e.g.
# `share::field "$endpoint" backend croc`.)
share::field() {
  local name="${1:?share::field: endpoint required}"
  local key="${2:?share::field: key required}"
  local fallback="${3-}"
  local endpoints
  endpoints="$(share::endpoints_json)" || return 1
  local json
  json="$(printf '%s' "$endpoints" | jq -e --arg n "$name" '.[$n]' 2>/dev/null)" || {
    log_error "share: unknown endpoint: $name"
    return 1
  }
  local value
  value="$(printf '%s' "$json" | jq -r --arg k "$key" '
    if (.[$k] == null) then "\u0000"
    elif (.[$k] | type) == "array" then (.[$k] | join("\n"))
    else (.[$k] | tostring) end')"
  if [[ "$value" == $'\0' ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  printf '%s\n' "$value"
}

# --- endpoint resolution + the policy fence ---------------------------------
# The endpoint is NEVER implicit. Two mechanisms enforce that: `profiles` is an
# allowlist checked on every resolution, and share::destination_host feeds the
# pre-send echo so the human sees the HOST (not the nickname they misremember)
# before a byte leaves.

# share::default_endpoint — the endpoint whose default_for claims this profile.
#
# A MANIFEST claim beats the built-in. jq's `*` merge puts built-in keys first,
# so a naive `to_entries | .[0]` would always find `public` (which claims
# `personal`) ahead of a local endpoint claiming the same profile — silently
# defaulting to getcroc.com on a machine that declared its own default. That is
# precisely the "endpoint is never implicit" failure the policy fence exists to
# prevent, so the manifest is scanned first and the built-in is the fallback.
share::default_endpoint() {
  local profile match
  profile="$(share::profile)"

  local manifest='{}'
  if [[ -f "$SHARE_ENDPOINTS_FILE" ]]; then
    manifest="$(yq -p toml -o json '.' "$SHARE_ENDPOINTS_FILE" 2>/dev/null)" || {
      log_error "share: cannot parse $SHARE_ENDPOINTS_FILE"
      return 1
    }
  fi
  match="$(jq -rn --argjson m "$manifest" --arg p "$profile" '
    $m | to_entries
    | map(select(((.value.default_for // []) | index($p)) != null))
    | if length > 0 then .[0].key else "" end')"
  if [[ -n "$match" ]]; then
    printf '%s\n' "$match"
    return 0
  fi

  printf '%s\n' "$(jq -rn --argjson b "$SHARE_BUILTIN_JSON" --arg p "$profile" '
    $b | to_entries
    | map(select(((.value.default_for // []) | index($p)) != null))
    | if length > 0 then .[0].key else "public" end')"
}

# share::allowed <endpoint> — fail CLOSED. A `profiles` key that is absent or
# declared empty both deny, with distinguishable messages: an endpoint with no
# `profiles` at all is a manifest that forgot to declare an allowlist, while
# `profiles = []` is (deliberately or accidentally) "nobody". Neither may be
# read as "open" — this repo's culture is fail-closed (cf.
# .chezmoitemplates/profile-traits.tmpl). Reads the endpoint's own JSON
# directly instead of going through share::field, because share::field's
# uniform missing-key fallback renders an empty declared array identically to
# a missing key.
share::allowed() {
  local name="${1:?share::allowed: endpoint required}" profile
  profile="$(share::profile)"
  local endpoints
  endpoints="$(share::endpoints_json)" || return 1
  local entry
  entry="$(printf '%s' "$endpoints" | jq -e --arg n "$name" '.[$n]' 2>/dev/null)" || {
    log_error "share: unknown endpoint: $name"
    return 1
  }
  if [[ "$(printf '%s' "$entry" | jq -r 'has("profiles")')" != "true" ]]; then
    log_error "share: endpoint $name declares no profiles allowlist — add profiles = [...] to endpoints.toml"
    return 1
  fi
  if (( $(printf '%s' "$entry" | jq -r '(.profiles // []) | length') == 0 )); then
    log_error "share: endpoint $name has an empty profiles allowlist — nobody is allowed"
    return 1
  fi
  printf '%s' "$entry" | jq -r '.profiles[]' | grep -qxF "$profile"
}

# share::resolve [<name>] — the one place an endpoint name is decided.
share::resolve() {
  local name="${1-}" profile
  profile="$(share::profile)"
  [[ -n "$name" ]] || { name="$(share::default_endpoint)" || return 1; }
  local endpoints
  endpoints="$(share::endpoints_json)" || return 1
  printf '%s' "$endpoints" | jq -e --arg n "$name" 'has($n)' >/dev/null 2>&1 || {
    log_error "share: unknown endpoint: $name"
    return 1
  }
  if ! share::allowed "$name"; then
    if [[ -n "${SHARE_FORCE:-}" ]]; then
      log_warn "share: policy override — $name is not allowed on profile $profile"
    else
      log_error "share: endpoint $name is not allowed on profile $profile"
      log_error "share: pass --to <endpoint> for an allowed one, or --force to override"
      return 1
    fi
  fi
  printf '%s\n' "$name"
}

# share::destination_host <endpoint> — what the pre-send echo names. The host of
# the store origin, or the rclone remote when there is no origin.
share::destination_host() {
  local name="${1:?share::destination_host: endpoint required}" store remote host
  store="$(share::field "$name" store)" || return 1
  if [[ -n "$store" ]]; then
    host="${${store#*://}%%/*}"
    if [[ -z "$host" ]]; then
      log_error "share: endpoint $name has a store URL with no host: $store"
      return 1
    fi
    printf '%s\n' "$host"
    return 0
  fi
  remote="$(share::field "$name" remote)"
  printf '%s\n' "$remote"
}
