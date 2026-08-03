# Tests for home/dot_local/bin/executable_system-service (the dispatcher).
#
# Workers are stubbed on PATH: each stub records its argv and prints canned
# TSV/name output. SERVICE_OS drives the platform routing so both worlds are
# exercised on any host.

Describe 'system-service'
  DISPATCHER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-service"

  setup() {
    TEST_TMP="$(mktemp -d)"
    STUB_DIR="$TEST_TMP/bin"
    mkdir -p "$STUB_DIR"
    export STUB_CALLS="$TEST_TMP/worker.calls"
    local w
    for w in launchd systemd brew; do
      cat >"$STUB_DIR/system-service-$w" <<STUB
#!/bin/sh
printf '%s %s\n' "$w" "\$*" >>"\$STUB_CALLS"
case "\$1" in
  list)     printf 'svc-$w\trunning\tme\t/dev/null\n' ;;
  declared) printf 'svc-$w\n' ;;
  names)    printf 'svc-$w\n' ;;
  status)   printf 'running\n' ;;
  matching) printf 'svc-$w\n' ;;
  *) : ;;
esac
exit 0
STUB
      chmod +x "$STUB_DIR/system-service-$w"
    done
    export PATH="$STUB_DIR:$PATH"
  }
  cleanup() { rm -rf "$TEST_TMP"; unset STUB_CALLS SERVICE_OS; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'on Linux, list consults only the systemd worker'
    export SERVICE_OS=Linux
    When run zsh "$DISPATCHER" list
    The status should be success
    The output should include "systemd"
    The output should include "svc-systemd"
    The contents of file "$STUB_CALLS" should not include "launchd"
    The contents of file "$STUB_CALLS" should not include "brew"
  End

  It 'on Darwin, list aggregates launchd + brew'
    export SERVICE_OS=Darwin
    When run zsh "$DISPATCHER" list
    The status should be success
    The output should include "svc-launchd"
    The output should include "svc-brew"
    The contents of file "$STUB_CALLS" should not include "systemd"
  End

  It 'on Linux, sync drives the systemd worker'
    export SERVICE_OS=Linux
    When run zsh "$DISPATCHER" sync
    The status should be success
    The contents of file "$STUB_CALLS" should include "systemd sync"
  End

  It 'on Linux, lifecycle verbs route to the systemd worker'
    export SERVICE_OS=Linux
    When run zsh "$DISPATCHER" restart svc-systemd
    The status should be success
    The contents of file "$STUB_CALLS" should include "systemd restart svc-systemd"
  End

  It 'on Linux, restart-for restarts a running matched service'
    export SERVICE_OS=Linux
    When run zsh "$DISPATCHER" restart-for svc-systemd
    The status should be success
    The output should include "restarting"
    The contents of file "$STUB_CALLS" should include "systemd restart svc-systemd"
  End
End
