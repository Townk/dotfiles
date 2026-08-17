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

  It 'revokes by deleting the object'
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_RCLONE_CALLS"
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    SHARE_RCLONE_CALLS="$SB/calls"; export SHARE_RCLONE_CALLS
    share::rclone_revoke 'onedrive:Shared/drop/x/Report.pdf'
    When call cat "$SB/calls"
    The output should include 'deletefile onedrive:Shared/drop/x/Report.pdf'
  End
End
