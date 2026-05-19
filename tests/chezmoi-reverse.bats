#!/usr/bin/env bats

setup() {
  TEST_TMP=$(mktemp -d)
  export HOME="$TEST_TMP/home"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME CHEZMOI_CONFIG_FILE
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
