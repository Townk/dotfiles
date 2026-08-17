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

# share::rclone_revoke <dir> — the ledger `ref` is the stamped directory
# (share::rclone_remote_path's parent), never a single file inside it, even
# for a single-file send: `rclone deletefile` refuses a directory outright
# (verified against rclone v1.75.0: "is a directory or doesn't exist", rc=4),
# which made `share revoke` on a multi-file rclone share a silent no-op — the
# link stayed live and the objects stayed in OneDrive. `purge` removes the
# whole stamped directory regardless of how many files it holds, and since
# the stamp (EPOCHREALTIME-$$) is unique per send, purging it can never touch
# another share's objects.
share::rclone_revoke() {
  rclone purge "$1"
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

  # Progress is weighted across path_count copy units plus one link unit, and
  # reported as completed_units/total_units — NOT as the current file's own
  # percent. A bare per-file percent would be non-monotonic on a multi-file
  # send: job::progress is a single clobbering write (the statusbar shows
  # only the latest value for a job), so file 1 finishing at its own 100%
  # would read as the WHOLE send being done, then regress to ~10% the moment
  # file 2 starts copying. Weighting by unit keeps the sequence
  # non-decreasing by construction, and — since a file's "finished" value is
  # (i * 100 / total_units), always < 100 while units remain — it still
  # fixes the original problem this replaced: a transfer that completes
  # inside rclone's first --stats interval printed no interim line at all,
  # so under the old bare-percent scheme the job was left stuck at 0%. Here
  # it reports its unit's share explicitly right after the copy, regardless
  # of whether any interim stats line ever arrived.
  local -i total_units=$(( path_count + 1 )) i=0 unit_pct
  for src in "$@"; do
    (( i += 1 ))
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
      if [[ -n "$pct" ]]; then
        unit_pct=$(( ((i - 1) * 100 + pct) / total_units ))
        share::_progress "$unit_pct" "uploading $i/$path_count: ${src:t}"
      fi
      print -r -- "$line" >&2
    done
    (( ${pipestatus[1]} == 0 )) \
      || { log_error "share: rclone copy failed for ${src:t}"; return 1; }
    # This file's unit is done regardless of whether an interim stats line
    # ever arrived — the fix for the 0%-stuck fast-transfer case, without
    # reintroducing the false-100%-then-regress bug a bare per-file percent
    # had.
    unit_pct=$(( (i * 100) / total_units ))
    share::_progress "$unit_pct" "uploaded $i/$path_count: ${src:t}"
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
  # The link is the final unit: only here does progress ever reach 100.
  share::_progress 100 "link created"

  # The ledger `ref` is the stamped DIRECTORY, not `$target` — `$target` is a
  # single file for a one-path send, and share::rclone_revoke's `rclone purge`
  # needs the directory in every case (see the comment there). Recording the
  # directory here is what makes revoke work uniformly for single- and
  # multi-file sends alike.
  local id; id="$(share::gen_id)"
  share::ledger_add "$id" rclone "$endpoint" "$label" "$dest_dir" "$url" 0
  share::blurb "$endpoint" web "$label" "$url" 'never' 'unlimited downloads'
}
