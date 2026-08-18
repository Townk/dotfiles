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
    "live": true,
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
#
# The manifest travels through jq's ENVIRONMENT (`manifest="$manifest" jq …
# $ENV.manifest`), never `--argjson manifest "$manifest"`: a literal
# (non-`@secret:`) endpoint password is a documented, supported
# configuration, and this function runs on every single field lookup —
# `share list`, `share endpoints`, `share revoke`, every send — not just
# during a transfer. `--argjson` would have put that password on jq's own
# argv on every one of those calls, far more often than the two send-path
# sites already fixed for the same reason (share/ledger.zsh,
# share/croc.zsh). SHARE_BUILTIN_JSON carries nothing secret, so it stays a
# plain --argjson.
share::endpoints_json() {
  local manifest='{}'
  if [[ -f "$SHARE_ENDPOINTS_FILE" ]]; then
    manifest="$(yq -p toml -o json '.' "$SHARE_ENDPOINTS_FILE" 2>/dev/null)" || {
      log_error "share: cannot parse $SHARE_ENDPOINTS_FILE"
      return 1
    }
  fi
  manifest="$manifest" jq -n --argjson builtin "$SHARE_BUILTIN_JSON" \
    '$builtin * ($ENV.manifest | fromjson)'
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
  if [[ -n "$remote" ]]; then
    printf '%s\n' "$remote"
    return 0
  fi

  # A relay, when there is no store and no rclone remote: the peer dials this.
  local relay; relay="$(share::relay_address "$name")" || return 1
  if [[ -n "$relay" ]]; then
    printf '%s\n' "${relay%%:*}"
    return 0
  fi

  # No store, no remote, no relay — legitimate for a local_only endpoint, where
  # the destination is "whichever peer answers on this LAN" and croc's --local
  # forbids leaving it. The pre-send echo must still name something honest, so
  # it names the LAN rather than a host. Any OTHER endpoint with nothing to
  # send to is a misconfiguration and still fails closed.
  if [[ "$(share::field "$name" local_only false)" == true ]]; then
    printf '%s\n' "this LAN (direct peer, no relay)"
    return 0
  fi
  log_error "share: endpoint $name has no store, remote or relay to send to"
  return 1
}

# share::endpoints_for_profile — one line per endpoint THIS PROFILE may use,
# the default marked. `share endpoints` advertises itself as exactly that
# ("endpoints this profile may use"), but calling share::endpoint_names
# straight from the CLI printed every manifest key unfiltered — on a `work`
# profile with only an `onedrive` entry it listed `onedrive` AND the
# built-in `public`, even though `share --to public` is then denied by the
# policy fence. share::endpoint_names itself stays raw (it is also the
# manifest-validity seam other callers rely on); this is the profile-scoped
# view the CLI actually needs.
share::endpoints_for_profile() {
  local profile default name
  profile="$(share::profile)"
  default="$(share::default_endpoint)" || return 1
  local -a names
  names=("${(@f)$(share::endpoint_names)}") || return 1
  for name in "${names[@]}"; do
    share::allowed "$name" 2>/dev/null || continue
    if [[ "$name" == "$default" ]]; then
      printf '%s (default)\n' "$name"
    else
      printf '%s\n' "$name"
    fi
  done
}

# --- @self: the relay's own address (phase 2, R4) ---------------------------
# A relay endpoint writes `relay = "@self:9009"` rather than a hostname, and
# this resolves it at SEND time.
#
# Why a placeholder and not a literal: endpoints.toml is deliberately
# byte-identical on every machine — the `profiles` allowlist is what makes each
# host behave correctly, and the file header says so. A literal hostname would
# make the file per-machine and put a host name in writing. `@self` keeps one
# file and keeps every hostname out of every file.

# share::self_host — this machine's name, as a RECIPIENT would have to type it.
#
# The Tailscale MagicDNS FQDN first, because it resolves for every tailnet
# member unconditionally. The short name only resolves when the recipient's
# client carries this tailnet as a DNS search domain — and when it does not,
# the failure happens at the FAR END, where the sender cannot see it. A pasted
# line that does not resolve is worthless, so the robust form wins over the
# tidy one. The trailing dot MagicDNS reports is stripped: `host.tailnet.ts.net.`
# is valid DNS but reads as a typo in a chat message.
share::self_host() {
  local ts name
  ts="${SHARE_TAILSCALE_BIN:-tailscale}"
  if command -v "$ts" >/dev/null 2>&1; then
    name="$("$ts" status --json 2>/dev/null | jq -r '.Self.DNSName // ""' 2>/dev/null)"
    name="${name%.}"
    if [[ -n "$name" ]]; then printf '%s\n' "$name"; return 0; fi
  fi
  name="$(hostname -s 2>/dev/null)"
  [[ -n "$name" ]] || { log_error "share: cannot determine this machine's name for @self"; return 1; }
  printf '%s\n' "$name"
}

# share::relay_address <endpoint> — the endpoint's relay, with @self resolved.
#
# THE one resolver. share::croc_argv (what croc dials),
# share::destination_host (the host echoed before a byte leaves) and
# share::blurb (the address the recipient is told to use) all go through it, so
# those three cannot disagree — a sender dialling one relay while advertising
# another is invisible until a recipient fails to connect.
#
# An endpoint with no relay at all (a LAN endpoint, where croc's multicast IS
# the rendezvous) yields empty and status 0: absent is not an error here.
share::relay_address() {
  local name="${1:?share::relay_address: endpoint required}" relay port host
  relay="$(share::field "$name" relay)" || return 1
  [[ -n "$relay" ]] || return 0
  case "$relay" in
    @self | @self:*)
      port="${relay#@self}"; port="${port#:}"
      host="$(share::self_host)" || return 1
      if [[ -n "$port" ]]; then printf '%s:%s\n' "$host" "$port"
      else printf '%s\n' "$host"; fi
      ;;
    *) printf '%s\n' "$relay" ;;
  esac
}

# share::relay_endpoint — the endpoint this machine runs a relay FOR.
#
# Identified by its `relay` starting with `@self`, not by a name in the service
# manifest: services.toml.tmpl is in a public repo, and this needs no new config
# key either. Two matches is a hard error rather than a guess — picking one
# silently would mean the relay comes up with the wrong password, which
# presents as "the recipient cannot connect" a long way from the cause.
share::relay_endpoint() {
  local name
  local -a matches=()
  local -a names
  names=("${(@f)$(share::endpoint_names)}") || return 1
  for name in "${names[@]}"; do
    [[ -n "$name" ]] || continue
    share::allowed "$name" 2>/dev/null || continue
    [[ "$(share::field "$name" relay)" == @self* ]] && matches+=("$name")
  done
  case ${#matches} in
    1) printf '%s\n' "${matches[1]}" ;;
    0) log_error "share: no endpoint on this profile declares relay = \"@self:<port>\""
       return 1 ;;
    *) log_error "share: ${#matches} endpoints declare @self (${matches[*]}) — set SHARE_RELAY_ENDPOINT"
       return 1 ;;
  esac
}

# share::live_capable <endpoint> — can this endpoint carry a LIVE transfer?
#
# Live needs a rendezvous both ends can reach. Three ways an endpoint has one:
#
#   relay = "host:port"   an actual croc relay
#   local_only = true     multicast on this LAN, no relay at all
#   live = true           explicit: this endpoint's rendezvous is croc's own
#                         default public relay (the built-in `public` says so)
#
# Everything else is store-only, and the distinction is a safety property, not
# a nicety. `drop` is a STORE — croc-web listening on 9014, no TCP relay — so a
# live transfer "to drop" would silently fall back to croc's DEFAULT PUBLIC
# relay. On the work profile that is precisely the egress the policy fence
# exists to prevent, and it would happen with no flag, no prompt and no log
# line. Requiring an endpoint to declare its rendezvous is what makes that
# impossible rather than merely unlikely.
share::live_capable() {
  local name="${1:?share::live_capable: endpoint required}" v
  [[ "$(share::field "$name" backend croc)" == croc ]] || return 1
  v="$(share::field "$name" live)"
  [[ "$v" == true  ]] && return 0
  [[ "$v" == false ]] && return 1
  [[ -n "$(share::field "$name" relay)" ]] && return 0
  [[ "$(share::field "$name" local_only false)" == true ]] && return 0
  return 1
}

# share::clip <text> — put the pasteable line on the clipboard.
#
# Through the existing SSH-aware pbcopy, never around it: sharing a file from
# the dev-shell must land the line on the Mac clipboard the human is actually
# looking at, and that behaviour is inherited from the clipboard silo rather
# than reimplemented here. Best-effort by design — a machine with no clipboard
# still printed the line, and failing a completed transfer over a missing
# pbcopy would be absurd.
#
# No trailing newline: this text is destined for a chat message, and printf
# '%s' keeps it a single line when pasted.
share::clip() {
  local text="${1-}"
  [[ -n "$text" ]] || return 0
  command -v pbcopy >/dev/null 2>&1 || return 0
  printf '%s' "$text" | pbcopy 2>/dev/null || return 0
}

# share::emit_live_blurb <endpoint> <secret-file> <path…>
# Compose the pasteable line and hand it over — print it, copy it. Called
# BEFORE the transfer starts, which is the only moment it is useful.
share::emit_live_blurb() {
  local endpoint="$1" secret_file="$2"; shift 2
  local code label blurb
  code="$(share::croc_secret_read "$secret_file" code)" || return 1
  label="$(share::label "$@")" || return 1
  blurb="$(share::blurb "$endpoint" live "$label" "$code" never "")" || return 1
  print -r -- "$blurb"
  share::clip "$blurb"
  return 0
}

# --- send dispatch ----------------------------------------------------------
# The faces never learn which backend answered. That is the seam the whole
# design rests on: adding a backend must not touch yazi, the picker, or the CLI.

SHARE_DEFAULT_EXPIRATION="${SHARE_DEFAULT_EXPIRATION:-3d}"
SHARE_DEFAULT_DOWNLOADS="${SHARE_DEFAULT_DOWNLOADS:-1}"

# share::send [--to E] [--live] [--expiration D] [--downloads N] <path…>
share::send() {
  # Live is the DEFAULT (amendment D1). The asynchrony this silo exists for is
  # on the SENDER's side — fire it, let the job hold the transfer open, walk
  # away — and live delivers that while escaping both the 2 GiB stored ceiling
  # and leaving a copy in anyone's custody. Stored is the explicit choice for a
  # recipient who will not be around today.
  local endpoint="" mode=live secret_file="" mode_explicit=0
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
      --live)       mode=live;  mode_explicit=1; shift ;;
      --store)      mode=store; mode_explicit=1; shift ;;
      # Internal: the caller already minted the live secrets and already
      # emitted the pasteable line. Used by share::send_background so the
      # human gets the phrase the instant the command returns, rather than
      # whenever the job happens to start.
      --secret-file)
                    [[ $# -ge 2 ]] || die "share: --secret-file requires a path"
                    secret_file="$2"; shift 2 ;;
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

  # "Prioritise live, but never silently" — the endpoint has the final say,
  # because an endpoint that cannot carry a live transfer would otherwise fall
  # back to croc's DEFAULT PUBLIC relay without saying so. Downgrading loudly
  # here is the difference between a considered choice and an accidental one.
  # To get live by default, mark a live-capable endpoint `default_for`.
  if [[ "$mode" == live ]] && ! share::live_capable "$endpoint"; then
    local why="no relay, and not LAN-only"
    [[ "$backend" != croc ]] && why="the $backend backend has no live mode"
    # An EXPLICIT --live is a statement about how this file must travel, so
    # quietly doing the opposite would be worse than refusing. Only the
    # default — live because live is the default, not because anyone said so
    # — downgrades, and even then it says so.
    if (( mode_explicit )); then
      log_error "share: $endpoint cannot carry a live transfer — $why"
      return 1
    fi
    log_warn "share: $endpoint cannot carry a live transfer ($why) — sending stored instead"
    mode=store
  fi

  # Live's value exists BEFORE the transfer; stored's URL only exists after the
  # upload. So live hands the human its pasteable line first and only then
  # starts waiting for a peer (D1/D3/D5).
  #
  # "Whoever mints the secret file owns the blurb": with --secret-file given,
  # some other process — share::send_background, standing in front of the
  # human — already emitted it, and emitting it again from inside a job would
  # only duplicate it into a log nobody reads.
  if [[ "$mode" == live && "$backend" == croc && -z "$secret_file" ]]; then
    secret_file="$(share::croc_secret_file "$endpoint")" || return 1
    share::emit_live_blurb "$endpoint" "$secret_file" "$@" || return 1
  fi

  local blurb rc=0
  case "$backend" in
    croc)
      local -a sf=()
      [[ -n "$secret_file" ]] && sf=(--secret-file "$secret_file")
      blurb="$(share::croc_send "${sf[@]}" "$endpoint" "$mode" "$expiration" "$downloads" "$@")" || rc=1
      # The secrets have served their purpose the moment croc stops retrying,
      # whether it succeeded or gave up. Removed here rather than inside
      # croc_send because the retry loop re-reads nothing but this process
      # still owns the file's lifetime.
      [[ -n "$secret_file" ]] && rm -f -- "$secret_file"
      (( rc == 0 )) || return 1
      ;;
    rclone)
      [[ "$mode" == live ]] && die "share: the rclone backend has no live mode"
      blurb="$(share::rclone_send "$endpoint" "$@")" || return 1
      ;;
    *) die "share: unknown backend: $backend" ;;
  esac

  if [[ "$mode" == live ]]; then
    # D6's split, as built. The VALUE was announced early — printed and copied,
    # with the human right there — so no toast was needed for it. COMPLETION is
    # the news worth a toast here: a live transfer finishes only when the
    # recipient actually collects, so this is the moment the file left.
    share::announce "$(share::label "$@") — collected" || true
    return 0
  fi
  # Stored: croc_send returns the blurb because the URL did not exist until now.
  [[ -n "$blurb" ]] || return 0
  print -r -- "$blurb"
  share::clip "$blurb"
  # share::announce is best-effort by contract (it wraps `notify`, which is
  # documented as best-effort itself): a failed RECOB bridge hop, or simply
  # no Hammerspoon on this host, must not turn a SUCCESSFUL transfer into a
  # reported failure. Left unguarded, share::announce's own exit status —
  # being the last command in this function — became share::send's, so
  # pueue recorded Failed and job-callback fired its --ack failure toast for
  # a share that actually worked. The upload already happened and the
  # ledger row already exists; only the toast is what's missing.
  share::announce "$blurb" || true
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
    # A live (peer-to-peer) croc transfer has no store-side id — it dies the
    # moment croc exits, or once the recipient completes it — so there is
    # nothing left to revoke. `ref` is empty by construction for these rows
    # (share/croc.zsh); refuse with a clear message instead of ever calling
    # `croc --revoke ''`, and leave the receipt in the ledger so `share list`
    # keeps rendering it honestly.
    croc-live)
      log_error "share: $id was a live transfer — it already ended when croc exited; nothing to revoke"
      return 1
      ;;
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

# share::parse_live <text> → "phrase\trelay"   (relay may be empty)
#
# Pulls a live share out of ARBITRARY text: the line share::blurb produced,
# pasted into a chat message, surrounded by whatever the sender and the chat
# client added around it. That is why this SCANS, unlike the stored branch of
# share::classify which matches a bare value end to end.
#
# The regex anchors on the whole `croc [--relay X] <phrase>` shape and the
# phrase is then taken as the LAST word of the match. That is what stops this
# repeating the bug phase 1 shipped: `grep -oE 'croc [a-z0-9-]{6,}'` put `-`
# inside the character class, so it happily matched "croc --relay" and returned
# "--relay" AS the code phrase. Here a phrase must be hyphen-joined groups of
# unreserved characters, so no flag can ever satisfy it.
share::parse_live() {
  local text="${1-}" m phrase relay=""
  m="$(printf '%s' "$text" \
    | grep -oE 'croc([[:space:]]+--relay[[:space:]]+[^[:space:]]+)?[[:space:]]+[a-z0-9]+(-[a-z0-9]+)+' \
    | head -1)"
  [[ -n "$m" ]] || return 1
  local -a w=(${=m})
  phrase="${w[-1]}"
  [[ "${w[2]:-}" == --relay ]] && relay="${w[3]:-}"
  printf '%s\t%s\n' "$phrase" "$relay"
}

share::classify() {
  # `##` and `(#i)` are extendedglob constructs and the option is off by
  # default. Scope it to this function rather than setting it at file level —
  # a file-scope setopt in a sourced lib leaks into every caller.
  setopt localoptions extendedglob
  local value="${1-}"
  if [[ "$value" == croc-store-v1.* ]] \
    || [[ "$value" == (#i)http(s|)://*/s/*\#v1.* ]]; then
    printf 'stored\n'
  # `live` is checked BEFORE the bare-phrase branch and AFTER the stored ones:
  # it scans embedded text, so it must not get first refusal on a value that is
  # a whole stored token, and a bare phrase must still classify as `code`.
  elif share::parse_live "$value" >/dev/null 2>&1; then
    printf 'live\n'
  elif [[ "$value" == [a-z0-9]##(-[a-z0-9]##)## ]]; then
    printf 'code\n'
  else
    printf 'unknown\n'
  fi
}

# share::relay_pass_for <relay-address> — the relay password for an address
# THIS machine already knows about, or empty.
#
# Found by live test, and it is a genuine asymmetry rather than an oversight
# waiting to happen: the SEND path takes `pass` from the endpoint it is sending
# through, while the receive path had nothing to take it from — it starts with
# a pasted line, not an endpoint. Against a password-protected relay that gave
# `bad response: bad password` at the receiver while the sender sat happily
# connected.
#
# Matching on the RESOLVED address (not the endpoint name) is what makes this
# work: the recipient pastes an address, and only an address can be compared.
# When it matches one of our own endpoints, the receive is from our own relay
# and the password is ours to supply. An address we do not recognise gets
# nothing, and croc falls back to its own default.
#
# NOTE THE LIMIT, because it shapes how a relay should be configured: a THIRD
# PARTY has no such manifest. A relay that sets `pass` can therefore only ever
# serve machines that share this config — see endpoints.toml.example.
share::relay_pass_for() {
  local addr="${1-}" name
  [[ -n "$addr" ]] || return 0
  local -a names
  names=("${(@f)$(share::endpoint_names 2>/dev/null)}") || return 0
  for name in "${names[@]}"; do
    [[ -n "$name" ]] || continue
    [[ "$(share::relay_address "$name" 2>/dev/null)" == "$addr" ]] || continue
    share::croc_pass "$name"
    return 0
  done
  return 0
}

# share::_croc_receive <code> <relay> <out> — the one place a receive runs.
#
# The phrase goes through CROC_SECRET rather than croc's argv. The spec permits
# a code phrase on a command line (it is single-use and worthless once the
# transfer completes, unlike a stored link's long-lived key), but "permitted"
# is not a reason to do it when the environment costs nothing here.
#
# --relay is passed only when the sender named one. Getting this wrong is
# silent rather than loud: without it croc dials its DEFAULT relay, waits for a
# peer that is somewhere else entirely, and simply never connects.
share::_croc_receive() {
  local code="${1:?share::_croc_receive: code required}" relay="${2-}" out="${3-.}"
  local -a cmd=(croc --ignore-stdin --disable-clipboard)
  [[ -n "$relay" ]] && cmd+=(--relay "$relay")
  cmd+=(--yes --out "$out")

  # Both secrets ride the environment, never argv, and each is set only when it
  # has a value — a present-but-empty CROC_PASS overrides croc's own default
  # passphrase with "", which breaks the handshake against every relay that
  # relies on that default.
  local pass; pass="$(share::relay_pass_for "$relay")"
  local -a envp=("CROC_SECRET=$code")
  [[ -n "$pass" ]] && envp+=("CROC_PASS=$pass")
  env "${envp[@]}" "${cmd[@]}"
}

# share::get_background <code> <relay> <out> — receive under job::.
#
# The phrase reaches the job through the same mode-0600 file the send half
# uses, never through pueue: job::start now strips CROC_SECRET (and every other
# credential-shaped name) from the environment it snapshots, so the file is not
# merely the tidier route — it is the only one that still works.
share::get_background() {
  local code="$1" relay="${2-}" out="${3-}"
  share::_load_jobs || { log_error "share: the job runner is unavailable"; return 1; }
  local sf
  sf="$(share::croc_secret_write "$code" "" "$relay")" || return 1
  local id
  # The title deliberately does NOT contain the phrase: it is copied into
  # meta.json and into notification history, and the recipient does not know
  # the filename until croc announces it anyway.
  id="$(job::start --group "$SHARE_JOB_GROUP" --title "share receive" \
        --icon "$SHARE_JOB_ICON" \
        -- share get --foreground --secret-file "$sf" --out "$out")" || {
    rm -f -- "$sf"
    return 1
  }
  log_ok "receiving in the background as job $id"
}

# share::get [--out DIR] [--allow-argv] [--background|--foreground]
#            [--secret-file F] [<value>|-]
share::get() {
  setopt localoptions extendedglob     # the trim below uses `##`
  local out="$SHARE_DEFAULT_OUT" allow_argv=0 value="" from_argv=0 source_requested=0
  local secret_file=""
  local -i background=-1               # -1 = caller expressed no preference
  while (( $# )); do
    case "$1" in
      --out)         [[ $# -ge 2 ]] || die "share get: --out requires a directory"
                     out="$2"; shift 2 ;;
      --allow-argv)  allow_argv=1; shift ;;
      --background)  background=1; shift ;;
      --foreground)  background=0; shift ;;
      --secret-file) [[ $# -ge 2 ]] || die "share get: --secret-file requires a path"
                     secret_file="$2"; shift 2 ;;
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

  # A secret file short-circuits acquisition entirely: this is the job half of
  # a backgrounded receive, and the phrase deliberately never passed through
  # pueue's environment or anyone's argv to get here. Unlinked on read — unlike
  # the send half, a receive has nothing to retry with.
  if [[ -n "$secret_file" ]]; then
    local jcode jrelay
    jcode="$(share::croc_secret_read "$secret_file" code)" || return 1
    jrelay="$(share::croc_secret_read "$secret_file" relay)" || return 1
    rm -f -- "$secret_file"
    [[ -n "$jcode" ]] || { log_error "share get: the secret file carried no phrase"; return 1; }
    mkdir -p -- "$out"
    share::_croc_receive "$jcode" "$jrelay" "$out"
    return $?
  fi

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
    live | code)
      local code relay="" parsed
      if [[ "$kind" == live ]]; then
        parsed="$(share::parse_live "$value")" || {
          log_error "share get: could not read the code phrase from that text"
          return 1
        }
        code="${parsed%%$'\t'*}"
        relay="${parsed##*$'\t'}"
      else
        code="$value"
      fi
      # Background by default (amendment D1): a live receive blocks until the
      # sender is reachable, which can be minutes, and the human has better
      # things to do than hold a terminal open. --foreground opts out, and the
      # job half runs with it so this can never recurse.
      if (( background != 0 )) && share::jobs_available; then
        share::get_background "$code" "$relay" "$out"
        return $?
      fi
      mkdir -p -- "$out"
      share::_croc_receive "$code" "$relay" "$out"
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
#
# job::_pueue only resolves the BINARY (command -v, else a hardcoded
# fallback, then -x) — it never contacts the daemon. Stopping at that check
# let `--background` pass the guard with pueue installed but pueued down,
# so `job::start` ran `pueue add`, that failed, and the whole send died
# instead of degrading to foreground — the opposite of the documented
# behaviour above. Probing `pueue status` here is what actually answers "is
# the daemon reachable", and — unlike job::_pueue's own resolution, which
# JOB_PUEUE_BIN short-circuits unconditionally with no executability check —
# gives this predicate a real negative test seam: a fake pueue whose `status`
# exits non-zero.
share::jobs_available() {
  share::_load_jobs || return 1
  local p; p="$(job::_pueue)" || return 1
  "$p" status >/dev/null 2>&1
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
  # Index-walked rather than shift-based, and it now captures --to's VALUE and
  # the mode as well as the paths: the live path below has to know WHERE it is
  # sending before the job exists, because that is what decides whether a
  # rendezvous is even available.
  local -a paths=()
  local -i i=1 n=${#send_args[@]} no_more_flags=0
  local a to="" mode=live
  local -i mode_explicit=0
  while (( i <= n )); do
    a="${send_args[i]}"
    if (( no_more_flags )); then paths+=("$a"); (( i += 1 )); continue; fi
    case "$a" in
      --to)                                   to="${send_args[i+1]:-}"; (( i += 2 )) ;;
      --expiration|--downloads|--secret-file) (( i += 2 )) ;;
      --live)                       mode=live;  mode_explicit=1; (( i += 1 )) ;;
      --store)                      mode=store; mode_explicit=1; (( i += 1 )) ;;
      --)                                     no_more_flags=1; (( i += 1 )) ;;
      -*)                                     (( i += 1 )) ;;
      *)                                      paths+=("$a"); (( i += 1 )) ;;
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

  # THE POINT OF THE WHOLE FEATURE (amendment D1/D5): for a live send the
  # secrets are minted and the pasteable line is handed over HERE, in the
  # foreground, before the job is even enqueued. The human can paste into a
  # chat the instant the command returns; the transfer then waits in the
  # background for however long it takes.
  #
  # Doing it the other way round — letting the job mint the phrase — would
  # mean the line appears whenever pueue happens to start the task, which is
  # exactly the "too late to be useful" failure the old live template had.
  local -a extra=()
  if [[ "$mode" == live ]] && (( ${#paths} )); then
    local ep
    ep="$(share::resolve "$to")" || return 1
    if share::live_capable "$ep"; then
      local sf
      sf="$(share::croc_secret_file "$ep")" || return 1
      # >&2 deliberately. share::send_background's STDOUT is the job id — the
      # CLI captures it as `id="$(share::send_background …)"` — so printing the
      # blurb there would swallow the pasteable line into the id variable and
      # show the human neither. The line is user-facing output, which in this
      # codebase means stderr, and it reaches the clipboard regardless.
      share::emit_live_blurb "$ep" "$sf" "${paths[@]}" >&2 || { rm -f -- "$sf"; return 1; }
      extra=(--secret-file "$sf")
    elif (( mode_explicit )); then
      # Refuse before enqueuing: share::send would refuse too, but only once
      # the job ran, turning an immediate error into a failure toast minutes
      # later.
      log_error "share: $ep cannot carry a live transfer — no relay, and not LAN-only"
      return 1
    else
      # Warn HERE, not from inside the job, where the message would land in a
      # log nobody is reading.
      log_warn "share: $ep cannot carry a live transfer (no relay, not LAN-only) — sending stored instead"
    fi
  fi

  local -a modal=()
  (( watch )) && modal=(--modal)
  job::start "${modal[@]}" \
    --group "$SHARE_JOB_GROUP" --title "$title" --icon "$SHARE_JOB_ICON" \
    -- share send "${extra[@]}" "${send_args[@]}"
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
