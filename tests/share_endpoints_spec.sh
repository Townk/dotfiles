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

  # --- F8 fix: `share endpoints` must list only what THIS profile may use --
  # share::endpoint_names (above) stays raw/unfiltered — other callers rely
  # on it for manifest-validity checks — but the CLI's `endpoints` subcommand
  # advertises itself as "endpoints this profile may use", and printing every
  # manifest key unfiltered contradicted that on a `work` profile with only
  # an `onedrive` entry: it listed `onedrive` AND the built-in `public`, even
  # though `share --to public` is then denied by the policy fence.
  # share::endpoints_for_profile is the profile-scoped view the CLI needs.
  It 'filters the endpoints listing to what the profile may use'
    printf '[onedrive]\nbackend = "rclone"\nremote = "onedrive:Shared/drop"\nweb = true\nprofiles = ["work"]\ndefault_for = ["work"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    SHARE_PROFILE=work
    When call share::endpoints_for_profile
    The output should include 'onedrive'
    The output should not include 'public'
  End

  It 'marks the default endpoint in the profile-filtered listing'
    printf '[onedrive]\nbackend = "rclone"\nremote = "onedrive:Shared/drop"\nweb = true\nprofiles = ["work"]\ndefault_for = ["work"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    SHARE_PROFILE=work
    When call share::endpoints_for_profile
    The output should include 'onedrive (default)'
  End

  It 'still lists the built-in public endpoint for a profile allowed to use it'
    write_manifest
    SHARE_PROFILE=personal
    When call share::endpoints_for_profile
    The output should include 'public'
    The output should include 'drop'
    The output should not include 'onedrive'
  End

  # F5 residual, folded in on re-review: share::endpoints_json used to pass
  # the WHOLE manifest to jq as `--argjson manifest "$manifest"`. A literal
  # (non-`@secret:`) endpoint password is documented, supported
  # configuration — and this function runs on every field lookup (`share
  # list`, `share endpoints`, `share revoke`, every send), not just during a
  # transfer, so that was a broader leak than the two send-path sites fixed
  # for the same reason (share/ledger.zsh, share/croc.zsh). Same fix: the
  # manifest now rides jq's ENVIRONMENT (`manifest="$manifest" jq …
  # $ENV.manifest | fromjson`). A logging jq shim proves it, mirroring the
  # ledger test in share_ledger_spec.sh.
  It 'never puts a literal manifest password on the jq invocation that merges endpoints'
    mkdir -p "$SB/bin"
    real_jq="$(command -v jq)"
    cat >"$SB/bin/jq" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"\$SHARE_JQ_ARGV_LOG"
exec "$real_jq" "\$@"
SH
    chmod +x "$SB/bin/jq"
    PATH="$SB/bin:$PATH"
    SHARE_JQ_ARGV_LOG="$SB/jq-argv.log"; export SHARE_JQ_ARGV_LOG
    printf '[lab]\nrelay = "r:9009"\npass = "literal-relay-secret"\nprofiles = ["personal"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    check() {
      share::endpoints_json >/dev/null || return 1
      grep -q 'literal-relay-secret' "$SHARE_JQ_ARGV_LOG" && return 1
      return 0
    }
    When call check
    The status should be success
  End
End
