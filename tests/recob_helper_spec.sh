# Tests for tests/recob_helper.sh itself.
Describe 'recob_helper.sh'
  Include tests/recob_helper.sh

  AfterEach 'recob_stop'

  # ShellSpec wires its executor and reporter together with pipes the example
  # inherits. A daemon that keeps them open outlives its example if a hook
  # fails before recob_stop runs, and the reporter then waits forever for EOF
  # on its input: the whole run hangs rather than failing.
  daemon_pipes() {
    recob_start || return 1
    fds=$(lsof -a -p "$RECOB_PID" -Ft 2>/dev/null)
    # A daemon lsof cannot see would count zero pipes too: require its fds.
    printf '%s\n' "$fds" | grep -q '^tREG' || return 2
    printf '%s\n' "$fds" | grep -c '^tPIPE'
    return 0
  }

  It "starts the daemon without any of ShellSpec's pipes"
    When call daemon_pipes
    The output should equal 0
  End
End
