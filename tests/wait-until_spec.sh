# Tests for the wait-until bin (home/dot_local/bin/executable_wait-until):
# poll a command until it succeeds or a timeout elapses. Kept as POSIX sh, so
# it is exercised explicitly via `sh`.
Describe 'wait-until'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_wait-until"

  # wait-until is POSIX sh: its only clock is `date` and its only nap is
  # `sleep`, both the virtual clock's fakes on PATH here. No example waits;
  # each asserts how long the script BELIEVES it waited. The fake `date`
  # answers in whole seconds (`+%s.%N` gives N.000000000, or the script falls
  # back to +%s by itself), so a budget below a second ends when the virtual
  # second turns: the clock starts on a whole second to make that a fixed count.
  setup() { spec_sandbox; WU=$SANDBOX; spec_clock_set 1000; }
  BeforeEach 'setup'
  # What the script asked `sleep` for, as "<naps>x<seconds>" (one interval).
  naps() { spec_clock_slept | sort | uniq -c | awk '{ printf "%sx%s\n", $1, $2 }'; }
  elapsed_ms() { echo $(($(spec_clock_now ms) - 1000000)); }

  It 'succeeds immediately when the condition is already true'
    When run command sh "$SCRIPT" --timeout 2s -- true
    The status should be success
    The result of function naps should equal ""
  End

  It 'times out and exits 1 when the condition never holds'
    # Ten naps of 0.1 s turn the virtual second: 1 >= 0.3, it gives up.
    When run command sh "$SCRIPT" --timeout 0.3s --quiet -- false
    The status should eq 1
    The result of function naps should equal "10x0.100000"
  End

  It 'exits 2 on a usage error (no command given)'
    When run command sh "$SCRIPT" --timeout 1s
    The status should eq 2
    The stderr should include "no command given"
  End

  It 'returns as soon as the condition becomes true'
    # The condition holds from its fourth check on: three naps, then out,
    # with 2.85 s of the budget unused.
    spec_stub "$WU" cond 'n=$(wc -l <"$STUB_LOG"); [ "$n" -ge 4 ]'
    When run command sh "$SCRIPT" --timeout 3s --interval 0.05 -- "$WU/cond"
    The status should be success
    The result of function naps should equal "3x0.050000"
    The result of function elapsed_ms should equal 150
  End

  It 'accepts a bare-number (seconds) timeout'
    When run command sh "$SCRIPT" --timeout 1 --interval 0.05 -- true
    The status should be success
  End

  It '--help exits 0 and prints usage'
    When run command sh "$SCRIPT" --help
    The status should be success
    The output should include "Usage:"
  End

  It 'bounds total time by the wall-clock timeout, not attempts * interval'
    # A condition slower than the interval (3 s each, on the virtual clock)
    # under a 6 s budget. The old code fixed the attempt COUNT up front
    # (ceil(6/1)+1 = 7) and never consulted the clock, so it ran all seven
    # checks (27 s), overshooting the budget by >4x. A wall-clock bound stops
    # at the first check that ends past the deadline: check (3 s), nap (4 s),
    # check (7 s >= 6), out, with no further nap.
    spec_stub "$WU" slow 'spec-clock-advance 3' 'exit 1'
    bounded() {
      sh "$SCRIPT" --timeout 6s --interval 1 --quiet -- "$WU/slow"
      local rc=$?
      echo "checks=$(spec_stub_calls "$WU" slow | wc -l | tr -d ' ') naps=$(naps) elapsed=$(elapsed_ms)ms"
      return $rc
    }
    When call bounded
    The status should eq 1
    The output should equal "checks=2 naps=1x1.000000 elapsed=7000ms"
  End
End
