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

  Describe 'bkp::thin — ladder counts (spec §5)'
    # NOW = 2026-01-02 Fri 00:00:00Z (1767312000): local midnight, and the
    # 11-day mark lands on a Monday midnight, so every band below aligns with
    # its grid. Fixtures place snapshots strictly INSIDE each band's open
    # interior — ages in (min, max) — because the exact band-min instant
    # belongs to the coarser tier and would add a boundary cell.
    NOW=1767312000

    series_keeps() {  # series_keeps <min_age> <max_age> <step> — dense series -> keep count
      source "$LIB/backup.zsh"
      local min=$1 max=$2 step=$3 age
      for (( age = min + step; age < max; age += step )); do
        printf 's%s\t%s\n' "$(( NOW - age ))" "$(( NOW - age ))"
      done | bkp::thin "$NOW" | grep -c '^keep'
    }

    It 'T1: 24h of 15-min snapshots thin to 48 half-hour keeps'
      When run series_keeps 0 86400 900
      The output should equal 48
    End
    It 'T2: day 2 thins to 24 hourly keeps'
      When run series_keeps 86400 172800 900
      The output should equal 24
    End
    It 'T3: day 3 thins to 4 six-hour keeps'
      When run series_keeps 172800 259200 900
      The output should equal 4
    End
    It 'T4: day 4 thins to 2 twelve-hour keeps'
      When run series_keeps 259200 345600 900
      The output should equal 2
    End
    It 'T5: days 4-11 thin to 7 daily keeps'
      When run series_keeps 345600 950400 3600
      The output should equal 7
    End
    It 'T6: days 11-67 thin to 8 weekly keeps'
      When run series_keeps 950400 5788800 21600
      The output should equal 8
    End
    It 'T7: a year of monthly snapshots keeps all 12'
      # Steady-state input after weekly thinning upstream: one snapshot on the
      # 15th of each month, 12:00Z, 2024-11-15 .. 2025-10-15 (ages ~78-413d,
      # all inside (67d, 432d)). Fixed epochs — a generated step risks landing
      # two snapshots in one calendar month or skipping one.
      months() {
        source "$LIB/backup.zsh"
        local e
        for e in 1731672000 1734264000 1736942400 1739620800 1742040000 \
                 1744718400 1747310400 1749988800 1752580800 1755259200 \
                 1757937600 1760529600; do
          printf 's%s\t%s\n' "$e" "$e"
        done | bkp::thin "$NOW" | grep -c '^keep'
      }
      When run months
      The output should equal 12
    End
    It 'T7: two snapshots in the same calendar month collapse to one'
      samemonth() {
        source "$LIB/backup.zsh"
        # 2025-08-05 and 2025-08-20 12:00Z — both in month cell 202508,
        # ages ~135-150d from NOW.
        printf '%s\n' $'a\t1754395200' $'b\t1755691200' | bkp::thin "$NOW"
      }
      When run samemonth
      The line 1 should equal "drop${TAB}a"
      The line 2 should equal "keep${TAB}b"
    End

    It 'T8: yearly tier keeps one per calendar year forever'
      yearly() {
        source "$LIB/backup.zsh"
        # 2020-01-15, 2020-06-01, 2018-03-03 (all 12:00Z): two collapse to
        # the newest of 2020; 2018 survives despite being 8y old.
        printf '%s\n' $'a\t1579089600' $'b\t1591012800' $'c\t1520078400' |
          bkp::thin "$NOW"
      }
      When run yearly
      The line 1 should equal "drop${TAB}a"
      The line 2 should equal "keep${TAB}b"
      The line 3 should equal "keep${TAB}c"
    End

    It 'is idempotent: thinning the keep-set again drops nothing'
      idem() {
        source "$LIB/backup.zsh"
        local age
        for (( age = 900; age < 40000000; age += 47700 )); do
          printf 's%s\t%s\n' "$(( NOW - age ))" "$(( NOW - age ))"
        done | bkp::thin "$NOW" |
          awk -F'\t' '$1 == "keep" { print $2 "\t" substr($2, 2) }' |
          bkp::thin "$NOW" | grep -c '^drop' || true
      }
      When run idem
      The output should equal 0
    End
  End

  Describe 'bkp::thin — wall clock is local time'
    # NOW = 2026-01-07 00:00Z. Snapshots 2026-01-01 03:00Z and 07:00Z are both
    # ~6 days old (daily tier). Same UTC date -> one cell; in Etc/GMT+5 they
    # straddle local midnight (Dec 31 22:00 / Jan 1 02:00) -> two cells.
    tz_thin() {
      export TZ="$1"
      source "$LIB/backup.zsh"
      printf '%s\n' $'a\t1767236400' $'b\t1767250800' | bkp::thin 1767744000 |
        grep -c '^keep'
    }

    It 'groups by UTC date under TZ=UTC'
      When run tz_thin UTC
      The output should equal 1
    End
    It 'splits across local midnight under TZ=Etc/GMT+5'
      When run tz_thin Etc/GMT+5
      The output should equal 2
    End
  End

  Describe 'bkp::manifest — parsing'
    setup_fix() { FIX=$(mktemp -d); }
    cleanup_fix() { rm -rf "$FIX"; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'applies per-root git defaults to string roots and honors table overrides'
      roots() {
        source "$LIB/backup.zsh"
        cat > "$FIX/m.toml" <<EOF
roots = [
  "$FIX/a",
  { path = "$FIX/b", bundle_unpushed = false },
  { path = "$FIX/c", untracked_warn_size = "2g" },
]
EOF
        bkp::manifest::roots "$FIX/m.toml"
      }
      When run roots
      The line 1 should equal "$FIX/a${TAB}true${TAB}50m"
      The line 2 should equal "$FIX/b${TAB}false${TAB}50m"
      The line 3 should equal "$FIX/c${TAB}true${TAB}2g"
    End

    It 'expands ~ in roots and deny'
      tilde() {
        source "$LIB/backup.zsh"
        printf 'roots = ["~/xyz"]\ndeny = ["~/.cache", "**/*.sock"]\n' > "$FIX/m.toml"
        bkp::manifest::roots "$FIX/m.toml"
        bkp::manifest::deny "$FIX/m.toml"
      }
      When run tilde
      The line 1 should equal "$HOME/xyz${TAB}true${TAB}50m"
      The line 2 should equal "$HOME/.cache"
      The line 3 should equal "**/*.sock"
    End

    It 'chezmoi filter defaults on and honors explicit false'
      toggle() {
        source "$LIB/backup.zsh"
        printf 'roots = []\n' > "$FIX/on.toml"
        printf 'exclude_chezmoi_managed = false\n' > "$FIX/off.toml"
        bkp::manifest::chezmoi_excluded "$FIX/on.toml" && print on
        bkp::manifest::chezmoi_excluded "$FIX/off.toml" || print off
      }
      When run toggle
      The line 1 should equal "on"
      The line 2 should equal "off"
    End

    It 'errors on a missing manifest'
      missing() { source "$LIB/backup.zsh"; bkp::manifest::json "$FIX/nope.toml"; }
      When run missing
      The status should equal 2
      The stderr should include "manifest not found"
    End

    It 'errors on unparseable TOML'
      bad() {
        source "$LIB/backup.zsh"
        printf 'roots = [ oops\n' > "$FIX/m.toml"
        bkp::manifest::json "$FIX/m.toml"
      }
      When run bad
      The status should equal 2
      The stderr should include "unparseable manifest"
    End
  End

  Describe 'bkp::manifest — policy mapping'
    setup_fix() { FIX=$(mktemp -d); }
    cleanup_fix() { rm -rf "$FIX"; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'converts durations to seconds'
      dur() {
        source "$LIB/backup.zsh"
        local d
        for d in 30m 24h 7d 2w; do
          bkp::duration "$d" && print -r -- "$REPLY"
        done
      }
      When run dur
      The line 1 should equal 1800
      The line 2 should equal 86400
      The line 3 should equal 604800
      The line 4 should equal 1209600
    End

    It 'rejects a malformed duration'
      baddur() { source "$LIB/backup.zsh"; bkp::duration 5years; }
      When run baddur
      The status should equal 2
      The stderr should include "bad duration"
    End

    It 'maps [policy].tiers onto cumulative bands with a terminal yearly tier'
      tiers() {
        source "$LIB/backup.zsh"
        cat > "$FIX/m.toml" <<'EOF'
[policy]
tiers = [ {interval="30m", window="24h"}, {interval="6h", window="24h"} ]
EOF
        bkp::manifest::thin_policy "$FIX/m.toml"
      }
      When run tiers
      The line 1 should equal "30m 0 86400"
      The line 2 should equal "6h 86400 172800"
      The line 3 should equal "year 172800 -"
    End

    It 'falls back to the default ladder when [policy] is absent'
      nopolicy() {
        source "$LIB/backup.zsh"
        printf 'roots = []\n' > "$FIX/m.toml"
        # Command substitution strips trailing newlines on both sides,
        # making the comparison newline-shape-proof.
        [ "$(bkp::manifest::thin_policy "$FIX/m.toml")" = "$(print -r -- "$BKP_THIN_DEFAULT_POLICY")" ] && print same
      }
      When run nopolicy
      The output should equal "same"
    End

    It 'rejects an interval with no wall-clock grid'
      badtier() {
        source "$LIB/backup.zsh"
        printf '[policy]\ntiers = [ {interval="42m", window="24h"} ]\n' > "$FIX/m.toml"
        bkp::manifest::thin_policy "$FIX/m.toml"
      }
      When run badtier
      The status should equal 2
      The stderr should include "unsupported tier interval"
    End
  End

  Describe 'bkp::manifest — sweep'
    setup_fix() {
      FIX=$(mktemp -d)
      # chezmoi stub: no managed files, always succeeds — the chezmoi-filter
      # block overrides it per test.
      STUB="$FIX/stub"; mkdir -p "$STUB"
      printf '#!/bin/sh\nexit 0\n' > "$STUB/chezmoi"
      chmod +x "$STUB/chezmoi"
      PATH="$STUB:$PATH"
    }
    cleanup_fix() { rm -rf "$FIX"; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'captures files, prunes deny paths and glob matches, keeps symlinks as entries'
      sweep() {
        source "$LIB/backup.zsh"
        mkdir -p "$FIX/root/sub" "$FIX/root/cache" "$FIX/root/Cache/deep"
        print keep > "$FIX/root/keep.txt"
        print nested > "$FIX/root/sub/nested.txt"
        print blob > "$FIX/root/cache/blob.bin"
        print cached > "$FIX/root/Cache/deep/f"
        print sock > "$FIX/root/junk.sock"
        ln -s keep.txt "$FIX/root/link"
        cat > "$FIX/m.toml" <<EOF
roots = ["$FIX/root", "$FIX/absent"]
deny = ["$FIX/root/cache", "**/*.sock", "**/Cache/**"]
EOF
        bkp::manifest::files "$FIX/m.toml" | sort
      }
      When run sweep
      The line 1 should equal "$FIX/root/keep.txt"
      The line 2 should equal "$FIX/root/link"
      The line 3 should equal "$FIX/root/sub/nested.txt"
      The lines of output should equal 3
    End

    It 'captures a root that is a single file'
      filedirect() {
        source "$LIB/backup.zsh"
        print one > "$FIX/one.txt"
        printf 'roots = ["%s/one.txt"]\n' "$FIX" > "$FIX/m.toml"
        bkp::manifest::files "$FIX/m.toml"
      }
      When run filedirect
      The output should equal "$FIX/one.txt"
    End

    It 'errors when the manifest itself is missing'
      nomanifest() { source "$LIB/backup.zsh"; bkp::manifest::files "$FIX/nope.toml"; }
      When run nomanifest
      The status should equal 2
      The stderr should include "manifest not found"
    End
  End

  Describe 'bkp::manifest — chezmoi filter'
    setup_fix() {
      FIX=$(mktemp -d)
      STUB="$FIX/stub"; mkdir -p "$STUB"
      PATH="$STUB:$PATH"
      mkdir -p "$FIX/root/mdir"
      print m > "$FIX/root/managed.txt"
      print u > "$FIX/root/unmanaged.txt"
      print m1 > "$FIX/root/mdir/a"
      print m2 > "$FIX/root/mdir/b"
      printf 'roots = ["%s/root"]\n' "$FIX" > "$FIX/m.toml"
    }
    cleanup_fix() { rm -rf "$FIX"; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    stub_chezmoi() {  # stub_chezmoi <line>... — managed-list stub on PATH
      { printf '#!/bin/sh\n'; printf 'echo "%s"\n' "$@"; } > "$STUB/chezmoi"
      chmod +x "$STUB/chezmoi"
    }

    It 'subtracts managed files and keeps unmanaged siblings'
      subtract() {
        source "$LIB/backup.zsh"
        stub_chezmoi "$FIX/root/managed.txt"
        bkp::manifest::files "$FIX/m.toml" | sort
      }
      When run subtract
      The line 1 should equal "$FIX/root/mdir/a"
      The line 2 should equal "$FIX/root/mdir/b"
      The line 3 should equal "$FIX/root/unmanaged.txt"
      The lines of output should equal 3
    End

    It 'prunes a fully-managed subtree wholesale'
      wholesale() {
        source "$LIB/backup.zsh"
        stub_chezmoi "$FIX/root/mdir/a" "$FIX/root/mdir/b"
        bkp::manifest::files "$FIX/m.toml" | sort
      }
      When run wholesale
      The line 1 should equal "$FIX/root/managed.txt"
      The line 2 should equal "$FIX/root/unmanaged.txt"
      The lines of output should equal 2
    End

    It 'over-captures when chezmoi fails (fail-safe)'
      failsafe() {
        source "$LIB/backup.zsh"
        printf '#!/bin/sh\nexit 1\n' > "$STUB/chezmoi"
        chmod +x "$STUB/chezmoi"
        bkp::manifest::files "$FIX/m.toml" | sort
      }
      When run failsafe
      The line 1 should equal "$FIX/root/managed.txt"
      The lines of output should equal 4
      The stderr should include "over-capturing"
    End

    It 'skips the subtraction entirely when exclude_chezmoi_managed = false'
      # grep -c managed.txt counts managed.txt AND unmanaged.txt — 2 means
      # the managed file was captured despite the stub listing it.
      disabled() {
        source "$LIB/backup.zsh"
        stub_chezmoi "$FIX/root/managed.txt"
        printf 'exclude_chezmoi_managed = false\nroots = ["%s/root"]\n' "$FIX" > "$FIX/m.toml"
        bkp::manifest::files "$FIX/m.toml" | grep -c managed.txt
      }
      When run disabled
      The output should equal 2
    End
  End

  Describe 'bkp::manifest — per-repo git filter'
    setup_fix() {
      FIX=$(mktemp -d)
      STUB="$FIX/stub"; mkdir -p "$STUB"
      printf '#!/bin/sh\nexit 0\n' > "$STUB/chezmoi"
      chmod +x "$STUB/chezmoi"
      PATH="$STUB:$PATH"
      # Hermetic git: fixture-owned global config with a global excludesfile.
      export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$FIX/gitconfig"
      printf '*.global-ignored\n' > "$FIX/global-ignore"
      printf '[core]\n\texcludesFile = %s\n[user]\n\tname = t\n\temail = t@t\n' \
        "$FIX/global-ignore" > "$FIX/gitconfig"

      mkdir -p "$FIX/root/repo" "$FIX/root/plain"
      REPO="$FIX/root/repo"    # no cd: keep shellspec's cwd untouched
      git -C "$REPO" init -q
      print tracked > "$REPO/tracked.txt"
      print build > "$REPO/build.out"
      print local > "$REPO/tmp.local"
      print glob > "$REPO/x.global-ignored"
      print untracked > "$REPO/untracked.txt"
      printf 'build.out\n' > "$REPO/.gitignore"
      printf 'tmp.local\n' >> "$REPO/.git/info/exclude"
      git -C "$REPO" add tracked.txt .gitignore
      git -C "$REPO" -c commit.gpgsign=false commit -qm init
      # Non-repo sibling: gitignore-looking files are NOT filtered there.
      print loose > "$FIX/root/plain/x.global-ignored"
      printf 'roots = ["%s/root"]\n' "$FIX" > "$FIX/m.toml"
    }
    cleanup_fix() { rm -rf "$FIX"; unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'honors full ignore resolution inside the repo, deny-only outside'
      gitsweep() {
        source "$LIB/backup.zsh"
        bkp::manifest::files "$FIX/m.toml" | sort
      }
      When run gitsweep
      The line 1 should equal "$FIX/root/plain/x.global-ignored"
      The line 2 should equal "$FIX/root/repo/.gitignore"
      The line 3 should equal "$FIX/root/repo/tracked.txt"
      The line 4 should equal "$FIX/root/repo/untracked.txt"
      The lines of output should equal 4
    End

    It 'records the repo in the bundle plan with the root defaults'
      plan() {
        source "$LIB/backup.zsh"
        bkp::manifest::repos "$FIX/m.toml"
      }
      When run plan
      The output should equal "$FIX/root/repo${TAB}true${TAB}50m"
    End

    It 'carries per-root overrides into the plan'
      overrides() {
        source "$LIB/backup.zsh"
        printf 'roots = [ { path = "%s/root", bundle_unpushed = false } ]\n' \
          "$FIX" > "$FIX/m.toml"
        bkp::manifest::repos "$FIX/m.toml"
      }
      When run overrides
      The output should equal "$FIX/root/repo${TAB}false${TAB}50m"
    End

    It 'over-captures (minus .git) when git enumeration fails'
      brokegit() {
        source "$LIB/backup.zsh"
        printf '#!/bin/sh\nexit 128\n' > "$STUB/git"
        chmod +x "$STUB/git"
        rehash   # setup ran the real git; drop the stale command-hash entry
        bkp::manifest::files "$FIX/m.toml" | grep -c "root/repo/"
      }
      When run brokegit
      # All 6 repo files (incl. ignored ones) captured, .git skipped.
      The output should equal 6
      The stderr should include "over-capturing"
    End

    It 'skips tracked-but-deleted files (they exist in the index, not on disk)'
      phantom() {
        source "$LIB/backup.zsh"
        rm "$FIX/root/repo/tracked.txt"   # deleted from disk, still in the index
        bkp::manifest::files "$FIX/m.toml" | grep -c "root/repo/"
      }
      When run phantom
      # .gitignore + untracked.txt survive; the phantom tracked.txt does not.
      The output should equal 2
    End

    It 'treats a broken gitfile dir (vendored tarball) as a plain dir, quietly'
      brokenfile() {
        source "$LIB/backup.zsh"
        # lua-language-server tarballs ship submodule gitfiles pointing at a
        # gitdir that does not exist in the extracted tree.
        mkdir -p "$FIX/root/vendored"
        printf 'gitdir: ../../.git/modules/nope\n' > "$FIX/root/vendored/.git"
        print v > "$FIX/root/vendored/data.txt"
        bkp::manifest::files "$FIX/m.toml" | grep -c "vendored/data.txt"
        bkp::manifest::repos "$FIX/m.toml" | grep -c vendored || true
      }
      When run brokenfile
      The line 1 should equal 1
      The line 2 should equal 0
      The stderr should equal ""
    End
  End

  Describe 'shipped manifest.toml'
    MANIFEST="$SHELLSPEC_PROJECT_ROOT/home/dot_config/backup/manifest.toml"

    It 'parses, keeps the chezmoi filter on, and declares sane roots'
      shipped() {
        source "$LIB/backup.zsh"
        bkp::manifest::chezmoi_excluded "$MANIFEST" || return 1
        bkp::manifest::roots "$MANIFEST" | grep -c "^$HOME/"
        bkp::manifest::deny "$MANIFEST" | grep -Fc '.cache'
        # The Application Support BULK trap: never a broad root (Steam et al
        # live there); only config-bearing subdir roots are allowed.
        bkp::manifest::roots "$MANIFEST" |
          grep -c "^$HOME/Library/Application Support$(printf '\t')" || true
      }
      When run shipped
      The line 1 should equal 9
      The line 2 should equal 1
      The line 3 should equal 0
    End
  End

  Describe 'bkp::time::epoch'
    epoch() { source "$LIB/backup.zsh"; bkp::time::epoch "$1" && print -r -- "$REPLY"; }

    It 'parses UTC (Z)'
      When run epoch "2026-01-02T00:00:00Z"
      The output should equal 1767312000
    End
    It 'parses a negative offset'
      When run epoch "2026-01-01T17:00:00-07:00"
      The output should equal 1767312000
    End
    It 'parses a positive offset with fractional seconds'
      When run epoch "2026-01-02T07:30:00.123456+07:30"
      The output should equal 1767312000
    End
    It 'rejects garbage'
      When run epoch "not-a-time"
      The status should equal 2
      The stderr should include "bad timestamp"
    End
  End

  Describe 'bkp::restic::parse_snapshots'
    It 'converts restic snapshot JSON to id/epoch lines'
      parse() {
        source "$LIB/backup.zsh"
        printf '%s' '[{"id":"aaa","time":"2026-01-02T00:00:00Z"},{"id":"bbb","time":"2026-01-01T17:00:00.5-07:00"}]' |
          bkp::restic::parse_snapshots
      }
      When run parse
      The line 1 should equal "aaa${TAB}1767312000"
      The line 2 should equal "bbb${TAB}1767312000"
    End
    It 'errors on non-JSON input'
      badparse() { source "$LIB/backup.zsh"; print oops | bkp::restic::parse_snapshots; }
      When run badparse
      The status should equal 2
      The stderr should include "unparseable snapshot list"
    End
  End

  Describe 'bkp::config'
    setup_fix() { FIX=$(mktemp -d); }
    cleanup_fix() { rm -rf "$FIX"; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'reads staging path (~ expanded) and password command'
      cfg() {
        source "$LIB/backup.zsh"
        printf '[staging]\npath = "~/repo"\npassword_command = "sec get x"\n' > "$FIX/c.toml"
        bkp::config::staging_path "$FIX/c.toml"
        bkp::config::password_command "$FIX/c.toml"
      }
      When run cfg
      The line 1 should equal "$HOME/repo"
      The line 2 should equal "sec get x"
    End

    It 'fails loudly when config.toml is missing'
      nocfg() { source "$LIB/backup.zsh"; bkp::config::staging_path "$FIX/nope.toml"; }
      When run nocfg
      The status should equal 2
      The stderr should include "config not found"
    End

    It 'fails loudly when [staging] is incomplete'
      partial() {
        source "$LIB/backup.zsh"
        printf '[staging]\npath = "~/repo"\n' > "$FIX/c.toml"
        bkp::config::password_command "$FIX/c.toml"
      }
      When run partial
      The status should equal 2
      The stderr should include "password_command"
    End

    It 'ships a valid config.toml.example'
      example() {
        source "$LIB/backup.zsh"
        local ex="$SHELLSPEC_PROJECT_ROOT/home/dot_config/backup/config.toml.example"
        bkp::config::staging_path "$ex" >/dev/null &&
          bkp::config::password_command "$ex" >/dev/null &&
          print ok
      }
      When run example
      The output should equal ok
    End
  End

  Describe 'bkp::project — git history sidecar'
    setup_fix() {
      FIX=$(mktemp -d)
      export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$FIX/gitconfig"
      printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$FIX/gitconfig"
      export BKP_STATE_DIR="$FIX/state" BKP_WIP_DIR="$FIX/state/wip"
      REPO="$FIX/proj"
      mkdir -p "$REPO"
      git -C "$REPO" init -q
      print pushed > "$REPO/pushed.txt"
      git -C "$REPO" add pushed.txt
      git -C "$REPO" commit -qm pushed
      git clone -q --bare "$REPO" "$FIX/origin.git"
      git -C "$REPO" remote add origin "$FIX/origin.git"
      git -C "$REPO" fetch -q origin
      print unpushed > "$REPO/unpushed.txt"
      git -C "$REPO" add unpushed.txt
      git -C "$REPO" commit -qm unpushed
      print stashme > "$REPO/stash.txt"
      git -C "$REPO" add stash.txt
      git -C "$REPO" stash -q
    }
    cleanup_fix() { rm -rf "$FIX"; unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL BKP_STATE_DIR BKP_WIP_DIR; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'converts size specs to bytes'
      size() {
        source "$LIB/backup.zsh"
        local s
        for s in 50m 2g 512k 123; do
          bkp::size_bytes "$s" && print -r -- "$REPLY"
        done
      }
      When run size
      The line 1 should equal 52428800
      The line 2 should equal 2147483648
      The line 3 should equal 524288
      The line 4 should equal 123
    End

    It 'derives a stable, name-bearing repo id'
      rid() { source "$LIB/backup.zsh"; bkp::project::id "$REPO" && print -r -- "$REPLY"; }
      When run rid
      The output should match pattern "proj-????????????"
    End

    It 'bundles only unpushed history (fetchable, includes stash)'
      bundle() {
        source "$LIB/backup.zsh"
        bkp::project::bundle "$REPO" "$FIX/b.bundle" || return 1
        # The bundle must verify against a clone that has only pushed history…
        git clone -q "$FIX/origin.git" "$FIX/verify"
        git -C "$FIX/verify" bundle verify "$FIX/b.bundle" >/dev/null 2>&1 && print verifies
        # …and fetching it must materialize the unpushed commit + the stash.
        git -C "$FIX/verify" fetch -q "$FIX/b.bundle" 'refs/*:refs/bkp/*'
        git -C "$FIX/verify" cat-file -e "$(git -C "$REPO" rev-parse main)" && print has-unpushed
        git -C "$FIX/verify" cat-file -e "$(git -C "$REPO" rev-parse refs/stash)" && print has-stash
      }
      When run bundle
      The line 1 should equal "verifies"
      The line 2 should equal "has-unpushed"
      The line 3 should equal "has-stash"
    End

    It 'writes no bundle when everything is pushed'
      nobundle() {
        source "$LIB/backup.zsh"
        git -C "$REPO" stash drop -q
        git -C "$REPO" push -q origin main
        bkp::project::bundle "$REPO" "$FIX/b.bundle" && print "rc0"
        [ ! -e "$FIX/b.bundle" ] && print "no-file"
      }
      When run nobundle
      The line 1 should equal "rc0"
      The line 2 should equal "no-file"
    End

    It 'meta.json records path, branch, head, remotes, status and stashes'
      meta() {
        source "$LIB/backup.zsh"
        bkp::project::meta "$REPO" | jq -r '
          .path, .branch, (.head | length),
          (.remotes | length), (.stashes | length)'
      }
      When run meta
      The line 1 should equal "$REPO"
      The line 2 should equal "main"
      The line 3 should equal 40
      The line 4 should equal 2
      The line 5 should equal 1
    End

    It 'flags an untracked file over the per-root guard'
      warn() {
        source "$LIB/backup.zsh"
        dd if=/dev/zero of="$REPO/blob.bin" bs=1024 count=2 2>/dev/null
        bkp::project::warn_large "$REPO" 1k
      }
      When run warn
      The status should be success
      The stderr should include "large untracked file"
      The stderr should include "blob.bin"
    End

    It 'sidecar writes meta + bundle under BKP_WIP_DIR and never fails capture'
      sidecar() {
        source "$LIB/backup.zsh"
        bkp::project::sidecar "$REPO" true 50m || return 1
        local REPLY
        bkp::project::id "$REPO"
        [ -s "$BKP_WIP_DIR/$REPLY.meta.json" ] && print meta
        [ -s "$BKP_WIP_DIR/$REPLY.bundle" ] && print bundle
      }
      When run sidecar
      The line 1 should equal "meta"
      The line 2 should equal "bundle"
    End

    It 'sidecar honors bundle_unpushed=false (meta only)'
      nosidecarbundle() {
        source "$LIB/backup.zsh"
        bkp::project::sidecar "$REPO" false 50m || return 1
        local REPLY
        bkp::project::id "$REPO"
        [ -s "$BKP_WIP_DIR/$REPLY.meta.json" ] && print meta
        [ ! -e "$BKP_WIP_DIR/$REPLY.bundle" ] && print no-bundle
      }
      When run nosidecarbundle
      The line 1 should equal "meta"
      The line 2 should equal "no-bundle"
    End

    It 'restore-project round-trips: branch, head, unpushed commit, stash, clean tree'
      roundtrip() {
        source "$LIB/backup.zsh"
        local head_before
        head_before=$(git -C "$REPO" rev-parse HEAD)
        bkp::project::sidecar "$REPO" true 50m || return 1
        rm -rf "$REPO/.git"                       # the disaster
        bkp::project::restore "$REPO" >/dev/null || return 1
        git -C "$REPO" symbolic-ref --short HEAD
        [ "$(git -C "$REPO" rev-parse HEAD)" = "$head_before" ] && print same-head
        git -C "$REPO" log --format=%s | head -1
        git -C "$REPO" stash list | grep -c .
        [ -z "$(git -C "$REPO" status --porcelain)" ] && print clean
      }
      When run roundtrip
      The line 1 should equal "main"
      The line 2 should equal "same-head"
      The line 3 should equal "unpushed"
      The line 4 should equal 1
      The line 5 should equal "clean"
    End

    It 'restore-project works with no remote (full bundle)'
      noremote() {
        source "$LIB/backup.zsh"
        local R2="$FIX/solo"
        mkdir -p "$R2"
        git -C "$R2" init -q
        print only > "$R2/only.txt"
        git -C "$R2" add only.txt
        git -C "$R2" commit -qm solo
        local head_before
        head_before=$(git -C "$R2" rev-parse HEAD)
        bkp::project::sidecar "$R2" true 50m || return 1
        rm -rf "$R2/.git"
        bkp::project::restore "$R2" >/dev/null || return 1
        git -C "$R2" symbolic-ref --short HEAD
        [ "$(git -C "$R2" rev-parse HEAD)" = "$head_before" ] && print same-head
        [ -z "$(git -C "$R2" status --porcelain)" ] && print clean
      }
      When run noremote
      The line 1 should equal "main"
      The line 2 should equal "same-head"
      The line 3 should equal "clean"
    End

    It 'restore-project refuses when .git already exists'
      hasgit() {
        source "$LIB/backup.zsh"
        bkp::project::sidecar "$REPO" true 50m || return 1
        bkp::project::restore "$REPO"
      }
      When run hasgit
      The status should equal 3
      The stderr should include "already has a .git"
    End
  End

  Describe 'bkp::lock'
    setup_fix() { FIX=$(mktemp -d); export BKP_STATE_DIR="$FIX/state"; }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_STATE_DIR; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'a second process cannot take a held lock'
      locks() {
        source "$LIB/backup.zsh"
        bkp::lock capture || return 1
        print first
        zsh -c 'source "'"$LIB"'/backup.zsh"; bkp::lock capture' && print oops || print blocked
      }
      When run locks
      The line 1 should equal "first"
      The line 2 should equal "blocked"
    End

    It 'the lock dies with its holder'
      afterlife() {
        source "$LIB/backup.zsh"
        zsh -c 'source "'"$LIB"'/backup.zsh"; bkp::lock capture'   # exits, releasing
        bkp::lock capture && print free
      }
      When run afterlife
      The output should equal "free"
    End
  End

  Describe 'bkp::capture'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_STATE_DIR="$FIX/state" BKP_WIP_DIR="$FIX/state/wip"
      mkdir -p "$FIX/root"
      print data > "$FIX/root/f.txt"
      printf 'roots = ["%s/root"]\n' "$FIX" > "$FIX/m.toml"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      STUB="$FIX/stub"; mkdir -p "$STUB"
      printf '#!/bin/sh\nexit 0\n' > "$STUB/chezmoi"
      chmod +x "$STUB/chezmoi"
      PATH="$STUB:$PATH"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_STATE_DIR BKP_WIP_DIR; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    # Recorder stub: logs every bkp::restic call, fakes minimal behavior.
    # $FIX/has-repo controls `cat config`; snapshots return two same-cell
    # snapshots so thin must drop the older one.
    stub_restic() {
      bkp::restic() {
        local repo="$1"; shift
        print -r -- "$repo $*" >> "$FIX/calls"
        case "$1 ${2:-}" in
          'cat config')       [ -e "$FIX/has-repo" ] ;;
          'snapshots --json') printf '%s' '[{"id":"old1","time":"2026-01-02T10:01:00Z"},{"id":"new1","time":"2026-01-02T10:14:00Z"}]' ;;
          *) return 0 ;;
        esac
      }
    }

    It 'runs the full tick: init -> backup -> forget (drop ids only)'
      tick() {
        source "$LIB/backup.zsh"
        stub_restic
        bkp::capture::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null || return 1
        grep -c "^$FIX/repo init" "$FIX/calls"
        # MUST be the -verbatim variant: plain --files-from glob-expands each
        # line, so a captured file literally named "[.md" (tldr pages ship
        # one) kills the whole backup with Go's "syntax error in pattern".
        grep -c "^$FIX/repo backup --files-from-verbatim " "$FIX/calls"
        grep -- forget "$FIX/calls"
      }
      When run tick
      The line 1 should equal 1
      The line 2 should equal 1
      The line 3 should equal "$FIX/repo forget --quiet old1"
    End

    It 'skips init when the repo exists'
      noinit() {
        source "$LIB/backup.zsh"
        stub_restic
        : > "$FIX/has-repo"
        bkp::capture::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null || return 1
        grep -c init "$FIX/calls" || true
      }
      When run noinit
      The output should equal 0
    End

    It 'coalesces when the lock is held'
      held() {
        source "$LIB/backup.zsh"
        stub_restic
        bkp::lock capture || return 1
        zsh -c '
          source "'"$LIB"'/backup.zsh"
          bkp::restic() { print -r -- "$@" >> "'"$FIX"'/calls"; }
          bkp::capture::run "'"$FIX"'/m.toml" "'"$FIX"'/c.toml"
        ' >/dev/null 2>&1 && print coalesced   # rc 0, log_info chatter silenced
        [ ! -e "$FIX/calls" ] && print untouched
      }
      When run held
      The line 1 should equal "coalesced"
      The line 2 should equal "untouched"
    End

    It 'fails loudly without config'
      noconf() {
        source "$LIB/backup.zsh"
        stub_restic
        bkp::capture::run "$FIX/m.toml" "$FIX/absent.toml"
      }
      When run noconf
      The status should equal 2
      The stderr should include "config not found"
    End

    It 'sweeps once per tick (repo plan + file list share one pass)'
      onesweep() {
        source "$LIB/backup.zsh"
        stub_restic
        # counting chezmoi stub: each sweep queries `chezmoi managed` once
        printf '#!/bin/sh\necho x >> "%s"\nexit 0\n' "$FIX/chezmoi-calls" > "$STUB/chezmoi"
        chmod +x "$STUB/chezmoi"
        bkp::capture::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null || return 1
        grep -c x "$FIX/chezmoi-calls"
      }
      When run onesweep
      The output should equal 1
    End

    It 'captures fresh sidecars even when BKP_WIP_DIR is outside every root'
      wipcapture() {
        source "$LIB/backup.zsh"
        stub_restic
        # a real repo inside the root produces a sidecar in the (external) wip dir
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$FIX/gitconfig"
        printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$FIX/gitconfig"
        git -C "$FIX/root" init -q
        git -C "$FIX/root" add f.txt
        git -C "$FIX/root" commit -qm init
        files_from_capture() {  # intercept the file list restic receives
          bkp::restic() {
            local repo="$1"; shift
            case "$1 ${2:-}" in
              'cat config') return 1 ;;
              backup*)      cp "$3" "$FIX/captured-list"; return 0 ;;
              'snapshots --json') printf '[]' ;;
              *) return 0 ;;
            esac
          }
          bkp::capture::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null
        }
        files_from_capture || return 1
        grep -c "meta.json" "$FIX/captured-list"
      }
      When run wipcapture
      The output should equal 1
    End

    It 'BKP_PROGRESS=1 drops --quiet and narrates the phases'
      narrated() {
        source "$LIB/backup.zsh"
        stub_restic
        # keep gum out of the interactive path: the spinner is untestable
        # TUI noise here; the log-line fallback is the assertable behavior
        gum() { return 127 }
        export BKP_PROGRESS=1
        bkp::capture::run "$FIX/m.toml" "$FIX/c.toml" || return 1
        print -r -- "quiet-count:$(grep -- backup "$FIX/calls" | grep -c -- --quiet || true)"
      }
      When run narrated
      The output should include "resolving capture set"
      The output should include "capturing"
      The output should include "applying retention"
      The output should include "quiet-count:0"
    End

    It 'stays --quiet for the scheduled (non-interactive) path'
      scheduled() {
        source "$LIB/backup.zsh"
        stub_restic
        export BKP_PROGRESS=0
        bkp::capture::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null || return 1
        grep -- backup "$FIX/calls" | grep -c -- --quiet
      }
      When run scheduled
      The output should equal 1
    End

    It 'restic rc 3 (partial read) warns but keeps the tick alive'
      partial() {
        source "$LIB/backup.zsh"
        stub_restic
        bkp::restic() {
          local repo="$1"; shift
          case "$1 ${2:-}" in
            'cat config') return 1 ;;
            backup*)      return 3 ;;   # snapshot created, some files unreadable
            'snapshots --json') printf '[]' ;;
            *) return 0 ;;
          esac
        }
        bkp::capture::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null && print survived
      }
      When run partial
      The line 1 should equal "survived"
      The stderr should include "unreadable"
    End

    It 'other restic backup failures still fail the tick'
      hardfail() {
        source "$LIB/backup.zsh"
        bkp::restic() {
          local repo="$1"; shift
          case "$1 ${2:-}" in
            'cat config') return 1 ;;
            backup*)      return 1 ;;
            *) return 0 ;;
          esac
        }
        bkp::capture::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null
      }
      When run hardfail
      The status should equal 1
      The stdout should include ""
    End

    It 'worker --help prints usage without touching restic'
      whelp() {
        BKP_LIB="$LIB" zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup-capture" --help
      }
      When run whelp
      The status should be success
      The output should include "system-backup-capture"
      The output should include "--manifest"
    End
  End

  Describe 'bkp::config — targets'
    setup_fix() { FIX=$(mktemp -d); }
    cleanup_fix() { rm -rf "$FIX"; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'emits name/path/role with mirror default and ~ expansion'
      tgts() {
        source "$LIB/backup.zsh"
        cat > "$FIX/c.toml" <<'EOF'
[staging]
path = "~/repo"
password_command = "echo pw"
[[target]]
name = "ssd"
path = "/Volumes/X/tb"
role = "master"
[[target]]
name = "onedrive"
path = "~/OneDrive/tb"
EOF
        bkp::config::targets "$FIX/c.toml"
      }
      When run tgts
      The line 1 should equal "ssd${TAB}/Volumes/X/tb${TAB}master"
      The line 2 should equal "onedrive${TAB}$HOME/OneDrive/tb${TAB}mirror"
    End

    It 'is empty (rc 0) for a staging-only config'
      none() {
        source "$LIB/backup.zsh"
        printf '[staging]\npath = "~/r"\npassword_command = "e"\n' > "$FIX/c.toml"
        bkp::config::targets "$FIX/c.toml" && print ok
      }
      When run none
      The output should equal "ok"
    End

    It 'rejects a target without a path'
      nopath() {
        source "$LIB/backup.zsh"
        printf '[[target]]\nname = "ssd"\n' > "$FIX/c.toml"
        bkp::config::targets "$FIX/c.toml"
      }
      When run nopath
      The status should equal 2
      The stderr should include "invalid [[target]]"
    End

    It 'rejects an unknown role'
      badrole() {
        source "$LIB/backup.zsh"
        printf '[[target]]\nname = "s"\npath = "/x"\nrole = "weird"\n' > "$FIX/c.toml"
        bkp::config::targets "$FIX/c.toml"
      }
      When run badrole
      The status should equal 2
      The stderr should include "invalid [[target]]"
    End
  End

  Describe 'bkp::target::present'
    setup_fix() { FIX=$(mktemp -d); }
    cleanup_fix() { chmod -R u+w "$FIX" 2>/dev/null; rm -rf "$FIX"; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'present when the parent exists and is writable'
      yes() { source "$LIB/backup.zsh"; mkdir -p "$FIX/vol"; bkp::target::present "$FIX/vol/repo" && print present; }
      When run yes
      The output should equal "present"
    End
    It 'absent when the parent is missing'
      nodir() { source "$LIB/backup.zsh"; bkp::target::present "$FIX/gone/repo" || print absent; }
      When run nodir
      The output should equal "absent"
    End
    It 'absent when the parent is not writable'
      rodir() {
        source "$LIB/backup.zsh"
        mkdir -p "$FIX/ro"
        chmod 555 "$FIX/ro"
        bkp::target::present "$FIX/ro/repo" || print absent
      }
      When run rodir
      The output should equal "absent"
    End
  End

  Describe 'bkp::reconcile — planner'
    It 'identity-matched copies produce no ops'
      noop() {
        source "$LIB/backup.zsh"
        # target s1c is a copy of staging s1 (original=s1): already converged.
        bkp::reconcile::plan $'s1\ts1' $'s1c\ts1' && print converged
      }
      When run noop
      The output should equal "converged"
    End

    It 'pushes staging-only and pulls target-only raw ids, sorted'
      diverged() {
        source "$LIB/backup.zsh"
        bkp::reconcile::plan $'s1\ts1\ns2\ts2\nb9\ta0' $'s1c\ts1\nt7\tt7'
      }
      When run diverged
      The line 1 should equal "push${TAB}b9"
      The line 2 should equal "push${TAB}s2"
      The line 3 should equal "pull${TAB}t7"
      The lines of output should equal 3
    End

    It 'is empty for empty inputs'
      empty() { source "$LIB/backup.zsh"; bkp::reconcile::plan '' '' && print none; }
      When run empty
      The output should equal "none"
    End

    It 'snapshot_keys emits raw id + identity (original wins)'
      keys() {
        source "$LIB/backup.zsh"
        bkp::restic() {
          printf '%s' '[{"id":"aaa","time":"t"},{"id":"bbb","original":"orig1","time":"t"}]'
        }
        bkp::restic::snapshot_keys /any
      }
      When run keys
      The line 1 should equal "aaa${TAB}aaa"
      The line 2 should equal "bbb${TAB}orig1"
    End
  End

  Describe 'bkp::reconcile — engine'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_STATE_DIR="$FIX/state" BKP_CONFIG="$FIX/c.toml"
      printf 'roots = []\n' > "$FIX/m.toml"
      printf '[staging]\npath = "%s/stg"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      # staging: s1 (10:01) + s2 (10:14); target: s1-copy + its own t9 (Jan 1).
      printf '%s' '[{"id":"s1","time":"2026-01-02T10:01:00Z"},{"id":"s2","time":"2026-01-02T10:14:00Z"}]' > "$FIX/stg.json"
      printf '%s' '[{"id":"s1c","original":"s1","time":"2026-01-02T10:01:00Z"},{"id":"t9","time":"2026-01-01T09:00:00Z"}]' > "$FIX/tgt.json"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_STATE_DIR BKP_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    # Recorder stub keyed by repo basename: <base>.json feeds snapshots,
    # $FIX/has-<base> makes `cat config` succeed (repo "exists").
    stub_restic() {
      bkp::restic() {
        local repo="$1"; shift
        print -r -- "$repo $*" >> "$FIX/calls"
        case "$1 ${2:-}" in
          'cat config')       [ -e "$FIX/has-${repo:t}" ] ;;
          'snapshots --json') cat "$FIX/${repo:t}.json" 2>/dev/null || printf '[]' ;;
          *) return 0 ;;
        esac
      }
    }

    It 'converges a fresh mirror target and applies retention'
      mirror() {
        source "$LIB/backup.zsh"
        stub_restic
        bkp::reconcile::one "$FIX/stg" tgt "$FIX/tgt" mirror "$FIX/m.toml" >/dev/null || return 1
        grep -c -- "--copy-chunker-params" "$FIX/calls"
        grep -- "copy --from-repo $FIX/stg" "$FIX/calls" | grep -c " s2$"
        grep -- "copy --from-repo $FIX/tgt" "$FIX/calls" | grep -c " t9$"
        grep -- forget "$FIX/calls"
      }
      When run mirror
      The line 1 should equal 1
      The line 2 should equal 1
      The line 3 should equal 1
      The line 4 should equal "$FIX/tgt forget --quiet t9"
    End

    It 'master role converges without forgetting'
      master() {
        source "$LIB/backup.zsh"
        stub_restic
        bkp::reconcile::one "$FIX/stg" tgt "$FIX/tgt" master "$FIX/m.toml" >/dev/null || return 1
        grep -c -- "copy --from-repo" "$FIX/calls"
        grep -c forget "$FIX/calls" || true
      }
      When run master
      The line 1 should equal 2
      The line 2 should equal 0
    End

    It 'an already-converged pair copies nothing'
      converged() {
        source "$LIB/backup.zsh"
        stub_restic
        : > "$FIX/has-tgt"
        printf '%s' '[{"id":"s1","time":"2026-01-02T10:01:00Z"}]' > "$FIX/stg.json"
        printf '%s' '[{"id":"s1c","original":"s1","time":"2026-01-02T10:01:00Z"}]' > "$FIX/tgt.json"
        bkp::reconcile::one "$FIX/stg" tgt "$FIX/tgt" mirror "$FIX/m.toml" >/dev/null || return 1
        grep -c -- "copy" "$FIX/calls" || true
      }
      When run converged
      The output should equal 0
    End

    It 'run skips absent targets and reconciles present ones'
      pass() {
        source "$LIB/backup.zsh"
        stub_restic
        cat >> "$FIX/c.toml" <<EOF
[[target]]
name = "tgt"
path = "$FIX/tgt"
[[target]]
name = "ghost"
path = "$FIX/gone/tb"
EOF
        bkp::reconcile::run "$FIX/m.toml" "$FIX/c.toml" | grep -c "ghost' absent"
        grep -c "^$FIX/tgt copy\|^$FIX/stg copy" "$FIX/calls"
      }
      When run pass
      The line 1 should equal 1
      The line 2 should equal 2
    End

    It 'prune hits staging + present initialized mirrors only'
      prunes() {
        source "$LIB/backup.zsh"
        stub_restic
        mkdir -p "$FIX/mastertb"
        : > "$FIX/has-tgt"
        cat >> "$FIX/c.toml" <<EOF
[[target]]
name = "tgt"
path = "$FIX/tgt"
[[target]]
name = "arch"
path = "$FIX/mastertb/repo"
role = "master"
[[target]]
name = "ghost"
path = "$FIX/gone/tb"
EOF
        bkp::reconcile::prune "$FIX/c.toml" >/dev/null || return 1
        grep -c "prune" "$FIX/calls"
        grep "prune" "$FIX/calls" | head -2
      }
      When run prunes
      The line 1 should equal 2
      The line 2 should equal "$FIX/stg prune --quiet"
      The line 3 should equal "$FIX/tgt prune --quiet"
    End

    It 'worker --help prints usage'
      rhelp() {
        BKP_LIB="$LIB" zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup-reconcile" --help
      }
      When run rhelp
      The status should be success
      The output should include "system-backup-reconcile"
      The output should include "--prune"
    End

    It 'bkp::tick captures then reconciles in one pass'
      tick2() {
        source "$LIB/backup.zsh"
        stub_restic
        mkdir -p "$FIX/root"
        print d > "$FIX/root/f.txt"
        STUB2="$FIX/stub2"; mkdir -p "$STUB2"
        printf '#!/bin/sh\nexit 0\n' > "$STUB2/chezmoi"
        chmod +x "$STUB2/chezmoi"
        PATH="$STUB2:$PATH"
        cat > "$FIX/c2.toml" <<EOF
[staging]
path = "$FIX/stg"
password_command = "echo pw"
[[target]]
name = "tgt"
path = "$FIX/tgt"
EOF
        printf 'roots = ["%s/root"]\n' "$FIX" > "$FIX/m2.toml"
        rm -f "$FIX/stg.json" "$FIX/tgt.json"   # stub falls back to []
        bkp::tick "$FIX/m2.toml" "$FIX/c2.toml" >/dev/null || return 1
        grep -c "backup --files-from" "$FIX/calls"
        grep -c "^$FIX/tgt init" "$FIX/calls"
      }
      When run tick2
      The line 1 should equal 1
      The line 2 should equal 1
    End

    It 'workers no-op cleanly on an unconfigured machine'
      unconf() {
        BKP_LIB="$LIB" zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup-capture" \
          --config "$FIX/never-created.toml" --manifest "$FIX/m.toml" && print cap-ok
        BKP_LIB="$LIB" zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup-reconcile" \
          --config "$FIX/never-created.toml" --manifest "$FIX/m.toml" && print rec-ok
      }
      When run unconf
      The line 1 should include "not configured"
      The line 2 should equal "cap-ok"
      The line 3 should include "not configured"
      The line 4 should equal "rec-ok"
    End

    It 'capture worker --help documents --reconcile'
      chelp() {
        BKP_LIB="$LIB" zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup-capture" --help
      }
      When run chelp
      The status should be success
      The output should include "--reconcile"
    End
  End

  Describe 'bkp::ux — read side'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_STATE_DIR="$FIX/state" BKP_CONFIG="$FIX/c.toml"
      printf 'roots = []\n' > "$FIX/m.toml"
      cat > "$FIX/c.toml" <<EOF
[staging]
path = "$FIX/stg"
password_command = "echo pw"
[[target]]
name = "here"
path = "$FIX/tgt"
[[target]]
name = "ghost"
path = "$FIX/gone/tb"
role = "master"
EOF
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_STATE_DIR BKP_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    stub_restic() {
      bkp::restic() {
        local repo="$1"; shift
        print -r -- "$repo $*" >> "$FIX/calls"
        case "$1 ${2:-}" in
          'cat config')       [ -e "$FIX/has-${repo:t}" ] ;;
          'snapshots --json') cat "$FIX/${repo:t}.json" 2>/dev/null || printf '[]' ;;
          check*)             [ ! -e "$FIX/check-fails" ] ;;
          *) return 0 ;;
        esac
      }
    }

    It 'labels tiers by age band'
      tiers() {
        source "$LIB/backup.zsh"
        local REPLY
        bkp::thin::tier_of 1767312000 1767311000 && print -r -- "$REPLY"   # ~17m -> 30m
        bkp::thin::tier_of 1767312000 1767225600 && print -r -- "$REPLY"   # 24h -> 1h
        bkp::thin::tier_of 1767312000 1727312000 && print -r -- "$REPLY"   # ~463d -> year
      }
      When run tiers
      The line 1 should equal "30m"
      The line 2 should equal "1h"
      The line 3 should equal "year"
    End

    It 'humanizes ages'
      ages() {
        source "$LIB/backup.zsh"
        local REPLY s
        for s in 300 7200 259200; do
          bkp::ux::age "$s" && print -r -- "$REPLY"
        done
      }
      When run ages
      The line 1 should equal "5m"
      The line 2 should equal "2h"
      The line 3 should equal "3d"
    End

    It 'lists snapshots with tier labels'
      lists() {
        source "$LIB/backup.zsh"
        stub_restic
        printf '%s' '[{"id":"aaaabbbbcccc","time":"2026-01-02T10:00:00Z"}]' > "$FIX/stg.json"
        bkp::ux::list "$FIX/m.toml" "$FIX/c.toml"
      }
      When run lists
      The line 1 should include "aaaabbbb"
      The line 1 should include "2026-01-02"
      The line 1 should match pattern "*[mhd]	*"
    End

    It 'shows target presence as dots'
      dots() {
        source "$LIB/backup.zsh"
        bkp::ux::targets "$FIX/c.toml"
      }
      When run dots
      The line 1 should equal "●${TAB}here${TAB}mirror${TAB}$FIX/tgt"
      The line 2 should equal "○${TAB}ghost${TAB}master${TAB}$FIX/gone/tb"
    End

    It 'status reports staging, snapshot count and targets'
      stat() {
        source "$LIB/backup.zsh"
        stub_restic
        printf '%s' '[{"id":"aaa","time":"2026-01-02T10:00:00Z"},{"id":"bbb","time":"2026-01-02T11:00:00Z"}]' > "$FIX/stg.json"
        bkp::ux::status "$FIX/m.toml" "$FIX/c.toml"
      }
      When run stat
      The line 1 should equal "staging: $FIX/stg"
      The line 2 should include "snapshots: 2 (latest"
      The line 3 should include "here"
    End

    It 'status survives the dispatcher shell options (set -eu -o pipefail)'
      # Regression: `(( count++ ))` post-increments from 0, the expression
      # evaluates to 0 → exit status 1 → errexit killed status mid-function
      # when run under the dispatcher (which sets -eu -o pipefail).
      strict() {
        zsh -c '
          set -eu -o pipefail
          source "$1/backup.zsh"
          bkp::restic() { printf "%s" "[{\"id\":\"aaa\",\"time\":\"2026-01-02T10:00:00Z\"}]"; }
          bkp::ux::status "$2" "$3"
        ' _ "$LIB" "$FIX/m.toml" "$FIX/c.toml"
      }
      When run strict
      The status should be success
      The line 2 should include "snapshots: 1"
      The line 3 should include "here"
    End

    It 'verify checks staging + present initialized targets, propagating failure'
      checks() {
        source "$LIB/backup.zsh"
        stub_restic
        : > "$FIX/has-tgt"
        bkp::ux::verify "$FIX/c.toml" >/dev/null && print all-ok
        : > "$FIX/check-fails"
        bkp::ux::verify "$FIX/c.toml" >/dev/null || print failed
        grep -c "check" "$FIX/calls"
      }
      When run checks
      The line 1 should equal "all-ok"
      The line 2 should equal "failed"
      The line 3 should equal 4
    End
  End

  Describe 'bkp::restore — undoable restores'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_STATE_DIR="$FIX/state" BKP_CONFIG="$FIX/c.toml"
      printf 'roots = []\n' > "$FIX/m.toml"
      printf '[staging]\npath = "%s/stg"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_STATE_DIR BKP_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    stub_restic() {
      bkp::restic() {
        local repo="$1"; shift
        print -r -- "$repo $*" >> "$FIX/calls"
        case "$1 ${2:-}" in
          'snapshots --json') cat "$FIX/stg.json" 2>/dev/null || printf '[]' ;;
          *) return 0 ;;
        esac
      }
    }

    It 'refuses to overwrite an existing path without --force'
      refuse() {
        source "$LIB/backup.zsh"
        stub_restic
        print live > "$FIX/f.txt"
        bkp::restore::paths abc123 "$FIX/f.txt"
      }
      When run refuse
      The status should equal 3
      The stderr should include "refusing to overwrite"
    End

    It 'takes the undo snapshot BEFORE restoring, with --force'
      order() {
        source "$LIB/backup.zsh"
        stub_restic
        print live > "$FIX/f.txt"
        bkp::restore::paths abc123 --force "$FIX/f.txt" >/dev/null || return 1
        awk '/bkp-undo/ {u = NR} /restore/ {r = NR} END {print ((u && r && u < r) ? "undo-first" : "wrong")}' "$FIX/calls"
        grep -- "restore abc123 --target / --include $FIX/f.txt" "$FIX/calls" >/dev/null && print restored
      }
      When run order
      The line 1 should equal "undo-first"
      The line 2 should equal "restored"
    End

    It 'skips the undo snapshot when nothing would be overwritten'
      fresh() {
        source "$LIB/backup.zsh"
        stub_restic
        bkp::restore::paths abc123 "$FIX/new-file.txt" >/dev/null || return 1
        grep -c "bkp-undo" "$FIX/calls" || true
      }
      When run fresh
      The output should equal 0
    End

    It 'undo restores the newest bkp-undo snapshot and forgets it'
      peel() {
        source "$LIB/backup.zsh"
        stub_restic
        printf '%s' '[{"id":"u-old","time":"2026-01-01T09:00:00Z","tags":["bkp-undo"]},{"id":"u-new","time":"2026-01-02T09:00:00Z","tags":["bkp-undo"]}]' > "$FIX/stg.json"
        bkp::restore::undo >/dev/null || return 1
        grep -- "restore u-new --target /" "$FIX/calls" >/dev/null && print restored
        grep -- "forget --quiet u-new" "$FIX/calls" >/dev/null && print forgotten
      }
      When run peel
      The line 1 should equal "restored"
      The line 2 should equal "forgotten"
    End

    It 'undo with no undo snapshots fails loudly'
      nothing() {
        source "$LIB/backup.zsh"
        stub_restic
        bkp::restore::undo
      }
      When run nothing
      The status should equal 1
      The stderr should include "nothing to undo"
    End

    It 'thin excludes undo snapshots from the ladder and expires old ones'
      isolate() {
        source "$LIB/backup.zsh"
        stub_restic
        local fresh_ts
        TZ=UTC strftime -s fresh_ts '%Y-%m-%dT%H:%M:%SZ' $(( EPOCHSECONDS - 3600 ))
        cat > "$FIX/stg.json" <<EOF
[{"id":"old1","time":"2026-01-02T10:01:00Z"},
 {"id":"new1","time":"2026-01-02T10:14:00Z"},
 {"id":"u-stale","time":"2026-01-02T10:20:00Z","tags":["bkp-undo"]},
 {"id":"u-fresh","time":"$fresh_ts","tags":["bkp-undo"]}]
EOF
        bkp::capture::thin "$FIX/stg" "$FIX/m.toml" >/dev/null || return 1
        local forget
        forget=$(grep -- forget "$FIX/calls")
        case "$forget" in
          *old1*) print drops-old1 ;;
        esac
        case "$forget" in
          *u-stale*) print drops-stale-undo ;;
        esac
        case "$forget" in
          *u-fresh*) print BAD ;;
          *) print keeps-fresh-undo ;;
        esac
        case "$forget" in
          *new1*) print BAD ;;
          *) print keeps-new1 ;;
        esac
      }
      When run isolate
      The line 1 should equal "drops-old1"
      The line 2 should equal "drops-stale-undo"
      The line 3 should equal "keeps-fresh-undo"
      The line 4 should equal "keeps-new1"
    End
  End

  Describe 'bkp::ux — browse/diff plumbing'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_STATE_DIR="$FIX/state" BKP_CONFIG="$FIX/c.toml"
      printf '[staging]\npath = "%s/stg"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      STUB="$FIX/stub"; mkdir -p "$STUB"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_STATE_DIR BKP_CONFIG BKP_HAS_FUSE; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'mount waits for the FUSE tree and reports the pid'
      mounts() {
        source "$LIB/backup.zsh"
        bkp::restic() {
          local repo="$1"; shift
          case "$1" in
            mount) mkdir -p "$2/snapshots"; sleep 3 ;;
            *) return 0 ;;
          esac
        }
        local REPLY
        bkp::mount "$FIX/stg" "$FIX/mp" || return 1
        [ -d "$FIX/mp/snapshots" ] && print mounted
        kill -0 "$REPLY" 2>/dev/null && print alive
        kill "$REPLY" 2>/dev/null
      }
      When run mounts
      The line 1 should equal "mounted"
      The line 2 should equal "alive"
    End

    It 'mount fails cleanly when restic dies'
      badmount() {
        source "$LIB/backup.zsh"
        bkp::restic() { return 1 }
        bkp::mount "$FIX/stg" "$FIX/mp"
      }
      When run badmount
      The status should equal 1
      The stderr should include "did not come up"
    End

    It 'diff dumps both snapshots and pipes them to the viewer'
      # hunk stubbed as plain `diff -u` so nothing interactive launches and
      # the viewer branch is exercised with deterministic output.
      diffs() {
        source "$LIB/backup.zsh"
        printf '#!/bin/sh\nshift\nexec diff -u "$@"\n' > "$STUB/hunk"
        chmod +x "$STUB/hunk"
        bkp::restic() {
          local repo="$1"; shift
          case "$1 ${2:-}" in
            'dump snapA') print old ;;
            'dump snapB') print new ;;
            *) return 0 ;;
          esac
        }
        PATH="$STUB:$PATH" bkp::ux::diff "$FIX/f.txt" snapA snapB
      }
      When run diffs
      The status should be success
      The output should include "-old"
      The output should include "+new"
    End

    It 'diff against the live file needs only one dump'
      livediff() {
        source "$LIB/backup.zsh"
        printf '#!/bin/sh\nshift\nexec diff -u "$@"\n' > "$STUB/hunk"
        chmod +x "$STUB/hunk"
        print live-content > "$FIX/f.txt"
        bkp::restic() {
          local repo="$1"; shift
          case "$1 ${2:-}" in
            'dump snapA') print old ;;
            *) return 0 ;;
          esac
        }
        PATH="$STUB:$PATH" bkp::ux::diff "$FIX/f.txt" snapA
      }
      When run livediff
      The status should be success
      The output should include "+live-content"
    End
  End

  Describe 'system-backup dispatcher + tm'
    DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup"
    TMFN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/functions.d/tm.sh"

    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_STATE_DIR="$FIX/state" BKP_CONFIG="$FIX/c.toml" BKP_LIB="$LIB"
      cat > "$FIX/c.toml" <<EOF
[staging]
path = "$FIX/stg"
password_command = "echo pw"
[[target]]
name = "ghost"
path = "$FIX/gone/tb"
EOF
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_STATE_DIR BKP_CONFIG BKP_LIB; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'top-level help lists every subcommand'
      When run zsh "$DISPATCH" --help
      The status should be success
      The output should include "status"
      The output should include "restore-project"
      The output should include "verify"
      The output should include "tm"
    End

    It 'dies on an unknown subcommand'
      When run zsh "$DISPATCH" frobnicate
      The status should equal 1
      The stderr should include "unknown subcommand"
      The output should include "Usage"
    End

    It 'restore --help documents --snapshot and --force'
      When run zsh "$DISPATCH" restore --help
      The status should be success
      The output should include "--snapshot"
      The output should include "--force"
    End

    It 'targets renders the presence table without touching restic'
      When run zsh "$DISPATCH" targets
      The status should be success
      The output should include "○"
      The output should include "ghost"
    End

    It 'is loud when unconfigured (a human asked)'
      loud() {
        BKP_CONFIG="$FIX/nope.toml" zsh "$DISPATCH" status
      }
      When run loud
      The status should equal 1
      The stderr should include "not configured"
    End

    It 'restore demands a snapshot id and paths'
      When run zsh "$DISPATCH" restore /some/path
      The status should equal 1
      The stderr should include "--snapshot"
    End

    It 'tm maps its forms onto system-backup browse'
      tmmap() {
        STUB="$FIX/stub"; mkdir -p "$STUB"
        cat > "$STUB/system-backup" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$FIX/tm-calls"
EOF
        chmod +x "$STUB/system-backup"
        PATH="$STUB:$PATH"
        source "$TMFN"
        cd "$FIX"
        tm
        tm /x/file.txt
        tm --deleted
        cat "$FIX/tm-calls"
      }
      When run tmmap
      The line 1 should equal "browse $FIX"
      The line 2 should equal "browse /x/file.txt"
      The line 3 should equal "browse --deleted $FIX"
    End

    It 'browse launches a one-pane explore scrub session under FUSE'
      run_it() {
        STUB="$FIX/stub"; mkdir -p "$STUB"
        printf '#!/bin/sh\necho "zellij $*" >> "%s/zj.calls"\n' "$FIX" > "$STUB/zellij"
        chmod +x "$STUB/zellij"
        cat > "$FIX/snaps.json" <<'JSON'
[{"id":"cccc000000000000000000000000000000000000000000000000000000000000","time":"2026-07-03T10:00:00Z"}]
JSON
        printf '#!/bin/sh\ncase "$1 $2" in\n  "snapshots --json") cat "%s/snaps.json" ;;\n  mount*) mkdir -p "$2/snapshots"; sleep 3 ;;\n  *) exit 0 ;;\nesac\n' "$FIX" > "$STUB/restic"
        chmod +x "$STUB/restic"
        printf 'roots = []\n' > "$FIX/m.toml"
        mkdir -p "$FIX/anchor"
        printf '#!/bin/sh\necho "tm $*" >> "%s/tm.calls"\n' "$FIX" > "$STUB/system-backup-tm"
        chmod +x "$STUB/system-backup-tm"
        PATH="$STUB:$PATH" BKP_HAS_FUSE=1 BKP_TM_SESSIONS="$FIX/sessions" BKP_MANIFEST="$FIX/m.toml" \
          BKP_TM_BIN="$STUB/system-backup-tm" ZELLIJ=1 \
          zsh "$DISPATCH" browse "$FIX/anchor"
        cat "$FIX/tm.calls"
        [ -f "$FIX/zj.calls" ] && cat "$FIX/zj.calls" || echo no-zellij-calls
      }
      When run run_it
      The status should be success
      # explore is ONE pane: yazi (in-column timeline) takes over the
      # invoking pane — no split, no timeline pane
      The output should include "tm lens"
      The output should include "no-zellij-calls"
      The output should not include "tm timeline"
    End

    It 'browse launches a zellij scrub session tab for a diff dir anchor without FUSE'
      run_it() {
        STUB="$FIX/stub"; mkdir -p "$STUB"
        printf '#!/bin/sh\necho "zellij $*" >> "%s/zj.calls"\n' "$FIX" > "$STUB/zellij"
        chmod +x "$STUB/zellij"
        cat > "$FIX/snaps.json" <<'JSON'
[{"id":"cccc000000000000000000000000000000000000000000000000000000000000","time":"2026-07-03T10:00:00Z"}]
JSON
        printf '#!/bin/sh\ncase "$1 $2" in\n  "snapshots --json") cat "%s/snaps.json" ;;\n  *) exit 0 ;;\nesac\n' "$FIX" > "$STUB/restic"
        chmod +x "$STUB/restic"
        printf 'roots = []\n' > "$FIX/m.toml"
        mkdir -p "$FIX/anchor"
        printf '#!/bin/sh\necho "tm $*" >> "%s/tm.calls"\n' "$FIX" > "$STUB/system-backup-tm"
        chmod +x "$STUB/system-backup-tm"
        PATH="$STUB:$PATH" BKP_HAS_FUSE=0 BKP_TM_SESSIONS="$FIX/sessions" BKP_MANIFEST="$FIX/m.toml" \
          BKP_TM_BIN="$STUB/system-backup-tm" ZELLIJ=1 \
          zsh "$DISPATCH" browse --diff "$FIX/anchor"
        cat "$FIX/zj.calls" "$FIX/tm.calls"
      }
      When run run_it
      The status should be success
      The output should include "run --close-on-exit --direction right"
      The output should include "tm timeline"
    End
  End

  Describe 'declared backup agents (services.toml.tmpl)'
    TMPL="$SHELLSPEC_PROJECT_ROOT/home/dot_config/packages/services.toml.tmpl"
    no_chezmoi() { ! command -v chezmoi >/dev/null 2>&1; }
    Skip if 'chezmoi unavailable' no_chezmoi

    It 'declares capture/reconcile/prune with the spec §6 schedule'
      agents() {
        chezmoi execute-template < "$TMPL" | yq -p toml -o json '.' | jq -r '
          (."backup-capture".cmd | join(" ")),
          ."backup-capture".start_interval,
          ."backup-capture".process_type,
          ."backup-reconcile".cmd[0],
          (."backup-reconcile".watch_paths | join(",")),
          ."backup-reconcile".start_interval,
          (."backup-prune".cmd | join(" ")),
          ."backup-prune".start_calendar_interval.Hour'
      }
      When run agents
      The line 1 should equal "system-backup-capture --reconcile"
      The line 2 should equal 1800
      The line 3 should equal "Background"
      The line 4 should equal "system-backup-reconcile"
      The line 5 should equal "/Volumes,~/Library/CloudStorage"
      The line 6 should equal 3600
      The line 7 should equal "system-backup-reconcile --prune"
      The line 8 should equal 3
    End
  End

  Describe 'integration smoke — real restic (BKP_SMOKE=1)'
    Skip if 'BKP_SMOKE != 1 (run: BKP_SMOKE=1 shellspec tests/backup_spec.sh)' \
      test "${BKP_SMOKE:-0}" != 1

    It 'capture -> thin/forget -> restore round-trips'
      smoke() {
        source "$LIB/backup.zsh"
        FIX=$(mktemp -d)
        export BKP_STATE_DIR="$FIX/state" BKP_WIP_DIR="$FIX/state/wip"
        mkdir -p "$FIX/root"
        print hello > "$FIX/root/f.txt"
        # Glob-metacharacter filename: tldr pages ship a literal "[.md"; it
        # must ride --files-from-verbatim without aborting the backup.
        print bracket > "$FIX/root/[.md"
        printf 'roots = ["%s/root"]\n' "$FIX" > "$FIX/m.toml"
        printf '[staging]\npath = "%s/repo"\npassword_command = "echo smoke-pass"\n' "$FIX" > "$FIX/c.toml"
        run_tick() {  # fresh process per tick: the run-lock is process-lifetime
          zsh -c 'source "$1/backup.zsh"; bkp::capture::run "$2" "$3"' _ "$LIB" "$FIX/m.toml" "$FIX/c.toml"
        }
        run_tick >/dev/null || return 1
        print world >> "$FIX/root/f.txt"
        run_tick >/dev/null || return 1
        RESTIC_REPOSITORY="$FIX/repo" RESTIC_PASSWORD_COMMAND="echo smoke-pass" \
          restic snapshots --json 2>/dev/null | jq length
        RESTIC_REPOSITORY="$FIX/repo" RESTIC_PASSWORD_COMMAND="echo smoke-pass" \
          restic restore latest --target "$FIX/out" --quiet >/dev/null 2>&1
        cat "$FIX/out$FIX/root/f.txt"
        cat "$FIX/out$FIX/root/[.md"
        rm -rf "$FIX"
      }
      When run smoke
      # 1 when both ticks land in one 30-min cell (thin dropped the older);
      # 2 in the rare tick-straddles-:00/:30 run. Restore is deterministic.
      The line 1 should match pattern "[12]"
      The line 2 should equal "hello"
      The line 3 should equal "world"
      The line 4 should equal "bracket"
      The stderr should be defined   # restic/log chatter allowed, not required
    End

    It 'reconcile converges a target and is idempotent (real restic copy)'
      rsmoke() {
        source "$LIB/backup.zsh"
        FIX=$(mktemp -d)
        export BKP_STATE_DIR="$FIX/state" BKP_WIP_DIR="$FIX/state/wip"
        mkdir -p "$FIX/root"
        print hello > "$FIX/root/f.txt"
        printf 'roots = ["%s/root"]\n' "$FIX" > "$FIX/m.toml"
        cat > "$FIX/c.toml" <<EOF
[staging]
path = "$FIX/repo"
password_command = "echo smoke-pass"
[[target]]
name = "tmp"
path = "$FIX/tgt"
EOF
        run_in_proc() {  # fresh process per op: locks are process-lifetime
          zsh -c 'source "$1/backup.zsh"; "$2" "$3" "$4"' _ "$LIB" "$@"
        }
        run_in_proc bkp::capture::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null 2>&1 || return 1
        run_in_proc bkp::reconcile::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null 2>&1 || return 1
        tsnaps() {
          RESTIC_REPOSITORY="$FIX/tgt" RESTIC_PASSWORD_COMMAND="echo smoke-pass" \
            restic snapshots --json 2>/dev/null | jq length
        }
        n1=$(tsnaps)
        run_in_proc bkp::reconcile::run "$FIX/m.toml" "$FIX/c.toml" >/dev/null 2>&1 || return 1
        n2=$(tsnaps)
        print "$n1 $n2"
        [ "$n1" = "$n2" ] && print idempotent
        RESTIC_REPOSITORY="$FIX/tgt" RESTIC_PASSWORD_COMMAND="echo smoke-pass" \
          restic restore latest --target "$FIX/out" --quiet >/dev/null 2>&1
        cat "$FIX/out$FIX/root/f.txt"
        rm -rf "$FIX"
      }
      When run rsmoke
      The line 1 should equal "1 1"
      The line 2 should equal "idempotent"
      The line 3 should equal "hello"
      The stderr should be defined
    End

    It 'restore --force is undoable (real restic round-trip)'
      usmoke() {
        source "$LIB/backup.zsh"
        FIX=$(mktemp -d)
        export BKP_STATE_DIR="$FIX/state" BKP_WIP_DIR="$FIX/state/wip" BKP_CONFIG="$FIX/c.toml"
        mkdir -p "$FIX/root"
        print v1 > "$FIX/root/f.txt"
        printf 'roots = ["%s/root"]\n' "$FIX" > "$FIX/m.toml"
        printf '[staging]\npath = "%s/repo"\npassword_command = "echo smoke-pass"\n' "$FIX" > "$FIX/c.toml"
        zsh -c 'source "$1/backup.zsh"; bkp::capture::run "$2" "$3"' \
          _ "$LIB" "$FIX/m.toml" "$FIX/c.toml" >/dev/null 2>&1 || return 1
        local snap
        snap=$(RESTIC_REPOSITORY="$FIX/repo" RESTIC_PASSWORD_COMMAND="echo smoke-pass" \
          restic snapshots --json 2>/dev/null | jq -r '.[0].id')
        print v2 > "$FIX/root/f.txt"
        bkp::restore::paths "$snap" --force "$FIX/root/f.txt" >/dev/null 2>&1 || return 1
        cat "$FIX/root/f.txt"
        bkp::restore::undo >/dev/null 2>&1 || return 1
        cat "$FIX/root/f.txt"
        rm -rf "$FIX"
      }
      When run usmoke
      The line 1 should equal "v1"
      The line 2 should equal "v2"
      The stderr should be defined
    End
  End
End
