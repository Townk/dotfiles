# Tests for home/dot_local/lib/backup.zsh — the system-backup bkp:: module.
#
# Phase 1: the thinning engine (bkp::thin), spec §5. Pure function; every test
# uses a fake `now` and synthetic timestamps. TZ is pinned per test (UTC unless
# the test is about TZ sensitivity) so wall-clock-grid assertions are hermetic.
#
# Epoch anchors used throughout (all UTC):
#   1767312000 = 2026-01-02 Fri 00:00:00Z   (NOW for ladder tests)
#   1767744000 = 2026-01-07 Wed 00:00:00Z   (NOW for TZ tests)

Describe 'backup.zsh'
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
  TAB=$(printf '\t')

  setup() { export TZ=UTC; }
  BeforeEach 'setup'

  Describe 'bkp::thin::cell'
    cell() {  # cell <grid> <epoch> — print the computed grid cell
      source "$LIB/backup.zsh"
      bkp::thin::cell "$1" "$2" && print -r -- "$REPLY"
    }

    # 1767312000 = 2026-01-02 00:00:00Z; +50700 = 14:05.
    It 'quantizes 30m cells at :00/:30'
      When run cell 30m 1767362700
      The output should equal "2026010214.0"
    End
    It 'puts :35 in the :30 half-cell'
      When run cell 30m 1767364500
      The output should equal "2026010214.1"
    End
    It 'quantizes 1h cells to the local hour'
      When run cell 1h 1767362700
      The output should equal "2026010214"
    End
    It 'quantizes 6h cells to 00/06/12/18'
      When run cell 6h 1767362700
      The output should equal "20260102.2"
    End
    It 'quantizes 12h cells'
      When run cell 12h 1767362700
      The output should equal "20260102.1"
    End
    It 'quantizes day cells to the local date'
      When run cell day 1767362700
      The output should equal "20260102"
    End
    It 'quantizes week cells ISO/Monday-anchored'
      # 2026-01-02 is Friday of ISO week 2026-W01.
      When run cell week 1767362700
      The output should equal "202601"
    End
    It 'puts Sunday in the same ISO week as the preceding Monday'
      # 2026-01-04 Sun 12:00Z is still 2026-W01.
      When run cell week 1767528000
      The output should equal "202601"
    End
    It 'quantizes month cells'
      When run cell month 1767362700
      The output should equal "202601"
    End
    It 'quantizes year cells'
      When run cell year 1767362700
      The output should equal "2026"
    End
    It 'rejects an unknown grid'
      When run cell fortnight 1767362700
      The status should equal 2
      The stderr should include "unknown grid"
    End
    It 'is not confused by octal-looking hours (08/09)'
      # 2026-01-02 08:10Z — $((10#$H / 6)) must not choke on "08".
      When run cell 6h 1767341400
      The output should equal "20260102.1"
    End
  End
End
