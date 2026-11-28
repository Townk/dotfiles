# Tests for home/dot_local/bin/executable_system-service (the dispatcher).
#
# Workers are stubbed on PATH: each stub records its argv and prints canned
# TSV/name output. SERVICE_OS drives the platform routing so both worlds are
# exercised on any host.

Describe 'system-service'
  DISPATCHER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-service"

  # The three worker stubs record into $STUB_CALLS, which each example
  # exports for itself, so one set serves every example: written and run once.
  workers() {
    STUB_DIR="$SHELLSPEC_TMPBASE/workers"
    mkdir -p "$STUB_DIR"
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
      STUB_CALLS=/dev/null "$STUB_DIR/system-service-$w" warm >/dev/null 2>&1
    done
  }
  BeforeAll 'workers'
  setup() {
    spec_sandbox svc; TEST_TMP=$SANDBOX
    export STUB_CALLS="$TEST_TMP/worker.calls"
    export PATH="$STUB_DIR:$PATH"
  }
  BeforeEach 'setup'

  It 'on Linux, list consults only the systemd worker'
    export SERVICE_OS=Linux
    When run zsh -f "$DISPATCHER" list
    The status should be success
    The output should include "systemd"
    The output should include "svc-systemd"
    The contents of file "$STUB_CALLS" should not include "launchd"
    The contents of file "$STUB_CALLS" should not include "brew"
  End

  It 'on Darwin, list aggregates launchd + brew'
    export SERVICE_OS=Darwin
    When run zsh -f "$DISPATCHER" list
    The status should be success
    The output should include "svc-launchd"
    The output should include "svc-brew"
    The contents of file "$STUB_CALLS" should not include "systemd"
  End

  It 'on Linux, sync drives the systemd worker'
    export SERVICE_OS=Linux
    When run zsh -f "$DISPATCHER" sync
    The status should be success
    The contents of file "$STUB_CALLS" should include "systemd sync"
  End

  It 'on Linux, lifecycle verbs route to the systemd worker'
    export SERVICE_OS=Linux
    When run zsh -f "$DISPATCHER" restart svc-systemd
    The status should be success
    The contents of file "$STUB_CALLS" should include "systemd restart svc-systemd"
  End

  It 'on Linux, restart-for restarts a running matched service'
    export SERVICE_OS=Linux
    When run zsh -f "$DISPATCHER" restart-for svc-systemd
    The status should be success
    The output should include "restarting"
    The contents of file "$STUB_CALLS" should include "systemd restart svc-systemd"
  End
End
