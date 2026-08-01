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

  # mas 7.0.0 replaced the "id name (ver)" text output these helpers used to
  # parse with per-app JSON (`mas list --json` / `mas outdated --json`, one
  # object per line). `mas` is stubbed here to emit representative JSON; jq is
  # real. Payloads live in $TEST_TMP/mas-<subcommand>.out and the exit code in
  # $TEST_TMP/mas-<subcommand>.rc (default 0).
  Describe 'mas 7 JSON parsing'
    mas_bin() {
      BINDIR="$TEST_TMP/bin"
      mkdir -p "$BINDIR"
      cat >"$BINDIR/mas" <<STUB
#!/bin/sh
sub="\$1"
out="$TEST_TMP/mas-\$sub.out"
rc="$TEST_TMP/mas-\$sub.rc"
[ -f "\$out" ] && cat "\$out"
[ -f "\$rc" ] && exit "\$(cat "\$rc")"
exit 0
STUB
      chmod +x "$BINDIR/mas"
      export PATH="$BINDIR:$PATH"
    }
    BeforeEach 'mas_bin'

    Describe 'pkg::mas_installed_rows'
      It 'parses names exactly (no leading-digit mangling) with versions'
        printf '%s\n%s\n' \
          '{"adamID":1569813296,"name":"1Password for Safari","version":"8.12.29"}' \
          '{"adamID":497799835,"name":"Xcode","version":"16.0"}' \
          >"$TEST_TMP/mas-list.out"
        When call pkg::mas_installed_rows
        The line 1 of output should equal "$(printf '1Password for Safari\t8.12.29')"
        The line 2 of output should equal "$(printf 'Xcode\t16.0')"
      End

      It 'emits nothing when no App Store apps are installed'
        : >"$TEST_TMP/mas-list.out"
        When call pkg::mas_installed_rows
        The output should equal ""
      End
    End

    Describe 'pkg::mas_outdated_rows'
      It 'populates the outdated map from newVersion'
        printf '%s\n%s\n' \
          '{"adamID":1569813296,"name":"1Password for Safari","version":"8.12.29","newVersion":"8.13.0"}' \
          '{"adamID":497799835,"name":"Xcode","version":"16.0","newVersion":"16.1"}' \
          >"$TEST_TMP/mas-outdated.out"
        When call pkg::mas_outdated_rows
        The line 1 of output should equal "$(printf '1Password for Safari\t8.13.0')"
        The line 2 of output should equal "$(printf 'Xcode\t16.1')"
        The stderr should equal ""
      End

      It 'stays silent when nothing is outdated (empty output, exit 0)'
        : >"$TEST_TMP/mas-outdated.out"
        When call pkg::mas_outdated_rows
        The output should equal ""
        The stderr should equal ""
      End

      It 'warns instead of reporting all-current when mas errors'
        printf '2\n' >"$TEST_TMP/mas-outdated.rc"
        When call pkg::mas_outdated_rows
        The output should equal ""
        The stderr should include "update check failed"
      End

      It 'warns when mas emits unparseable output (e.g. the pre-7 text format)'
        printf '%s\n' '497799835  Xcode (16.0 -> 16.1)' >"$TEST_TMP/mas-outdated.out"
        When call pkg::mas_outdated_rows
        The output should equal ""
        The stderr should include "update check failed"
      End
    End
  End
End
