# share.zsh — manifest parsing and endpoint resolution.
#
# The manifest is a LOOSE per-machine file (~/.config/share/endpoints.toml,
# chezmoiignored) because an endpoint hostname can name a work resource. The
# built-in `public` endpoint must therefore exist in CODE, so a machine with no
# manifest at all still shares files.

Describe 'share:: manifest parsing'
  Include home/dot_local/lib/share.zsh
  Include tests/share_helper.sh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-endpoints"
    share_fresh "$SB"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_PROFILE=personal
  }
  BeforeEach 'setup'

  write_manifest() {
    share_write "$SHARE_ENDPOINTS_FILE" <<'TOML'
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

  # --- one parse per command ---------------------------------------------
  # The manifest is converted (yq) and flattened (jq) ONCE per process and
  # every lookup then reads shell variables. What a cache could break is
  # pinned here: staleness, two manifests in one process, odd values, the
  # exact output for a missing field, and the malformed-manifest failure.
  Describe 'the parsed-manifest cache'
    two_lookups() {
      printf '[drop]\nstore = "https://one.example.com"\nprofiles = ["personal"]\n' >"$SHARE_ENDPOINTS_FILE"
      share::field drop store
      # Same path, same size, same second: only the content differs.
      printf '[drop]\nstore = "https://two.example.com"\nprofiles = ["personal"]\n' >"$SHARE_ENDPOINTS_FILE"
      share::field drop store
    }

    It 're-reads a manifest that changed between two lookups in one process'
      When call two_lookups
      The line 1 of output should equal 'https://one.example.com'
      The line 2 of output should equal 'https://two.example.com'
    End

    two_manifests() {
      printf '[a]\nstore = "https://a.example.com"\nprofiles = ["personal"]\n' >"$SB/a.toml"
      printf '[b]\nstore = "https://b.example.com"\nprofiles = ["personal"]\n' >"$SB/b.toml"
      SHARE_ENDPOINTS_FILE="$SB/a.toml"
      share::endpoint_names | tr '\n' ' '
      SHARE_ENDPOINTS_FILE="$SB/b.toml"
      share::endpoint_names | tr '\n' ' '
      share::field a store 2>&1
      return 0
    }

    It 'does not mix two manifests used in one process'
      When call two_manifests
      The output should equal 'a public b public error: share: unknown endpoint: a'
    End

    appears_and_goes() {
      share::endpoint_names | tr '\n' ' '
      printf '[late]\nstore = "https://late.example.com"\nprofiles = ["personal"]\n' >"$SHARE_ENDPOINTS_FILE"
      share::endpoint_names | tr '\n' ' '
      rm -f "$SHARE_ENDPOINTS_FILE"
      share::endpoint_names | tr '\n' ' '
    }

    It 'sees a manifest appear and disappear'
      When call appears_and_goes
      The output should equal 'public late public public '
    End

    bad_then_good() {
      write_manifest
      share::field drop store
      write_malformed_manifest
      share::field drop store; print -r -- "status=$?"
      share::resolve drop; print -r -- "status=$?"
      write_manifest
      share::field drop store
    }

    It 'fails on a manifest that turned malformed, and recovers once it is fixed'
      When call bad_then_good
      The line 1 of output should equal 'https://drop.example.com'
      The line 2 of output should equal 'status=1'
      The line 3 of output should equal 'status=1'
      The line 4 of output should equal 'https://drop.example.com'
      The stderr should equal "error: share: cannot parse $SHARE_ENDPOINTS_FILE
error: share: cannot parse $SHARE_ENDPOINTS_FILE"
    End

    write_odd_manifest() {
      share_write "$SHARE_ENDPOINTS_FILE" <<'TOML'
[odd]
spaced = "  two  words  "
quoted = "it's \"quoted\" $HOME `id` \\ back * ?"
unicode = "café 日本 →"
multiline = "line1\nline2\n\n"
empty = ""
port = 9009
ratio = 1.50
off = false
on = true
word_null = "null"
list = ["a b", "c", 3, true]
profiles = ["personal"]

[odd.table]
k = "v"

["we ird]\"name"]
store = "https://weird.example.com"
profiles = ["personal"]
TOML
    }
    BeforeEach 'write_odd_manifest'

    Describe 'a scalar'
      Parameters
        spaced    '  two  words  '
        quoted    "it's \"quoted\" \$HOME \`id\` \\ back * ?"
        unicode   'café 日本 →'
        port      '9009'
        ratio     '1.50'
        off       'false'
        on        'true'
        word_null 'null'
        table     '{"k":"v"}'
      End

      It "returns the value of $1 exactly"
        When call share::field odd "$1" DEFAULT
        The output should equal "$2"
        The status should be success
      End
    End

    It 'keeps the inner newline of a multi-line value and drops the trailing ones'
      When call share::field odd multiline DEFAULT
      The output should equal 'line1
line2'
    End

    It 'returns an empty string as empty, not as the default'
      When call share::field odd empty DEFAULT
      The output should equal ''
      The status should be success
    End

    It 'joins an array with newlines, one element per line'
      When call share::field odd list DEFAULT
      The output should equal 'a b
c
3
true'
    End

    It 'prints one empty line for a missing field when no default is given'
      missing() { [[ "$(share::field odd nope; print -r -- end)" == $'\nend' ]]; }
      When call missing
      The status should be success
    End

    # The parsed manifest crosses from jq to the shell as NUL-terminated
    # tokens, so a NUL inside a value (TOML allows "\u0000") is the one byte
    # that has to be escaped on the way — with \u0001, which then needs it too.
    It 'carries a NUL and a control character inside a value'
      control() {
        printf '[c]\nv = "a\\u0000b\\u0001c\\u00010d\\u00011"\nafter = "intact"\n' >"$SHARE_ENDPOINTS_FILE"
        local v; v="$(share::field c v)"
        print -r -- "${#v} ${(qqqq)v} $(share::field c after)"
      }
      When call control
      The output should equal "10 \$'a\\0b\\001c\\0010d\\0011' intact"
    End

    It 'reads an endpoint whose name has spaces, a bracket and a quote'
      When call share::field 'we ird]"name' store
      The output should equal 'https://weird.example.com'
    End

    It 'lists that endpoint by its exact name'
      When call share::endpoint_names
      The line 1 of output should equal 'odd'
      The line 2 of output should equal 'public'
      The line 3 of output should equal 'we ird]"name'
    End

    # The budget itself. yq and jq are wrapped by counters; a command path
    # that loads the manifest first pays for ONE of each, however many
    # fields it then reads — also through $(…), where a cache filled in the
    # subshell would be lost.
    count_tools() {
      mkdir -p "$SB/bin"
      local tool
      for tool in yq jq; do
        share_write "$SB/bin/$tool" <<SH
#!/bin/sh
echo $tool >>"\$SHARE_TOOL_LOG"
exec "${commands[$tool]}" "\$@"
SH
        chmod +x "$SB/bin/$tool"
      done
      SHARE_TOOL_LOG="$SB/tools.log"; export SHARE_TOOL_LOG
      : >"$SHARE_TOOL_LOG"
      PATH="$SB/bin:$PATH"
    }
    tool_calls() { sort "$SHARE_TOOL_LOG" | uniq -c | tr -s ' \n' ' '; }

    It 'parses the manifest once for any number of lookups after a load'
      Skip if 'complete-only: measured at 0.28 s in the fast suite' spec_complete_only
      spec_complete_only && return 0
      many() {
        count_tools
        share::manifest_load || return 1
        local a b c
        a="$(share::field odd port)" b="$(share::field odd unicode)" c="$(share::field public store)"
        share::allowed odd && share::resolve odd >/dev/null && share::endpoint_names >/dev/null
        share::default_endpoint >/dev/null
        print -r -- "$a $c$(tool_calls)"
      }
      When call many
      The output should equal '9009 https://getcroc.com 1 jq 1 yq '
    End

    It 'resolves a destination host with one yq and one jq'
      one_host() {
        count_tools
        share::destination_host odd 2>&1
        tool_calls
      }
      When call one_host
      The line 1 of output should include 'no store, remote or relay'
      The line 2 of output should equal ' 1 jq 1 yq '
    End
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
    real_jq="${commands[jq]}"
    share_write "$SB/bin/jq" <<SH
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

  # A settings file with no table in it - empty, blank, or only comments, as a
  # template left for later is - says "no endpoints of my own". yq renders it
  # as null, the merge with the built-in then failed, and every lookup failed
  # with it: a machine that had only ever created the file could not share.
  Describe 'a manifest with nothing in it'
    Parameters
      'an empty file'       ''
      'only blank lines'    $'\n\n'
      'only comments'       $'# my endpoints go here\n#[drop]\n# store = "https://x"\n'
    End

    lookups() {
      print -rn -- "$1" >"$SHARE_ENDPOINTS_FILE"
      print -r -- "names=$(share::endpoint_names | tr '\n' ' ')rc=$?"
      print -r -- "default=$(share::default_endpoint) rc=$?"
      share::allowed public && print "public allowed"
      print -r -- "kind=$(share::field public backend none) rc=$?"
      share::endpoints_json | jq -c 'keys'
    }

    It "answers as if there were no file: $1"
      expected() {
        rm -f "$SHARE_ENDPOINTS_FILE"
        print -r -- "names=$(share::endpoint_names | tr '\n' ' ')rc=$?"
        print -r -- "default=$(share::default_endpoint) rc=$?"
        share::allowed public && print "public allowed"
        print -r -- "kind=$(share::field public backend none) rc=$?"
        share::endpoints_json | jq -c 'keys'
      }
      When call lookups "$2"
      The output should equal "$(expected 2>&1)"
      The error should equal ""
      The status should be success
    End
  End

End
