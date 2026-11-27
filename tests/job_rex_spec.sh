# job/rex.zsh — a job's tab in Rex's Jobs session: resolving the rex client,
# opening the tab, and scheduling it from job::start. Hermetic: JOB_STATE_ROOT
# lives in a sandbox; pueue, tmux and rex are fakes (JOB_PUEUE_BIN,
# JOB_TMUX_BIN, JOB_REX_BIN) and no Rex server is ever consulted.
Describe 'job/rex.zsh'
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    JOB_SANDBOX=$(mktemp -d)
    export JOB_STATE_ROOT="$JOB_SANDBOX/state"
    export JOB_CLI="$JOB_SANDBOX/job"
    cat > "$JOB_SANDBOX/pueue" <<'EOS'
#!/bin/sh
case "$1" in
  add) echo 7 ;;
  status) echo '{}' ;;
esac
exit 0
EOS
    chmod +x "$JOB_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$JOB_SANDBOX/pueue"
    printf '#!/bin/sh\nexit 0\n' > "$JOB_SANDBOX/tmux"
    chmod +x "$JOB_SANDBOX/tmux"
    export JOB_TMUX_BIN="$JOB_SANDBOX/tmux"
    # rex: records argv to JOB_FAKE_REX_LOG. `whoami` exits
    # JOB_FAKE_REX_WHOAMI_RC (4 = no server). `ls --json` prints the
    # JOB_FAKE_REX_LS fixture. `new` exits JOB_FAKE_REX_NEW_RC when set;
    # otherwise it takes a moment (widening any race between two openers),
    # adds the Jobs session to the ls fixture, and answers like the real CLI.
    export JOB_FAKE_REX_LOG="$JOB_SANDBOX/rex.log"
    export JOB_FAKE_REX_LS="$JOB_SANDBOX/ls.json"
    printf '%s\n' '{"sessions":[{"session_id":"session:main","label":"Main"}]}' \
      > "$JOB_FAKE_REX_LS"
    cat > "$JOB_SANDBOX/rex" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_REX_LOG"
case "$*" in
  *' whoami'*) exit "${JOB_FAKE_REX_WHOAMI_RC:-0}" ;;
  *' ls --json'*) cat "$JOB_FAKE_REX_LS" ;;
  *' window new '*)
    echo '{"window_id":"window:w2","block_ids":["block:b2"]}'
    ;;
  *' new Jobs '*)
    [ -n "${JOB_FAKE_REX_NEW_RC:-}" ] && exit "$JOB_FAKE_REX_NEW_RC"
    sleep 0.3
    printf '%s\n' '{"sessions":[{"session_id":"session:main","label":"Main"},{"session_id":"session:jobs","label":"Jobs"}]}' \
      > "$JOB_FAKE_REX_LS"
    echo '{"session_id":"session:jobs","initial_windows":[{"window_id":"window:w1","block_ids":["block:b1"]}]}'
    ;;
esac
exit 0
EOS
    chmod +x "$JOB_SANDBOX/rex"
    export JOB_REX_BIN="$JOB_SANDBOX/rex"
    export JOB_FOLLOW_DELAY=0
  }
  cleanup() { rm -rf "$JOB_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # -f: this repo's ~/.zshenv would re-export XDG vars over the sandbox.
  run_job() {
    zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift; "$@"' \
      -- "$JOBLIB" "$@"
  }
  meta() {
    mkdir -p "$JOB_STATE_ROOT/$1"
    printf '{"title":"%s","notify":"all","pueue_id":7}\n' "$2" \
      > "$JOB_STATE_ROOT/$1/meta.json"
  }
  jobs_session() {
    printf '%s\n' '{"sessions":[{"session_id":"session:main","label":"Main"},{"session_id":"session:jobs","label":"Jobs"}]}' \
      > "$JOB_FAKE_REX_LS"
  }
  # Bounded poll (5 s) until the rex log has a line matching $1.
  wait_log() {
    local i=0
    until grep -q -- "$1" "$JOB_FAKE_REX_LOG" 2>/dev/null; do
      i=$((i + 1)); [ "$i" -gt 50 ] && return 1
      sleep 0.1
    done
  }
  opens() { grep -c ' new ' "$JOB_FAKE_REX_LOG" 2>/dev/null || :; }

  Describe 'job::_rex'
    It 'falls back to the CLI bundled in the Rex app'
      bundled() {
        local app="$JOB_SANDBOX/home/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS"
        mkdir -p "$app"
        printf '#!/bin/sh\n' > "$app/rex"; chmod +x "$app/rex"
        HOME="$JOB_SANDBOX/home" PATH=/usr/bin:/bin JOB_REX_BIN= \
          run_job job::_rex
      }
      When call bundled
      The output should end with "Contents/MacOS/rex"
      The status should be success
    End

    It 'fails when no rex is found anywhere'
      When call env HOME="$JOB_SANDBOX/home" PATH=/usr/bin:/bin JOB_REX_BIN= \
        zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; job::_rex' -- "$JOBLIB"
      The status should equal 1
      The output should equal ""
    End
  End

  Describe 'job::_rex_open_tab'
    It 'creates the Jobs session for the first job'
      opened() {
        meta j1 "Remux"
        run_job job::_rex_open_tab j1 || return 1
        cat "$JOB_FAKE_REX_LOG"
        cat "$JOB_STATE_ROOT/.rex_session"
      }
      When call opened
      The line 2 of output should equal "--autostart=false --timeout 5s new Jobs --window Remux --json -- $JOB_CLI follow j1"
      The output should include "session:jobs"
      The status should be success
    End

    It 'adds a tab when the session exists'
      opened() {
        meta j1 "Remux"; jobs_session
        run_job job::_rex_open_tab j1 || return 1
        cat "$JOB_FAKE_REX_LOG"
        cat "$JOB_STATE_ROOT/.rex_session"
      }
      When call opened
      The line 2 of output should equal "--autostart=false --timeout 5s window new -s Jobs Remux --focus=false --json -- $JOB_CLI follow j1"
      The output should include "session:jobs"
      The status should be success
    End

    It 'creates one session for two simultaneous jobs'
      both() {
        meta j1 "One"; meta j2 "Two"
        run_job job::_rex_open_tab j1 & p1=$!
        run_job job::_rex_open_tab j2 & p2=$!
        wait "$p1" "$p2"
        echo "new=$(grep -c ' new Jobs ' "$JOB_FAKE_REX_LOG")"
        echo "window=$(grep -c ' window new ' "$JOB_FAKE_REX_LOG")"
      }
      When call both
      The line 1 of output should equal "new=1"
      The line 2 of output should equal "window=1"
    End

    It 'opens a tab for a 200-character, two-line title'
      long() {
        local t
        t="$(printf 'a%.0s' $(seq 1 100))
$(printf 'b%.0s' $(seq 1 99))"
        mkdir -p "$JOB_STATE_ROOT/j1"
        jq -n --arg t "$t" '{title:$t, notify:"all", pueue_id:7}' \
          > "$JOB_STATE_ROOT/j1/meta.json"
        run_job job::_rex_open_tab j1 || return 1
        # The label is the argument after --window: one line, ≤128 chars.
        wc -l < "$JOB_FAKE_REX_LOG" | tr -d ' '
        sed -n 's/.* --window \(.*\) --json .*/\1/p' "$JOB_FAKE_REX_LOG"
      }
      When call long
      The line 1 of output should equal 2
      The line 2 of output should equal "$(printf 'a%.0s' $(seq 1 100)) $(printf 'b%.0s' $(seq 1 27))"
    End
  End

  Describe 'job::start'
    It 'opens the tab in the background after the delay'
      started() {
        id=$(run_job job::start --title "plan check" -- sleep 1) || return 1
        wait_log " follow $id" || return 2
        grep -c " new Jobs --window plan check --json -- $JOB_CLI follow $id" \
          "$JOB_FAKE_REX_LOG"
      }
      When call started
      The output should equal 1
    End

    It 'returns at once while the tab waits for its delay'
      # A $(…) capture waits for every holder of its pipe: a background step
      # that kept stdout would hold this for the whole 3 s delay.
      quick() {
        zmodload zsh/datetime
        local t0=$EPOCHREALTIME
        id=$(JOB_FOLLOW_DELAY=3 run_job job::start -- sleep 1) || return 1
        (( EPOCHREALTIME - t0 < 2 )) && echo fast || echo slow
      }
      When call quick
      The output should equal fast
    End

    It 'never passes a call without --autostart=false'
      calls() {
        id=$(run_job job::start --title "plan check" -- sleep 1) || return 1
        wait_log " follow $id" || return 2
        jobs_session
        id=$(run_job job::start --title "second" -- sleep 1) || return 1
        wait_log " follow $id" || return 2
        echo "calls=$(wc -l < "$JOB_FAKE_REX_LOG" | tr -d ' ')"
        echo "without=$(grep -vc '^--autostart=false ' "$JOB_FAKE_REX_LOG")"
      }
      When call calls
      The line 1 of output should equal "calls=6"
      The line 2 of output should equal "without=0"
    End

    # A control job started right after proves the background step ran; the
    # finished job's step started first, with the same delay.
    It 'opens no tab for a job that finished within the delay'
      finished() {
        export JOB_FOLLOW_DELAY=0.5
        a=$(run_job job::start --title "quick" -- true) || return 1
        echo "1700000000 Success 0" > "$JOB_STATE_ROOT/$a/result"
        b=$(run_job job::start --title "control" -- sleep 1) || return 1
        wait_log " follow $b" || return 2
        grep -c " follow $a" "$JOB_FAKE_REX_LOG" || :
      }
      When call finished
      The output should equal 0
    End

    It 'opens no tab for a --notify none job'
      silent() {
        a=$(run_job job::start --notify none --title "quiet" -- sleep 1) || return 1
        b=$(run_job job::start --title "control" -- sleep 1) || return 1
        wait_log " follow $b" || return 2
        grep -c " follow $a" "$JOB_FAKE_REX_LOG" || :
      }
      When call silent
      The output should equal 0
    End

    It 'opens no tab for a --modal job'
      modal() {
        a=$(run_job job::start --modal --title "watched" -- sleep 1 2>/dev/null) \
          || return 1
        b=$(run_job job::start --title "control" -- sleep 1) || return 1
        wait_log " follow $b" || return 2
        grep -c " follow $a" "$JOB_FAKE_REX_LOG" || :
      }
      When call modal
      The output should equal 0
    End

    # A tty stand-in: `script` gives the child a pty, so `[ -t 2 ]` is true.
    # The child sources job.zsh, stubs job::follow/job::watch to record their
    # arguments, runs "$@" and writes its result to $JOB_SANDBOX/result.
    run_tty() {
      script -q /dev/null zsh -f -c '
        source "$1" >/dev/null 2>&1 || exit 99; shift
        job::follow() { print -r -- "follow $*" >> "$JOB_SANDBOX/calls"; }
        job::watch() { print -r -- "watch $*" >> "$JOB_SANDBOX/calls"; }
        "$@"
      ' -- "$JOBLIB" "$@" >/dev/null 2>&1
    }
    calls() { cat "$JOB_SANDBOX/calls" 2>/dev/null; }

    It 'follows a --modal job inline in a Rex pane, with no watch or tab'
      inline() {
        export JOB_SANDBOX REX_BLOCK=block:x
        run_tty job::start --modal --title "watched" -- sleep 1 || return 1
        id=$(ls "$JOB_STATE_ROOT" | grep '^[0-9]' | head -n1)
        [ "$(calls)" = "follow --inline $id" ] || { calls; return 2; }
        sleep 0.3
        echo "tabs=$(cat "$JOB_FAKE_REX_LOG" 2>/dev/null | grep -c ' follow ' || :)"
      }
      When call inline
      The output should equal "tabs=0"
    End

    It 'still opens the watch dashboard for a --modal job outside Rex'
      outside() {
        export JOB_SANDBOX
        unset REX_BLOCK
        run_tty job::start --modal --title "watched" -- sleep 1 || return 1
        calls
      }
      When call outside
      The output should equal "watch "
    End

    It 'keeps the caller alive when the inline follower exits'
      survive() {
        export JOB_SANDBOX REX_BLOCK=block:x
        script -q /dev/null zsh -f -c '
          source "$1" >/dev/null 2>&1 || exit 99
          job::follow() { exit 7; }
          job::start --modal --title "watched" -- sleep 1 >/dev/null
          rc=$?
          echo "after rc=$rc" > "$JOB_SANDBOX/after"
        ' -- "$JOBLIB" >/dev/null 2>&1
        cat "$JOB_SANDBOX/after"
      }
      When call survive
      The output should equal "after rc=0"
    End

    It 'does nothing and succeeds when no server answers'
      down() {
        export JOB_FAKE_REX_WHOAMI_RC=4
        id=$(run_job job::start --title "plan check" -- sleep 1) || return 1
        [ -d "$JOB_STATE_ROOT/$id" ] || return 2
        wait_log ' whoami' || return 3
        sleep 0.3
        echo "opens=$(opens)"
      }
      When call down
      The output should equal "opens=0"
    End

    It 'survives Rex vanishing between the check and the open'
      vanish() {
        export JOB_FAKE_REX_NEW_RC=4
        id=$(run_job job::start --title "plan check" -- sleep 1) || return 1
        [ -d "$JOB_STATE_ROOT/$id" ] || return 2
        wait_log " follow $id" || return 3
        echo "session=$([ -e "$JOB_STATE_ROOT/.rex_session" ] && echo yes || echo no)"
      }
      When call vanish
      The output should equal "session=no"
      The status should be success
    End

    It 'returns rc 1 from the opener when Rex vanishes'
      meta j1 "Remux"
      export JOB_FAKE_REX_NEW_RC=4
      When call run_job job::_rex_open_tab j1
      The status should equal 1
    End
  End
End
