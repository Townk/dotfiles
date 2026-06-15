#!/usr/bin/env bats

setup() {
  TEST_TMP=$(mktemp -d)
  source "$BATS_TEST_DIRNAME/../home/dot_local/lib/system-package-common.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "pkg::manifest_read strips full-line comments" {
  cat > "$TEST_TMP/m" <<'EOF'
# top comment
ruff
# middle comment
black
EOF
  result=$(pkg::manifest_read "$TEST_TMP/m")
  [ "$result" = "$(printf 'ruff\nblack')" ]
}

@test "pkg::manifest_read strips inline trailing comments" {
  cat > "$TEST_TMP/m" <<'EOF'
ruff   # linter
black  # formatter
EOF
  result=$(pkg::manifest_read "$TEST_TMP/m")
  [ "$result" = "$(printf 'ruff\nblack')" ]
}

@test "pkg::manifest_read skips blank lines and trims whitespace" {
  cat > "$TEST_TMP/m" <<'EOF'
   ruff

  black
EOF
  result=$(pkg::manifest_read "$TEST_TMP/m")
  [ "$result" = "$(printf 'ruff\nblack')" ]
}

@test "pkg::manifest_read preserves entries with @ and / characters" {
  cat > "$TEST_TMP/m" <<'EOF'
@anthropic-ai/claude-code
github.com/foo/bar/cmd/baz
EOF
  result=$(pkg::manifest_read "$TEST_TMP/m")
  [ "$result" = "$(printf '@anthropic-ai/claude-code\ngithub.com/foo/bar/cmd/baz')" ]
}

@test "pkg::manifest_read errors on missing file" {
  run pkg::manifest_read "$TEST_TMP/nonexistent"
  [ "$status" -ne 0 ]
}

@test "pkg::diff_only_in returns lines unique to first file, sorted" {
  printf 'b\na\nc\n' > "$TEST_TMP/a"
  printf 'b\nd\n' > "$TEST_TMP/b"
  result=$(pkg::diff_only_in "$TEST_TMP/a" "$TEST_TMP/b")
  [ "$result" = "$(printf 'a\nc')" ]
}

@test "pkg::diff_only_in handles empty second file" {
  printf 'a\nb\n' > "$TEST_TMP/a"
  : > "$TEST_TMP/b"
  result=$(pkg::diff_only_in "$TEST_TMP/a" "$TEST_TMP/b")
  [ "$result" = "$(printf 'a\nb')" ]
}

@test "pkg::diff_only_in returns empty when first file is subset of second" {
  printf 'a\n' > "$TEST_TMP/a"
  printf 'a\nb\n' > "$TEST_TMP/b"
  result=$(pkg::diff_only_in "$TEST_TMP/a" "$TEST_TMP/b")
  [ -z "$result" ]
}

@test "pkg::changed_versions returns empty when versions match" {
  printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/before"
  printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/after"
  result=$(pkg::changed_versions "$TEST_TMP/before" "$TEST_TMP/after")
  [ -z "$result" ]
}

@test "pkg::changed_versions emits packages whose version changed" {
  printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/before"
  printf 'ruff\t0.6.0\nblack\t24.1.0\n' > "$TEST_TMP/after"
  result=$(pkg::changed_versions "$TEST_TMP/before" "$TEST_TMP/after")
  [ "$result" = "ruff" ]
}

@test "pkg::changed_versions emits newly-installed packages" {
  printf 'ruff\t0.5.0\n' > "$TEST_TMP/before"
  printf 'ruff\t0.5.0\nmypy\t1.10.0\n' > "$TEST_TMP/after"
  result=$(pkg::changed_versions "$TEST_TMP/before" "$TEST_TMP/after")
  [ "$result" = "mypy" ]
}

@test "pkg::changed_versions does NOT emit packages that were removed" {
  printf 'ruff\t0.5.0\nblack\t24.1.0\n' > "$TEST_TMP/before"
  printf 'ruff\t0.5.0\n' > "$TEST_TMP/after"
  result=$(pkg::changed_versions "$TEST_TMP/before" "$TEST_TMP/after")
  [ -z "$result" ]
}

# is_help / args_contain_help now live in the base; see tests/common.bats.

@test "pkg::restart_changed is a no-op (exit 0) when system-service is absent" {
  printf 'ruff\t1.0\n' > "$TEST_TMP/before"
  printf 'ruff\t2.0\nmypy\t1.0\n' > "$TEST_TMP/after"
  # system-service is not on PATH in the test env, so pkg::restart_services_for
  # short-circuits; the helper must still complete cleanly.
  run pkg::restart_changed "$TEST_TMP/before" "$TEST_TMP/after"
  [ "$status" -eq 0 ]
}
