# share.zsh — manifest parsing and endpoint resolution.
#
# The manifest is a LOOSE per-machine file (~/.config/share/endpoints.toml,
# chezmoiignored) because an endpoint hostname can name a work resource. The
# built-in `public` endpoint must therefore exist in CODE, so a machine with no
# manifest at all still shares files.

Describe 'share:: manifest parsing'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-endpoints"
    rm -rf "$SB"; mkdir -p "$SB"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_PROFILE=personal
  }
  BeforeEach 'setup'

  write_manifest() {
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[drop]
description = "Home store"
store = "https://drop.example.com"
web = true
profiles = ["personal"]

[onedrive]
backend = "rclone"
remote = "onedrive:Shared/drop"
link_scope = "organization"
web = true
profiles = ["work"]
default_for = ["work"]
TOML
  }

  write_malformed_manifest() {
    printf 'this is not valid toml [[[\n' >"$SHARE_ENDPOINTS_FILE"
  }

  It 'exposes the built-in public endpoint with no manifest at all'
    When call share::field public store
    The output should equal 'https://getcroc.com'
    The status should be success
  End

  It 'defaults an endpoint backend to croc'
    When call share::field public backend
    The output should equal 'croc'
  End

  It 'lists manifest endpoints alongside the built-in'
    write_manifest
    When call share::endpoint_names
    The output should include 'drop'
    The output should include 'onedrive'
    The output should include 'public'
  End

  It 'reads a manifest scalar'
    write_manifest
    When call share::field onedrive remote
    The output should equal 'onedrive:Shared/drop'
  End

  It 'lets a manifest entry override the built-in public'
    printf '[public]\nstore = "https://mine.example.com"\n' >"$SHARE_ENDPOINTS_FILE"
    When call share::field public store
    The output should equal 'https://mine.example.com'
  End

  It 'returns the supplied default for a missing key'
    write_manifest
    When call share::field drop link_scope anonymous
    The output should equal 'anonymous'
  End

  It 'honours the caller default for a missing backend, same as any other key'
    write_manifest
    When call share::field drop backend rclone
    The output should equal 'rclone'
  End

  It 'treats progress reporting as a no-op outside a job'
    unset JOB_ID
    When call share::_progress 42 'uploading'
    The status should be success
  End

  It 'fails on an unknown endpoint'
    write_manifest
    When run share::field nope store
    The status should be failure
    The stderr should include 'unknown endpoint'
  End

  It 'fails share::endpoint_names on a malformed manifest, naming the parse failure'
    write_malformed_manifest
    When run share::endpoint_names
    The status should be failure
    The stderr should include 'cannot parse'
  End

  It 'fails share::field on a malformed manifest without masking it as unknown endpoint'
    write_malformed_manifest
    When run share::field drop store
    The status should be failure
    The stderr should include 'cannot parse'
    The stderr should not include 'unknown endpoint'
  End
End
