# Tests for the qmk-flash bin (home/dot_local/bin/executable_qmk-flash): resolve
# a keyboard's newest firmware, validate it, then install it over the in-firmware
# updater (sval_update.py through uv) or, as the fallback, with picotool.
#
# Nothing here touches a board, and it must stay that way: picotool, diskutil,
# uv and hs are ALWAYS stubbed, so an example that finds a real bootloader drive
# (a half left in BOOTSEL while the suite runs) still cannot write to it, and no
# example can reach the updater of the board that is plugged into this Mac. The
# examples that wait for a drive use --timeout 1 to keep that wait to a second.
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
    rm -f -- "$CONFIG" "$CALLS" "$FW"/*.uf2(N) "$FW"/*.svup(N) "$FW"/*.py(N)
    unset FAKE_VERSION_LEFT FAKE_VERSION_RIGHT FAKE_INFO FAKE_INFO_AFTER \
      FAKE_INFO_RC FAKE_PAIR_RC FAKE_PAIR_SIGNAL

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
    # hs is here even for the examples that point HS elsewhere: notify falls
    # back to the `hs` on PATH when $HS is not executable, and that must be this
    # stub rather than the real one, which would paint on this screen.
    printf '#!/bin/sh\necho "hs $*" >> "%s"\nexit 0\n' "$CALLS" > "$STUBS/hs"

    # uv stands in for every updater call, told apart by its arguments: `-c`
    # is svup_version reading a .svup's build version (the left or right file
    # is the last argument), `info` is the probe, `pair` is the install. The
    # `info` after a `pair` is the read-back, which FAKE_INFO_AFTER can answer
    # differently from the probe; "after a pair" is read off the call log
    # itself, so the stub needs no state of its own.
    sed "s|@CALLS@|$CALLS|g" > "$STUBS/uv" <<'STUB'
#!/bin/sh
echo "uv $*" >> "@CALLS@"
for last; do :; done
case " $* " in
  *" -c "*)
    case "$last" in
      *left*) echo "${FAKE_VERSION_LEFT:-abc1234-120000}" ;;
      *right*) echo "${FAKE_VERSION_RIGHT:-abc1234-120000}" ;;
    esac
    exit 0
    ;;
  *" info "*)
    d='{"protocol": 4, "version": "abc1234-120000"}'
    if grep -q ' pair ' "@CALLS@"; then
      printf '%s\n' "${FAKE_INFO_AFTER:-${FAKE_INFO:-$d}}"
    else
      printf '%s\n' "${FAKE_INFO:-$d}"
    fi
    exit "${FAKE_INFO_RC:-0}"
    ;;
  *" pair "*)
    # FAKE_PAIR_SIGNAL stands in for a Ctrl-C mid-update: interrupt the
    # script (this stub's parent, the backgrounded job having exec'd it), then
    # linger so the signal lands while the script still waits on us.
    if [ -n "${FAKE_PAIR_SIGNAL:-}" ]; then
      kill -INT "$PPID"
      sleep 1
    fi
    exit "${FAKE_PAIR_RC:-0}"
    ;;
esac
exit 0
STUB
    chmod +x "$STUBS/ssh" "$STUBS/rsync" "$STUBS/picotool" "$STUBS/diskutil" \
      "$STUBS/hs" "$STUBS/uv"
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

  # svup <half> — a fixture update file for <half>, named as the local build
  # names it, plus the two updater scripts the build leaves beside it. Their
  # contents do not matter: uv is stubbed, so nothing ever runs them.
  svup() {
    : > "$FW/svalboard_trackball_pmw3389_${1}_townk.svup"
    : > "$FW/sval_update.py"
    : > "$FW/make_update.py"
  }

  # calls <args…> — run the script, then print the call log as CALL: lines on
  # stdout, so an example can assert on both in one go. The script's status is
  # passed through.
  calls() {
    local rc=0
    act "$@" || rc=$?
    [ -f "$CALLS" ] && sed 's/^/CALL: /' "$CALLS"
    return $rc
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
      When run command zsh -f "$SCRIPT" --bootsel right --host cli.example --timeout 1
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
        act --bootsel right --host localhost --dir "$FW" --timeout 1
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
      When run command zsh -f "$SCRIPT" --bootsel right --host localhost --dir "$FW" --timeout 1
      The status should be failure
      The stdout should include "svalboard_trackball_right_townk.uf2"
      The stdout should not include "older_right_build.uf2"
      The stderr should include "no bootloader drive appeared"
    End

    It 'refuses a non-UF2 image before asking for a reset'
      uf2 right bad
      no_reset() {
        act --bootsel right --host localhost --dir "$FW" --timeout 1
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
      When run command zsh -f "$SCRIPT" --bootsel right --host localhost --dir "$FW" --timeout 1
      The status should be failure
      The stderr should include "no right-half firmware"
    End

    It 'reports a missing firmware directory'
      When run command zsh -f "$SCRIPT" --bootsel right --host localhost --dir "$FW/nope" --timeout 1
      The status should be failure
      The stderr should include "no such directory"
    End

    It 'validates both images up front and prompts for the right half first'
      uf2 right
      uf2 left
      When run command zsh -f "$SCRIPT" --bootsel both --host localhost --dir "$FW" --timeout 1
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
      When run command zsh -f "$SCRIPT" --bootsel right --host build.example --dir some/dir --timeout 1
      The status should be failure
      The stderr should include "no such directory on build.example"
      The stderr should include "some/dir"
    End

    It 'resolves the updater files from the configured host too'
      When run command zsh -f "$SCRIPT" --host build.example --dir some/dir
      The status should be failure
      The stderr should include "no such directory on build.example"
    End
  End

  Describe 'the in-firmware updater'
    # The overlay pause/resume goes through hs, so it is pointed at the stub
    # that records into the call log.
    updater_setup() { export HS="$STUBS/hs"; }
    BeforeEach 'updater_setup'

    It 'pairs both halves over the updater'
      svup left
      svup right
      When call calls both --host localhost --dir "$FW"
      The status should be success
      The output should include "sval_update.py pair $FW/svalboard_trackball_pmw3389_left_townk.svup $FW/svalboard_trackball_pmw3389_right_townk.svup --yes"
      The output should not include "CALL: picotool"
    End

    It 'defaults to both halves'
      svup left
      svup right
      When call calls --host localhost --dir "$FW"
      The status should be success
      The output should include "sval_update.py pair"
    End

    It 'refuses halves from different builds'
      svup left
      svup right
      export FAKE_VERSION_LEFT=abc1234-120000 FAKE_VERSION_RIGHT=abc1234-130000
      When call calls --host localhost --dir "$FW"
      The status should be failure
      The stderr should include "abc1234-120000"
      The stderr should include "abc1234-130000"
      # Refused before the board is asked anything: no probe, no overlay pause.
      The output should not include "sval_update.py info"
      The output should not include "CALL: hs"
      The output should not include "sval_update.py pair"
    End

    It 'falls back to BOOTSEL when the probe fails'
      svup left
      svup right
      uf2 left
      uf2 right
      export FAKE_INFO_RC=1
      When call calls --host localhost --dir "$FW" --timeout 1
      The status should be failure
      The output should include "using BOOTSEL"
      The output should include "Double-click the RESET button"
      The output should not include "sval_update.py pair"
      The output should not include "may now run different builds"
      The stderr should not include "may now run different builds"
      The stderr should include "no bootloader drive appeared"
    End

    It 'pauses the overlay for the probe and resumes it before BOOTSEL'
      svup left
      svup right
      uf2 left
      uf2 right
      export FAKE_INFO_RC=1
      # pause, then the probe, then the resume, then the reset prompt (whose
      # notification goes through the hs stub too) — in that order.
      ordered() {
        act --host localhost --dir "$FW" --timeout 1
        awk '/pause\(/{if(!p)p=NR} /sval_update.py info/{if(!i)i=NR} /resume\(\)/{if(!r)r=NR}
             /Double-click RESET/{if(!d)d=NR}
             END{if (p && p<i && i<r && r<d) print "ORDERED"; else printf "p=%d i=%d r=%d d=%d\n", p, i, r, d}' "$CALLS"
      }
      When call ordered
      The output should include "ORDERED"
      The stderr should include "no bootloader drive appeared"
    End

    It 'refuses a single half over the updater'
      svup left
      svup right
      When call calls right --host localhost --dir "$FW"
      The status should be failure
      The stderr should include "--bootsel"
      The output should not include "sval_update.py pair"
    End

    It '--bootsel right skips the updater'
      uf2 right
      When call calls --bootsel right --host localhost --dir "$FW" --timeout 1
      The status should be failure
      The output should not include "sval_update.py info"
      The output should include "RESET button on the RIGHT half"
      The stderr should include "same build"
      The stderr should include "no bootloader drive appeared"
    End

    It 'reports a failed pair loudly'
      svup left
      svup right
      export FAKE_PAIR_RC=1
      When call calls --host localhost --dir "$FW"
      The status should be failure
      The output should include "sval_update.py pair"
      The stderr should include "may now run different builds"
      The stderr should include "rerun"
    End

    It 'resumes the overlay when pair fails'
      svup left
      svup right
      export FAKE_PAIR_RC=1
      # The resume must come AFTER the pair, not merely somewhere in the log.
      resumed_after_pair() {
        act --host localhost --dir "$FW"
        awk '/ pair /{p=NR} /resume\(\)/{r=NR} END{if (p && r > p) print "RESUMED AFTER PAIR"}' "$CALLS"
      }
      When call resumed_after_pair
      The output should include "RESUMED AFTER PAIR"
      The stderr should include "may now run different builds"
    End

    It 'resumes the overlay and explains when interrupted during pair'
      svup left
      svup right
      export FAKE_PAIR_SIGNAL=1
      When call calls --host localhost --dir "$FW"
      The status should eq 130
      The output should include "sval_update.py pair"
      The output should include "resume()"
      The stderr should include "may now run different builds"
    End

    It 'flashes when hs is unavailable'
      svup left
      svup right
      export HS=/nonexistent
      When call calls --host localhost --dir "$FW"
      The status should be success
      The output should include "sval_update.py pair"
      The stderr should include "overlay"
    End

    It 'fails when the version does not read back'
      svup left
      svup right
      export FAKE_INFO_AFTER='{"protocol": 4, "version": "zzz"}'
      When call calls --host localhost --dir "$FW"
      The status should be failure
      The output should include "sval_update.py pair"
      The stderr should include "zzz"
      The stderr should include "abc1234-120000"
    End
  End
End
