# Tests for the budgets of tests/run-shellspec.sh, for tests/spec_suite.sh
# (suite membership, per-example timing) and for tests/spec-profile.sh.
#
# The verdict is two functions of the wrapper, budget_settings and
# budget_report; the first group sources the wrapper (RUN_SHELLSPEC_LIB=1
# stops it after its functions) and calls them in the example's own shell: a
# few milliseconds each, so they are in the fast suite.
#
# The second group runs the wrapper itself against a FAKE shellspec
# ($RUN_SHELLSPEC_BIN): it prints a summary line, "takes" $FAKE_TOOK_MS by
# appending to the virtual-clock journal the wrapper reads its clock from
# ($COMMON_CLOCK_FILE), and writes $FAKE_PROFILE as the per-example table.
# Nothing waits, but a wrapper run is a dozen processes (~0.17 s), so by the
# rule under test those examples are complete-only. So are the two that run a
# real nested shellspec.
Describe 'run-shellspec.sh budgets'
  RUNNER="$PWD/tests/run-shellspec.sh"
  RUN_SHELLSPEC_LIB=1
  Include tests/run-shellspec.sh

  table() {
    spec_sandbox
    TAB=$(printf '\t')
    TABLE="tests/a_spec.sh${TAB}12${TAB}0.031${TAB}a is quick
tests/a_spec.sh${TAB}40${TAB}0.450${TAB}a starts a server
tests/b_spec.sh${TAB}7${TAB}1.250${TAB}b runs restic"
    print -r -- "$TABLE" >"$SANDBOX/examples.tsv"
  }
  BeforeEach 'table'

  # verdict <seconds the run took> VAR=value... : what the wrapper would say
  # about such a run, and "fail=1" when it would fail it.
  verdict() {
    local took=$1 fail=0; shift
    (
      unset SPEC_SUITE SPEC_BUDGET SPEC_SUITE_BUDGET SPEC_EXAMPLE_BUDGET SPEC_BUDGET_LIST SPEC_PROFILE_KEEP
      (( $# )) && export "$@"
      budget_settings || exit 2
      budget_report $(( took * 1000 )) "$SANDBOX/${PROFILE-examples.tsv}" || fail=1
      print -r -- "fail=$fail over=$over"
    )
  }

  Describe 'for the run'
    PROFILE=none.tsv

    It 'says nothing about a fast run inside 60 s'
      When call verdict 59 SPEC_SUITE=fast SPEC_BUDGET=fail
      The output should equal 'fail=0 over='
    End

    It 'fails a fast run over 60 s under SPEC_BUDGET=fail'
      When call verdict 61 SPEC_SUITE=fast SPEC_BUDGET=fail
      The output should equal 'fail=1 over=OVER BUDGET (suite 61 s > 60 s)'
      The line 1 of error should equal 'run-shellspec: fast suite took 61 s, budget 60 s'
      The line 2 of error should equal 'run-shellspec: OVER BUDGET (suite 61 s > 60 s); failing the run (SPEC_BUDGET=fail)'
    End

    It 'only warns by default'
      When call verdict 61 SPEC_SUITE=fast
      The output should equal 'fail=0 over=OVER BUDGET (suite 61 s > 60 s)'
      The line 2 of error should equal 'run-shellspec: OVER BUDGET (suite 61 s > 60 s); not failing the run (SPEC_BUDGET=warn)'
    End

    It 'gives the complete suite 180 s'
      When call verdict 179 SPEC_SUITE=complete SPEC_BUDGET=fail
      The output should equal 'fail=0 over='
    End

    It 'fails a complete run over 180 s'
      When call verdict 181 SPEC_SUITE=complete SPEC_BUDGET=fail
      The output should equal 'fail=1 over=OVER BUDGET (suite 181 s > 180 s)'
      The error should include 'run-shellspec: complete suite took 181 s, budget 180 s'
    End

    It 'takes the budget from SPEC_SUITE_BUDGET'
      When call verdict 61 SPEC_SUITE=fast SPEC_BUDGET=fail SPEC_SUITE_BUDGET=90
      The output should equal 'fail=0 over='
    End

    It 'has no budget without a suite'
      When call verdict 900 SPEC_BUDGET=fail PROFILE=examples.tsv
      The output should equal 'fail=0 over='
    End

    It 'measures nothing under SPEC_BUDGET=off'
      When call verdict 900 SPEC_SUITE=fast SPEC_BUDGET=off PROFILE=examples.tsv
      The output should equal 'fail=0 over='
    End

    It 'refuses a SPEC_BUDGET it does not know'
      When call verdict 1 SPEC_SUITE=fast SPEC_BUDGET=maybe
      The status should eq 2
      The error should equal "run-shellspec: SPEC_BUDGET must be warn, fail or off (got 'maybe')"
    End
  End

  Describe 'for each example'
    It 'names the fast examples over 0.1 s, slowest first, and fails'
      When call verdict 20 SPEC_SUITE=fast SPEC_BUDGET=fail
      The output should equal 'fail=1 over=OVER BUDGET (2 slow examples)'
      The line 1 of error should equal 'run-shellspec: 2 examples over the fast budget of 0.1 s each (1.70 s in total), slowest first:'
      The line 2 of error should equal '    1.250 s  tests/b_spec.sh:7  b runs restic'
      The line 3 of error should equal '    0.450 s  tests/a_spec.sh:40  a starts a server'
      The line 4 of error should equal 'run-shellspec: OVER BUDGET (2 slow examples); failing the run (SPEC_BUDGET=fail)'
    End

    It 'reports the run and the examples together'
      When call verdict 75 SPEC_SUITE=fast
      The output should equal 'fail=0 over=OVER BUDGET (suite 75 s > 60 s; 2 slow examples)'
      The line 1 of error should equal 'run-shellspec: fast suite took 75 s, budget 60 s'
      The error should include 'not failing the run (SPEC_BUDGET=warn)'
    End

    It 'takes the budget from SPEC_EXAMPLE_BUDGET'
      When call verdict 20 SPEC_SUITE=fast SPEC_BUDGET=fail SPEC_EXAMPLE_BUDGET=1
      The output should equal 'fail=1 over=OVER BUDGET (1 slow examples)'
      The error should include '1 examples over the fast budget of 1 s each (1.25 s in total)'
      The error should not include 'a starts a server'
    End

    It 'has none in the complete suite'
      When call verdict 20 SPEC_SUITE=complete SPEC_BUDGET=fail
      The output should equal 'fail=0 over='
    End

    It 'lists at most SPEC_BUDGET_LIST of them and counts the rest'
      When call verdict 20 SPEC_SUITE=fast SPEC_BUDGET_LIST=1
      The output should include '2 slow examples'
      The error should include 'b runs restic'
      The error should not include 'a starts a server'
      The error should include '  ... and 1 more'
    End

    It 'leaves the whole table, slowest first, in SPEC_PROFILE_KEEP'
      When call verdict 20 SPEC_SUITE=complete SPEC_PROFILE_KEEP="$SANDBOX/kept.tsv"
      The output should equal 'fail=0 over='
      The line 1 of contents of file "$SANDBOX/kept.tsv" should include 'b runs restic'
      The line 3 of contents of file "$SANDBOX/kept.tsv" should include 'a is quick'
    End
  End

  Describe 'the wrapper, run'
    Skip if 'complete-only: a wrapper run is a dozen processes' spec_complete_only

    setup() {
      BIN=$SANDBOX
      spec_clock_set 1000
      spec_stub "$BIN" shellspec \
        'echo "+ ${FAKE_TOOK_MS:-0}" >>"$COMMON_CLOCK_FILE"' \
        '[ -z "${FAKE_PROFILE:-}" ] || printf "%s\n" "$FAKE_PROFILE" >"$SPEC_PROFILE_DIR/examples.tsv"' \
        'echo "suite=${SPEC_SUITE:-}" >"$STUB_DIR/seen"' \
        'echo "3 examples, ${FAKE_FAILURES:-0} failures"' \
        '[ "${FAKE_FAILURES:-0}" = 0 ] || exit 101'
    }
    BeforeEach 'setup'

    # run_wrapper VAR=value... : the wrapper, with only this environment.
    run_wrapper() {
      env -i PATH="$PATH" HOME="$HOME" COMMON_CLOCK_FILE="$COMMON_CLOCK_FILE" \
        RUN_SHELLSPEC_BIN="$BIN/shellspec" SPEC_RUN_TOAST=0 "$@" zsh -f "$RUNNER" tests/a_spec.sh tests/b_spec.sh
    }
    toast_of() {
      spec_desktop_reset
      run_wrapper HS="$HS" SPEC_RUN_TOAST=1 "$@" >/dev/null 2>&1; print -r -- "rc=$?"
      spec_notifications
    }

    It 'passes a run inside its budget, with the summary line and nothing more'
      When run run_wrapper SPEC_SUITE=fast SPEC_BUDGET=fail FAKE_TOOK_MS=59000
      The status should be success
      The output should equal '3 examples, 0 failures'
      The error should equal 'run-shellspec: 3 examples, 0 failures, 0 skips in 0m 59s'
    End

    It 'exits 103 for a blown budget, after the report and the summary line'
      When run run_wrapper SPEC_SUITE=fast SPEC_BUDGET=fail FAKE_TOOK_MS=61000 FAKE_PROFILE="$TABLE"
      The status should eq 103
      The output should equal '3 examples, 0 failures'
      The line 1 of error should equal 'run-shellspec: 3 examples, 0 failures, 0 skips in 1m 1s'
      The line 2 of error should equal 'run-shellspec: fast suite took 61 s, budget 60 s'
      The line 6 of error should equal 'run-shellspec: OVER BUDGET (suite 61 s > 60 s; 2 slow examples); failing the run (SPEC_BUDGET=fail)'
    End

    It 'keeps the status of a red run that is also over budget'
      When run run_wrapper SPEC_SUITE=fast SPEC_BUDGET=fail FAKE_TOOK_MS=61000 FAKE_FAILURES=2
      The status should eq 101
      The output should include '2 failures'
      The error should include 'OVER BUDGET (suite 61 s > 60 s); failing the run'
    End

    It 'refuses an unknown SPEC_BUDGET before running anything'
      When run run_wrapper SPEC_SUITE=fast SPEC_BUDGET=maybe
      The status should eq 2
      The error should include "SPEC_BUDGET must be warn, fail or off (got 'maybe')"
      The file "$BIN/shellspec.log" should not be exist
    End

    It 'hands the suite name down to shellspec'
      seen() { run_wrapper SPEC_SUITE=fast >/dev/null 2>&1; cat "$BIN/seen"; }
      When call seen
      The output should equal 'suite=fast'
    End

    It 'says in the toast which budget was blown'
      When call toast_of SPEC_SUITE=fast FAKE_TOOK_MS=75000 FAKE_PROFILE="$TABLE"
      The line 1 of output should equal 'rc=0'
      The line 2 of output should include 'Tests (fast): 3 examples, 0 failures, 0 skips in 1m 15s — OVER BUDGET (suite 75 s > 60 s; 2 slow examples)'
      The line 2 of output should include 'check_circle'
    End

    It 'raises a failure toast when the budget fails the run'
      When call toast_of SPEC_SUITE=fast SPEC_BUDGET=fail FAKE_TOOK_MS=75000
      The line 1 of output should equal 'rc=103'
      The line 2 of output should include '— OVER BUDGET (suite 75 s > 60 s) — FAILED (exit 103)'
      The line 2 of output should include 'close_circle'
    End
  End
End

Describe 'spec_suite.sh'
  Describe 'spec_complete_only'
    It 'skips in the fast suite'
      fast() { SPEC_SUITE_ACTIVE=fast; spec_complete_only; }
      When call fast
      The status should be success
    End

    It 'runs in the complete suite'
      complete() { SPEC_SUITE_ACTIVE=complete; spec_complete_only; }
      When call complete
      The status should be failure
    End

    It 'runs when no suite is named'
      none() { SPEC_SUITE_ACTIVE=; spec_complete_only; }
      When call none
      The status should be failure
    End

    It 'does not hand SPEC_SUITE or SPEC_PROFILE_DIR down to what a spec runs'
      When call zsh -fc 'print -r -- "suite=${SPEC_SUITE-unset} profile=${SPEC_PROFILE_DIR-unset}"'
      The output should equal 'suite=unset profile=unset'
    End
  End

  # A real shellspec on a throwaway project that loads the real module:
  # ~0.4 s each, so by their own rule they are not in the fast suite.
  Describe 'in a real run'
    Skip if 'complete-only: runs a nested shellspec' spec_complete_only

    setup() {
      spec_sandbox; PROJ=$SANDBOX
      mkdir "$PROJ/spec" "$PROJ/helper" "$PROJ/profile"
      cp tests/spec_suite.sh "$PROJ/helper/"
      print -rl -- '--shell zsh' '--helperdir helper' '--require spec_suite' >"$PROJ/.shellspec"
      print -rl -- \
        "Describe 'p'" \
        "  It 'is in both suites'" '    When call true' '    The status should be success' '  End' \
        "  It 'is complete-only'" \
        "    Skip if 'complete-only: pretend' spec_complete_only" \
        '    When call true' '    The status should be success' '  End' \
        "  Describe 'a complete-only group'" \
        "    Skip if 'complete-only: pretend' spec_complete_only" \
        "    BeforeAll 'echo hook >>$PROJ/hooks'" \
        "    It 'is inside'" '      When call true' '      The status should be success' '    End' \
        '  End' \
        'End' >"$PROJ/spec/p_spec.sh"
    }
    BeforeEach 'setup'
    nested() { (cd "$PROJ" && env -i PATH="$PATH" HOME="$HOME" SPEC_PROFILE_DIR="$PROJ/profile" "$@" shellspec --jobs 2 2>&1 | grep -E '^[0-9]+ examples'); }
    table() { cut -f 1,2,4 "$PROJ/profile/examples.tsv" | sort -t "$(printf '\t')" -k2,2n | tr '\t' '|'; [[ -e "$PROJ/hooks" ]] && print hooks-ran; cut -f1 "$PROJ/profile/files.tsv"; }

    It 'skips the complete-only examples, and the hooks of a group, in the fast suite'
      run() { nested SPEC_SUITE=fast; table; }
      When call run
      The output should equal '3 examples, 0 failures, 2 skips
spec/p_spec.sh|2|p is in both suites
spec/p_spec.sh|6|p is complete-only
spec/p_spec.sh|14|p a complete-only group is inside
spec/p_spec.sh'
    End

    It 'runs and times everything in the complete suite'
      run() { nested SPEC_SUITE=complete; table; }
      When call run
      The output should equal '3 examples, 0 failures
spec/p_spec.sh|2|p is in both suites
spec/p_spec.sh|6|p is complete-only
spec/p_spec.sh|14|p a complete-only group is inside
hooks-ran
spec/p_spec.sh'
    End
  End
End

Describe 'spec-profile.sh'
  PROFILE="$PWD/tests/spec-profile.sh"

  setup() {
    spec_sandbox
    TAB=$(printf '\t')
    print -r -- "tests/a_spec.sh${TAB}12${TAB}0.031${TAB}a is quick
tests/b_spec.sh${TAB}7${TAB}1.250${TAB}b runs restic
tests/a_spec.sh${TAB}40${TAB}0.450${TAB}a starts a server" >"$SANDBOX/t.tsv"
  }
  BeforeEach 'setup'

  It 'lists the examples over the budget: file:line, seconds, description'
    When run "$PROFILE" over "$SANDBOX/t.tsv"
    The output should equal "tests/b_spec.sh:7${TAB}1.250${TAB}b runs restic
tests/a_spec.sh:40${TAB}0.450${TAB}a starts a server"
    The error should equal '2 examples over 0.1 s, 1.70 s in total'
  End

  It 'takes another budget with -b'
    When run "$PROFILE" over -b 0.5 "$SANDBOX/t.tsv"
    The output should equal "tests/b_spec.sh:7${TAB}1.250${TAB}b runs restic"
    The error should equal '1 examples over 0.5 s, 1.25 s in total'
  End

  It 'lists the N slowest'
    When run "$PROFILE" top -n 1 "$SANDBOX/t.tsv"
    The output should equal "tests/b_spec.sh:7${TAB}1.250${TAB}b runs restic"
  End

  It 'adds up each file, heaviest first'
    When run "$PROFILE" files "$SANDBOX/t.tsv"
    The output should equal "1.25${TAB}1${TAB}1${TAB}1.25${TAB}tests/b_spec.sh
0.48${TAB}2${TAB}1${TAB}0.45${TAB}tests/a_spec.sh"
  End

  It 'says where to get a table when there is none'
    When run "$PROFILE" over "$SANDBOX/none.tsv"
    The status should be failure
    The error should include 'no table at'
  End
End
