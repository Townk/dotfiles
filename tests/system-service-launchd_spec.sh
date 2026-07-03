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

  Describe 'stop (synchronous bootout)'
    # `launchctl bootout` returns before the service finishes draining. This
    # stateful stub models that: `bootout` starts a drain, `print` reports the
    # service still up for a few polls, then gone. A correct svc::bootout must
    # POLL until it's actually gone — so the "down" marker only appears if the
    # wait loop ran. The pre-fix code returned right after `launchctl bootout`
    # and never re-polled, so the marker would be absent.
    setup_stateful() {
      STUB_STATE="$TEST_TMP/state"; mkdir -p "$STUB_STATE"
      export STUB_STATE
      cat >"$STUB_DIR/launchctl" <<'STUB'
#!/bin/sh
ST="$STUB_STATE"
case "$1" in
  bootout)   printf 0 > "$ST/poll" ;;             # drain begins
  bootstrap) rm -f "$ST/poll" "$ST/down" ;;       # back up
  print)
    [ -f "$ST/down" ] && exit 1                    # fully gone
    if [ -f "$ST/poll" ]; then
      n=$(cat "$ST/poll"); n=$((n + 1)); printf '%s' "$n" > "$ST/poll"
      [ "$n" -ge 3 ] && : > "$ST/down"             # drained after 3 polls
    fi
    exit 0                                          # still up on this call
    ;;
esac
exit 0
STUB
      chmod +x "$STUB_DIR/launchctl"
    }
    BeforeEach 'setup_stateful'

    It 'waits for the unload to drain before returning'
      When run zsh "$LAUNCHD" stop mlx-gemma
      The status should be success
      The output should include "stopped"
      The path "$STUB_STATE/down" should be exist
    End
  End

  Describe 'render (scheduling keys)'
    # A fixture Servicefile exercises the optional scheduling keys added for
    # system-backup (spec §6): StartInterval / StartCalendarInterval /
    # WatchPaths / ProcessType / LowPriorityIO / Nice. Entries WITHOUT them
    # must render exactly the classic plist (regression pin).
    setup_svc() {
      export SVCFILE="$TEST_TMP/services.toml"
      cat > "$SVCFILE" <<'EOF'
[scheduled]
cmd = ["/bin/echo", "tick"]
start_interval = 1800
watch_paths = ["/Volumes", "~/Library/CloudStorage"]
process_type = "Background"
low_priority_io = true
nice = 10
start_calendar_interval = {Hour = 3, Minute = 17}

[classic]
cmd = ["/bin/echo", "hi"]
keep_alive = true
EOF
    }
    BeforeEach 'setup_svc'
    AfterEach 'unset SVCFILE'

    render_json() {  # render <name> -> plist as JSON
      zsh "$LAUNCHD" render "$1" | plutil -convert json -o - -- -
    }

    It 'renders all six scheduling keys'
      sched() {
        render_json scheduled | jq -r '
          .StartInterval, .ProcessType, .LowPriorityIO, .Nice,
          (.WatchPaths | join(",")),
          .StartCalendarInterval.Hour, .StartCalendarInterval.Minute'
      }
      When run sched
      The line 1 should equal 1800
      The line 2 should equal "Background"
      The line 3 should equal "true"
      The line 4 should equal 10
      The line 5 should equal "/Volumes,$HOME/Library/CloudStorage"
      The line 6 should equal 3
      The line 7 should equal 17
    End

    It 'renders none of them when absent (classic entries unchanged)'
      classic() {
        render_json classic | jq -r '
          [has("StartInterval"), has("StartCalendarInterval"), has("WatchPaths"),
           has("ProcessType"), has("LowPriorityIO"), has("Nice")] | any'
      }
      When run classic
      The output should equal "false"
    End
  End

  Describe 'list (idle labels for timer-driven services)'
    # A bootstrapped interval/calendar/watch agent between fires is launchd
    # "not running", but "stopped" reads as broken to a human. `list` shows
    # those as idle (<schedule>); plain on-demand services stay "stopped".
    # The internal `status` verb is UNCHANGED (restart-for's contract).
    setup_sched() {
      export SVCFILE="$TEST_TMP/services.toml"
      cat > "$SVCFILE" <<'EOF'
[half-hourly]
cmd = ["/bin/echo", "tick"]
start_interval = 1800

[nightly]
cmd = ["/bin/echo", "repack"]
start_calendar_interval = {Hour = 3, Minute = 17}

[watcher]
cmd = ["/bin/echo", "sync"]
watch_paths = ["/Volumes"]
start_interval = 3600

[classic]
cmd = ["/bin/echo", "hi"]
EOF
      # Every service reports bootstrapped + cleanly exited (the idle state).
      export STUB_RC=0
      export STUB_PRINT="$(printf '\tstate = not running\n\tlast exit code = 0')"
    }
    BeforeEach 'setup_sched'
    AfterEach 'unset SVCFILE STUB_RC STUB_PRINT'

    It 'labels timer-driven services idle with their schedule'
      rows() { zsh "$LAUNCHD" list | cut -f1,2; }
      When run rows
      The output should include "half-hourly	idle (every 30m)"
      The output should include "nightly	idle (daily 03:17)"
      The output should include "watcher	idle (every 1h + watch)"
      The output should include "classic	stopped"
    End

    It 'keeps the internal status verb vocabulary untouched'
      When run zsh "$LAUNCHD" status half-hourly
      The output should equal "stopped"
    End
  End
End
