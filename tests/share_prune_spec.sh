# `share prune` — Phase 4 of the design: rclone's own `expires` ledger field
# is advisory (OneDrive itself does not enforce it, see share/rclone.zsh), so
# this command is what actually enforces it. Dry run by default; `--apply`
# purges the remote object and forgets the receipt. A stored croc share
# expires server-side on croc's own schedule, so an overdue croc row has
# nothing left to purge — prune only forgets its receipt, never calling croc
# (Mode B 2026-09-29: such rows were otherwise stuck in the ledger forever,
# since `croc --revoke` refuses once croc's own revoke receipt has expired).

Describe 'share:: prune'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-prune"
    rm -rf "$SB"; mkdir -p "$SB/bin"
    SHARE_STATE_DIR="$SB"
    SHARE_PROFILE=work
    zmodload zsh/datetime 2>/dev/null
  }
  BeforeEach 'setup'

  It 'reports nothing overdue and touches the ledger not at all'
    share::ledger_add live rclone onedrive 'a' refA 'urlA' 9999999999
    When call share::prune
    The output should include 'nothing overdue'
    The status should be success
  End

  It 'lists overdue rclone rows in dry-run and changes nothing'
    share::ledger_add old rclone onedrive 'Report.pdf (1 B)' onedrive:Shared/drop/x 'https://x' 1
    share::ledger_add newer rclone onedrive 'Notes.txt (1 B)' onedrive:Shared/drop/y 'https://y' 9999999999
    mkdir -p "$SB/bin"
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_RCLONE_CALLS"
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    SHARE_RCLONE_CALLS="$SB/calls"; export SHARE_RCLONE_CALLS
    When call share::prune
    The output should include 'old'
    The output should include 'Report.pdf'
    The output should include 'onedrive'
    The output should not include 'newer'
    The output should include '1 overdue rclone share(s) would be purged'
    The status should be success
    The path "$SB/calls" should not be exist
  End

  It 'never touches rclone (nor calls it) when nothing is overdue'
    share::ledger_add live rclone onedrive 'a' onedrive:Shared/drop/x 'https://x' 9999999999
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_RCLONE_CALLS"
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    SHARE_RCLONE_CALLS="$SB/calls"; export SHARE_RCLONE_CALLS
    share::prune >/dev/null
    check() { [[ ! -s "$SHARE_RCLONE_CALLS" ]]; }
    When call check
    The status should be success
  End

  # Mixed ledger: an overdue croc row, a live croc row, a non-overdue rclone
  # row and an overdue rclone row. The overdue rclone row is purged; the
  # overdue croc row is only forgotten (croc is never called); the live and
  # fresh rows survive — proven by the surviving ids and by what reached the
  # fakes.
  It 'apply purges overdue rclone rows and forgets overdue croc rows in a mixed ledger'
    share::ledger_add crocrow croc public 'a' crocref 'crocurl' 1
    share::ledger_add liverow croc-live public 'l' '' 'aaaa-bbbb' 0
    share::ledger_add freshrow rclone onedrive 'b' onedrive:Shared/drop/fresh 'https://fresh' 9999999999
    share::ledger_add overdue rclone onedrive 'c' onedrive:Shared/drop/stale 'https://stale' 1
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_RCLONE_CALLS"
exit 0
SH
    printf '#!/bin/sh\necho croc-called >>"$SHARE_RCLONE_CALLS"\n' >"$SB/bin/croc"
    chmod +x "$SB/bin/rclone" "$SB/bin/croc"
    PATH="$SB/bin:$PATH"
    SHARE_RCLONE_CALLS="$SB/calls"; export SHARE_RCLONE_CALLS
    do_it() {
      share::prune --apply >/dev/null 2>&1
      local ids; ids="$(share::ledger_list | jq -r '.[].id' | sort | tr '\n' ' ')"
      [[ "$ids" == 'freshrow liverow ' ]] || return 1
      grep -q 'croc-called' "$SHARE_RCLONE_CALLS" && return 1
      grep -qxF 'purge onedrive:Shared/drop/stale' "$SHARE_RCLONE_CALLS" || return 1
      grep -q 'crocref\|fresh' "$SHARE_RCLONE_CALLS" && return 1
      return 0
    }
    When call do_it
    The status should be success
  End

  It 'lists an overdue croc row in dry-run as a receipt to forget'
    share::ledger_add old croc public 'Big.dmg (1 MB)' crocref 'https://x' 1
    When call share::prune
    The output should include 'Big.dmg (1 MB)'
    The output should include '1 expired croc receipt(s) would be forgotten'
    The output should not include 'nothing overdue'
    The status should be success
  End

  It 'apply reports the forgotten croc receipts'
    share::ledger_add old croc public 'Big.dmg (1 MB)' crocref 'https://x' 1
    When run share::prune --apply
    The status should be success
    The output should include 'purged 0, forgot 1, failed 0'
    The output should include 'forgot old (Big.dmg (1 MB), public)'
  End

  It 'reports purged/failed and exits non-zero when a purge fails, without aborting the sweep'
    share::ledger_add good rclone onedrive 'a' onedrive:Shared/drop/good 'https://good' 1
    share::ledger_add bad rclone onedrive 'b' onedrive:Shared/drop/bad 'https://bad' 1
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_RCLONE_CALLS"
case "$*" in
  *bad*) exit 1 ;;
  *)     exit 0 ;;
esac
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    SHARE_RCLONE_CALLS="$SB/calls"; export SHARE_RCLONE_CALLS
    When run share::prune --apply
    The status should be failure
    The output should include 'purged 1, forgot 0, failed 1'
    The stderr should include 'FAILED to purge bad'
  End

  It 'leaves the failed row in the ledger and removes the succeeded one'
    share::ledger_add good rclone onedrive 'a' onedrive:Shared/drop/good 'https://good' 1
    share::ledger_add bad rclone onedrive 'b' onedrive:Shared/drop/bad 'https://bad' 1
    cat >"$SB/bin/rclone" <<'SH'
#!/bin/sh
case "$*" in
  *bad*) exit 1 ;;
  *)     exit 0 ;;
esac
SH
    chmod +x "$SB/bin/rclone"
    PATH="$SB/bin:$PATH"
    do_it() {
      share::prune --apply >/dev/null 2>&1 || :
      local ids; ids="$(share::ledger_list | jq -r '.[].id')"
      [[ "$ids" == 'bad' ]]
    }
    When call do_it
    The status should be success
  End
End
