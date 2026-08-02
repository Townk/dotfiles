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
    SECRETS_BLOB_DIR="$TEST_TMP/secrets"
    FRAGMENT_DIR="$TEST_TMP/frags"
    MANIFEST="$TEST_TMP/secrets.yaml"
    cat >"$MANIFEST" <<'YAML'
secrets:
  - name: EXISTING_ONE
    prompt: an existing secret
    requiredFor: [personal]
YAML
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

  Describe 'sec::map_clear_color'
    It 'removes a previously set color'
      sec::map_set slot-abc123 host-a personal human ""
      sec::map_set_color slot-abc123 teal
      sec::map_clear_color slot-abc123
      When call sec::map_get slot-abc123 color
      The output should equal ""
    End

    It 'leaves managed fields intact'
      sec::map_set slot-abc123 host-a personal human ""
      sec::map_set_color slot-abc123 teal
      sec::map_clear_color slot-abc123
      When call sec::map_get slot-abc123 alias
      The output should equal "host-a"
    End

    It 'is a no-op when the slot has no color'
      sec::map_set slot-abc123 host-a personal human ""
      When call sec::map_clear_color slot-abc123
      The status should be success
    End
  End

  Describe 'per-secret blob paths'
    It 'places a blob under the slot directory keyed by NAME'
      When call sec::blob_path slot-abc123 FOO
      The output should equal "$SECRETS_BLOB_DIR/slot-abc123/FOO.sops.sh"
    End

    It 'exposes the slot blob directory'
      When call sec::blob_dir slot-abc123
      The output should equal "$SECRETS_BLOB_DIR/slot-abc123"
    End

    It 'keeps the legacy monolithic path for migration detection'
      When call sec::legacy_blob_path slot-abc123
      The output should equal "$SECRETS_BLOB_DIR/slot-abc123.sops.sh"
    End
  End

  Describe 'sec::manifest_add'
    It 'appends a new secret with prompt and profiles'
      sec::manifest_add NEW_ONE "a new secret" "personal,work"
      When call sec::manifest_prompt NEW_ONE
      The output should equal "a new secret"
    End

    It 'makes the new secret visible to profile queries'
      sec::manifest_add NEW_ONE "a new secret" "personal,work"
      When call sec::manifest_names_for_profile work
      The line 1 should equal "NEW_ONE"
    End
  End

  Describe 'sec::manifest_add_profile'
    It 'adds a missing profile to an existing secret and reports success'
      When call sec::manifest_add_profile EXISTING_ONE work
      The status should be success
    End

    It 'includes the added profile in the secret requiredFor'
      sec::manifest_add_profile EXISTING_ONE work
      When call sec::manifest_names_for_profile work
      The line 1 should equal "EXISTING_ONE"
    End

    It 'is a no-op returning failure when the profile is already present'
      When call sec::manifest_add_profile EXISTING_ONE personal
      The status should be failure
    End
  End

  # SEC-1: the human fragment is a .tmpl sourced by every shell + the launchd
  # agent. chezmoi splices the 1Password VALUE in at render time, so the value
  # MUST be inert in shell: single-quoted, with each embedded single quote
  # escaped via a Go-template `replace`. A bare double-quoted value breaks on a
  # literal quote and evaluates $(...)/`...`/$VAR on every shell start — a real
  # risk for BACKUP_REPO_PASSPHRASE (a restic passphrase, not an alnum token).
  Describe 'sec::write_human_fragment (SEC-1: shell-safe interpolation)'
    # op stub: chezmoi's `output "op" ...` resolves via PATH, so a stub that
    # echoes OP_TEST_VALUE (no trailing newline) lets us render a chosen value.
    op_stub_setup() {
      STUB="$TEST_TMP/stub"; mkdir -p "$STUB"
      printf '#!/bin/sh\nprintf %%s "$OP_TEST_VALUE"\n' >"$STUB/op"
      chmod +x "$STUB/op"
    }
    BeforeEach 'op_stub_setup'

    It 'emits a single-quoted assignment escaped through replace'
      esc='| replace "'\''" "'\''\"'\''\"'\''"'
      sec::write_human_fragment slot-abc123 "FOO=op://Vault/FOO/deadbe"
      frag="$FRAGMENT_DIR/private_slot-abc123.sh.tmpl"
      The contents of file "$frag" should include "export FOO='{{ output"
      The contents of file "$frag" should include "$esc"
    End

    It 'does not emit the unsafe bare double-quoted value form'
      sec::write_human_fragment slot-abc123 "FOO=op://Vault/FOO/deadbe"
      frag="$FRAGMENT_DIR/private_slot-abc123.sh.tmpl"
      The contents of file "$frag" should not include "export FOO=\"{{ output"
    End

    # Render a representative dangerous VALUE through the emitted template line
    # (op stubbed to return it) and confirm it decodes back to the exact literal
    # with no shell evaluation and no broken quoting. Expected is the input
    # literal, derived from the shell-quoting spec — not by re-running the code.
    render_value() {
      local val="$1" frag line rendered FOO
      sec::write_human_fragment slot-abc123 "FOO=op://Vault/FOO/deadbe"
      frag="$FRAGMENT_DIR/private_slot-abc123.sh.tmpl"
      line="$(grep -- '^export FOO=' "$frag")"
      rendered="$(OP_TEST_VALUE="$val" PATH="$STUB:$PATH" chezmoi execute-template "$line")"
      eval "$rendered"
      print -r -- "$FOO"
    }

    Parameters
      'p@ss"word'
      "a'b"
      '`id`'
      '$(id)'
      '$HOME'
    End

    It "round-trips a dangerous value to the exact literal ($1)"
      When call render_value "$1"
      The output should equal "$1"
    End
  End

  # HI-10: rotating a human slot's secret leaves the name=ref set byte-identical,
  # so the OLD cache signature was reproduced verbatim, the commit was empty, and
  # every OTHER machine's next `chezmoi apply` matched its op-cache and re-emitted
  # the STALE value — a rotated/compromised credential never propagated. The fix
  # folds a per-slot rotation stamp into the cache signature: a rotate advances the
  # stamp, which changes the committed fragment's sig, so every target's next apply
  # misses its cache and re-resolves the NEW value. A NORMAL apply (no rotation)
  # must still reproduce the identical sig so the Touch-ID-avoiding cache still hits.
  Describe 'sec::write_human_fragment (HI-10: rotation invalidates target cache)'
    # First byte-word of the op-cache-v1 signature line inside the fragment.
    cache_sig() { sed -n 's/^# chezmoi: op-cache-v1 //p' "$1" | head -n1; }

    It 'produces a DIFFERENT cache signature after a rotation stamp bump (same refs)'
      frag="$FRAGMENT_DIR/private_slot-abc123.sh.tmpl"
      sec::write_human_fragment slot-abc123 "FOO=op://Vault/FOO/deadbe"
      before="$(cache_sig "$frag")"
      sec::bump_rotation_stamp slot-abc123
      sec::write_human_fragment slot-abc123 "FOO=op://Vault/FOO/deadbe"
      When call cache_sig "$frag"
      The output should not equal "$before"
    End

    It 'reproduces the IDENTICAL cache signature without a rotation (cache still hits)'
      frag="$FRAGMENT_DIR/private_slot-abc123.sh.tmpl"
      sec::write_human_fragment slot-abc123 "FOO=op://Vault/FOO/deadbe"
      before="$(cache_sig "$frag")"
      sec::write_human_fragment slot-abc123 "FOO=op://Vault/FOO/deadbe"
      When call cache_sig "$frag"
      The output should equal "$before"
    End

    It 'advances the rotation stamp strictly, even within one second'
      sec::bump_rotation_stamp slot-abc123
      first="$(sec::rotation_stamp slot-abc123)"
      sec::bump_rotation_stamp slot-abc123
      second="$(sec::rotation_stamp slot-abc123)"
      When call test "$second" -gt "$first"
      The status should be success
    End
  End

  # sec::op_use_service is the resolution-time analog of environment.sh's
  # over-SSH block: both must fire on the FULL canonical remote triple
  # (SSH_TTY / SSH_CONNECTION / SSH_CLIENT), the identity of mux::is_remote.
  # The regression these guard: an SSH_TTY-only `ssh -T` login (no pty) was
  # misclassified as local because SSH_TTY was dropped. Each var is set
  # explicitly (including to "") so ambient SSH state cannot leak in.
  Describe 'sec::op_use_service (mirror of environment.sh / mux::is_remote)'
    use_service() { SSH_TTY="$1" SSH_CONNECTION="$2" SSH_CLIENT="$3" sec::op_use_service; }

    It 'selects service mode for an SSH_TTY-only (ssh -T) session'
      When call use_service /dev/pts/3 "" ""
      The status should be success
    End

    It 'selects service mode when only SSH_CONNECTION is set'
      When call use_service "" "10.0.0.1 5 10.0.0.2 22" ""
      The status should be success
    End

    It 'selects service mode when only SSH_CLIENT is set'
      When call use_service "" "" "10.0.0.1 5 22"
      The status should be success
    End

    It 'stays in account mode locally (no SSH vars)'
      When call use_service "" "" ""
      The status should be failure
    End
  End
End
