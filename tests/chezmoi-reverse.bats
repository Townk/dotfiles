#!/usr/bin/env bats

setup() {
  TEST_TMP=$(mktemp -d)
  export HOME="$TEST_TMP/home"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME CHEZMOI_CONFIG_FILE CHEZMOI_SOURCE_DIR CHEZMOI_HOME_DIR
  mkdir -p "$HOME" "$HOME/.config/chezmoi" "$TEST_TMP/src"

  # Stub merge tool that records its arguments to a sentinel file.
  cat > "$TEST_TMP/stub-merge" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TMP/merge-invoked"
EOF
  chmod +x "$TEST_TMP/stub-merge"

  # chezmoi config: point source at our temp dir, route merges to the stub,
  # provide a data value so templates can render.
  cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$TEST_TMP/src"

[merge]
  command = "$TEST_TMP/stub-merge"
  args = ["{{ .Destination }}", "{{ .Source }}", "{{ .Target }}"]

[data]
  role = "engineer"
EOF

  SCRIPT="$BATS_TEST_DIRNAME/../dot_local/bin/executable_chezmoi-reverse"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "usage: no args exits 2 with usage line on stderr" {
  run "$SCRIPT"
  [ "$status" -eq 2 ] || false
  { [[ "$stderr" == *"usage: chezmoi-reverse"* ]] || [[ "$output" == *"usage: chezmoi-reverse"* ]]; } || false
}

@test "clean: unchanged destination reports clean and exits 0" {
  printf 'name = thiago\n' > "$TEST_TMP/src/dot_foo.tmpl"
  chezmoi apply
  run "$SCRIPT" "$HOME/.foo"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"clean"* ]] || false
  [[ "$output" == *".foo"* ]] || false
}

@test "applied: change to a literal line is patched into the template" {
  cat > "$TEST_TMP/src/dot_foo.tmpl" <<'EOF'
name = thiago
role = {{ .role }}
EOF
  chezmoi apply
  # Edit only the literal first line in the destination.
  sed -i.bak 's/^name = thiago$/name = alice/' "$HOME/.foo"; rm "$HOME/.foo.bak"

  run "$SCRIPT" "$HOME/.foo"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"applied"* ]] || false

  # The templated line must still be in template form, the literal line updated.
  run cat "$TEST_TMP/src/dot_foo.tmpl"
  [[ "$output" == *"name = alice"* ]] || false
  [[ "$output" == *"role = {{ .role }}"* ]] || false
  [ ! -e "$TEST_TMP/merge-invoked" ] || false
}

@test "merged: change to a templated line restores template and invokes merge" {
  cat > "$TEST_TMP/src/dot_foo.tmpl" <<'EOF'
name = thiago
role = {{ .role }}
EOF
  chezmoi apply
  # Capture template byte-for-byte before the edit.
  cp "$TEST_TMP/src/dot_foo.tmpl" "$TEST_TMP/template-before"

  # Edit the rendered form of the templated line in the destination.
  sed -i.bak 's/^role = engineer$/role = manager/' "$HOME/.foo"; rm "$HOME/.foo.bak"

  run "$SCRIPT" "$HOME/.foo"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"merged"* ]] || false

  # Merge stub must have been invoked.
  [ -f "$TEST_TMP/merge-invoked" ] || false

  # Template must be byte-identical to its pre-run state (the merge stub is a
  # no-op; we only verify our backup-and-restore worked).
  run diff "$TEST_TMP/template-before" "$TEST_TMP/src/dot_foo.tmpl"
  [ "$status" -eq 0 ] || false

  # No stray reject or backup files left behind in the source dir.
  [ ! -e "$TEST_TMP/src/dot_foo.tmpl.rej" ] || false
  [ ! -e "$TEST_TMP/src/dot_foo.tmpl.orig" ] || false
  [ ! -e "$TEST_TMP/src/dot_foo.tmpl.bak" ] || false
}

@test "applied: non-template file is re-added via chezmoi re-add" {
  printf 'literal one\nliteral two\n' > "$TEST_TMP/src/dot_bar"
  chezmoi apply
  printf 'literal one\nliteral CHANGED\n' > "$HOME/.bar"

  run "$SCRIPT" "$HOME/.bar"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"applied"* ]] || false

  run cat "$TEST_TMP/src/dot_bar"
  [[ "$output" == *"literal CHANGED"* ]] || false
  [ ! -f "$TEST_TMP/merge-invoked" ] || false
}

@test "multi: clean + applied across two files exits 0 with both statuses" {
  printf 'unchanged\n' > "$TEST_TMP/src/dot_a.tmpl"
  printf 'before\n' > "$TEST_TMP/src/dot_b.tmpl"
  chezmoi apply
  printf 'after\n' > "$HOME/.b"

  run "$SCRIPT" "$HOME/.a" "$HOME/.b"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"clean"* ]] || false
  [[ "$output" == *"applied"* ]] || false
  [[ "$output" == *".a"* ]] || false
  [[ "$output" == *".b"* ]] || false
}

@test "clean: unchanged non-template destination reports clean" {
  printf 'literal one\nliteral two\n' > "$TEST_TMP/src/dot_baz"
  chezmoi apply
  # No edit; destination should be byte-identical to source.

  run "$SCRIPT" "$HOME/.baz"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *".baz"* ]] || false
  [[ "$output" == *"clean"* ]] || false
}

@test "multi: unmanaged file causes non-zero exit but other files still process" {
  printf 'x\n' > "$TEST_TMP/src/dot_a.tmpl"
  chezmoi apply

  run "$SCRIPT" "$HOME/does-not-exist" "$HOME/.a"
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"failed"* ]] || false
  [[ "$output" == *"clean"* ]] || false
}

@test "skipped: symlink template is skipped without touching source" {
  # Source content is the symlink target; chezmoi apply creates ~/.mylink
  # pointing there. Reverse-propagating an edit to a symlink target string
  # isn't meaningful, so the script should refuse with 'skipped'.
  printf '/tmp/some-target\n' > "$TEST_TMP/src/symlink_dot_mylink"
  chezmoi apply
  cp "$TEST_TMP/src/symlink_dot_mylink" "$TEST_TMP/source-before"

  run "$SCRIPT" "$HOME/.mylink"
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"skipped"* ]] || false
  [[ "$output" == *".mylink"* ]] || false

  run diff "$TEST_TMP/source-before" "$TEST_TMP/src/symlink_dot_mylink"
  [ "$status" -eq 0 ] || false
}
