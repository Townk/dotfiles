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

  Describe 'bkp::thin — core'
    # Helpers run in a fresh zsh via `run`; TAB-separated stdin comes from
    # printf so the spec file itself stays tab-free.
    thin() {  # thin <now> [<policy>] — stdin: "<id> <epoch>" space pairs, one per line
      source "$LIB/backup.zsh"
      local id epoch
      while read -r id epoch; do
        printf '%s\t%s\n' "$id" "$epoch"
      done | bkp::thin "$@"
    }

    It 'keeps a single snapshot (keep_last)'
      single() { printf 'abc 999999999\n' | thin 1000000000; }
      When run single
      The output should equal "keep${TAB}abc"
    End

    It 'emits nothing for empty input'
      empty() { : | thin 1000000000; }
      When run empty
      The output should equal ""
      The status should be success
    End

    It 'keeps newest per 30-min cell and drops the rest'
      # 14:05 and 14:10 share cell 2026010214.0 (ages < 24h from NOW);
      # 14:40 is in the .1 half-cell. NOW = 2026-01-02 18:00Z = 1767376800.
      pair() {
        printf '%s\n' 'a 1767362700' 'b 1767363000' 'c 1767364800' | thin 1767376800
      }
      When run pair
      The line 1 should equal "drop${TAB}a"
      The line 2 should equal "keep${TAB}b"
      The line 3 should equal "keep${TAB}c"
    End

    It 'preserves input order in the output'
      order() {
        printf '%s\n' 'z 1767364800' 'a 1767362700' 'b 1767363000' | thin 1767376800
      }
      When run order
      The line 1 should equal "keep${TAB}z"
      The line 2 should equal "drop${TAB}a"
      The line 3 should equal "keep${TAB}b"
    End

    It 'assigns age exactly 24h to the hourly tier (half-open bands)'
      # NOW = 2026-01-02 00:00Z. A = exactly 24h old (T2, hour cell Jan1-00),
      # B = 23h30m old (T1, 30-min cell). Both survive: different tiers.
      boundary() {
        printf '%s\n' 'a 1767225600' 'b 1767227400' | thin 1767312000
      }
      When run boundary
      The line 1 should equal "keep${TAB}a"
      The line 2 should equal "keep${TAB}b"
    End

    It 'treats a future snapshot (clock skew) as age 0'
      skew() { printf 'f 1767312100\n' | thin 1767312000; }
      When run skew
      The output should equal "keep${TAB}f"
    End

    It 'honors a custom policy'
      # Single daily tier: same local date collapses to one keep.
      custom() {
        printf '%s\n' 'a 1767362700' 'b 1767363000' | thin 1767376800 'day 0 -'
      }
      When run custom
      The line 1 should equal "drop${TAB}a"
      The line 2 should equal "keep${TAB}b"
    End

    It 'rejects a non-numeric now'
      badnow() { printf 'a 1\n' | thin tomorrow; }
      When run badnow
      The status should equal 2
      The stderr should include "unix epoch"
    End

    It 'rejects a malformed snapshot line'
      badline() { printf 'no-epoch-here\n' | thin 1767312000; }
      When run badline
      The status should equal 2
      The stderr should include "bad snapshot line"
    End

    It 'rejects a malformed policy'
      badpolicy() { printf 'a 1\n' | thin 1767312000 'day zero'; }
      When run badpolicy
      The status should equal 2
      The stderr should include "bad policy line"
    End
  End
End
