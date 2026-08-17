# The policy fence. A `share` that quietly defaults to a third party's server is
# a one-keystroke exfiltration path, so: the resolved destination HOST is echoed
# before any bytes leave, and `profiles` is an allowlist that --to cannot bypass
# without --force.

Describe 'share:: policy fence'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-policy"
    rm -rf "$SB"; mkdir -p "$SB"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[onedrive]
backend = "rclone"
remote = "onedrive:Shared/drop"
store = "https://corp.example.com"
profiles = ["work"]
default_for = ["work"]

[drop]
store = "https://drop.home.example.com"
profiles = ["personal"]
TOML
  }
  BeforeEach 'setup'

  It 'picks the profile default'
    SHARE_PROFILE=work
    When call share::resolve
    The output should equal 'onedrive'
  End

  It 'falls back to the built-in public on a profile with no declared default'
    SHARE_PROFILE=personal
    When call share::resolve
    The output should equal 'public'
  End

  It 'lets a manifest default_for beat the built-in public'
    SHARE_PROFILE=personal
    printf '[mine]\nstore = "https://mine.example.com"\nprofiles = ["personal"]\ndefault_for = ["personal"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    When call share::resolve
    The output should equal 'mine'
  End

  It 'honours an explicit endpoint that the profile allows'
    SHARE_PROFILE=personal
    When call share::resolve drop
    The output should equal 'drop'
  End

  It 'refuses an endpoint the current profile is not allowed to use'
    SHARE_PROFILE=work
    When run share::resolve drop
    The status should be failure
    The stderr should include 'not allowed on profile work'
  End

  It 'refuses the public endpoint on the work profile'
    SHARE_PROFILE=work
    When run share::resolve public
    The status should be failure
    The stderr should include 'not allowed on profile work'
  End

  It 'allows a disallowed endpoint under SHARE_FORCE'
    SHARE_PROFILE=work
    SHARE_FORCE=1
    When call share::resolve drop
    The output should equal 'drop'
    The stderr should include 'policy override'
  End

  It 'reports the bare destination host for the pre-send echo'
    When call share::destination_host drop
    The output should equal 'drop.home.example.com'
  End

  It 'reports the rclone remote as the destination when there is no store URL'
    SHARE_PROFILE=work
    printf '[od]\nbackend = "rclone"\nremote = "onedrive:X"\nprofiles = ["work"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    When call share::destination_host od
    The output should equal 'onedrive:X'
  End

  It 'fails closed on an empty profiles allowlist — share::allowed denies'
    SHARE_PROFILE=work
    printf '[locked]\nstore = "https://locked.example.com"\nprofiles = []\n' \
      >"$SHARE_ENDPOINTS_FILE"
    When call share::allowed locked
    The status should be failure
    The stderr should include 'empty profiles allowlist'
  End

  It 'fails closed on an empty profiles allowlist — share::resolve denies'
    SHARE_PROFILE=work
    printf '[locked]\nstore = "https://locked.example.com"\nprofiles = []\n' \
      >"$SHARE_ENDPOINTS_FILE"
    When run share::resolve locked
    The status should be failure
    The stderr should include 'empty profiles allowlist'
  End

  It 'fails closed on a missing profiles key, and tells the author to declare one'
    SHARE_PROFILE=work
    printf '[open]\nstore = "https://open.example.com"\n' \
      >"$SHARE_ENDPOINTS_FILE"
    When run share::resolve open
    The status should be failure
    The stderr should include 'declares no profiles allowlist'
  End

  It 'refuses a store URL with no host rather than printing empty'
    SHARE_PROFILE=work
    printf '[bare]\nstore = "https:///x"\nprofiles = ["work"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    When run share::destination_host bare
    The status should be failure
    The stderr should include 'no host'
  End

  It 'reports a parse failure, not "unknown endpoint", when the manifest is malformed'
    SHARE_PROFILE=work
    printf 'this is not valid toml [[[\n' >"$SHARE_ENDPOINTS_FILE"
    When run share::resolve onedrive
    The status should be failure
    The stderr should include 'cannot parse'
    The stderr should not include 'unknown endpoint'
  End

  It 'fails share::default_endpoint on a malformed manifest instead of returning public'
    SHARE_PROFILE=personal
    printf 'this is not valid toml [[[\n' >"$SHARE_ENDPOINTS_FILE"
    When run share::default_endpoint
    The status should be failure
    The stderr should include 'cannot parse'
  End
End
