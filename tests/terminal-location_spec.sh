# Regression tests for terminal-location: pick a named palette tint from the
# onboard map (per-machine `color` override → profile default → grey).

Describe 'terminal-location.zsh — named-tint classification'
  setup() {
    TEST_TMP=$(mktemp -d)
    export TERMINAL_LOCATION_ONBOARD_MAP="$TEST_TMP/onboard-map.yaml"
    # macmini has an explicit color override; devbox falls back to its profile.
    cat > "$TERMINAL_LOCATION_ONBOARD_MAP" <<'EOF'
slot-aaaaaa:
  alias: macmini
  profile: personal
  kind: human
  color: teal
slot-bbbbbb:
  alias: devbox
  profile: dev-shell
  kind: headless
EOF
    # ssh config.d: macmini reaches a real hostname; devbox is used by alias.
    export TERMINAL_LOCATION_SSH_CONFIG_DIR="$TEST_TMP/config.d"
    mkdir -p "$TERMINAL_LOCATION_SSH_CONFIG_DIR"
    printf 'Host macmini\n    HostName macmini-aa-bbbb.local\n' \
      > "$TERMINAL_LOCATION_SSH_CONFIG_DIR/macmini.conf"
    . "$SHELLSPEC_PROJECT_ROOT/home/dot_config/zellij/scripts/lib/terminal-location.zsh"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'tl_ssh_target'
    It 'extracts a bare host'
      When call tl_ssh_target "ssh devbox"
      The output should equal "devbox"
    End
    It 'strips user@ and arg-taking option flags'
      When call tl_ssh_target "ssh -p 2222 -i key user@devbox"
      The output should equal "devbox"
    End
    It 'handles an absolute ssh path'
      When call tl_ssh_target "/usr/bin/ssh devbox"
      The output should equal "devbox"
    End
    It 'is empty for a non-ssh command'
      When call tl_ssh_target "nvim foo"
      The output should equal ""
    End
  End

  Describe 'tl_colorname_for_target'
    It 'uses an explicit per-machine color override'
      When call tl_colorname_for_target "macmini"
      The output should equal "teal"
      The status should be success
    End
    It 'falls back to the profile default when no color is set'
      When call tl_colorname_for_target "devbox"
      The output should equal "blue"
      The status should be success
    End
    It 'resolves a real hostname to its alias via ssh config.d'
      When call tl_colorname_for_target "macmini-aa-bbbb.local"
      The output should equal "teal"
      The status should be success
    End
    It 'fails for a host not in the map or config.d'
      When call tl_colorname_for_target "nope"
      The status should be failure
    End
  End

  Describe 'tl_classify_command'
    It 'returns the color for an onboarded ssh target'
      When call tl_classify_command "ssh macmini"
      The output should equal "teal"
    End
    It 'returns the remote default color for an unmapped ssh host'
      When call tl_classify_command "ssh someother"
      The output should equal "grey"
    End
    It 'fails (caller treats as local) for a non-ssh command'
      When call tl_classify_command "vim file"
      The status should be failure
    End
  End

  Describe 'resolve_terminal_location'
    It 'classifies a bare ssh pane to an onboarded host'
      ps() {
        case "$*" in
          *"-p 4242"*comm=*) print -r -- "ssh"; return 0 ;;
          *"-p 4242"*args=*) print -r -- "ssh macmini"; return 0 ;;
        esac
        command ps "$@"
      }
      When call resolve_terminal_location 4242
      The output should equal "teal"
    End

    It 'classifies a nested zellij session by its ssh target'
      ps() { case "$*" in *"-p 5555"*comm=*) print -r -- "zellij"; return 0 ;; esac; command ps "$@"; }
      resolve_session() { print -r -- "Some Dev Session"; }
      tl_focused_pane_command() { print -r -- "ssh devbox"; }
      When call resolve_terminal_location 5555
      The output should equal "blue"
    End

    It 'classifies a nested session that sshes to a real hostname'
      ps() { case "$*" in *"-p 5556"*comm=*) print -r -- "zellij"; return 0 ;; esac; command ps "$@"; }
      resolve_session() { print -r -- "Home Session"; }
      tl_focused_pane_command() { print -r -- "ssh macmini-aa-bbbb.local"; }
      When call resolve_terminal_location 5556
      The output should equal "teal"
    End

    It 'returns the remote default for a session to a non-onboarded host'
      ps() { case "$*" in *"-p 5557"*comm=*) print -r -- "zellij"; return 0 ;; esac; command ps "$@"; }
      resolve_session() { print -r -- "Some Session"; }
      tl_focused_pane_command() { print -r -- "ssh elsewhere"; }
      When call resolve_terminal_location 5557
      The output should equal "grey"
    End

    It 'returns local for a non-ssh local pane'
      ps() {
        case "$*" in
          *"-p 6666"*comm=*) print -r -- "zsh"; return 0 ;;
          *"-p 6666"*args=*) print -r -- "-zsh"; return 0 ;;
        esac
        command ps "$@"
      }
      When call resolve_terminal_location 6666
      The output should equal "local"
    End
  End
End
