#!/usr/bin/env zsh
# spec-profile.sh — per-example wall time of a spec run, as a table.
#
#   tests/spec-profile.sh run [-o TABLE] [shellspec args...]
#       Run the specs through tests/run-shellspec.sh (so: same exit status,
#       same budgets if SPEC_SUITE is set) and leave the table in TABLE
#       (default: $TMPDIR/spec-profile.tsv). With no shellspec args: --jobs
#       $JOBS (default 6) over every spec.
#   tests/spec-profile.sh over [-b SECONDS] [TABLE]
#       The examples over the budget (default 0.1), slowest first:
#       "<file>:<line> TAB <seconds> TAB <description>". Count and total on
#       stderr. This is the to-do list for `spec_complete_only`.
#   tests/spec-profile.sh top [-n N] [TABLE]
#       The N slowest examples (default 30), same columns.
#   tests/spec-profile.sh files [-b SECONDS] [TABLE]
#       Per spec file, heaviest first: "<seconds> TAB <examples> TAB
#       <over budget> TAB <seconds over budget> TAB <file>".
#   tests/spec-profile.sh summary [-b SECONDS] [TABLE]
#       One screen: examples, total, over budget, a histogram.
#
# TABLE is tab-separated, one line per example run, slowest first:
#   <specfile> TAB <line of the It> TAB <seconds> TAB <description>
# written by tests/spec_suite.sh (see there for what the time covers: the
# example with its BeforeEach/AfterEach hooks, not BeforeAll, not the file's
# start-up). A parameterized It has one line per parameter set, same line
# number. Times are wall time under whatever --jobs the run used: a loaded
# machine stretches them, so profile at the --jobs the suites run with.
#
# shellspec's own --profile cannot do this: it refuses --jobs ("Cannot be
# specified profiler and parallel execution at the same time"), and its
# numbers are a share of a busy-loop counter, not a clock.
emulate -L zsh
setopt err_return no_unset pipefail

self=${0:A} here=${0:A:h}
default_table=${TMPDIR:-/tmp}/spec-profile.tsv

usage() { sed -n '2,/^emulate/{/^emulate/d;s/^# \{0,1\}//;p;}' "$self" >&2; exit 2; }

(( $# )) || usage
cmd=$1; shift
budget=0.1 limit=30 table=
# Only the leading options are this script's: after `run`, the rest is
# shellspec's.
while (( $# >= 2 )); do
  case $1 in
    -b) budget=$2 ;;
    -n) limit=$2 ;;
    -o) table=$2 ;;
    *) break ;;
  esac
  shift 2
done

if [[ $cmd != run ]]; then
  table=${1:-${table:-$default_table}}
  [[ -r $table ]] || { print -u2 "spec-profile: no table at $table (make one: tests/spec-profile.sh run)"; exit 1; }
fi

case $cmd in
  run)
    table=${table:-$default_table}
    (( $# )) || set -- --jobs ${JOBS:-6}
    rc=0
    SPEC_PROFILE_KEEP=$table "$here/run-shellspec.sh" "$@" || rc=$?
    print -u2 "spec-profile: table in $table"
    exit $rc ;;
  over)
    sort -t $'\t' -k3,3 -rn "$table" | awk -F '\t' -v b="$budget" '
      $3 + 0 > b + 0 { n++; total += $3; printf "%s:%s\t%s\t%s\n", $1, $2, $3, $4 }
      END { printf "%d examples over %s s, %.2f s in total\n", n, b, total >"/dev/stderr" }' ;;
  top)
    # No `head`: it would end the pipe early, and pipefail turns sort's SIGPIPE into a failure.
    sort -t $'\t' -k3,3 -rn "$table" | awk -F '\t' -v n="$limit" 'NR <= n { printf "%s:%s\t%s\t%s\n", $1, $2, $3, $4 }' ;;
  files)
    awk -F '\t' -v b="$budget" '
      { n[$1]++; t[$1] += $3; if ($3 + 0 > b + 0) { o[$1]++; ot[$1] += $3 } }
      END { for (f in n) printf "%.2f\t%d\t%d\t%.2f\t%s\n", t[f], n[f], o[f], ot[f], f }' "$table" | sort -rn ;;
  summary)
    awk -F '\t' -v b="$budget" '
      { n++; t += $3; files[$1] = 1
        if ($3 + 0 > b + 0) { o++; ot += $3 }
        k = ($3 < 0.01) ? 1 : ($3 < 0.05) ? 2 : ($3 < 0.1) ? 3 : ($3 < 0.25) ? 4 : ($3 < 1) ? 5 : 6
        h[k]++; ht[k] += $3 }
      END {
        for (f in files) nf++
        printf "%d examples in %d files, %.1f s of example time\n", n, nf, t
        printf "%d over %s s, %.1f s (%.0f%% of the time)\n", o, b, ot, t ? 100 * ot / t : 0
        split("<10ms 10-50ms 50-100ms 100-250ms 250ms-1s >=1s", name, " ")
        for (k = 1; k <= 6; k++) printf "  %-10s %5d examples %8.1f s\n", name[k], h[k], ht[k]
      }' "$table" ;;
  *) usage ;;
esac
