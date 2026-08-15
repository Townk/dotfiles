# Tests for the remove/sync layer of system-secrets-common.zsh — manifest
# removal helpers, committed-artifact readers (kind detection, human pair
# parsing), the per-slot scrub, and the two orchestrators. Everything runs
# against a temp git repo standing in for the chezmoi source, with the
# operator map, vault cache, and leak patterns pointed at temp files; the
# interactive seams (prompt::confirm, sec::materialize_secret,
# sec::sync_can_collect) are overridden per example.
Describe 'system-secrets remove/sync'
  Include home/dot_local/lib/system-secrets-common.zsh

  setup() {
    TEST_TMP=$(mktemp -d)
    REPO_ROOT="$TEST_TMP/repo"
    mkdir -p "$REPO_ROOT"
    git -C "$REPO_ROOT" init -q
    git -C "$REPO_ROOT" config user.email test@example.com
    git -C "$REPO_ROOT" config user.name Test
    git -C "$REPO_ROOT" config commit.gpgsign false
    MANIFEST="$REPO_ROOT/secrets.yaml"
    FRAGMENT_DIR="$REPO_ROOT/frags"
    SECRETS_BLOB_DIR="$REPO_ROOT/secrets"
    SOPS_YAML="$REPO_ROOT/.sops.yaml"
    LEAK_PATTERNS="$REPO_ROOT/.leak-patterns"
    GENERATIONS="$SECRETS_BLOB_DIR/generations.yaml"
    print -r -- '# no patterns' >"$LEAK_PATTERNS"
    OPERATOR_MAP="$TEST_TMP/onboard-map.yaml"
    OP_VAULT_FILE="$TEST_TMP/op-vault"
    mkdir -p "$FRAGMENT_DIR" "$SECRETS_BLOB_DIR"
    cat >"$MANIFEST" <<'YAML'
secrets:
  - name: ALPHA_TOKEN
    prompt: alpha
    requiredFor: [personal, work]
  - name: BETA_TOKEN
    prompt: beta
    requiredFor: [personal]
  - name: GAMMA_TOKEN
    prompt: gamma
    requiredFor: [dev-shell]
YAML
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Build a headless slot: blobs (stand-in plaintext files) + fragment.
  make_headless() { # <slot> <name>...
    local slot="$1"
    shift
    local n
    mkdir -p "$SECRETS_BLOB_DIR/$slot"
    for n in "$@"; do print -r -- cipher >"$SECRETS_BLOB_DIR/$slot/$n.sops.sh"; done
    sec::write_headless_fragment "$slot" "$@"
  }

  # Build a human slot from NAME=op://ref pairs.
  make_human() { # <slot> <pair>...
    local slot="$1"
    shift
    sec::write_human_fragment "$slot" "$@"
  }

  Describe 'sec::manifest_remove_profile'
    It 'narrows requiredFor and reports the change'
      When call sec::manifest_remove_profile ALPHA_TOKEN work
      The status should be success
      The contents of file "$MANIFEST" should not include "work"
      The contents of file "$MANIFEST" should include "personal"
    End

    It 'returns failure when the profile was not required'
      When call sec::manifest_remove_profile BETA_TOKEN work
      The status should be failure
    End
  End

  Describe 'sec::manifest_remove'
    It 'deletes the whole entry'
      sec::manifest_remove BETA_TOKEN
      When call sec::manifest_has BETA_TOKEN
      The status should be failure
    End
  End

  Describe 'sec::manifest_profiles_for'
    It 'lists the profiles requiring a name'
      When call sec::manifest_profiles_for ALPHA_TOKEN
      The line 1 of output should equal "personal"
      The line 2 of output should equal "work"
    End
  End

  Describe 'sec::slot_kind_from_fragment'
    It 'detects a headless slot'
      make_headless slot-aaa111 ALPHA_TOKEN
      When call sec::slot_kind_from_fragment slot-aaa111
      The output should equal "headless"
    End

    It 'detects a human slot even with no exports left'
      make_human slot-bbb222
      When call sec::slot_kind_from_fragment slot-bbb222
      The output should equal "human"
    End

    It 'is empty for a slot with no fragment'
      When call sec::slot_kind_from_fragment slot-ccc333
      The output should equal ""
    End
  End

  Describe 'sec::human_slot_pairs'
    It 'round-trips the pairs the writer emitted'
      make_human slot-bbb222 "ALPHA_TOKEN=op://V/ALPHA_TOKEN/bbb222" "BETA_TOKEN=op://V/BETA_TOKEN/bbb222"
      When call sec::human_slot_pairs slot-bbb222
      The line 1 of output should equal "ALPHA_TOKEN=op://V/ALPHA_TOKEN/bbb222"
      The line 2 of output should equal "BETA_TOKEN=op://V/BETA_TOKEN/bbb222"
    End
  End

  Describe 'sec::scrub_slot_name'
    It 'removes a headless blob and its fragment line, keeping the rest'
      make_headless slot-aaa111 ALPHA_TOKEN GAMMA_TOKEN
      When call sec::scrub_slot_name slot-aaa111 GAMMA_TOKEN
      The status should be success
      The file "$SECRETS_BLOB_DIR/slot-aaa111/GAMMA_TOKEN.sops.sh" should not be exist
      The contents of file "$(sec::fragment_path slot-aaa111)" should not include "GAMMA_TOKEN"
      The contents of file "$(sec::fragment_path slot-aaa111)" should include "ALPHA_TOKEN"
    End

    It 'removes a human pair, keeping the rest'
      make_human slot-bbb222 "ALPHA_TOKEN=op://V/ALPHA_TOKEN/bbb222" "BETA_TOKEN=op://V/BETA_TOKEN/bbb222"
      When call sec::scrub_slot_name slot-bbb222 ALPHA_TOKEN
      The status should be success
      The contents of file "$(sec::fragment_path slot-bbb222)" should not include "ALPHA_TOKEN"
      The contents of file "$(sec::fragment_path slot-bbb222)" should include "BETA_TOKEN"
    End

    It 'reports no change for a name the slot does not carry'
      make_headless slot-aaa111 ALPHA_TOKEN
      When call sec::scrub_slot_name slot-aaa111 BETA_TOKEN
      The status should be failure
    End
  End

  commit_count() { git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || print -r -- 0; }

  Describe 'sec::sync_slot'
    It 'reports an already-synced slot without committing'
      sec::map_set slot-aaa111 host-a personal headless ""
      make_headless slot-aaa111 ALPHA_TOKEN BETA_TOKEN
      sec::sync_slot slot-aaa111 personal >"$TEST_TMP/out" 2>&1
      When call commit_count
      The output should equal "0"
      The contents of file "$TEST_TMP/out" should include "already in sync"
    End

    It 'scrubs stale names and commits'
      sec::map_set slot-aaa111 host-a personal headless ""
      make_headless slot-aaa111 ALPHA_TOKEN BETA_TOKEN GAMMA_TOKEN
      sec::sync_slot slot-aaa111 personal >/dev/null 2>&1
      When call git -C "$REPO_ROOT" log --format=%s -1
      The output should equal "feat(secrets): sync slot-aaa111"
      The file "$SECRETS_BLOB_DIR/slot-aaa111/GAMMA_TOKEN.sops.sh" should not be exist
    End

    It 'collects missing names through the materialize seam when interactive'
      sec::map_set slot-aaa111 host-a personal headless ""
      make_headless slot-aaa111 ALPHA_TOKEN
      sec::sync_can_collect() { return 0; }
      sec::materialize_secret() {
        print -r -- cipher >"$SECRETS_BLOB_DIR/$1/$2.sops.sh"
      }
      sec::sync_slot slot-aaa111 personal >/dev/null 2>&1
      When call git -C "$REPO_ROOT" log --format=%s -1
      The output should equal "feat(secrets): sync slot-aaa111"
      The file "$SECRETS_BLOB_DIR/slot-aaa111/BETA_TOKEN.sops.sh" should be exist
    End

    It 'only reports missing names without a terminal'
      sec::map_set slot-aaa111 host-a personal headless ""
      make_headless slot-aaa111 ALPHA_TOKEN
      sec::sync_can_collect() { return 1; }
      When call sec::sync_slot slot-aaa111 personal
      The status should be success
      The stderr should include "BETA_TOKEN"
      The file "$SECRETS_BLOB_DIR/slot-aaa111/BETA_TOKEN.sops.sh" should not be exist
    End

    It 'dies for a slot missing from the operator map'
      When run sec::sync_slot slot-zzz999 personal
      The status should be failure
      The stderr should include "operator map"
    End
  End

  Describe 'rotation broadcast'
    It 'round-trips generation stamps'
      sec::gen_set slot-aaa111 ALPHA_TOKEN 100
      When call sec::gen_get slot-aaa111 ALPHA_TOKEN
      The output should equal "100"
    End

    It 'reads 0 for a never-stamped generation and never-rotated manifest entry'
      When call sec::manifest_rotated ALPHA_TOKEN
      The output should equal "0"
    End

    It 're-collects a name whose generation predates the rotated stamp'
      sec::map_set slot-aaa111 host-a personal headless ""
      make_headless slot-aaa111 ALPHA_TOKEN BETA_TOKEN
      sec::manifest_set_rotated ALPHA_TOKEN 200
      sec::gen_set slot-aaa111 ALPHA_TOKEN 100
      sec::sync_can_collect() { return 0; }
      sec::materialize_secret() { print -r -- "$2" >>"$TEST_TMP/collected"; }
      sec::sync_slot slot-aaa111 personal >/dev/null 2>&1
      When call cat "$TEST_TMP/collected"
      The output should equal "ALPHA_TOKEN"
    End

    It 'stays in sync once the generation catches up to the rotation'
      sec::map_set slot-aaa111 host-a personal headless ""
      make_headless slot-aaa111 ALPHA_TOKEN BETA_TOKEN
      sec::manifest_set_rotated ALPHA_TOKEN 200
      sec::gen_set slot-aaa111 ALPHA_TOKEN 300
      When call sec::sync_slot slot-aaa111 personal
      The status should be success
      The output should include "already in sync"
    End
  End

  Describe 'sec::remove_secret'
    It 'removes everywhere with --all: manifest entry, blobs, both fragments'
      make_headless slot-aaa111 ALPHA_TOKEN GAMMA_TOKEN
      make_human slot-bbb222 "ALPHA_TOKEN=op://V/ALPHA_TOKEN/bbb222" "BETA_TOKEN=op://V/BETA_TOKEN/bbb222"
      sec::remove_secret ALPHA_TOKEN "" 1 1 >/dev/null 2>&1
      When call sec::manifest_has ALPHA_TOKEN
      The status should be failure
      The file "$SECRETS_BLOB_DIR/slot-aaa111/ALPHA_TOKEN.sops.sh" should not be exist
      The contents of file "$(sec::fragment_path slot-bbb222)" should not include "ALPHA_TOKEN"
    End

    It 'profile-scoped: scrubs only local-map slots of that profile and reports foreign ones'
      sec::map_set slot-aaa111 host-a personal headless ""
      make_headless slot-aaa111 ALPHA_TOKEN BETA_TOKEN
      make_human slot-bbb222 "ALPHA_TOKEN=op://V/ALPHA_TOKEN/bbb222"
      When call sec::remove_secret ALPHA_TOKEN personal 0 1
      The status should be success
      The output should include "scrubbed: slot-aaa111"
      The file "$SECRETS_BLOB_DIR/slot-aaa111/ALPHA_TOKEN.sops.sh" should not be exist
      The contents of file "$(sec::fragment_path slot-bbb222)" should include "ALPHA_TOKEN"
      The stderr should include "slot-bbb222"
      The contents of file "$MANIFEST" should include "work"
    End

    It 'promotes to full removal when the last profile is removed (with --yes)'
      make_headless slot-aaa111 BETA_TOKEN
      sec::remove_secret BETA_TOKEN personal 0 1 >/dev/null 2>&1
      When call sec::manifest_has BETA_TOKEN
      The status should be failure
    End
  End
End
