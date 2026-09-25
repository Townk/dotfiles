# Tests for the Makefile's test-one lane: make test-one SPEC=<one spec>.
#
# Each example runs the real target from the repo root against a throwaway
# spec. shellspec refuses specs outside the project and names outside
# *_spec.sh, so the fixtures live in a hidden dir under tests/ — created after
# this run's spec discovery and removed after each example. Runs are
# isolated from this run's own SHELLSPEC_* environment with `env -i` (as
# tests/run-shellspec_spec.sh does). Whether recob would build is read off
# `make -n`, so no example ever needs cargo.
Describe 'make test-one'
  setup() {
    PROJ="$(mktemp -d "$PWD/tests/.test-one.XXXXXX")"
    { echo "Describe 'passes'"
      echo "  It 'passes'"
      echo '    When call true'
      echo '    The status should be success'
      echo '  End'
      echo 'End'
    } > "$PROJ/pass_spec.sh"
    { echo '# needs the recob binary'
      echo "Describe 'uses recob'"
      echo '  Include tests/recob_helper.sh'
      echo 'End'
    } > "$PROJ/recob_spec.sh"
    # Stands in for tests/run-shellspec.sh: records that it ran.
    { echo '#!/bin/sh'
      echo "echo \"\$@\" >> '$PROJ/shellspec.called'"
    } > "$PROJ/stub-shellspec"
    chmod +x "$PROJ/stub-shellspec"
  }
  cleanup() { rm -rf "$PROJ"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  inner() { env -i PATH="$PATH" HOME="$HOME" "$@"; }

  It 'runs shellspec, through the wrapper, on exactly the named spec'
    When run inner make --no-print-directory test-one SPEC="$PROJ/pass_spec.sh"
    The status should be success
    The output should include 'tests/run-shellspec.sh'
    The output should include '1 example, 0 failures'
    The error should include 'run-shellspec: 1 examples, 0 failures, 0 skips'
  End

  It 'passes SPEC to the wrapper and nothing else'
    When run inner make --no-print-directory test-one SPEC="$PROJ/pass_spec.sh" \
      SHELLSPEC="$PROJ/stub-shellspec"
    The status should be success
    The output should include 'stub-shellspec'
    The contents of file "$PROJ/shellspec.called" should equal "$PROJ/pass_spec.sh"
  End

  It 'does not build recob for a spec without tests/recob_helper.sh'
    When run inner make -n --no-print-directory test-one SPEC="$PROJ/pass_spec.sh"
    The status should be success
    The output should not include 'custom-builds/recob'
  End

  It 'builds recob first for a spec that includes tests/recob_helper.sh'
    When run inner make -n --no-print-directory test-one SPEC="$PROJ/recob_spec.sh"
    The status should be success
    The line 1 of output should include 'custom-builds/recob'
    The output should include "tests/run-shellspec.sh $PROJ/recob_spec.sh"
  End

  Describe 'without SPEC'
    Parameters
      'unset' ''
      'empty' 'SPEC='
    End

    It "fails with usage and never runs shellspec ($1)"
      When run inner make --no-print-directory test-one ${2:+"$2"} \
        SHELLSPEC="$PROJ/stub-shellspec"
      The status should be failure
      The error should include 'usage: make test-one SPEC=tests/<name>_spec.sh'
      The output should not include 'stub-shellspec'
      The file "$PROJ/shellspec.called" should not be exist
    End
  End
End
