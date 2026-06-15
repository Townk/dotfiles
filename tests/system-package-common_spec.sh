# Tests for home/dot_local/lib/system-package-common.zsh (the pkg:: helpers:
# manifest parsing, version diffing, post-sync restart hook).
Describe 'system-package-common.zsh'
  Include home/dot_local/lib/system-package-common.zsh

  setup()   { TEST_TMP=$(mktemp -d); }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'pkg::manifest_read'
    It 'strips full-line comments'
      printf '# top comment\nruff\n# middle comment\nblack\n' > "$TEST_TMP/m"
      When call pkg::manifest_read "$TEST_TMP/m"
      The output should equal "$(printf 'ruff\nblack')"
    End

    It 'strips inline trailing comments'
      printf 'ruff   # linter\nblack  # formatter\n' > "$TEST_TMP/m"
      When call pkg::manifest_read "$TEST_TMP/m"
      The output should equal "$(printf 'ruff\nblack')"
    End

    It 'skips blank lines and trims whitespace'
      printf '   ruff\n\n  black\n' > "$TEST_TMP/m"
      When call pkg::manifest_read "$TEST_TMP/m"
      The output should equal "$(printf 'ruff\nblack')"
    End

    It 'preserves entries with @ and / characters'
      printf '@anthropic-ai/claude-code\ngithub.com/foo/bar/cmd/baz\n' > "$TEST_TMP/m"
      When call pkg::manifest_read "$TEST_TMP/m"
      The output should equal "$(printf '@anthropic-ai/claude-code\ngithub.com/foo/bar/cmd/baz')"
    End

    It 'errors on a missing file'
      When call pkg::manifest_read "$TEST_TMP/nonexistent"
      The status should be failure
      The stderr should include "manifest not found"
    End
  End

  Describe 'pkg::diff_only_in'
    It 'returns lines unique to the first file, sorted'
      printf 'b\na\nc\n' > "$TEST_TMP/a"
      printf 'b\nd\n'     > "$TEST_TMP/b"
      When call pkg::diff_only_in "$TEST_TMP/a" "$TEST_TMP/b"
      The output should equal "$(printf 'a\nc')"
    End

    It 'handles an empty second file'
      printf 'a\nb\n' > "$TEST_TMP/a"
      : > "$TEST_TMP/b"
      When call pkg::diff_only_in "$TEST_TMP/a" "$TEST_TMP/b"
      The output should equal "$(printf 'a\nb')"
    End

    It 'returns empty when the first file is a subset of the second'
      printf 'a\n'   > "$TEST_TMP/a"
      printf 'a\nb\n' > "$TEST_TMP/b"
      When call pkg::diff_only_in "$TEST_TMP/a" "$TEST_TMP/b"
      The output should equal ""
    End
  End

  Describe 'pkg::changed_versions'
    It 'returns empty when versions match'
      printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/before"
      printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/after"
      When call pkg::changed_versions "$TEST_TMP/before" "$TEST_TMP/after"
      The output should equal ""
    End

    It 'emits packages whose version changed'
      printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/before"
      printf 'ruff\t0.6.0\nblack\t24.1.0\n' > "$TEST_TMP/after"
      When call pkg::changed_versions "$TEST_TMP/before" "$TEST_TMP/after"
      The output should equal "ruff"
    End

    It 'emits newly-installed packages'
      printf 'ruff\t0.5.0\n'              > "$TEST_TMP/before"
      printf 'ruff\t0.5.0\nmypy\t1.10.0\n' > "$TEST_TMP/after"
      When call pkg::changed_versions "$TEST_TMP/before" "$TEST_TMP/after"
      The output should equal "mypy"
    End

    It 'does NOT emit packages that were removed'
      printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/before"
      printf 'ruff\t0.5.0\n'               > "$TEST_TMP/after"
      When call pkg::changed_versions "$TEST_TMP/before" "$TEST_TMP/after"
      The output should equal ""
    End
  End

  Describe 'pkg::restart_changed'
    It 'is a no-op (exit 0) when system-service is absent'
      printf 'ruff\t1.0\n'          > "$TEST_TMP/before"
      printf 'ruff\t2.0\nmypy\t1.0\n' > "$TEST_TMP/after"
      # Isolate PATH so a real system-service can't fire during the test.
      restart_isolated() { PATH=/usr/bin:/bin pkg::restart_changed "$TEST_TMP/before" "$TEST_TMP/after"; }
      When call restart_isolated
      The status should be success
    End
  End
End
