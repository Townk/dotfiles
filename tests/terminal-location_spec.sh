# Regression tests for terminal-location classification (WezTerm remote tint).

Describe 'terminal-location.zsh — mapping helpers'
  setup() {
    TEST_TMP=$(mktemp -d)
    export TERMINAL_LOCATION_CONFIG="$TEST_TMP/terminal-location.yaml"
    cat > "$TERMINAL_LOCATION_CONFIG" <<'EOF'
sessions:
  home:
    - "Home Lab"
  dev:
    - "Dev Box"
hosts:
  home:
    - "mini"
  dev:
    - "dev-shell"
EOF
    . "$SHELLSPEC_PROJECT_ROOT/home/dot_config/zellij/scripts/lib/terminal-location.zsh"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'maps exact session names from config'
    When call tl_session_to_location "Home Lab" "$TERMINAL_LOCATION_CONFIG"
    The output should equal "home"
    The status should be success
  End

  It 'maps host substrings case-insensitively'
    When call tl_command_to_location "ssh dev-shell.example" "$TERMINAL_LOCATION_CONFIG"
    The output should equal "dev"
    The status should be success
  End

  It 'detects ssh commands'
    When call tl_command_is_ssh "ssh mini.local zellij"
    The status should be success
  End
End

Describe 'terminal-location.zsh — resolve_terminal_location'
  setup() {
    TEST_TMP=$(mktemp -d)
    export TERMINAL_LOCATION_CONFIG="$TEST_TMP/terminal-location.yaml"
    printf 'sessions:\n  dev:\n    - "Nested Dev"\n' > "$TERMINAL_LOCATION_CONFIG"

    . "$SHELLSPEC_PROJECT_ROOT/home/dot_config/zellij/scripts/lib/terminal-location.zsh"
    resolve_session() { print -r -- "Nested Dev"; }
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'classifies configured zellij session names'
    ps() {
      if [[ "$*" == *"-p 99999"* && "$*" == *"comm="* ]]; then
        print -r -- "zellij"
        return 0
      fi
      command ps "$@"
    }
    When call resolve_terminal_location 99999
    The output should equal "dev"
    The status should be success
  End

  It 'classifies bare ssh foreground processes'
    ps() {
      if [[ "$*" == *"-p 4242"* && "$*" == *"comm="* ]]; then
        print -r -- "ssh"
        return 0
      fi
      if [[ "$*" == *"-p 4242"* && "$*" == *"args="* ]]; then
        print -r -- "ssh mini"
        return 0
      fi
      command ps "$@"
    }
    When call resolve_terminal_location 4242
    The output should equal "remote"
    The status should be success
  End

  It 'classifies nested quick-launch sessions without config as remote'
    printf '' > "$TERMINAL_LOCATION_CONFIG"
    export NESTED_REG="$TEST_TMP/nested-sessions"
    print -r -- "Remote Only" > "$NESTED_REG"
    tl_is_nested_session() { grep -Fxq "$1" "$NESTED_REG" 2>/dev/null; }
    resolve_session() { print -r -- "Remote Only"; }
    ps() {
      if [[ "$*" == *"-p 77777"* && "$*" == *"comm="* ]]; then
        print -r -- "zellij"
        return 0
      fi
      command ps "$@"
    }
    When call resolve_terminal_location 77777
    The output should equal "remote"
    The status should be success
  End
End
