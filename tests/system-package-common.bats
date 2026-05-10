#!/usr/bin/env bats

setup() {
  TEST_TMP=$(mktemp -d)
  source "$BATS_TEST_DIRNAME/../dot_local/lib/system-package-common.sh"
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
