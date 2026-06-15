# Tests for the wait-until bin (home/dot_local/bin/executable_wait-until):
# poll a command until it succeeds or a timeout elapses. Kept as POSIX sh, so
# it is exercised explicitly via `sh`.
Describe 'wait-until'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_wait-until"

  It 'succeeds immediately when the condition is already true'
    When run command sh "$SCRIPT" --timeout 2s -- true
    The status should be success
  End

  It 'times out and exits 1 when the condition never holds'
    When run command sh "$SCRIPT" --timeout 0.3s --quiet -- false
    The status should eq 1
  End

  It 'exits 2 on a usage error (no command given)'
    When run command sh "$SCRIPT" --timeout 1s
    The status should eq 2
    The stderr should include "no command given"
  End

  It 'returns as soon as the condition becomes true'
    flag="$SHELLSPEC_TMPBASE/flag"
    rm -f "$flag"
    ( sleep 0.3; : > "$flag" ) &
    When run command sh "$SCRIPT" --timeout 3s --interval 0.05 -- test -f "$flag"
    The status should be success
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
End
