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
  # Source the shared lib from the worktree, not the installed copy, so the
  # suite exercises the code under test (e.g. svc::bootout's poll::until).
  export SYS_PKG_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

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

# launchd also accepts an ARRAY of calendar dicts (several fire times a
# day) — backup-capture uses this form. The label must render every fire
# time, not die with "Cannot index array with string" and truncate list.
[thrice-daily]
cmd = ["/bin/echo", "snap"]
start_calendar_interval = [{Hour = 9, Minute = 0}, {Hour = 21, Minute = 30}]

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
      The output should include "thrice-daily	idle (daily 09:00 + daily 21:30)"
      The output should include "watcher	idle (every 1h + watch)"
      The output should include "classic	stopped"
    End

    It 'keeps the internal status verb vocabulary untouched'
      When run zsh "$LAUNCHD" status half-hourly
      The output should equal "stopped"
    End
  End

  Describe 'sync (drift on a running on-demand service)'
    # An on-demand service (RunAtLoad=false) is registered by `bootstrap` but
    # stays idle until something kickstarts it. When its plist drifts, do_sync
    # boots out the running instance and re-bootstraps the new plist — which
    # leaves it idle. `start` follows bootstrap with kickstart; sync must do the
    # same for the drift branch ONLY when the service was running, so editing a
    # manually-started service's config and re-syncing doesn't silently kill it.
    # A service that was already stopped must be left stopped (the contract).
    #
    # Stateful stub: `up` = bootstrapped, `pid` = has a live PID (running).
    #   bootout   drops both (drained)   bootstrap re-registers idle (no pid)
    #   kickstart sets pid (now running) print reports running iff pid present
    # The plist on disk is absent, so write_plist always reports "wrote" (drift).
    setup_sync() {
      export SVCFILE="$TEST_TMP/services.toml"
      cat > "$SVCFILE" <<'EOF'
[mlx-gemma]
cmd = ["/bin/echo", "serve"]
EOF
      export LAUNCH_AGENTS="$TEST_TMP/LaunchAgents"
      STUB_STATE="$TEST_TMP/state"; mkdir -p "$STUB_STATE"
      export STUB_STATE
      cat >"$STUB_DIR/launchctl" <<'STUB'
#!/bin/sh
ST="$STUB_STATE"
case "$1" in
  bootout)   rm -f "$ST/up" "$ST/pid" ;;
  bootstrap) : > "$ST/up"; rm -f "$ST/pid" ;;
  kickstart) : > "$ST/pid" ;;
  print)
    [ -f "$ST/up" ] || exit 1
    if [ -f "$ST/pid" ]; then
      printf 'state = running\n\tpid = 4242\n\tlast exit code = (never exited)\n'
    else
      printf 'state = not running\n\tlast exit code = 0\n'
    fi
    exit 0
    ;;
esac
exit 0
STUB
      chmod +x "$STUB_DIR/launchctl"
    }
    BeforeEach 'setup_sync'
    AfterEach 'unset SVCFILE LAUNCH_AGENTS STUB_STATE'

    # sync, then ask the tool its own status — kickstart re-runs the service.
    sync_then_status() {
      zsh "$LAUNCHD" sync >/dev/null 2>&1
      zsh "$LAUNCHD" status mlx-gemma
    }

    It 'kickstarts a running on-demand service back up after a drift'
      : > "$STUB_STATE/up"; : > "$STUB_STATE/pid"   # bootstrapped + running
      When run sync_then_status
      The output should equal "running"
      # zsh regression pin: bare in-loop `local changed` reprinted
      # changed=wrote|unchanged from the 2nd declared service on.
      The output should not include "changed="
    End

    It 'leaves an already-stopped service stopped'
      : > "$STUB_STATE/up"                           # bootstrapped, idle
      When run sync_then_status
      The output should equal "stopped"
    End
  End

  Describe 'clipboard trusted endpoint contract'
    RECOBD_BIN="${RECOB_BIN:-$SHELLSPEC_PROJECT_ROOT/custom-builds/recob/target/release/recobd}"
    BRIDGE_BIN="${SYSTEM_BRIDGE_BIN:-$SHELLSPEC_PROJECT_ROOT/custom-builds/recob/target/release/system-bridge}"
    no_recobd() { [ ! -x "$RECOBD_BIN" ] || [ ! -x "$BRIDGE_BIN" ]; }

    It 'keeps SSH forwarding on TCP and makes the local socket service-owned mode 0600'
      services="$SHELLSPEC_PROJECT_ROOT/home/dot_config/packages/services.toml.tmpl"
      public_socket="$SHELLSPEC_PROJECT_ROOT/home/dot_config/systemd/user/clipboard-bridge.socket"
      trusted_socket="$SHELLSPEC_PROJECT_ROOT/home/dot_config/systemd/user/clipboard-bridge-trusted.socket"
      When run command sh -c '
        grep -F "libexec/recobd\", \"--capture\"" "$1" >/dev/null &&
        grep -F "ListenStream=127.0.0.1:2489" "$2" >/dev/null &&
        grep -F "ListenStream=%h/.local/state/cb.sock" "$3" >/dev/null &&
        grep -F "SocketMode=0600" "$3" >/dev/null &&
        grep -F "RemoveOnStop=yes" "$3" >/dev/null
      ' _ "$services" "$public_socket" "$trusted_socket"
      The status should be success
    End

    It 'derives endpoint trust from the listener, never from configuration'
      # The RECOB inversion of the old CLIPBOARD_BRIDGE_ENDPOINT env bit: one
      # persistent daemon adopts both sockets and classifies them by TYPE, so
      # no unit or plist may carry a trust assignment for a request to inherit.
      services="$SHELLSPEC_PROJECT_ROOT/home/dot_config/packages/services.toml.tmpl"
      bridge_service="$SHELLSPEC_PROJECT_ROOT/home/dot_config/systemd/user/clipboard-bridge.service"
      trusted_socket="$SHELLSPEC_PROJECT_ROOT/home/dot_config/systemd/user/clipboard-bridge-trusted.socket"
      setup_hook="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_onchange_after_37-setup-clipboard-bridge.sh.tmpl"
      ignore_template="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiignore.tmpl"
      When run command sh -c '
        ! grep -F "CLIPBOARD_BRIDGE_ENDPOINT" "$1" >/dev/null &&
        ! grep -F "CLIPBOARD_BRIDGE_ENDPOINT" "$2" >/dev/null &&
        grep -F "Sockets=clipboard-bridge.socket clipboard-bridge-trusted.socket" "$2" >/dev/null &&
        grep -F "Service=clipboard-bridge.service" "$3" >/dev/null &&
        grep -F "enable clipboard-bridge.socket clipboard-bridge-trusted.socket" "$4" >/dev/null &&
        grep -F ".config/systemd/user/clipboard-bridge.service" "$5" >/dev/null &&
        grep -F ".config/systemd/user/clipboard-bridge-trusted.socket" "$5" >/dev/null &&
        ! grep -F "clipboard-bridge@.service" "$5" >/dev/null
      ' _ "$services" "$bridge_service" "$trusted_socket" "$setup_hook" "$ignore_template"
      The status should be success
    End

    It 'reconciles launchd on apply whenever the manifest changes'
      # chezmoi apply must SWAP the services, not merely rewrite the manifest
      # (docs/recob-migration.md's apply-order promise): the hook re-fires on
      # the manifest hash and runs the reconciler — after booting out the
      # orphaned trusted service, whose socat would otherwise still hold
      # cb.sock when the drifted clipboard-bridge kickstarts recobd.
      sync_hook="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_onchange_after_57-sync-launchd-services.sh.tmpl"
      When run command sh -c '
        grep -F "services.toml.tmpl: {{ include \"dot_config/packages/services.toml.tmpl\" | sha256sum }}" "$1" >/dev/null &&
        grep -F "system-service\" sync" "$1" >/dev/null &&
        bootout_line=$(grep -nF "launchctl bootout" "$1" | head -1 | cut -d: -f1) &&
        sync_line=$(grep -nF "system-service\" sync" "$1" | head -1 | cut -d: -f1) &&
        [ "$bootout_line" -lt "$sync_line" ]
      ' _ "$sync_hook"
      The status should be success
    End

    It 'answers the trusted contract over a real service-owned mode-0600 socket'
      Skip if 'recob binaries are not built' no_recobd
      # The real daemon, self-binding exactly as the launchd service does:
      # it tightens the socket parent to 0700, hardens the socket to 0600,
      # and answers the trusted endpoint with no credential — the uid
      # boundary is the credential. host.identity is read-only, so nothing
      # here can touch a pasteboard or a real store.
      When run command sh -c '
        root=$1; recobd=$2; bridge=$3
        sock="$root/state/cb.sock"
        export XDG_STATE_HOME="$root/state"
        export XDG_DATA_HOME="$root/data"
        mkdir -p "$XDG_STATE_HOME/clipboard" "$XDG_DATA_HOME"
        chmod 700 "$XDG_STATE_HOME/clipboard"
        printf "socket-test\n" > "$XDG_STATE_HOME/clipboard/self-name"
        "$recobd" --no-public --socket "$sock" > "$root/daemon.log" 2>&1 &
        daemon=$!
        trap "kill $daemon 2>/dev/null || true; wait $daemon 2>/dev/null || true" EXIT
        i=0
        while [ ! -S "$sock" ] && [ "$i" -lt 100 ]; do
          sleep 0.02
          i=$((i + 1))
        done
        [ -S "$sock" ] || { cat "$root/daemon.log" >&2; exit 9; }
        out=$(CLIPBOARD_BRIDGE_LOCAL_SOCKET="$sock" "$bridge" call host.identity) || exit 8
        [ "$out" = "host=$(printf socket-test | xxd -p)" ] || { echo "got: $out" >&2; exit 7; }
        mode=$(stat -f %Lp "$sock" 2>/dev/null || stat -c %a "$sock")
        [ "$mode" = 600 ] || exit 6
      ' _ "$TEST_TMP" "$RECOBD_BIN" "$BRIDGE_BIN"
      The status should be success
    End
  End
End
