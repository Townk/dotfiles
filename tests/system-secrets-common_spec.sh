# Tests for home/dot_local/lib/system-secrets-common.zsh — the operator-map
# writers. sec::map_set must MERGE over an existing entry (so an unmanaged field
# such as a per-machine `color` window-tint survives a re-onboard), and
# sec::map_set_color must set that field. A temp OPERATOR_MAP keeps the real
# ~/.config/chezmoi/onboard-map.yaml untouched.
Describe 'system-secrets-common.zsh'
  Include home/dot_local/lib/system-secrets-common.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    OPERATOR_MAP="$TEST_TMP/onboard-map.yaml"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'sec::map_set'
    It 'records a managed field for a slot'
      sec::map_set slot-abc123 host-a personal human ""
      When call sec::map_get slot-abc123 profile
      The output should equal "personal"
    End

    It 'updates managed fields when re-recording an existing slot'
      sec::map_set slot-abc123 host-a personal human ""
      sec::map_set slot-abc123 host-b personal human ""
      When call sec::map_get slot-abc123 alias
      The output should equal "host-b"
    End

    It 'preserves an unmanaged color field across a re-record (merge, not clobber)'
      sec::map_set slot-abc123 host-a personal human ""
      sec::map_set_color slot-abc123 teal
      sec::map_set slot-abc123 host-b personal human ""
      When call sec::map_get slot-abc123 color
      The output should equal "teal"
    End
  End

  Describe 'sec::map_set_color'
    It 'sets the color field on a slot'
      sec::map_set slot-abc123 host-a personal human ""
      sec::map_set_color slot-abc123 cyan
      When call sec::map_get slot-abc123 color
      The output should equal "cyan"
    End
  End
End
