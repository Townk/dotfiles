# Tests for tests/run-shellspec.sh — the gate wrapper every make lane runs.
#
# shellspec 0.28.1 (the latest release) exits 0 whenever its error handler
# sees a stderr line: the handler `exit`s its pipeline subshell before the
# status echo, the third status arrives empty, and the empty value overwrites
# a real 101. One corrupted report record therefore turns a red run green.
# Each example below runs a throwaway shellspec project, isolated from this
# run's own SHELLSPEC_* environment with `env -i`.
Describe 'run-shellspec.sh'
  RUNNER="$PWD/tests/run-shellspec.sh"

  setup() {
    PROJ="$(mktemp -d)"
    mkdir "$PROJ/spec"
    echo '--shell zsh' > "$PROJ/.shellspec"
    # A US byte followed by an RS byte in a reported value (a US/RS record,
    # like input::form's output) breaks shellspec's report stream, so the
    # reporter writes to stderr and the error handler fires.
    { echo "Describe 'corrupts the report'"
      echo "  It 'has a US/RS record in its expectation'"
      echo "    When call printf 'a\\037b\\036c'"
      echo "    The output should equal \"a\$(printf '\\037')b\$(printf '\\036')c\""
      echo '  End'
      echo 'End'
    } > "$PROJ/spec/corrupt_spec.sh"
    { echo "Describe 'fails'"
      echo "  It 'fails'"
      echo '    When call false'
      echo '    The status should be success'
      echo '  End'
      echo 'End'
    } > "$PROJ/spec/fail_spec.sh"
    { echo "Describe 'passes'"
      echo "  It 'passes'"
      echo '    When call true'
      echo '    The status should be success'
      echo '  End'
      echo 'End'
    } > "$PROJ/spec/pass_spec.sh"
  }
  cleanup() { rm -rf "$PROJ"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  inner() { (cd "$PROJ" && env -i PATH="$PATH" HOME="$HOME" "$@"); }

  It 'pins the upstream bug: plain shellspec exits 0 on an aborted run with a failure'
    # If this starts failing, shellspec fixed its exit status; the wrapper
    # can go.
    When run inner shellspec spec/corrupt_spec.sh spec/fail_spec.sh
    The status should be success
    The output should include '1 failure'
    The error should include 'Aborted with status code'
  End

  It 'fails an aborted run that plain shellspec would pass'
    When run inner "$RUNNER" spec/corrupt_spec.sh spec/fail_spec.sh
    The status should eq 102
    The output should include '1 failure'
    The error should include 'run-shellspec: shellspec aborted'
  End

  It 'fails an aborted run even when every example passed'
    When run inner "$RUNNER" spec/corrupt_spec.sh spec/pass_spec.sh
    The status should eq 102
    The output should include '0 failures'
    The error should include 'run-shellspec: shellspec aborted'
  End

  It 'keeps the failure status of a clean run'
    When run inner "$RUNNER" spec/fail_spec.sh
    The status should eq 101
    The output should include '1 failure'
  End

  It 'passes a clean green run'
    When run inner "$RUNNER" spec/pass_spec.sh
    The status should be success
    The output should include '0 failures'
  End
End
