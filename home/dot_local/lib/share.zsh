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
source "$SHARE_LIB_SELF_DIR/share/rclone.zsh"

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
  if [[ -z "$remote" ]]; then
    log_error "share: endpoint $name has no store and no remote to send to"
    return 1
  fi
  printf '%s\n' "$remote"
}

# --- send dispatch ----------------------------------------------------------
# The faces never learn which backend answered. That is the seam the whole
# design rests on: adding a backend must not touch yazi, the picker, or the CLI.

SHARE_DEFAULT_EXPIRATION="${SHARE_DEFAULT_EXPIRATION:-3d}"
SHARE_DEFAULT_DOWNLOADS="${SHARE_DEFAULT_DOWNLOADS:-1}"

# share::send [--to E] [--live] [--expiration D] [--downloads N] <path…>
share::send() {
  local endpoint="" mode=store
  local expiration="$SHARE_DEFAULT_EXPIRATION" downloads="$SHARE_DEFAULT_DOWNLOADS"
  # Each value-consuming flag is guarded BEFORE the `shift 2`: with the flag
  # as the last token, `$2` is empty and `shift 2` fails in zsh (shift count
  # must be <= $#) WITHOUT changing `$#` — so `$1` is still the same flag and
  # `while (( $# ))` spins forever. Verified: `share::send --to` hung until
  # killed. Guarding turns that CPU-spinning hang into an immediate, named
  # error instead.
  while (( $# )); do
    case "$1" in
      --to)         [[ $# -ge 2 ]] || die "share: --to requires an endpoint name"
                     endpoint="$2"; shift 2 ;;
      --live)       mode=live; shift ;;
      --expiration) [[ $# -ge 2 ]] || die "share: --expiration requires a value"
                     expiration="$2"; shift 2 ;;
      --downloads)  [[ $# -ge 2 ]] || die "share: --downloads requires a value"
                     downloads="$2"; shift 2 ;;
      --)           shift; break ;;
      -*)           die "share: unknown option: $1" ;;
      *)            break ;;
    esac
  done
  (( $# )) || die "share: no files given"

  # Every path is validated BEFORE any transfer starts — a partial multi-file
  # send that dies on file 3 having already uploaded 1 and 2 is worse than
  # refusing up front. Two hazards, checked per path:
  #
  #  * a literal newline in the path. The backends' argv seam
  #    (share::croc_argv / share::rclone_copy_argv) prints one token per line
  #    and callers reassemble with `cmd=("${(@f)$(...)}")` — deliberately, so
  #    the whole command is testable without a transfer ever running. A
  #    newline inside a path (legal on POSIX filesystems) would split into two
  #    argv tokens there and corrupt the command silently. Caught here, before
  #    that seam ever sees the path — `${(V)p}` renders the newline visibly
  #    (`\n`) so the error itself does not fold across lines.
  #  * the path does not exist. share::label fails on this too, but only once
  #    it is called deep inside a backend — this is the earliest point common
  #    to every backend, so a typo anywhere in a multi-file list is visible
  #    before the first byte of ANY file moves.
  #
  # The loop variable is `p`, deliberately NOT `path`: in zsh, the lowercase
  # `path` array is TIED to `$PATH` (same storage, like `argv`/`$@`). `local
  # path` shadows that tie for the rest of THIS function's scope, and
  # assigning it scalar values in the loop replaces the whole tied array with
  # a one-element PATH — verified: it broke every external-command lookup
  # (`yq`, `jq`, …) for the remainder of share::send and everything it calls,
  # surfacing as a bogus "cannot parse endpoints.toml" from share::resolve
  # deep in the call stack, with the real cause (`yq: command not found`)
  # swallowed by that code path's own `2>/dev/null`.
  local p
  for p in "$@"; do
    case "$p" in
      *$'\n'*)
        log_error "share: path contains a newline, which would corrupt the argv seam: ${(V)p}"
        return 1
        ;;
    esac
    [[ -e "$p" ]] || { log_error "share: no such file: $p"; return 1; }
  done

  endpoint="$(share::resolve "$endpoint")" || return 1

  # The pre-send echo. Not a nicety: it is what makes a wrong endpoint visible
  # before any bytes leave, and it names the HOST rather than the nickname.
  # Captured and status-checked (not inlined into the log_info call): an
  # endpoint whose destination_host fails closed (e.g. an rclone endpoint with
  # no remote) must abort the send here, not print "sending to " with an
  # empty host and carry on — log_info's own exit status would otherwise mask
  # a failed command substitution inside its argument.
  local host
  host="$(share::destination_host "$endpoint")" || return 1
  log_info "sending to $host" >&2

  # The croc default lives at the CALL SITE, not inside share::field: a
  # key-specific default hidden in the accessor silently overrode whatever a
  # caller passed.
  local backend
  backend="$(share::field "$endpoint" backend croc)" || return 1
  local blurb
  case "$backend" in
    croc)   blurb="$(share::croc_send "$endpoint" "$mode" "$expiration" "$downloads" "$@")" || return 1 ;;
    rclone)
      [[ "$mode" == live ]] && die "share: the rclone backend has no live mode"
      blurb="$(share::rclone_send "$endpoint" "$@")" || return 1
      ;;
    *) die "share: unknown backend: $backend" ;;
  esac
  print -r -- "$blurb"
  share::announce "$blurb"
}

# share::revoke <id> — dispatch on the receipt's own backend, then forget it.
share::revoke() {
  local id="${1:?share::revoke: id required}" row backend ref
  row="$(share::ledger_get "$id")" || { log_error "share: no receipt: $id"; return 1; }
  backend="$(printf '%s' "$row" | jq -r '.backend')"
  ref="$(printf '%s' "$row" | jq -r '.ref')"
  case "$backend" in
    croc)   share::croc_revoke "$ref" || return 1 ;;
    rclone) share::rclone_revoke "$ref" || return 1 ;;
    *) log_error "share: unknown backend in receipt: $backend"; return 1 ;;
  esac
  share::ledger_remove "$id"
}

# --- receive ----------------------------------------------------------------
# croc refuses a stored link on argv (src/cli/cli.go:712): the decryption key
# would be visible in `ps`. A wrapper that accepts it on OUR argv reintroduces
# the same leak, so the precedence is clipboard → stdin → argv-with-consent, and
# the value always reaches croc through CROC_STORE_TOKEN in the environment.
#
# A code phrase is exempt: single-use, worthless once consumed. Upstream draws
# the same line.

SHARE_DEFAULT_OUT="${SHARE_DEFAULT_OUT:-$HOME/Downloads}"

share::classify() {
  # `##` and `(#i)` are extendedglob constructs and the option is off by
  # default. Scope it to this function rather than setting it at file level —
  # a file-scope setopt in a sourced lib leaks into every caller.
  setopt localoptions extendedglob
  local value="${1-}"
  if [[ "$value" == croc-store-v1.* ]] \
    || [[ "$value" == (#i)http(s|)://*/s/*\#v1.* ]]; then
    printf 'stored\n'
  elif [[ "$value" == [a-z0-9]##(-[a-z0-9]##)## ]]; then
    printf 'code\n'
  else
    printf 'unknown\n'
  fi
}

# share::get [--out DIR] [--allow-argv] [<value>|-]
share::get() {
  setopt localoptions extendedglob     # the trim below uses `##`
  local out="$SHARE_DEFAULT_OUT" allow_argv=0 value="" from_argv=0 source_requested=0
  while (( $# )); do
    case "$1" in
      --out)         [[ $# -ge 2 ]] || die "share get: --out requires a directory"
                     out="$2"; shift 2 ;;
      --allow-argv)  allow_argv=1; shift ;;
      --)            shift
                     # A bare trailing `--` with nothing after it requested
                     # no source (clipboard fallback below is correct). A
                     # `--` followed by a value hands us that value exactly
                     # like the plain positional branch — including
                     # from_argv=1, so a stored token after `--` is still
                     # refused without --allow-argv. `--` must never become
                     # a silent way around the argv-consent check.
                     if (( $# )); then
                       value="$1"; from_argv=1; source_requested=1; shift
                     fi
                     break ;;
      -)             value="$(cat)"; source_requested=1; shift ;;
      -*)            die "share get: unknown option: $1" ;;
      *)             value="$1"; from_argv=1; source_requested=1; shift ;;
    esac
  done

  # `-z "$value"` cannot tell "no source was requested" from "the requested
  # source produced nothing" — a caller who explicitly asked for stdin (`-`)
  # or passed an explicit empty argument would silently fall through to the
  # clipboard, handing back a value the caller never asked for. Fall back to
  # pbpaste ONLY when no source was requested at all; an explicitly-requested
  # source that comes back empty falls through to share::classify below,
  # which reports "unknown" for an empty string and fails cleanly.
  if (( ! source_requested )); then
    command -v pbpaste >/dev/null 2>&1 || die "share get: no value given and pbpaste is unavailable"
    value="$(pbpaste 2>/dev/null)"
    from_argv=0
  fi
  value="${${value##[[:space:]]##}%%[[:space:]]##}"

  local kind; kind="$(share::classify "$value")"
  case "$kind" in
    unknown)
      log_error "share get: no croc share found in the input"
      return 1
      ;;
    stored)
      if (( from_argv && ! allow_argv )); then
        log_error "share get: a stored link on the command line would expose its"
        log_error "share get: decryption key in the process list. Pipe it in, copy it"
        log_error "share get: to the clipboard, or pass --allow-argv to accept the risk."
        return 1
      fi
      mkdir -p -- "$out"
      CROC_STORE_TOKEN="$value" croc --yes --out "$out"
      ;;
    code)
      mkdir -p -- "$out"
      croc --yes --out "$out" "$value"
      ;;
  esac
}

# --- background sends via job:: ---------------------------------------------
# An upload is long, network-bound, worth watching and worth cancelling — the
# exact shape job:: exists for. Consuming it means completion toasts (routed
# over the RECOB bridge, so a dev-shell send toasts on whichever Mac the human
# is sitting at) and process-group cancel arrive for free.
#
# Uploads get their own group so they never contend with `heavy` (pinned to
# parallelism 1 for custom builds).

SHARE_JOB_GROUP="${SHARE_JOB_GROUP:-share}"
SHARE_JOB_ICON="${SHARE_JOB_ICON:-glyph:nf-md-share_variant}"

share::_load_jobs() {
  [ -n "${__JOB_ZSH_LOADED:-}" ] && return 0
  local lib="$SHARE_LIB_SELF_DIR/job.zsh"
  [[ -f "$lib" ]] || return 1
  source "$lib"
}

# share::jobs_available — pueue reachable? The CLI degrades to a foreground run
# when it is not, so a machine without the job runner still shares files.
share::jobs_available() {
  share::_load_jobs || return 1
  job::_pueue >/dev/null 2>&1
}

# share::send_background [--watch] <send-args…> — enqueue `share send
# <send-args…>` as a job and print its id.
share::send_background() {
  share::_load_jobs || { log_error "share: the job runner is unavailable"; return 1; }
  local watch=0
  while (( $# )); do
    case "$1" in
      --watch) watch=1; shift ;;
      *) break ;;
    esac
  done
  local -a send_args=("$@")

  # Title from the file label, so the completion toast names what was sent.
  # Mirrors share::send's own flag/positional split — a real `--` ends flag
  # parsing, so a filename that happens to start with `-` after `--` is never
  # mistaken for an option here.
  local -a paths=()
  local arg skip=0 no_more_flags=0
  for arg in "${send_args[@]}"; do
    if (( skip )); then skip=0; continue; fi
    if (( no_more_flags )); then paths+=("$arg"); continue; fi
    case "$arg" in
      --to|--expiration|--downloads) skip=1 ;;
      --live) ;;
      --) no_more_flags=1 ;;
      -*) ;;
      *) paths+=("$arg") ;;
    esac
  done

  # share::label fails closed on a bad path (logs to stderr, returns 1,
  # prints nothing) — that failure must not be swallowed by the command
  # substitution below into a silently-truncated title like "share " on a
  # job that is then enqueued anyway. Refuse to enqueue instead: the same
  # bad path would fail share::send itself once the job actually ran, so
  # refusing here just moves the same clean error earlier and skips wasting
  # a job slot on a send that cannot possibly succeed.
  local title="share"
  if (( ${#paths} )); then
    local label
    label="$(share::label "${paths[@]}")" || {
      log_error "share: cannot enqueue — see error above"
      return 1
    }
    title="share $label"
  fi

  local -a modal=()
  (( watch )) && modal=(--modal)
  job::start "${modal[@]}" \
    --group "$SHARE_JOB_GROUP" --title "$title" --icon "$SHARE_JOB_ICON" \
    -- share send "${send_args[@]}"
}

# share::announce <blurb> — the acknowledgable completion toast, and the ONLY
# notification share sends.
#
# job-callback already covers failures (it sends those with --ack itself) and
# already fires a generic "<title> completed" on success. What it cannot carry
# is the LINK. So when a send finishes with nobody watching a terminal, this
# puts the blurb into notification history and raises the red bell:
#
#   --ack   the bell stays up until pick-notifications is opened, so a link
#           nobody read cannot be lost to an overwritten clipboard — which for
#           --store-downloads 1 would mean re-uploading.
#   text    the blurb ITSELF, so pick-notifications → Enter re-shows the link.
#   --meta  the pueue id, which is what makes that row's Ctrl-L open the job
#           log exactly as a native job row does.
#   --kind  classifies the row as a share.
#
# Guarded on JOB_ID: a foreground send prints the blurb to a terminal the
# human is already looking at, and needs no acknowledgment.
share::announce() {
  local blurb="$1"
  [ -n "${JOB_ID:-}" ] || return 0

  # job::start writes meta.json BEFORE `pueue add` (pueue_id: -1) and patches
  # it with the real task id AFTER. A job that announces before the patch
  # lands — or one whose enqueue itself failed — must not carry that -1
  # sentinel into notification history as if it were a real task id. Anything
  # that is not a positive integer degrades to an empty meta object: still
  # valid JSON, never malformed, never a Ctrl-L that opens a bogus log.
  local root="${JOB_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/jobs}"
  local pueue_id meta='{}'
  pueue_id="$(jq -r '.pueue_id // empty' "$root/$JOB_ID/meta.json" 2>/dev/null)"
  [[ "$pueue_id" == <1-> ]] && meta="$(jq -nc --argjson pid "$pueue_id" '{pueue_id: $pid}')"

  notify --ack --kind share --icon "$SHARE_JOB_ICON" --meta "$meta" -- "$blurb"
}
