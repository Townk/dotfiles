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
