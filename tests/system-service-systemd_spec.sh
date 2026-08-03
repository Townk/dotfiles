# Tests for home/dot_local/bin/executable_system-service-systemd.
#
# systemctl is stubbed on PATH so the suite never touches a real user
# manager (and stays runnable on macOS). The stub honours:
#   $STUB_SHOW     — body printed for `systemctl --user show ...`
#   $STUB_CALLS    — file path; every invocation's argv is appended to it
# Manifest and unit dir point at per-example sandboxes via SVCFILE and
# SYSTEMD_USER_DIR (the launchd suite's LAUNCH_AGENTS pattern).

Describe 'system-service-systemd'
  SYSTEMD_BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-service-systemd"
  export SYS_PKG_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    TEST_TMP="$(mktemp -d)"
    STUB_DIR="$TEST_TMP/bin"
    mkdir -p "$STUB_DIR" "$TEST_TMP/units"
    export SYSTEMD_USER_DIR="$TEST_TMP/units"
    export SVCFILE="$TEST_TMP/services.toml"
    export STUB_CALLS="$TEST_TMP/systemctl.calls"
    cat >"$STUB_DIR/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:-/dev/null}"
case "$*" in
  *" show "*)
    printf '%s\n' "$STUB_SHOW"
    ;;
  *"is-enabled"*)
    [ "${STUB_ENABLED:-no}" = yes ] && { echo enabled; exit 0; }
    echo disabled; exit 1
    ;;
  *) : ;;   # start/stop/restart/enable/disable/daemon-reload — succeed silently
esac
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    export PATH="$STUB_DIR:$PATH"
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset STUB_SHOW STUB_ENABLED STUB_CALLS
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A rendered entry and an adopted entry, used across the suite.
  write_manifest() {
    cat >"$SVCFILE" <<'TOML'
[demo]
description = "demo daemon"
cmd = ["/bin/demo-daemon", "--flag", "a b"]
keep_alive = true
run_at_load = true

[clipboard-bridge]
unit = "clipboard-bridge.socket"
description = "clipboard bridge socket"
TOML
  }

  Describe 'status'
    It 'reports an active service as running'
      write_manifest
      export STUB_SHOW="$(printf 'LoadState=loaded\nActiveState=active\nSubState=running\nResult=success\nExecMainStatus=0')"
      When run zsh "$SYSTEMD_BIN" status demo
      The output should equal "running"
      The status should be success
    End

    It 'reports an active socket/oneshot (SubState listening/exited) as running'
      write_manifest
      export STUB_SHOW="$(printf 'LoadState=loaded\nActiveState=active\nSubState=listening\nResult=success\nExecMainStatus=0')"
      When run zsh "$SYSTEMD_BIN" status clipboard-bridge
      The output should equal "running"
    End

    It 'reports a cleanly inactive service as stopped'
      write_manifest
      export STUB_SHOW="$(printf 'LoadState=loaded\nActiveState=inactive\nSubState=dead\nResult=success\nExecMainStatus=0')"
      When run zsh "$SYSTEMD_BIN" status demo
      The output should equal "stopped"
    End

    It 'reports a failed service as error'
      write_manifest
      export STUB_SHOW="$(printf 'LoadState=loaded\nActiveState=failed\nSubState=failed\nResult=exit-code\nExecMainStatus=2')"
      When run zsh "$SYSTEMD_BIN" status demo
      The output should equal "error"
    End

    It 'reports a not-found unit as none'
      write_manifest
      export STUB_SHOW="$(printf 'LoadState=not-found\nActiveState=inactive\nSubState=dead\nResult=success\nExecMainStatus=0')"
      When run zsh "$SYSTEMD_BIN" status demo
      The output should equal "none"
    End

    It 'targets the adopted unit name, not a generated one'
      write_manifest
      export STUB_SHOW="$(printf 'LoadState=loaded\nActiveState=active\nSubState=listening\nResult=success\nExecMainStatus=0')"
      When run zsh "$SYSTEMD_BIN" status clipboard-bridge
      The status should be success
      The contents of file "$STUB_CALLS" should include "clipboard-bridge.socket"
    End
  End

  Describe 'declared'
    It 'prints the manifest keys'
      write_manifest
      When run zsh "$SYSTEMD_BIN" declared
      The line 1 of output should equal "clipboard-bridge"
      The line 2 of output should equal "demo"
    End
  End
End
