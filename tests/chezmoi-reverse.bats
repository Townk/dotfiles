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
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage: chezmoi-reverse"* ]] || [[ "$output" == *"usage: chezmoi-reverse"* ]]
}

@test "clean: unchanged destination reports clean and exits 0" {
  printf 'name = thiago\n' > "$TEST_TMP/src/dot_foo.tmpl"
  chezmoi apply
  run "$SCRIPT" "$HOME/.foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [[ "$output" == *".foo"* ]]
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
  [ "$status" -eq 0 ]
  [[ "$output" == *"applied"* ]]

  # The templated line must still be in template form, the literal line updated.
  run cat "$TEST_TMP/src/dot_foo.tmpl"
  [[ "$output" == *"name = alice"* ]]
  [[ "$output" == *"role = {{ .role }}"* ]]
  [ ! -e "$TEST_TMP/merge-invoked" ]
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
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged"* ]]

  # Merge stub must have been invoked.
  [ -f "$TEST_TMP/merge-invoked" ]

  # Template must be byte-identical to its pre-run state (the merge stub is a
  # no-op; we only verify our backup-and-restore worked).
  run diff "$TEST_TMP/template-before" "$TEST_TMP/src/dot_foo.tmpl"
  [ "$status" -eq 0 ]

  # No stray reject or backup files left behind in the source dir.
  [ ! -e "$TEST_TMP/src/dot_foo.tmpl.rej" ]
  [ ! -e "$TEST_TMP/src/dot_foo.tmpl.orig" ]
  [ ! -e "$TEST_TMP/src/dot_foo.tmpl.bak" ]
}
