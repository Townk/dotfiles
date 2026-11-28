# Tests for home/dot_local/lib/system-service-common.zsh — the helpers the
# launchd and systemd workers share. Only the manifest (yq + jq) and the
# filesystem are involved: no service manager is ever called.
Describe 'system-service-common.zsh'
  Include home/dot_local/lib/system-package-common.zsh
  Include home/dot_local/lib/system-service-common.zsh

  setup() {
    TEST_TMP="$(mktemp -d)"
    SVCFILE="$TEST_TMP/services.toml"
    cat >"$SVCFILE" <<'TOML'
[demo]
cmd = ["/bin/demo-daemon", "--flag"]

[bridge]
unit = "bridge.socket"
TOML
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'svc::require_declared'
    It 'passes silently for a declared service'
      When run svc::require_declared demo
      The status should be success
      The output should equal ""
    End

    It 'dies naming the manifest and the service when it is not declared'
      When run svc::require_declared nope
      The status should be failure
      The stderr should include "no such service in $SVCFILE: nope"
    End

    It 'dies when the manifest does not exist'
      rm -f "$SVCFILE"
      When run svc::require_declared demo
      The status should be failure
      The stderr should include "no such service in $SVCFILE: demo"
    End
  End

  Describe 'do_matching'
    It 'matches a service by its cmd[0] basename'
      When run do_matching demo-daemon
      The output should equal "demo"
    End

    It 'matches a service without cmd by its key'
      When run do_matching bridge
      The output should equal "bridge"
    End

    It 'prints nothing when no service matches'
      When run do_matching zzz
      The status should be success
      The output should equal ""
    End

    Parameters
      "no argument"
      "two arguments" a b
    End
    It "dies with its usage for $1"
      shift
      When run do_matching "$@"
      The status should be failure
      The stderr should include "usage: matching <pkg>"
    End
  End

  Describe 'svc::print_manifest_entry'
    It 'prints the heading and the entry JSON indented four spaces'
      When call svc::print_manifest_entry bridge
      The line 1 of output should equal "  manifest entry:"
      The line 2 of output should equal "    {"
      The line 3 of output should equal '      "unit": "bridge.socket"'
      The line 4 of output should equal "    }"
    End
  End

  Describe 'svc::orphans'
    artifacts() {   # artifacts <file...> — create them in the artifact dir
      mkdir -p "$TEST_TMP/units"
      local f
      for f in "$@"; do : >"$TEST_TMP/units/$f"; done
    }

    It 'prints generated artifacts whose name is not declared'
      artifacts com.system-service.demo.service com.system-service.ghost.service
      When call svc::orphans "$TEST_TMP/units" .service demo bridge
      The output should equal "ghost"
    End

    It 'treats every generated artifact as an orphan when nothing is declared'
      artifacts com.system-service.a.plist com.system-service.b.plist
      When call svc::orphans "$TEST_TMP/units" .plist
      The output should equal "$(printf 'a\nb')"
    End

    It 'never reports a file outside the generated prefix or suffix'
      artifacts bridge.socket com.other.ghost.service com.system-service.ghost.plist
      When call svc::orphans "$TEST_TMP/units" .service demo
      The output should equal ""
    End

    It 'keeps dots in a service name and compares names literally'
      artifacts 'com.system-service.a.b.service' 'com.system-service.a*b.service'
      When call svc::orphans "$TEST_TMP/units" .service 'a.b' 'axb'
      The output should equal "a*b"
    End

    It 'prints nothing for an empty or missing directory'
      When call svc::orphans "$TEST_TMP/absent" .service demo
      The status should be success
      The output should equal ""
    End
  End
End
