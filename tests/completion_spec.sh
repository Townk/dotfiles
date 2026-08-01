# Tests for home/dot_config/zsh/completion.sh.
#
# HI-2: the compdump freshness decision that gates `compinit -C` (skip the slow
# insecure-directory audit) vs a full `compinit`. The original code wrote the
# glob qualifier INSIDE [[ ... ]]:
#
#     [[ -n ${ZSH_COMPDUMP}(#qNmh-24) ]]
#
# zsh does no filename generation inside [[ ... ]], so the qualifier never fired
# and `-n` tested a non-empty literal string — always true, even for a missing
# dump. compinit -C then ran forever, skipping staleness + insecure-dir checks,
# so a newly added _foo completion was never picked up.
#
# The decision is now a helper, _compdump_is_fresh, expanded in command
# position. We source only that helper (ZSH_COMPLETION_LIB_ONLY seam) and assert
# the three cases below. Expectations are derived from the zsh glob spec for
# (Nmh-24) — N=nullglob, mh-24 = modified within the last 24h — NOT from the code.
Describe 'completion.sh compdump freshness (HI-2)'
  COMPLETION="$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/completion.sh"

  setup() {
    WORKDIR="$SHELLSPEC_TMPBASE/compdump"
    mkdir -p "$WORKDIR"
    FRESH="$WORKDIR/fresh"
    OLD="$WORKDIR/old"
    MISSING="$WORKDIR/missing"   # deliberately never created
    : > "$FRESH"
    : > "$OLD"
    touch -t "$(date -v-25H +%Y%m%d%H%M)" "$OLD"
    rm -f "$MISSING"
  }
  BeforeEach 'setup'

  # Source ONLY the helper (the seam returns before the heavy compinit/fzf
  # wiring), then run the predicate against $1.
  probe() {
    ZSH_COMPLETION_LIB_ONLY=1 source "$COMPLETION"
    if _compdump_is_fresh "$1"; then print fresh; else print stale; fi
  }

  It 'reports a nonexistent dump as stale (must regenerate)'
    When run probe "$MISSING"
    The output should equal "stale"
    The status should be success
  End

  It 'reports a just-created dump as fresh (skip the audit)'
    When run probe "$FRESH"
    The output should equal "fresh"
    The status should be success
  End

  It 'reports a dump older than 24h as stale (re-audit)'
    When run probe "$OLD"
    The output should equal "stale"
    The status should be success
  End
End
