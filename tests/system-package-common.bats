#!/usr/bin/env bats

setup() {
  TEST_TMP=$(mktemp -d)
  source "$BATS_TEST_DIRNAME/../home/dot_local/lib/system-package-common.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "pkg_manifest_read strips full-line comments" {
  cat > "$TEST_TMP/m" <<'EOF'
# top comment
ruff
# middle comment
black
EOF
  result=$(pkg_manifest_read "$TEST_TMP/m")
  [ "$result" = "$(printf 'ruff\nblack')" ]
}

@test "pkg_manifest_read strips inline trailing comments" {
  cat > "$TEST_TMP/m" <<'EOF'
ruff   # linter
black  # formatter
EOF
  result=$(pkg_manifest_read "$TEST_TMP/m")
  [ "$result" = "$(printf 'ruff\nblack')" ]
}

@test "pkg_manifest_read skips blank lines and trims whitespace" {
  cat > "$TEST_TMP/m" <<'EOF'
   ruff

  black
EOF
  result=$(pkg_manifest_read "$TEST_TMP/m")
  [ "$result" = "$(printf 'ruff\nblack')" ]
}

@test "pkg_manifest_read preserves entries with @ and / characters" {
  cat > "$TEST_TMP/m" <<'EOF'
@anthropic-ai/claude-code
github.com/foo/bar/cmd/baz
EOF
  result=$(pkg_manifest_read "$TEST_TMP/m")
  [ "$result" = "$(printf '@anthropic-ai/claude-code\ngithub.com/foo/bar/cmd/baz')" ]
}

@test "pkg_manifest_read errors on missing file" {
  run pkg_manifest_read "$TEST_TMP/nonexistent"
  [ "$status" -ne 0 ]
}

@test "pkg_diff_only_in returns lines unique to first file, sorted" {
  printf 'b\na\nc\n' > "$TEST_TMP/a"
  printf 'b\nd\n' > "$TEST_TMP/b"
  result=$(pkg_diff_only_in "$TEST_TMP/a" "$TEST_TMP/b")
  [ "$result" = "$(printf 'a\nc')" ]
}

@test "pkg_diff_only_in handles empty second file" {
  printf 'a\nb\n' > "$TEST_TMP/a"
  : > "$TEST_TMP/b"
  result=$(pkg_diff_only_in "$TEST_TMP/a" "$TEST_TMP/b")
  [ "$result" = "$(printf 'a\nb')" ]
}

@test "pkg_diff_only_in returns empty when first file is subset of second" {
  printf 'a\n' > "$TEST_TMP/a"
  printf 'a\nb\n' > "$TEST_TMP/b"
  result=$(pkg_diff_only_in "$TEST_TMP/a" "$TEST_TMP/b")
  [ -z "$result" ]
}

@test "pkg_changed_versions returns empty when versions match" {
  printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/before"
  printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/after"
  result=$(pkg_changed_versions "$TEST_TMP/before" "$TEST_TMP/after")
  [ -z "$result" ]
}

@test "pkg_changed_versions emits packages whose version changed" {
  printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/before"
  printf 'ruff\t0.6.0\nblack\t24.1.0\n' > "$TEST_TMP/after"
  result=$(pkg_changed_versions "$TEST_TMP/before" "$TEST_TMP/after")
  [ "$result" = "ruff" ]
}

@test "pkg_changed_versions emits newly-installed packages" {
  printf 'ruff\t0.5.0\n' > "$TEST_TMP/before"
  printf 'ruff\t0.5.0\nmypy\t1.10.0\n' > "$TEST_TMP/after"
  result=$(pkg_changed_versions "$TEST_TMP/before" "$TEST_TMP/after")
  [ "$result" = "mypy" ]
}

@test "pkg_changed_versions does NOT emit packages that were removed" {
  printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/before"
  printf 'ruff\t0.5.0\n' > "$TEST_TMP/after"
  result=$(pkg_changed_versions "$TEST_TMP/before" "$TEST_TMP/after")
  [ -z "$result" ]
}

@test "pkg_is_help recognizes -h, --help, and help" {
  pkg_is_help -h
  pkg_is_help --help
  pkg_is_help help
}

@test "pkg_is_help rejects other tokens" {
  ! pkg_is_help list
  ! pkg_is_help sync
  ! pkg_is_help --update
  ! pkg_is_help ""
}

@test "pkg_args_contain_help finds --help among trailing args" {
  pkg_args_contain_help --update --help
  pkg_args_contain_help -h
  pkg_args_contain_help --all -h --update
}

@test "pkg_args_contain_help returns false when no help flag is present" {
  ! pkg_args_contain_help
  ! pkg_args_contain_help --update --all
  # Bare `help` is intentionally NOT a help flag at the args-list level —
  # it would collide with valid positional values (service names, etc.).
  ! pkg_args_contain_help help
}
