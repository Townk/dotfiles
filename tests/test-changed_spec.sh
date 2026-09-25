# Tests for tests/test-changed.sh, the Makefile's test-changed lane.
#
# The selection is driven directly through `select FILE...` against a
# throwaway tree (TEST_CHANGED_ROOT), so no example needs git history. The
# few examples that cover the no-argument path build a tiny git repo with a
# master branch and stand a stub in for make, so none of them ever runs
# shellspec or the real test lane. Runs are isolated from this run's own
# SHELLSPEC_* environment with `env -i` (as tests/test-one_spec.sh does).
Describe 'tests/test-changed.sh'
  SCRIPT="$PWD/tests/test-changed.sh"

  setup() {
    ROOT="$(mktemp -d)"
    mkdir -p "$ROOT/tests" "$ROOT/home/dot_local/lib/mux" "$ROOT/docs"
    echo "Describe 'a'; End" > "$ROOT/tests/a_spec.sh"
    echo 'Include "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/foo.zsh"' \
      > "$ROOT/tests/uses-foo_spec.sh"
    echo 'source ~/.local/lib/mux/bar.zsh' > "$ROOT/tests/uses-bar_spec.sh"
    echo 'Include tests/helper.sh' > "$ROOT/tests/uses-helper_spec.sh"
    echo 'echo unrelated' > "$ROOT/tests/unrelated_spec.sh"
    # foo.zsh must not also match the fooXzsh a sloppy regex would allow.
    echo 'source dot_local/lib/fooXzsh' > "$ROOT/tests/near-miss_spec.sh"
    : > "$ROOT/tests/helper.sh"
    : > "$ROOT/home/dot_local/lib/foo.zsh"
    : > "$ROOT/home/dot_local/lib/mux/bar.zsh"
  }
  cleanup() { rm -rf "$ROOT"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  inner() { env -i PATH="$PATH" HOME="$HOME" TEST_CHANGED_ROOT="$ROOT" "$@"; }
  pick() { inner "$SCRIPT" select "$@"; }

  Describe 'select'
    It 'picks a changed spec'
      When run pick tests/a_spec.sh
      The status should be success
      The output should equal 'tests/a_spec.sh'
    End

    It 'drops a changed spec that no longer exists (deleted or renamed away)'
      When run pick tests/gone_spec.sh
      The status should be success
      The output should equal ''
    End

    It 'picks a spec that references a changed lib by its source path'
      When run pick home/dot_local/lib/foo.zsh
      The status should be success
      The output should equal 'tests/uses-foo_spec.sh'
    End

    It 'picks a spec that references a changed nested lib by its rendered path'
      When run pick home/dot_local/lib/mux/bar.zsh
      The status should be success
      The output should equal 'tests/uses-bar_spec.sh'
    End

    It 'picks a spec that references a changed tests/ helper'
      When run pick tests/helper.sh
      The status should be success
      The output should equal 'tests/uses-helper_spec.sh'
    End

    It 'does not pick unrelated specs, and lists the selection sorted and once'
      When run pick home/dot_local/lib/foo.zsh tests/a_spec.sh tests/uses-foo_spec.sh
      The status should be success
      The line 1 of output should equal 'tests/a_spec.sh'
      The line 2 of output should equal 'tests/uses-foo_spec.sh'
      The lines of output should equal 2
      The output should not include 'unrelated_spec.sh'
      The output should not include 'near-miss_spec.sh'
    End

    It 'selects nothing, successfully, for a docs-only change'
      When run pick docs/readme.md home/dot_config/foo.toml
      The status should be success
      The output should equal ''
    End

    Describe 'falls back to the full lane'
      Parameters
        'Makefile'
        '.shellspec'
        'tests/spec_helper.sh'
      End

      It "when $1 changed"
        When run pick tests/a_spec.sh "$1"
        The status should equal 3
        The output should equal "$1 changed; every spec depends on it"
      End
    End
  End

  Describe 'the make lane (no arguments)'
    git_fixture() {
      export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
      git -c init.defaultBranch=master init -q "$ROOT"
      ( cd "$ROOT" && git add -A \
        && git -c user.name=t -c user.email=t@t commit -qm base \
        && git checkout -qb topic )
      # Stands in for make: records that the full lane was asked for.
      { echo '#!/bin/sh'
        echo "echo \"make \$*\" >> '$ROOT/make.called'"
      } > "$ROOT/stub-make"
      chmod +x "$ROOT/stub-make"
      echo 'stub-make' >> "$ROOT/.git/info/exclude"
      echo 'make.called' >> "$ROOT/.git/info/exclude"
    }
    BeforeEach 'git_fixture'

    lane() { inner MAKE="$ROOT/stub-make" "$SCRIPT"; }

    It 'runs nothing and passes when only docs changed'
      echo notes > "$ROOT/docs/notes.md"
      When run lane
      The status should be success
      The output should include 'nothing to run'
      The file "$ROOT/make.called" should not be exist
    End

    It 'falls back to make test, saying why, when the Makefile changed'
      echo 'test:' > "$ROOT/Makefile"
      When run lane
      The status should be success
      The output should include 'Makefile changed; every spec depends on it'
      The output should include 'running the full test lane'
      The contents of file "$ROOT/make.called" should equal 'make --no-print-directory test'
    End

    It 'falls back to make test when there is no master to diff against'
      ( cd "$ROOT" && git branch -qm topic other && git branch -qD master )
      When run lane
      The status should be success
      The output should include 'cannot diff against master'
      The contents of file "$ROOT/make.called" should equal 'make --no-print-directory test'
    End
  End
End
