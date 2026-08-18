# Backend dispatch. The faces (yazi, the clipboard picker, the CLI) all call
# share::send and never learn which backend answered — that is the whole point
# of the brain. The pre-send echo of the destination HOST is part of the
# contract, not a nicety: it is the thing that makes a wrong endpoint visible
# before bytes leave.

Describe 'share:: send dispatch'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-dispatch"
    rm -rf "$SB"; mkdir -p "$SB/bin"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_STATE_DIR="$SB/state"
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[drop]
store = "https://drop.example.com"
web = true
profiles = ["personal"]
default_for = ["personal"]

[lan]
relay = ""
local_only = true
web = false
profiles = ["personal"]

[onedrive]
backend = "rclone"
remote = "onedrive:Shared/drop"
web = true
profiles = ["work"]
default_for = ["work"]
TOML
    printf 'x' >"$SB/Report.pdf"
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf 'https://drop.example.com/s/abc123#v1.KEY\ncroc-store-v1.b64.abc123.KEY\n'
SH
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = link ]; then printf 'https://corp.example.com/:b:/g/abc\n'; exit 0; fi
done
exit 0
SH
    chmod +x "$SB/bin/croc" "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
  }
  BeforeEach 'setup'

  It 'routes a personal send to the croc backend'
    SHARE_PROFILE=personal
    When call share::send "$SB/Report.pdf"
    The output should include 'drop.example.com/s/abc123'
    The stderr should include 'drop.example.com'
  End

  It 'routes a work send to the rclone backend'
    SHARE_PROFILE=work
    When call share::send "$SB/Report.pdf"
    The output should include 'corp.example.com'
    The stderr should include 'sending to onedrive:Shared/drop'
  End

  It 'echoes the destination host before sending'
    SHARE_PROFILE=personal
    When call share::send "$SB/Report.pdf"
    The stderr should include 'sending to drop.example.com'
    The output should include 'drop.example.com/s/abc123'
  End

  It 'refuses to send to an endpoint the profile disallows'
    SHARE_PROFILE=work
    When run share::send --to drop "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'not allowed on profile work'
  End

  It 'fails cleanly when a path does not exist'
    SHARE_PROFILE=personal
    When run share::send "$SB/missing.pdf"
    The status should be failure
    The stderr should include 'no such file'
  End

  It 'revokes a croc receipt through the croc backend'
    SHARE_PROFILE=personal
    share::ledger_add rid croc drop 'R' abc123 'https://x' 0
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_CALLS"
SH
    chmod +x "$SB/bin/croc"
    SHARE_CALLS="$SB/calls"; export SHARE_CALLS
    share::revoke rid
    When call cat "$SB/calls"
    The output should include '--revoke abc123'
  End

  It 'revokes an rclone receipt by deleting the object'
    SHARE_PROFILE=work
    share::ledger_add rid rclone onedrive 'R' 'onedrive:Shared/drop/x/R' 'https://x' 0
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_CALLS"
SH
    chmod +x "$SB/bin/rclone"
    SHARE_CALLS="$SB/calls"; export SHARE_CALLS
    share::revoke rid
    When call cat "$SB/calls"
    The output should include 'purge onedrive:Shared/drop/x/R'
  End

  # F7 fix: a live-mode croc row is tagged with the distinct backend
  # "croc-live" and an empty ref (there is no store-side id to revoke — the
  # transfer just dies when croc exits). share::revoke must refuse it with a
  # clear message rather than ever calling `croc --revoke ''`, and must leave
  # the receipt in place so `share list` keeps rendering it honestly.
  It 'refuses to revoke a live croc share, with a clear message, and keeps the receipt'
    SHARE_PROFILE=personal
    share::ledger_add rid croc-live drop 'R' '' '8878-salary-courage-roger' 0
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf 'called\n' >>"$SHARE_CALLS"
SH
    chmod +x "$SB/bin/croc"
    SHARE_CALLS="$SB/calls"; export SHARE_CALLS
    When run share::revoke rid
    The status should be failure
    The stderr should include 'live transfer'
    The path "$SB/calls" should not be exist
  End

  It 'still lists a live croc share after a refused revoke'
    SHARE_PROFILE=personal
    share::ledger_add rid croc-live drop 'R' '' '8878-salary-courage-roger' 0
    share::revoke rid 2>/dev/null || :
    When call share::ledger_get rid
    The status should be success
    The output should include '"backend": "croc-live"'
  End

  It 'drops the receipt after a successful revoke'
    SHARE_PROFILE=personal
    share::ledger_add rid croc drop 'R' abc123 'https://x' 0
    printf '#!/bin/sh\nexit 0\n' >"$SB/bin/croc"; chmod +x "$SB/bin/croc"
    share::revoke rid
    When run share::ledger_get rid
    The status should be failure
  End

  # --- ruling: reject a path containing a literal newline -------------------
  # The argv seam (share::croc_argv / share::rclone_copy_argv) prints one
  # token per line; a newline embedded in a path would silently split into two
  # argv tokens when a caller reassembles with `cmd=("${(@f)$(...)}")`. That
  # must never reach the seam — share::send rejects it up front, and the fake
  # croc/rclone below prove no transfer was ever attempted.
  It 'rejects a path containing a literal newline before any transfer starts'
    SHARE_PROFILE=personal
    SHARE_CALLS="$SB/calls"; export SHARE_CALLS
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf 'called\n' >>"$SHARE_CALLS"
printf 'https://drop.example.com/s/abc123#v1.KEY\ncroc-store-v1.b64.abc123.KEY\n'
SH
    chmod +x "$SB/bin/croc"
    nl_path="$SB/evil"$'\n'"file.pdf"
    printf 'x' >"$nl_path"
    When run share::send "$nl_path"
    The status should be failure
    The stderr should include 'newline'
    The path "$SB/calls" should not be exist
  End

  # --- ruling: guard destination_host's empty-remote branch -----------------
  # An rclone endpoint declared with no `remote` must fail closed rather than
  # print (and send to) a blank host. share::send is where the pre-send echo
  # actually runs, so this is where the guard becomes user-visible.
  It 'fails a send to an rclone endpoint with no remote, instead of echoing a blank host'
    SHARE_PROFILE=work
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[bare]
backend = "rclone"
profiles = ["work"]
TOML
    When run share::send --to bare "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'no store, remote or relay'
    The stderr should not include 'sending to'
  End

  It 'makes share::destination_host itself fail on a remote-less rclone endpoint'
    SHARE_PROFILE=work
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[bare]
backend = "rclone"
profiles = ["work"]
TOML
    When run share::destination_host bare
    The status should be failure
    The stderr should include 'no store, remote or relay'
  End

  # --- ruling: no partial multi-file transfer on a mid-list typo -------------
  It 'fails a multi-file send before any transfer when one path does not exist'
    SHARE_PROFILE=personal
    SHARE_CALLS="$SB/calls"; export SHARE_CALLS
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf 'called\n' >>"$SHARE_CALLS"
printf 'https://drop.example.com/s/abc123#v1.KEY\ncroc-store-v1.b64.abc123.KEY\n'
SH
    chmod +x "$SB/bin/croc"
    printf 'y' >"$SB/Second.pdf"
    When run share::send "$SB/Report.pdf" "$SB/Missing.pdf" "$SB/Second.pdf"
    The status should be failure
    The stderr should include 'no such file'
    The path "$SB/calls" should not be exist
  End

  # --- review finding 1: a valueless flag must not spin forever -------------
  # `share::send --to` (or --expiration / --downloads) as the LAST token used
  # to leave `$2` empty and fail `shift 2` without changing `$#`, so `$1` was
  # still the same flag and `while (( $# ))` never terminated — a
  # CPU-spinning hang from an ordinary typo, with no test to catch it.
  #
  # A `timeout` alone is NOT enough to keep a regression here from wedging
  # the whole suite. shellspec's own output capture (shellspec_readfile in
  # lib/general.sh) rebuilds its buffer line-by-line — O(n^2) in output
  # size — and the pre-fix spin emits on the order of 270K lines/second.
  # Even after `timeout` kills the child, shellspec is left trying to slurp
  # everything the spin already wrote to the pipe before it died: at 5s that
  # is >1M lines / tens of MB, and the capture itself hangs on THAT, not on
  # the child. Verified against the pre-fix commit (c5365a08) — see the
  # fix-round report for the exact number; it did not return in under a
  # few minutes, let alone the suite's normal few seconds.
  #
  # So this helper bounds BOTH dimensions: `timeout` bounds wall-clock time,
  # and redirecting the child's stderr to a FILE (never a pipe shellspec
  # reads directly) plus `head -c` on the way back out bounds the volume
  # shellspec's capture ever sees — regardless of how much the child wrote
  # before `timeout` caught it.
  run_bare_flag() {
    local errf="$SB/spin.err"
    timeout 5 zsh -c "source home/dot_local/lib/share.zsh; share::send $1" 2>"$errf"
    local rc=$?
    head -c 300 "$errf" >&2
    return $rc
  }

  It 'terminates instead of hanging when --to has no value, and names the flag'
    When run run_bare_flag --to
    The status should be failure
    The stderr should include '--to requires an endpoint name'
  End

  It 'terminates instead of hanging when --expiration has no value, and names the flag'
    When run run_bare_flag --expiration
    The status should be failure
    The stderr should include '--expiration requires a value'
  End

  It 'terminates instead of hanging when --downloads has no value, and names the flag'
    When run run_bare_flag --downloads
    The status should be failure
    The stderr should include '--downloads requires a value'
  End

  # --- review finding 2: --live against the rclone backend ------------------
  It 'refuses --live against the rclone backend'
    SHARE_PROFILE=work
    When run share::send --live --to onedrive "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'no live mode'
  End

  # --- amendment D1/D2: live is the default, but never silently -------------
  # `drop` is a STORE (croc-web on 9014, no TCP relay), so a live transfer
  # "to drop" would fall back to croc's DEFAULT PUBLIC relay. On a work profile
  # that is exactly the egress the policy fence exists to prevent, and it would
  # happen with no flag and no prompt. The default therefore downgrades — and
  # SAYS SO — rather than quietly reaching a third party's relay.
  It 'downgrades the DEFAULT live mode to stored on a store-only endpoint, loudly'
    SHARE_PROFILE=personal
    When run share::send --to drop "$SB/Report.pdf"
    The status should be success
    The stderr should include 'cannot carry a live transfer'
    The stderr should include 'sending stored instead'
    The stdout should include 'drop.example.com/s/abc123'
  End

  # An EXPLICIT --live is a statement about how the file must travel, so the
  # same situation must refuse instead of downgrading.
  It 'refuses an EXPLICIT --live on the same store-only endpoint'
    SHARE_PROFILE=personal
    When run share::send --live --to drop "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'cannot carry a live transfer'
    The stdout should equal ''
  End

  # A LAN endpoint needs no relay at all — croc's multicast discovery is the
  # rendezvous — so it IS live-capable and must not be downgraded.
  It 'treats a local_only endpoint as live-capable'
    SHARE_PROFILE=personal
    When call share::live_capable lan
    The status should be success
  End
End
