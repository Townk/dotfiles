# Tests for the qmk-flash bin (home/dot_local/bin/executable_qmk-flash): resolve
# a keyboard half's newest firmware, validate it, then flash it with picotool.
#
# Nothing here touches a board, and it must stay that way: picotool and diskutil
# are ALWAYS stubbed, so an example that finds a real bootloader drive (a half
# left in BOOTSEL while the suite runs) still cannot write to it. The examples
# that wait for a drive use --timeout 1 to keep that wait to a second.
#
# The script's own decisions are what get asserted, not the hardware's: which
# host it resolved from, whether it took the ssh hop at all, and whether it
# refused a bad image BEFORE asking for a reset.
Describe 'qmk-flash'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_qmk-flash"

  setup() {
    # A config sandbox: this developer machine has a REAL ~/.config/qmk-flash/
    # config.toml pointing at its build host, and it must not leak in and decide
    # what "the default host" means here.
    export XDG_CONFIG_HOME="$SHELLSPEC_TMPBASE/qf-config"
    CONFIG="$XDG_CONFIG_HOME/qmk-flash/config.toml"
    STUBS="$SHELLSPEC_TMPBASE/qf-bin"
    CALLS="$SHELLSPEC_TMPBASE/qf-calls"
    FW="$SHELLSPEC_TMPBASE/qf-fw"
    export PATH="$STUBS:$PATH"
    mkdir -p "$XDG_CONFIG_HOME/qmk-flash" "$STUBS" "$FW"
    # (N) nullglob: an empty fixture dir is the normal case for the first
    # example, and a bare *.uf2 would be a nomatch ERROR under zsh, not an empty
    # list — the same trap the script's own remote listing avoids.
    rm -f -- "$CONFIG" "$CALLS" "$FW"/*.uf2(N)

    # notify must not paint on a real screen, and must not dial the clipboard
    # bridge because the suite happens to be running over ssh.
    export HS=/usr/bin/true
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY NOTIFY_VIA_BRIDGE

    # Every external the script shells out to, recording into one log so an
    # example can assert what did NOT run as easily as what did. ssh exits 3,
    # the "no such directory" code, so the remote path fails at a known step
    # while still reporting the host it dialed.
    printf '#!/bin/sh\necho "ssh $*" >> "%s"\nexit 3\n' "$CALLS" > "$STUBS/ssh"
    printf '#!/bin/sh\necho "rsync $*" >> "%s"\nexit 0\n' "$CALLS" > "$STUBS/rsync"
    printf '#!/bin/sh\necho "picotool $*" >> "%s"\nexit 0\n' "$CALLS" > "$STUBS/picotool"
    printf '#!/bin/sh\necho "diskutil $*" >> "%s"\nexit 0\n' "$CALLS" > "$STUBS/diskutil"
    chmod +x "$STUBS/ssh" "$STUBS/rsync" "$STUBS/picotool" "$STUBS/diskutil"
  }
  BeforeEach 'setup'

  # -f so this repo's own rc files cannot re-export the XDG paths the sandbox
  # depends on (the trap documented in tests/notify_bridge_spec.sh).
  act() { zsh -f "$SCRIPT" "$@"; }

  # uf2 <half> [magic] — a fixture image for <half>. Valid magic is "UF2\n"
  # followed by the 0x9E5D5157 second word; anything else stands in for a
  # truncated or wrong-format build.
  uf2() {
    local f="$FW/svalboard_trackball_${1}_townk.uf2"
    if [ "${2:-good}" = good ]; then
      printf '\x55\x46\x32\x0a\x57\x51\x5d\x9e' > "$f"
    else
      printf 'not a uf2 at all' > "$f"
    fi
    head -c 504 /dev/zero >> "$f"
  }

  Describe 'arguments'
    It '--help exits 0 and prints usage'
      When run command zsh -f "$SCRIPT" --help
      The status should be success
      The output should include "Usage:"
    End

    It 'exits 2 on an unknown argument'
      When run command zsh -f "$SCRIPT" bogus
      The status should eq 2
      The stderr should include "unknown argument"
    End

    It 'rejects a non-integer timeout'
      When run command zsh -f "$SCRIPT" right --timeout 2m
      The status should be failure
      The stderr should include "whole seconds"
    End

    It 'rejects a flag with no value'
      When run command zsh -f "$SCRIPT" --host
      The status should be failure
      The stderr should include "needs a value"
    End
  End

  Describe 'configuration'
    It 'defaults to localhost with no config file'
      When run command zsh -f "$SCRIPT" --help
      The status should be success
      The output should include "host=localhost"
    End

    It 'takes its defaults from config.toml'
      printf 'host = "cfg.example"\ntimeout = 45\n' > "$CONFIG"
      When run command zsh -f "$SCRIPT" --help
      The status should be success
      The output should include "host=cfg.example"
      The output should include "timeout=45"
    End

    It 'lets a flag override the config file'
      printf 'host = "cfg.example"\n' > "$CONFIG"
      When run command zsh -f "$SCRIPT" right --host cli.example --timeout 1
      The status should be failure
      # The host named in the failure is the host it actually dialed.
      The stderr should include "cli.example"
      The stderr should not include "cfg.example"
    End

    It 'reports an unknown config key instead of ignoring the typo'
      printf 'hst = "cfg.example"\n' > "$CONFIG"
      When run command zsh -f "$SCRIPT" --help
      The status should be success
      The stderr should include "ignoring unknown key"
      # …and the misspelt key changed nothing.
      The output should include "host=localhost"
    End

    It 'fails by name on an unparseable config file'
      printf 'host = "unterminated\n' > "$CONFIG"
      When run command zsh -f "$SCRIPT" --help
      The status should be failure
      The stderr should include "cannot parse"
    End
  End

  Describe 'local firmware (host = localhost)'
    It 'resolves the file directly, with no ssh hop and no copy'
      uf2 right
      local_flash() {
        act right --host localhost --dir "$FW" --timeout 1
        # Nothing may have shelled out to ssh/rsync on this path: that is the
        # whole point of localhost, not an incidental optimisation.
        [ -f "$CALLS" ] && { echo "SHELLED OUT:"; cat "$CALLS"; }
        return 0
      }
      When call local_flash
      The stdout should include "svalboard_trackball_right_townk.uf2"
      The stdout should not include "SHELLED OUT"
      The stderr should include "no bootloader drive appeared"
    End

    It 'picks the newest match when several builds are present'
      uf2 right
      local newest="$FW/svalboard_trackball_right_townk.uf2"
      local older="$FW/older_right_build.uf2"
      cp "$newest" "$older"
      touch -t 202001010000 "$older"
      When run command zsh -f "$SCRIPT" right --host localhost --dir "$FW" --timeout 1
      The status should be failure
      The stdout should include "svalboard_trackball_right_townk.uf2"
      The stdout should not include "older_right_build.uf2"
      The stderr should include "no bootloader drive appeared"
    End

    It 'refuses a non-UF2 image before asking for a reset'
      uf2 right bad
      no_reset() {
        act right --host localhost --dir "$FW" --timeout 1
        [ -f "$CALLS" ] && { echo "TOUCHED HARDWARE:"; cat "$CALLS"; }
        return 0
      }
      When call no_reset
      The stderr should include "not a UF2 image"
      The stdout should not include "Double-click"
      The stdout should not include "TOUCHED HARDWARE"
    End

    It 'reports the half when no firmware matches'
      uf2 left
      When run command zsh -f "$SCRIPT" right --host localhost --dir "$FW" --timeout 1
      The status should be failure
      The stderr should include "no right-half firmware"
    End

    It 'reports a missing firmware directory'
      When run command zsh -f "$SCRIPT" right --host localhost --dir "$FW/nope" --timeout 1
      The status should be failure
      The stderr should include "no such directory"
    End

    It 'validates both images up front and prompts for the right half first'
      uf2 right
      uf2 left
      When run command zsh -f "$SCRIPT" both --host localhost --dir "$FW" --timeout 1
      The status should be failure
      # Both resolved before any prompt; the reset asked for is the right half's,
      # so the left half's turn is where the cables get swapped.
      The stdout should include "right: svalboard_trackball_right_townk.uf2"
      The stdout should include "left: svalboard_trackball_left_townk.uf2"
      The stdout should include "RESET button on the RIGHT half"
      The stdout should not include "RESET button on the LEFT half"
      The stderr should include "no bootloader drive appeared"
    End
  End

  Describe 'remote firmware'
    It 'dials the configured host and reports its exit'
      When run command zsh -f "$SCRIPT" right --host build.example --dir some/dir --timeout 1
      The status should be failure
      The stderr should include "no such directory on build.example"
      The stderr should include "some/dir"
    End
  End
End
