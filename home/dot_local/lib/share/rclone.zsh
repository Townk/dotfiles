#!/usr/bin/env zsh
# share/rclone.zsh — the rclone backend, for sanctioned custodial storage
# (OneDrive at work). SOURCED by share.zsh, never executed.
#
# Not end-to-end encrypted, and that is deliberate: for company files reaching
# coworkers through the company's own system, the custodian is the party that
# already owns the data. The policy fence keeps this endpoint on the work
# profile and croc's zero-knowledge store on the personal one.
#
# The rclone remote itself is configured with `rclone config` and lives in
# rclone's own store — share never duplicates that credential.

# share::rclone_remote_path <endpoint> <src> — a stamped destination, so two
# sends of the same filename never collide (and one revoke cannot delete the
# other's object).
share::rclone_remote_path() {
  zmodload zsh/datetime 2>/dev/null
  local endpoint="$1" src="$2" remote
  remote="$(share::field "$endpoint" remote)" || return 1
  printf '%s/%s/%s\n' "${remote%/}" "${EPOCHREALTIME/./}-$$" "${src:t}"
}

# The one-line stats stream is what makes the tmux statusbar percent real on the
# work path. Verified shape (rclone v1.75.0, on STDERR):
#   NOTICE:        40 MiB / 40 MiB, 100%, 0 B/s, ETA -
# Flag order verified against the installed rclone (v1.75.0): `copyto <flags>
# <src> <dest>` parses fine with the stats flags ahead of the positional
# args, and the stats line does land on stderr — both confirmed against a
# real local-disk copy (no network, no configured remote involved).
share::rclone_copy_argv() {
  printf '%s\n' rclone copyto \
    --stats "${SHARE_RCLONE_STATS_INTERVAL:-1s}" \
    --stats-one-line \
    --stats-log-level NOTICE \
    "$2" "$3"
}

# share::rclone_pct <line> — the percent in a stats line, or nothing. Returning
# empty for an unparseable line is the point: a garbage pct would poison the
# statusbar mean, which is computed across every running job. Only one `%`
# ever appears in the verified stats shape (the transfer-progress field), so
# the first match is also the only match — no ambiguity to resolve between
# several percentages on one line.
share::rclone_pct() {
  local pct
  pct="$(printf '%s\n' "$1" | grep -oE '[0-9]+%' | head -1)"
  printf '%s\n' "${pct%\%}"
}

share::rclone_link_argv() {
  local endpoint="$1" dest="$2" scope type
  scope="$(share::field "$endpoint" link_scope organization)" || return 1
  type="$(share::field "$endpoint" link_type view)"
  printf '%s\n' rclone link \
    --onedrive-link-scope "$scope" \
    --onedrive-link-type "$type" \
    "$dest"
}

share::rclone_revoke() {
  rclone deletefile "$1"
}

# share::rclone_send <endpoint> <path…>
share::rclone_send() {
  local endpoint="$1"; shift
  local label; label="$(share::label "$@")" || return 1

  # One share = one remote directory, so a multi-file send stays revocable as a
  # unit and the link points at something coherent.
  local dest_dir src dest url
  dest_dir="$(share::rclone_remote_path "$endpoint" "$1")" || return 1
  dest_dir="${dest_dir:h}"

  # NEVER name a command array `argv`: in zsh `argv` IS the positional-parameter
  # array, so `local -a argv=(...)` silently replaces "$@". Verified:
  #   f() { local -a argv=(croc); argv+=("$@"); print "$@" }; f /p/Report.pdf
  #   → "croc croc"   (the path is gone)
  # Use `cmd`. And capture the path count/first path BEFORE any loop, so the
  # single-vs-multi decision below cannot read a clobbered $#.
  local -i path_count=$#
  local first_path="$1"
  local -a cmd
  local line pct
  for src in "$@"; do
    dest="$dest_dir/${src:t}"
    cmd=("${(@f)$(share::rclone_copy_argv "$endpoint" "$src" "$dest")}")
    # Stats ride stderr; fold them in and report each percent we can parse.
    # share::_progress is a no-op outside a job, so this same code path serves
    # a foreground run untouched. This pipeline runs directly in THIS shell
    # (never through `$(...)`), which is what makes `$pipestatus[1]` below
    # rclone's real exit status rather than the `while read`'s — verified
    # against both a real rclone (local-disk copy, no network) and a fake
    # rclone that prints output then exits non-zero (see
    # tests/share_rclone_spec.sh).
    "${cmd[@]}" 2>&1 | while IFS= read -r line; do
      pct="$(share::rclone_pct "$line")"
      [[ -n "$pct" ]] && share::_progress "$pct" "uploading ${src:t}"
      print -r -- "$line" >&2
    done
    (( ${pipestatus[1]} == 0 )) \
      || { log_error "share: rclone copy failed for ${src:t}"; return 1; }
    # A small file can finish inside rclone's first --stats interval and
    # print no stats line at all — nothing above ever reports a percent for
    # it. Report completion explicitly so a job never sits stuck at 0%.
    share::_progress 100 "uploaded ${src:t}"
  done

  # Link the directory for a multi-file share, the file itself for a single one.
  # Uses the pre-loop capture, not $#/$1.
  local target="$dest_dir"
  (( path_count == 1 )) && target="$dest_dir/${first_path:t}"
  cmd=("${(@f)$(share::rclone_link_argv "$endpoint" "$target")}")
  url="$("${cmd[@]}" 2>&1)" || {
    log_error "share: rclone could not create a link for $target"
    log_error "share: SharePoint/OneDrive for Business returns 'Invalid request' when"
    log_error "share: administrators have not enabled link permissions for this tenant"
    return 1
  }

  local id; id="$(share::gen_id)"
  share::ledger_add "$id" rclone "$endpoint" "$label" "$target" "$url" 0
  share::blurb "$endpoint" web "$label" "$url" 'never' 'unlimited downloads'
}
