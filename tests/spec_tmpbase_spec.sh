# Tests for the per-file $SHELLSPEC_TMPBASE that tests/spec_helper.sh sets up.
#
# shellspec gives a whole run ONE $SHELLSPEC_TMPBASE, and the specs here write
# fixed names under it ($SHELLSPEC_TMPBASE/state, /bin, /calls, ...). Run one
# file at a time that was fine; under `--jobs` two files that use the same name
# overwrite each other's fixtures mid-example. Each example below runs a
# throwaway two-file project in parallel with a copy of the real spec_helper,
# isolated from this run's own SHELLSPEC_* environment with `env -i`.
Describe 'spec_helper: a per-file SHELLSPEC_TMPBASE'
  HELPER="$PWD/tests/spec_helper.sh"

  setup() {
    PROJ="$(mktemp -d)"
    mkdir "$PROJ/spec" "$PROJ/barrier"
    printf '%s\n' '--shell zsh' '--require spec_helper' > "$PROJ/.shellspec"
    cp "$HELPER" "$PROJ/spec/spec_helper.sh"
    # Both files write the same fixed name, then read it back. The barriers
    # force the interleaving: a writes, b writes after a has, and only then
    # does a read. With one shared base, a reads b's value.
    { echo "Describe 'a'"
      echo "  It 'reads back its own fixture'"
      echo '    f() {'
      echo '      echo a > "$SHELLSPEC_TMPBASE/shared"; : > "$BARRIER/a"'
      echo '      i=0; while [ ! -e "$BARRIER/b" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done'
      echo '      cat "$SHELLSPEC_TMPBASE/shared"'
      echo '    }'
      echo '    When call f'
      echo '    The output should equal a'
      echo '  End'
      echo 'End'
    } > "$PROJ/spec/a_spec.sh"
    { echo "Describe 'b'"
      echo "  It 'reads back its own fixture'"
      echo '    f() {'
      echo '      i=0; while [ ! -e "$BARRIER/a" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done'
      echo '      echo b > "$SHELLSPEC_TMPBASE/shared"; : > "$BARRIER/b"'
      echo '      cat "$SHELLSPEC_TMPBASE/shared"'
      echo '    }'
      echo '    When call f'
      echo '    The output should equal b'
      echo '  End'
      echo 'End'
    } > "$PROJ/spec/b_spec.sh"
  }
  cleanup() { rm -rf "$PROJ"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  inner() { (cd "$PROJ" && env -i PATH="$PATH" HOME="$HOME" BARRIER="$PROJ/barrier" "$@"); }

  It 'keeps two files running in parallel out of each other'"'"'s fixtures'
    When run inner shellspec --jobs 2 spec/a_spec.sh spec/b_spec.sh
    The status should be success
    The output should include '2 examples, 0 failures'
  End

  It 'still gives every example a directory that exists'
    { echo "Describe 'c'"
      echo "  It 'writes under it'"
      echo '    When call sh -c '"'"'echo ok > "$SHELLSPEC_TMPBASE/x" && cat "$SHELLSPEC_TMPBASE/x"'"'"
      echo '    The output should equal ok'
      echo '  End'
      echo 'End'
    } > "$PROJ/spec/c_spec.sh"
    When run inner shellspec spec/c_spec.sh
    The status should be success
    The output should include '1 example, 0 failures'
  End
End
