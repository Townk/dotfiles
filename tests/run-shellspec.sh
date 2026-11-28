#!/usr/bin/env zsh
# shellspec, with an exit status that can be trusted. Every make lane runs this.
#
# shellspec 0.28.1 (the latest release) exits 0 when its error handler fires:
# the handler `exit`s its pipeline subshell before the status echo, the third
# status arrives empty, and the empty value overwrites a real 101. It prints
# "Aborted with status code ..." to stderr and reports success, so a run with
# failures goes green. Its stderr is teed here, and an aborted run fails with
# shellspec's own error status (102). tests/run-shellspec_spec.sh pins both
# the upstream bug and this behaviour.
#
# Every run, pass or fail, ends with one line on stderr:
#   run-shellspec: <N> examples, <N> failures, <N> skips in <M>m <S>s
# parsed from shellspec's own summary line, so a nine-minute lane's outcome
# is readable without scrolling back through the failure listing.
#
# BUDGETS. $SPEC_SUITE names the suite (the make lanes set it) and picks the
# budgets; every number is a variable:
#   SPEC_SUITE=fast      SPEC_SUITE_BUDGET=60   s of wall time for the run
#                        SPEC_EXAMPLE_BUDGET=0.1 s for any one example
#                        SPEC_EXAMPLE_FAIL       s past which an example
#                          blows the budget (default: the same). Between the
#                          two an example is listed and fails nothing: times
#                          near the mark jitter between identical runs.
#   SPEC_SUITE=complete  SPEC_SUITE_BUDGET=180  (no per-example budget)
#   unset / other        no budget unless the two variables are given
# After shellspec's report and the summary line, an overrun is reported on
# stderr: "<suite> suite took N s, budget M s", and the examples over their
# budget, slowest first (the first $SPEC_BUDGET_LIST, default 30). What then
# happens is $SPEC_BUDGET:
#   warn  (default) say so, keep shellspec's status
#   fail  exit 103 when the run was otherwise green
#   off   measure nothing, say nothing
# Per-example times come from tests/spec_suite.sh, which every spec file
# loads: it appends "<file> TAB <line> TAB <seconds> TAB <description>" to
# $SPEC_PROFILE_DIR/examples.tsv. This wrapper makes that directory (or uses
# the one it is given), and leaves the table, slowest first, in
# $SPEC_PROFILE_KEEP when that names a file (and "<file> TAB <seconds>" per
# spec file beside it, in <name>.files.tsv). tests/spec-profile.sh reads it.
#
# The clock is read through one function. When $COMMON_CLOCK_FILE names a
# readable file it is the tests' virtual-clock journal ("= <ms>" sets,
# "+ <ms>" advances; see tests/spec_helper.sh), so a fake shellspec can "take"
# 61 s by appending one line. tests/run-shellspec_budget_spec.sh does, and
# names its fake through $RUN_SHELLSPEC_BIN (PATH is not a seam here: this is
# zsh, and the user's .zshenv rebuilds PATH before the first line runs).
# With RUN_SHELLSPEC_LIB set, sourcing this file only defines its functions:
# the same spec calls budget_settings / budget_report in its own shell.
zmodload -F zsh/datetime p:EPOCHREALTIME

# now_ms: the clock, in milliseconds, in REPLY.
now_ms() {
  local op ms rest t=0
  if [[ -n ${COMMON_CLOCK_FILE-} && -r $COMMON_CLOCK_FILE ]]; then
    while read -r op ms rest; do
      case $op in
        '=') t=$ms ;;
        '+') (( t += ms )) ;;
      esac
    done <$COMMON_CLOCK_FILE
    REPLY=$t
  else
    REPLY=${$(( EPOCHREALTIME * 1000 ))%.*}
  fi
}

# budget_settings: the suite and its budgets, from the environment. Sets
# suite, budget_mode, suite_budget and example_budget (empty: no budget).
# Fails on a SPEC_BUDGET it does not know.
budget_settings() {
  suite=${SPEC_SUITE-} budget_mode=${SPEC_BUDGET:-warn}
  case $suite in
    fast)     suite_budget=${SPEC_SUITE_BUDGET-60}  example_budget=${SPEC_EXAMPLE_BUDGET-0.1} ;;
    complete) suite_budget=${SPEC_SUITE_BUDGET-180} example_budget=${SPEC_EXAMPLE_BUDGET-} ;;
    *)        suite_budget=${SPEC_SUITE_BUDGET-}    example_budget=${SPEC_EXAMPLE_BUDGET-} ;;
  esac
  example_fail=${SPEC_EXAMPLE_FAIL:-$example_budget}
  case $budget_mode in
    warn|fail) ;;
    off) suite_budget= example_budget= example_fail= ;;
    *) print -u2 "run-shellspec: SPEC_BUDGET must be warn, fail or off (got '$budget_mode')"; return 2 ;;
  esac
}

# budget_report <elapsed ms> <examples.tsv>: say on stderr what was over
# budget, slowest example first, and leave the verdict in $over (empty:
# nothing was). Returns 1 when the run must fail for it (SPEC_BUDGET=fail).
# Also leaves the table, sorted, in $SPEC_PROFILE_KEEP.
budget_report() {
  emulate -L zsh
  local elapsed_ms=$1 profile=$2 sorted slow slow_count slow_total fatal limit= max=${SPEC_BUDGET_LIST:-30}
  local -a blown
  over=
  if [[ -n $suite_budget ]] && (( elapsed_ms > suite_budget * 1000 )); then
    blown+=("suite $(( (elapsed_ms + 500) / 1000 )) s > $suite_budget s")
    print -u2 "run-shellspec: ${suite:+$suite }suite took $(( (elapsed_ms + 500) / 1000 )) s, budget $suite_budget s"
  fi
  if [[ -s $profile && -n ${example_budget}${SPEC_PROFILE_KEEP-} ]]; then
    sorted=$(sort -t $'\t' -k3,3 -rn "$profile")
    if [[ -n ${SPEC_PROFILE_KEEP-} ]]; then
      print -r -- "$sorted" >$SPEC_PROFILE_KEEP 2>/dev/null || SPEC_PROFILE_KEEP=
      [[ -n $SPEC_PROFILE_KEEP && -s ${profile:h}/files.tsv ]] &&
        sort -t $'\t' -k2,2 -rn ${profile:h}/files.tsv >${SPEC_PROFILE_KEEP:r}.files.tsv 2>/dev/null
    fi
    if [[ -n $example_budget ]]; then
      slow=$(print -r -- "$sorted" | awk -F '\t' -v b="$example_budget" -v f="${example_fail:-$example_budget}" -v max="$max" '
        $3 + 0 > b + 0 { n++; total += $3; if ($3 + 0 > f + 0) k++; if (n <= max) printf "  %7.3f s  %s:%s  %s\n", $3, $1, $2, $4 }
        END { if (n) printf "%d %d %.2f\n", n, k, total }')
      if [[ -n $slow ]]; then
        slow_count=${${slow##*$'\n'}%% *} slow_total=${slow##* }
        fatal=${${${slow##*$'\n'}#* }% *}
        if [[ ${example_fail:-$example_budget} == $example_budget ]]; then
          blown+=("$slow_count slow examples")
        else
          limit=", $fatal over the limit of $example_fail s"
          (( fatal )) && blown+=("$fatal examples over $example_fail s")
        fi
        print -u2 "run-shellspec: $slow_count examples over the ${suite:+$suite }budget of $example_budget s each ($slow_total s in total)$limit, slowest first:"
        (( ${#${(f)slow}} > 1 )) && print -u2 -r -- "${slow%$'\n'*}"
        (( slow_count > max )) && print -u2 "  ... and $(( slow_count - max )) more${SPEC_PROFILE_KEEP:+ (all of them: tests/spec-profile.sh over $SPEC_PROFILE_KEEP)}"
      fi
    fi
  fi
  (( $#blown )) || return 0
  over="OVER BUDGET (${(j:; :)blown})"
  if [[ $budget_mode == fail ]]; then
    print -u2 "run-shellspec: $over; failing the run (SPEC_BUDGET=fail)"
    return 1
  fi
  print -u2 "run-shellspec: $over; not failing the run (SPEC_BUDGET=warn)"
}

# A spec sources this file for the functions above and stops here.
[[ -n ${RUN_SHELLSPEC_LIB-} ]] && return 0

setopt pipefail no_multios  # multios would copy stdout into the stderr pipe too
budget_settings || exit 2

log=$(mktemp) || exit 1
out=$(mktemp) || { rm -f "$log"; exit 1; }
own_profile=
if [[ -z ${SPEC_PROFILE_DIR-} || ! -d ${SPEC_PROFILE_DIR-} ]]; then
  own_profile=$(mktemp -d) || { rm -f "$log" "$out"; exit 1; }
  export SPEC_PROFILE_DIR=$own_profile
fi
profile=$SPEC_PROFILE_DIR/examples.tsv
trap 'rm -f "$log" "$out"; [[ -n $own_profile ]] && rm -rf "$own_profile"' EXIT

# stdout is teed through $out to read the summary from, which makes it a pipe;
# keep shellspec's colours on a terminal (NO_COLOR still wins inside shellspec).
[[ -t 1 && -z ${NO_COLOR-} ]] && export FORCE_COLOR=${FORCE_COLOR:-1}

# stdout goes straight through and is kept in $out; stderr is shown as it
# comes and kept in $log.
now_ms; start=$REPLY
{ ${RUN_SHELLSPEC_BIN:-shellspec} "$@" 2>&1 1>&3 3>&- | tee "$log" >&2 } 3>&1 | tee "$out"
rc=$?
now_ms; elapsed_ms=$(( REPLY - start )); elapsed=$(( elapsed_ms / 1000 ))
if (( rc == 0 )) && grep -q 'Aborted with status code' "$log"; then
  print -u2 'run-shellspec: shellspec aborted but exited 0 (shellspec 0.28.1 exit-status bug); failing the run'
  rc=102
fi

# shellspec's summary: "4 examples, 1 failure, 1 skip, 1 fix" — the skip field
# only appears when there are skips. Colour codes are stripped first.
summary=$(sed $'s/\e\\[[0-9;]*m//g' "$out" | grep -E '^[0-9]+ examples?, [0-9]+ failures?' | tail -n 1)
examples=? failures=? skips=0
if [[ $summary =~ '^([0-9]+) examples?, ([0-9]+) failures?' ]]; then
  examples=$match[1] failures=$match[2]
  [[ $summary =~ '([0-9]+) skips?' ]] && skips=$match[1]
fi
print -u2 "run-shellspec: $examples examples, $failures failures, $skips skips in $(( elapsed / 60 ))m $(( elapsed % 60 ))s"

# Budgets. Reported after everything shellspec printed; see the header.
budget_report $elapsed_ms $profile || { (( rc == 0 )) && rc=103 }

# The ONE desktop notification a test run may cause: the run is over. Specs
# themselves cannot reach the desktop (tests/spec_helper.sh blocks it), and
# this fires here, after shellspec has exited, so once per run whatever
# --jobs is. $SPEC_SUITE names the run (the make lanes set it); without it
# the toast says how many spec files were asked for. A blown budget is in
# the text too ("— OVER BUDGET (suite 72 s > 60 s; 3 slow examples)").
#
# SPEC_RUN_TOAST=1 forces it, =0 silences it. Unset, it fires only for a
# human at this machine: stderr is a terminal, the session is not SSH, and
# neither CI nor an agent is driving. spec_helper.sh exports SPEC_RUN_TOAST=0,
# so a spec that runs this wrapper (tests/run-shellspec_spec.sh) stays silent.
run_toast() {
  case ${SPEC_RUN_TOAST-} in
    1) ;;
    0) return 0 ;;
    *) [[ -t 2 && -z ${SSH_CONNECTION-}${SSH_TTY-}${CI-}${CLAUDECODE-} ]] || return 0 ;;
  esac
  local lib=${ZSH_ARGZERO:A:h:h}/home/dot_local/lib/common.zsh suite=${SPEC_SUITE-}
  [[ -r $lib ]] || return 0
  [[ -n $suite ]] || suite="${#${(M)@:#*_spec.sh}} spec files"
  local text="Tests ($suite): $examples examples, $failures failures, $skips skips in $(( elapsed / 60 ))m $(( elapsed % 60 ))s"
  local icon=glyph:nf-md-check_circle sound=Glass
  [[ -n $over ]] && text="$text — $over"
  (( rc == 0 )) || { icon=glyph:nf-md-close_circle sound=Basso text="$text — FAILED (exit $rc)" }
  ( source $lib && notify --kind test-run --source run-shellspec --icon $icon --sound $sound -- $text ) >/dev/null 2>&1
  return 0
}
run_toast "$@"
exit $rc
