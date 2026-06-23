# Tests for home/dot_local/bin/executable_system-service-launchd.
#
# Focus: svc::status, exposed as the internal `status` subcommand. The status
# string drives the `system-service list` table, and its parse of launchctl's
# "last exit code" line is subtle — launchctl reports "(never exited)" (not a
# number) for any service that is bootstrapped but has not run yet, which is
# the normal resting state of an on-demand service (RunAtLoad=false). A naive
# whitespace split turns that into "(never" and mislabels every idle service
# "error". These cases pin the correct mapping.
#
# launchctl is stubbed on PATH so the suite never touches the real launchd
# domain. The stub honours $STUB_RC (print exit code, for the not-bootstrapped
# case) and $STUB_PRINT (the body of `launchctl print`).

Describe 'system-service-launchd'
  LAUNCHD="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-service-launchd"

  setup() {
    TEST_TMP="$(mktemp -d)"
    STUB_DIR="$TEST_TMP/bin"
    mkdir -p "$STUB_DIR"
    cat >"$STUB_DIR/launchctl" <<'STUB'
#!/bin/sh
case "$1" in
  print)
    [ "${STUB_RC:-0}" = 0 ] || exit "${STUB_RC}"
    printf '%s\n' "$STUB_PRINT"
    ;;
  *) : ;;   # bootstrap/bootout/kickstart — succeed silently
esac
exit 0
STUB
    chmod +x "$STUB_DIR/launchctl"
    export PATH="$STUB_DIR:$PATH"
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset STUB_PRINT STUB_RC
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'status'
    It 'reports a never-run on-demand service as stopped, not error'
      # The regression: "(never exited)" must not be read as a nonzero code.
      export STUB_RC=0
      export STUB_PRINT="$(printf '\tstate = not running\n\truns = 0\n\tlast exit code = (never exited)')"
      When run zsh "$LAUNCHD" status mlx-gemma
      The output should equal "stopped"
      The status should be success
    End

    It 'reports a nonzero last exit code as error'
      export STUB_RC=0
      export STUB_PRINT="$(printf '\tstate = not running\n\truns = 3\n\tlast exit code = 2')"
      When run zsh "$LAUNCHD" status mlx-gemma
      The output should equal "error"
    End

    It 'reports a signal-style nonzero exit as error'
      export STUB_RC=0
      export STUB_PRINT="$(printf '\tstate = not running\n\tlast exit code = 137')"
      When run zsh "$LAUNCHD" status mlx-gemma
      The output should equal "error"
    End

    It 'reports a clean (zero) exit as stopped'
      export STUB_RC=0
      export STUB_PRINT="$(printf '\tstate = not running\n\tlast exit code = 0')"
      When run zsh "$LAUNCHD" status mlx-gemma
      The output should equal "stopped"
    End

    It 'reports a live PID as running even when it has never exited'
      # A running service also shows "(never exited)"; the PID check wins.
      export STUB_RC=0
      export STUB_PRINT="$(printf '\tstate = running\n\tpid = 4242\n\tlast exit code = (never exited)')"
      When run zsh "$LAUNCHD" status mlx-gemma
      The output should equal "running"
    End

    It 'reports an unbootstrapped service as none'
      export STUB_RC=1
      When run zsh "$LAUNCHD" status mlx-gemma
      The output should equal "none"
    End
  End
End
