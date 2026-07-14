# Tests for clipboard-mount — the owner of clipboard peer mounts (rclone SFTP
# on MacFUSE). Spec: docs/superpowers/specs/2026-07-13-clipboard-mount-subsystem-design.md
# All invocations use `zsh -f` (see Global Constraints: ~/.zshenv clobbers the
# sandbox XDG override otherwise).
Describe 'clipboard-mount: map + host validation'
  CM="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-mount"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    MNT_ROOT="$XDG_STATE_HOME/clipboard/mnt"
  }
  BeforeEach 'setup'

  It 'maps one absolute path under the host mountpoint'
    When run command zsh -f "$CM" map peer-mini /Users/thiago/big.bin
    The status should be success
    The output should equal "$MNT_ROOT/peer-mini/Users/thiago/big.bin"
  End

  It 'maps several paths, one per line, preserving spaces and unicode'
    When run command zsh -f "$CM" map peer-mini "/tmp/a b.txt" "/tmp/é.png"
    The status should be success
    The line 1 of output should equal "$MNT_ROOT/peer-mini/tmp/a b.txt"
    The line 2 of output should equal "$MNT_ROOT/peer-mini/tmp/é.png"
  End

  It 'rejects a relative path'
    When run command zsh -f "$CM" map peer-mini not/abs
    The status should be failure
    The stderr should include "not absolute"
  End

  It 'rejects a traversal-shaped host (defense: host comes off the wire)'
    When run command zsh -f "$CM" map "../evil" /tmp/x
    The status should be failure
    The stderr should include "invalid host"
  End

  It 'rejects an empty host'
    When run command zsh -f "$CM" map "" /tmp/x
    The status should be failure
    The stderr should include "invalid host"
  End

  It 'prints usage and fails on an unknown subcommand'
    When run command zsh -f "$CM" frobnicate
    The status should be failure
    The stderr should include "usage"
  End
End

Describe 'clipboard-mount: unmount + sweep'
  CM="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-mount"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    MNT_ROOT="$XDG_STATE_HOME/clipboard/mnt"
    STUBS="$SHELLSPEC_TMPBASE/bin"
    export PATH="$STUBS:$PATH"
    mkdir -p "$STUBS" "$MNT_ROOT"
    rm -f "$SHELLSPEC_TMPBASE/mount-table" "$SHELLSPEC_TMPBASE/calls"
    : > "$SHELLSPEC_TMPBASE/mount-table"
    # `mount` prints the fixture table; umount/diskutil/kill-targets record.
    printf '#!/bin/sh\ncat "%s"\n' "$SHELLSPEC_TMPBASE/mount-table" > "$STUBS/mount"
    printf '#!/bin/sh\necho "umount $*" >> "%s"\nexit 0\n' "$SHELLSPEC_TMPBASE/calls" > "$STUBS/umount"
    printf '#!/bin/sh\necho "diskutil $*" >> "%s"\nexit 0\n' "$SHELLSPEC_TMPBASE/calls" > "$STUBS/diskutil"
    printf '#!/bin/sh\nexit 1\n' > "$STUBS/pgrep"   # no rclone pids by default
    chmod +x "$STUBS/mount" "$STUBS/umount" "$STUBS/diskutil" "$STUBS/pgrep"
  }
  BeforeEach 'setup'

  It 'unmount tears down and removes the mountpoint dir'
    mkdir -p "$MNT_ROOT/peer-mini"
    When run command zsh -f "$CM" unmount peer-mini
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/calls" should include "umount $MNT_ROOT/peer-mini"
    The path "$MNT_ROOT/peer-mini" should not be exist
  End

  It 'sweep leaves a healthy mount alone'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    When run command zsh -f "$CM" sweep
    The status should be success
    The path "$MNT_ROOT/peer-mini" should be exist
    The path "$SHELLSPEC_TMPBASE/calls" should not be exist
  End

  It 'sweep reaps a mountpoint dir with no mount-table entry (orphan)'
    mkdir -p "$MNT_ROOT/peer-mini"
    When run command zsh -f "$CM" sweep
    The status should be success
    The path "$MNT_ROOT/peer-mini" should not be exist
  End

  It 'sweep reaps a mounted-but-hung volume (probe timeout) with force escalation'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    # stat hangs -> probe must time out (bounded), then teardown runs.
    printf '#!/bin/sh\nsleep 20\n' > "$STUBS/stat"; chmod +x "$STUBS/stat"
    # first umount "fails" so the diskutil force escalation is exercised
    printf '#!/bin/sh\necho "umount $*" >> "%s"\nexit 1\n' "$SHELLSPEC_TMPBASE/calls" > "$STUBS/umount"
    When run command zsh -f "$CM" sweep
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/calls" should include "diskutil unmount force $MNT_ROOT/peer-mini"
  End
End
