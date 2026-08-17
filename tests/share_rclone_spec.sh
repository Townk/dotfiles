# The rclone/OneDrive backend. Custodial rather than end-to-end — which is
# CORRECT for company files reaching coworkers through the company's own
# sanctioned system, and is why the policy fence keeps it on the work profile.
#
# Revoke deletes the object rather than stripping one Graph permission: simple,
# effective, and it needs no OAuth client of our own.

Describe 'share:: rclone backend'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-rclone"
    rm -rf "$SB"; mkdir -p "$SB/bin"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_STATE_DIR="$SB/state"
    SHARE_PROFILE=work
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[onedrive]
backend = "rclone"
remote = "onedrive:Shared/drop"
link_scope = "organization"
link_type = "view"
web = true
profiles = ["work"]
TOML
    printf 'x' >"$SB/Report.pdf"
    printf 'y' >"$SB/Notes.txt"
  }
  BeforeEach 'setup'

  It 'stamps the remote path so two sends of one name do not collide'
    a="$(share::rclone_remote_path onedrive "$SB/Report.pdf")"
    b="$(share::rclone_remote_path onedrive "$SB/Report.pdf")"
    When call test "$a" != "$b"
    The status should be success
  End

  It 'keeps the basename in the remote path'
    When call share::rclone_remote_path onedrive "$SB/Report.pdf"
    The output should include 'onedrive:Shared/drop/'
    The output should include 'Report.pdf'
  End

  It 'builds a copyto argv'
    When call share::rclone_copy_argv onedrive "$SB/Report.pdf" 'onedrive:Shared/drop/x/Report.pdf'
    The output should include 'copyto'
    The output should include 'onedrive:Shared/drop/x/Report.pdf'
  End

  It 'builds a link argv carrying the configured scope and type'
    When call share::rclone_link_argv onedrive 'onedrive:Shared/drop/x/Report.pdf'
    The output should include 'link'
    The output should include '--onedrive-link-scope'
    The output should include 'organization'
    The output should include '--onedrive-link-type'
    The output should include 'view'
  End

  It 'sends: copies, links, records a receipt and prints one line'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = link ]; then printf 'https://corp.example.com/:b:/g/abc\n'; exit 0; fi
done
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    When call share::rclone_send onedrive "$SB/Report.pdf"
    The output should include 'https://corp.example.com/:b:/g/abc'
    The lines of output should equal 1
  End

  It 'surfaces the admin-disabled link failure with an actionable message'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = link ]; then printf 'Invalid request\n' >&2; exit 1; fi
done
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    When run share::rclone_send onedrive "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'link permissions'
  End

  # Hazard from the brief: this library sets no pipefail, and a pipeline's
  # `$pipestatus` does not survive a `$(...)` boundary. share::rclone_send
  # runs the copy pipeline directly (not through command substitution) so
  # `${pipestatus[1]}` is checked in THIS shell right after it — this example
  # pins down that the status it reads is rclone's, not the `while read` on
  # the right-hand side of the pipe (which always exits 0). A fake rclone
  # that prints stats-shaped output and THEN exits non-zero is the case that
  # would fool a check reading the wrong side of the pipe.
  It 'fails when rclone copy exits non-zero, even after it printed output'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = copyto ]; then
    echo "2026/08/17 05:46:12 NOTICE:  20 MiB / 40 MiB, 50%, 1.2 MiB/s, ETA 16s" >&2
    exit 9
  fi
done
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    When run share::rclone_send onedrive "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'rclone copy failed'
  End

  # A multi-file send shares one remote directory, and the link target for
  # that case must be the DIRECTORY, not any one file inside it — otherwise
  # the recipient's link would only ever reach the last file copied.
  It 'links the shared directory (not a file inside it) for a multi-file send'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_RCLONE_CALLS"
for a in "$@"; do
  if [ "$a" = link ]; then printf 'https://corp.example.com/:f:/g/dir\n'; exit 0; fi
done
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    SHARE_RCLONE_CALLS="$SB/calls"; export SHARE_RCLONE_CALLS
    share::rclone_send onedrive "$SB/Report.pdf" "$SB/Notes.txt" >/dev/null
    link_call="$(grep '^link ' "$SB/calls")"
    no_basename_leaked() {
      case "$link_call" in
        *Report.pdf*|*Notes.txt*) return 1 ;;
        *) return 0 ;;
      esac
    }
    When call no_basename_leaked
    The status should be success
  End

  # --- progress: weighted across copy units + one link unit ----------------
  # Finding: reporting each file's OWN percent is non-monotonic on a
  # multi-file send. job::progress is a single clobbering write (the
  # statusbar shows only the latest value for a job), so file 1 finishing at
  # its own 100% would read as the whole send being done, then regress to
  # ~10% the instant file 2 starts copying. share::rclone_send instead
  # reports completed_units/total_units (total_units = path_count + 1, the
  # extra unit being the link step), which is non-decreasing by
  # construction and never claims 100 until the link actually succeeds.
  #
  # The seam: share::_progress is a no-op unless JOB_ID is set AND
  # job::progress is a defined function (job.zsh is never sourced here) — so
  # each example below defines its own job::progress stub that appends the
  # reported percent to a file, and sets JOB_ID to turn share::_progress on.

  It 'reports monotonic weighted progress across a multi-file send, never reaching 100 before the link step'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = link ]; then printf 'https://corp.example.com/:f:/g/dir\n'; exit 0; fi
done
echo "2026/08/17 05:46:12 NOTICE:  5 MiB / 10 MiB, 50%, 1 MiB/s, ETA 1s" >&2
echo "2026/08/17 05:46:13 NOTICE: 10 MiB / 10 MiB, 100%, 0 B/s, ETA -" >&2
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    JOB_ID=test-job
    job::progress() { printf '%s\n' "$1" >>"$SB/progress"; }
    share::rclone_send onedrive "$SB/Report.pdf" "$SB/Notes.txt" >/dev/null 2>/dev/null
    check() {
      local -a vals
      vals=("${(@f)$(<"$SB/progress")}")
      local -i n=${#vals[@]} k prev=-1
      (( n >= 2 )) || return 1
      for (( k = 1; k <= n; k++ )); do
        (( vals[k] >= prev )) || return 1
        prev=${vals[k]}
      done
      (( vals[n] == 100 )) || return 1
      for (( k = 1; k < n; k++ )); do
        (( vals[k] < 100 )) || return 1
      done
      return 0
    }
    When call check
    The status should be success
  End

  It 'reports 100 only after the link succeeds for a single-file send'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = link ]; then printf 'https://corp.example.com/:b:/g/abc\n'; exit 0; fi
done
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    JOB_ID=test-job
    job::progress() { printf '%s\n' "$1" >>"$SB/progress"; }
    share::rclone_send onedrive "$SB/Report.pdf" >/dev/null
    check() {
      local -a vals
      vals=("${(@f)$(<"$SB/progress")}")
      local -i n=${#vals[@]} k
      (( n >= 2 )) || return 1
      (( vals[n] == 100 )) || return 1
      for (( k = 1; k < n; k++ )); do
        (( vals[k] < 100 )) || return 1
      done
      return 0
    }
    When call check
    The status should be success
  End

  It 'leaves the last progress value below 100 when the link fails'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = link ]; then printf 'Invalid request\n' >&2; exit 1; fi
done
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    JOB_ID=test-job
    job::progress() { printf '%s\n' "$1" >>"$SB/progress"; }
    share::rclone_send onedrive "$SB/Report.pdf" >/dev/null 2>&1 || :
    check() {
      local -a vals
      vals=("${(@f)$(<"$SB/progress")}")
      local -i n=${#vals[@]}
      (( n >= 1 )) || return 1
      (( vals[n] < 100 )) || return 1
      return 0
    }
    When call check
    The status should be success
  End

  # The original defect this whole scheme fixed: a fast transfer that
  # completes inside rclone's first --stats interval prints no interim
  # NOTICE line at all (this fake rclone, same as the "sends" example above,
  # never emits one). It must still end at 100, not sit stuck at 0. For a
  # single file, total_units is 2: the copy's own unit finishes at exactly
  # 50 (1*100/2), then the link brings it to 100 — matching the resolution
  # worked example exactly.
  It 'still reaches 100 for a fast transfer that prints no interim stats line'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = link ]; then printf 'https://corp.example.com/:b:/g/abc\n'; exit 0; fi
done
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    JOB_ID=test-job
    job::progress() { printf '%s\n' "$1" >>"$SB/progress"; }
    share::rclone_send onedrive "$SB/Report.pdf" >/dev/null
    check() {
      local -a vals
      vals=("${(@f)$(<"$SB/progress")}")
      (( ${#vals[@]} == 2 )) || return 1
      (( vals[1] == 50 )) || return 1
      (( vals[2] == 100 )) || return 1
      return 0
    }
    When call check
    The status should be success
  End

  It 'extracts a percent from an rclone one-line stats NOTICE'
    When call share::rclone_pct '2026/08/17 05:46:12 NOTICE:  20 MiB / 40 MiB, 50%, 1.2 MiB/s, ETA 16s'
    The output should equal '50'
  End

  It 'ignores a stats line with no percent in it'
    When call share::rclone_pct '2026/08/17 05:46:12 NOTICE: Config file not found - using defaults'
    The output should equal ''
  End

  It 'passes the one-line stats flags to copyto so progress is parseable'
    When call share::rclone_copy_argv onedrive "$SB/Report.pdf" 'onedrive:X/Report.pdf'
    The output should include '--stats'
    The output should include '--stats-one-line'
    The output should include '--stats-log-level'
    The output should include 'NOTICE'
  End

  # F3 fix: `rclone deletefile` refuses a DIRECTORY outright (verified against
  # rclone v1.75.0: "is a directory or doesn't exist", rc=4), and the ledger
  # `ref` for an rclone share is always the stamped directory (see below) —
  # even for a single-file send. `deletefile` on that ref made `share revoke`
  # on a multi-file rclone share a silent no-op: the link stayed live and the
  # objects stayed in OneDrive. `purge` removes the directory regardless.
  It 'revokes by purging the shared directory'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_RCLONE_CALLS"
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    SHARE_RCLONE_CALLS="$SB/calls"; export SHARE_RCLONE_CALLS
    share::rclone_revoke 'onedrive:Shared/drop/x'
    When call cat "$SB/calls"
    The output should include 'purge onedrive:Shared/drop/x'
  End

  # Two examples below drive share::rclone_send end to end (real ledger, real
  # revoke dispatch) and assert the RECORDED ref — and therefore what
  # share::revoke eventually purges — is the stamped directory, never a path
  # that includes any file's basename. This is the regression the bug
  # report named directly: a multi-file send's ledger `ref` used to be the
  # directory already, but a SINGLE-file send recorded `$target`
  # (dest_dir/basename) instead, which is exactly what made `rclone
  # deletefile` (now `purge`) fail on that case specifically once a
  # directory-only revoke command was in play.
  It 'records the shared directory, not a file inside it, as the ledger ref for a single-file send'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_RCLONE_CALLS"
for a in "$@"; do
  if [ "$a" = link ]; then printf 'https://corp.example.com/:b:/g/abc\n'; exit 0; fi
done
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    SHARE_RCLONE_CALLS="$SB/calls"; export SHARE_RCLONE_CALLS
    do_it() {
      share::rclone_send onedrive "$SB/Report.pdf" >/dev/null
      local ref; ref="$(share::ledger_list | jq -r '.[0].ref')"
      case "$ref" in
        *Report.pdf*) return 1 ;;
        *) : ;;
      esac
      local id; id="$(share::ledger_list | jq -r '.[0].id')"
      share::revoke "$id"
      grep -qxF "purge $ref" "$SHARE_RCLONE_CALLS"
    }
    When call do_it
    The status should be success
  End

  It 'records the shared directory as the ledger ref for a multi-file send, and revoke purges it'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_RCLONE_CALLS"
for a in "$@"; do
  if [ "$a" = link ]; then printf 'https://corp.example.com/:f:/g/dir\n'; exit 0; fi
done
exit 0
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    SHARE_RCLONE_CALLS="$SB/calls"; export SHARE_RCLONE_CALLS
    do_it() {
      share::rclone_send onedrive "$SB/Report.pdf" "$SB/Notes.txt" >/dev/null
      local ref; ref="$(share::ledger_list | jq -r '.[0].ref')"
      case "$ref" in
        *Report.pdf* | *Notes.txt*) return 1 ;;
        *) : ;;
      esac
      local id; id="$(share::ledger_list | jq -r '.[0].id')"
      share::revoke "$id"
      grep -qxF "purge $ref" "$SHARE_RCLONE_CALLS"
    }
    When call do_it
    The status should be success
  End
End
