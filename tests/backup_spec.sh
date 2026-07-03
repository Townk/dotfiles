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
  End

  Describe 'shipped manifest.toml'
    MANIFEST="$SHELLSPEC_PROJECT_ROOT/home/dot_config/backup/manifest.toml"

    It 'parses, keeps the chezmoi filter on, and declares sane roots'
      shipped() {
        source "$LIB/backup.zsh"
        bkp::manifest::chezmoi_excluded "$MANIFEST" || return 1
        bkp::manifest::roots "$MANIFEST" | grep -c "^$HOME/"
        bkp::manifest::deny "$MANIFEST" | grep -Fc '.cache'
      }
      When run shipped
      The line 1 should equal 8
      The line 2 should equal 1
    End
  End
End
