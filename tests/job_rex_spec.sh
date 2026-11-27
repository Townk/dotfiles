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
    # `block ls` prints the JOB_FAKE_REX_BLOCKS fixture and, like the real
    # CLI, exits 1 when the ls fixture has no Jobs session; `block close`
    # notes in JOB_FAKE_REX_CLOSING_SEEN whether $JOB_STATE_ROOT/.rex_closing
    # lists the block at that moment, then exits JOB_FAKE_REX_CLOSE_RC.
    export JOB_FAKE_REX_LOG="$JOB_SANDBOX/rex.log"
    export JOB_FAKE_REX_CLOSING_SEEN="$JOB_SANDBOX/closing.seen"
    export JOB_FAKE_REX_LS="$JOB_SANDBOX/ls.json"
    export JOB_FAKE_REX_BLOCKS="$JOB_SANDBOX/blocks.json"
    printf '%s\n' '{"blocks":[]}' > "$JOB_FAKE_REX_BLOCKS"
    printf '%s\n' '{"sessions":[{"session_id":"session:main","label":"Main"}]}' \
      > "$JOB_FAKE_REX_LS"
    cat > "$JOB_SANDBOX/rex" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_REX_LOG"
case "$*" in
  *' whoami'*) exit "${JOB_FAKE_REX_WHOAMI_RC:-0}" ;;
  *' block ls '*)
    grep -q '"label":"Jobs"' "$JOB_FAKE_REX_LS" || exit 1
    cat "$JOB_FAKE_REX_BLOCKS"
    ;;
  *' block close '*)
    for a; do last=$a; done
    if grep -q "^[0-9]* $last\$" "$JOB_STATE_ROOT/.rex_closing" 2>/dev/null; then
      echo "listed $last" >> "$JOB_FAKE_REX_CLOSING_SEEN"
    else
      echo "unlisted $last" >> "$JOB_FAKE_REX_CLOSING_SEEN"
    fi
    exit "${JOB_FAKE_REX_CLOSE_RC:-0}"
    ;;
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
    # job::_rex_log writes under $XDG_CACHE_HOME/jobs, never the real cache.
    export XDG_CACHE_HOME="$JOB_SANDBOX/cache"
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
      The line 2 of output should equal "--autostart=false --timeout 5s new Jobs --window=Remux --json -- $JOB_CLI follow j1"
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
        sed -n 's/.* --window=\(.*\) --json .*/\1/p' "$JOB_FAKE_REX_LOG"
      }
      When call long
      The line 1 of output should equal 2
      The line 2 of output should equal "$(printf 'a%.0s' $(seq 1 100)) $(printf 'b%.0s' $(seq 1 27))"
    End

    It 'creates nothing when the session list cannot be read'
      unreadable() {
        meta j1 "Remux"
        printf 'not json\n' > "$JOB_FAKE_REX_LS"
        run_job job::_rex_open_tab j1
        echo "rc=$? opens=$(opens)"
      }
      When call unreadable
      The output should equal "rc=1 opens=0"
    End

    It 'passes a title starting with a dash as a label, not a flag'
      dashed() {
        meta j1 "--help me"
        run_job job::_rex_open_tab j1 || return 1
        jobs_session
        run_job job::_rex_open_tab j1 || return 2
        grep ' new ' "$JOB_FAKE_REX_LOG"
      }
      When call dashed
      The line 1 of output should equal "--autostart=false --timeout 5s new Jobs --window=--help me --json -- $JOB_CLI follow j1"
      The line 2 of output should equal "--autostart=false --timeout 5s window new -s Jobs  --help me --focus=false --json -- $JOB_CLI follow j1"
    End

    It 'records when it opened the tab and its block'
      recorded() {
        meta j1 "Remux"; jobs_session
        run_job job::_rex_open_tab j1 || return 1
        read -r epoch block < "$JOB_STATE_ROOT/j1/tab"
        [ $(( $(date +%s) - epoch )) -lt 5 ] && echo "recent $block"
      }
      When call recorded
      The output should equal "recent block:b2"
    End

    It 'logs a failed open to the sandboxed rex log'
      logged() {
        meta j1 "Remux"
        JOB_FAKE_REX_NEW_RC=4 run_job job::_rex_open_tab j1
        grep -c 'j1' "$XDG_CACHE_HOME/jobs/rex.log"
      }
      When call logged
      The output should equal 1
    End
  End

  Describe 'job::_rex_reconcile'
    # blocks <block_id>… — the Jobs session's block listing, as the real
    # `block ls -s Jobs --json` prints it.
    blocks() {
      jq -nc '{blocks: [$ARGS.positional[]
        | {block_id: ., label: "shell", placement: "placed", window_id: "window:w"}]}' \
        --args "$@" > "$JOB_FAKE_REX_BLOCKS"
    }
    # A pid that is certainly dead: a child that exited and was reaped.
    dead_pid() { sh -c 'exit 0' & p=$!; wait "$p"; echo "$p"; }
    result() { echo "1700000000 $2 $3" > "$JOB_STATE_ROOT/$1/result"; }
    follower() { echo "$2 $3" > "$JOB_STATE_ROOT/$1/follower"; }
    reconcile() { run_job job::_rex_reconcile; }
    closes() { grep ' block close ' "$JOB_FAKE_REX_LOG" | sed 's/.* block close //'; }
    tabs() { grep ' window new \| new Jobs ' "$JOB_FAKE_REX_LOG" | sed 's/.* follow //'; }
    count() { "$@" | grep -c . || :; }

    It 'closes a tab that is not a live follower'
      stale() {
        jobs_session; blocks block:b9
        reconcile || return 1
        cat "$JOB_FAKE_REX_LOG"
      }
      When call stale
      The output should equal "--autostart=false --timeout 2s ls --json
--autostart=false --timeout 2s block ls -s Jobs --json
--autostart=false --timeout 2s block close -s Jobs block:b9"
    End

    It 'leaves a live follower alone'
      live() {
        meta j1 "One"; follower j1 block:b1 $$
        jobs_session; blocks block:b1
        reconcile || return 1
        echo "closes=$(count closes) tabs=$(count tabs)"
      }
      When call live
      The output should equal "closes=0 tabs=0"
    End

    It 'reopens a running job that lost its tab'
      lost() {
        meta j2 "Two"; follower j2 block:b2 "$(dead_pid)"
        jobs_session; blocks block:b2
        reconcile || return 1
        echo "closed: $(closes)"
        grep ' window new ' "$JOB_FAKE_REX_LOG"
      }
      When call lost
      The line 1 of output should equal "closed: -s Jobs block:b2"
      The line 2 of output should equal "--autostart=false --timeout 5s window new -s Jobs Two --focus=false --json -- $JOB_CLI follow j2"
    End

    It 'reopens a failed job that was not dismissed'
      failed() {
        meta j3 "Three"; result j3 Failed 2
        echo "1700000000 block:b3" > "$JOB_STATE_ROOT/j3/tab"
        follower j3 block:b3 "$(dead_pid)"
        jobs_session
        reconcile || return 1
        tabs
      }
      When call failed
      The output should equal "j3"
    End

    # A failure followed inline, or over within the delay, never had a Jobs
    # tab (no `tab` file): reconcile must not open one for it.
    It 'opens nothing for a failed job that never had a tab'
      tabless() {
        meta j3 "Three"; result j3 Failed 2
        jobs_session
        reconcile || return 1
        echo "tabs=$(count tabs)"
      }
      When call tabless
      The output should equal "tabs=0"
    End

    It 'closes only the stale block beside a live follower'
      mixed() {
        meta j1 "One"; follower j1 block:b1 $$
        jobs_session; blocks block:b1 block:b9
        reconcile || return 1
        closes
        echo "live=$(grep ' block close ' "$JOB_FAKE_REX_LOG" | grep -c 'block:b1' || :)"
      }
      When call mixed
      The output should equal "-s Jobs block:b9
live=0"
    End

    It 'does not reopen a dismissed failure, a success, a cancel or a notify=none job'
      settled() {
        meta j4 "Four"; result j4 Failed 2; touch "$JOB_STATE_ROOT/j4/dismissed"
        meta j5 "Five"; result j5 Success 0
        meta j6 "Six"; result j6 Killed ""
        mkdir -p "$JOB_STATE_ROOT/j7"
        printf '{"title":"Seven","notify":"none","pueue_id":7}\n' \
          > "$JOB_STATE_ROOT/j7/meta.json"
        result j7 Failed 1
        jobs_session
        reconcile || return 1
        echo "tabs=$(count tabs)"
      }
      When call settled
      The output should equal "tabs=0"
    End

    It 'does nothing when there is no Jobs session'
      nosession() {
        meta j2 "Two"; follower j2 block:b2 "$(dead_pid)"
        blocks block:b2 block:b9
        reconcile || return 1
        cat "$JOB_FAKE_REX_LOG"
      }
      When call nosession
      The output should equal "--autostart=false --timeout 2s ls --json"
    End

    # Session ids change across a Rex restart, and Rex's Lua reads
    # .rex_session for the close confirmation and the show-Jobs key.
    It 'rewrites a stale .rex_session with the Jobs session id'
      stale() {
        mkdir -p "$JOB_STATE_ROOT"
        echo session:old > "$JOB_STATE_ROOT/.rex_session"
        jobs_session
        reconcile || return 1
        cat "$JOB_STATE_ROOT/.rex_session"
      }
      When call stale
      The output should equal "session:jobs"
    End

    It 'removes .rex_session when there is no Jobs session'
      gone() {
        mkdir -p "$JOB_STATE_ROOT"
        echo session:old > "$JOB_STATE_ROOT/.rex_session"
        reconcile || return 1
        [ -e "$JOB_STATE_ROOT/.rex_session" ] && echo kept || echo removed
      }
      When call gone
      The output should equal "removed"
    End

    It 'does nothing when the session list cannot be read'
      unreadable() {
        meta j2 "Two"
        printf 'garbage\n' > "$JOB_FAKE_REX_LS"
        blocks block:b9
        reconcile || return 1
        echo "closes=$(count closes) opens=$(opens)"
      }
      When call unreadable
      The output should equal "closes=0 opens=0"
    End

    It 'only ever names the Jobs session'
      named() {
        meta j2 "Two"
        jobs_session; blocks block:b8 block:b9
        reconcile || return 1
        echo "calls=$(grep -c ' block \| window new ' "$JOB_FAKE_REX_LOG")"
        echo "other=$(grep ' block \| window new ' "$JOB_FAKE_REX_LOG" | grep -vc -- ' -s Jobs ' || :)"
      }
      When call named
      The output should equal "calls=4
other=0"
    End

    # The rule for a tab still starting: its follower may not have written
    # the follower file yet, so a tab opened less than JOB_FOLLOW_DELAY + 5
    # seconds ago is neither closed nor reopened.
    It 'leaves a tab opened moments ago alone'
      starting() {
        meta j1 "One"; echo "$(date +%s) block:b3" > "$JOB_STATE_ROOT/j1/tab"
        jobs_session; blocks block:b3
        reconcile || return 1
        echo "closes=$(count closes) tabs=$(count tabs)"
      }
      When call starting
      The output should equal "closes=0 tabs=0"
    End

    It 'reopens a tab opened long ago whose follower never started'
      never() {
        meta j1 "One"; echo "1700000000 block:b3" > "$JOB_STATE_ROOT/j1/tab"
        jobs_session; blocks block:b3
        reconcile || return 1
        echo "closed: $(closes)"
        tabs
      }
      When call never
      The output should equal "closed: -s Jobs block:b3
j1"
    End

    It 'leaves a job started moments ago to its own scheduled step'
      young() {
        mkdir -p "$JOB_STATE_ROOT/j1"
        printf '{"title":"One","notify":"all","pueue_id":7,"created":%s}\n' \
          "$(date +%s)" > "$JOB_STATE_ROOT/j1/meta.json"
        jobs_session
        reconcile || return 1
        echo "tabs=$(count tabs)"
      }
      When call young
      The output should equal "tabs=0"
    End

    It 'does not reopen a job followed inline in another session'
      inline() {
        meta j1 "One"; follower j1 block:elsewhere $$
        jobs_session
        reconcile || return 1
        echo "tabs=$(count tabs)"
      }
      When call inline
      The output should equal "tabs=0"
    End

    It 'logs every close and reopen to the sandboxed rex log'
      logged() {
        meta j2 "Two"
        jobs_session; blocks block:b9
        reconcile || return 1
        grep -c 'block:b9' "$XDG_CACHE_HOME/jobs/rex.log"
        grep -c 'j2' "$XDG_CACHE_HOME/jobs/rex.log"
      }
      When call logged
      The output should equal "1
1"
    End

    # A follower in a block reconcile closes must not take the hangup for
    # its owner closing the tab: the block is listed in .rex_closing before
    # the close, and entries older than 60 s are dropped on the way.
    It 'lists a block in .rex_closing before closing it'
      listed() {
        local epoch block
        mkdir -p "$JOB_STATE_ROOT"
        printf '%s block:old\n%s block:recent\n' "$(( $(date +%s) - 61 ))" \
          "$(date +%s)" > "$JOB_STATE_ROOT/.rex_closing"
        jobs_session; blocks block:b8 block:b9
        reconcile || return 1
        cat "$JOB_FAKE_REX_CLOSING_SEEN"
        sed 's/^[0-9]* //' "$JOB_STATE_ROOT/.rex_closing"
        while read -r epoch block; do
          [ $(( $(date +%s) - epoch )) -lt 5 ] || echo "stale $block"
        done < "$JOB_STATE_ROOT/.rex_closing"
      }
      When call listed
      The output should equal "listed block:b8
listed block:b9
block:recent
block:b8
block:b9"
    End

    It 'succeeds when a close fails'
      closefail() {
        jobs_session; blocks block:b9
        JOB_FAKE_REX_CLOSE_RC=4 reconcile
        echo "rc=$?"
      }
      When call closefail
      The output should equal "rc=0"
    End
  End

  # The close keys ask before closing a running job's tab: Rex's Lua asks
  # `job owns-block <block>` whether the focused pane is one.
  Describe 'job::_rex_block_job'
    follower() { echo "$2 $3" > "$JOB_STATE_ROOT/$1/follower"; }

    It 'prints the title of the running job the block follows'
      running() {
        meta j1 "One"; follower j1 block:b1 $$
        meta j2 "Two"; follower j2 block:b2 $$
        run_job job::_rex_block_job block:b2
      }
      When call running
      The status should be success
      The output should equal "Two"
    End

    It 'fails for a block whose job has finished'
      finished() {
        meta j1 "One"; follower j1 block:b1 $$
        echo "1700000000 Success 0" > "$JOB_STATE_ROOT/j1/result"
        run_job job::_rex_block_job block:b1
      }
      When call finished
      The status should equal 1
      The output should equal ""
    End

    It 'fails for a block no job follows'
      unknown() {
        meta j1 "One"; follower j1 block:b1 $$
        run_job job::_rex_block_job block:b9
      }
      When call unknown
      The status should equal 1
      The output should equal ""
    End

    It 'answers through the job command as owns-block'
      cli() {
        meta j1 "One"; follower j1 block:b1 $$
        zsh -f "$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_job" \
          owns-block block:b1
      }
      When call cli
      The status should be success
      The output should equal "One"
    End
  End

  Describe 'job::start'
    It 'opens the tab in the background after the delay'
      started() {
        id=$(run_job job::start --title "plan check" -- sleep 1) || return 1
        wait_log " follow $id" || return 2
        grep -c " new Jobs --window=plan check --json -- $JOB_CLI follow $id" \
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
      # First job: whoami, reconcile's ls (no Jobs session), the opener's
      # ls and new. Second: whoami, reconcile's ls and block ls, then the
      # opener's ls and window new.
      The line 1 of output should equal "calls=9"
      The line 2 of output should equal "without=0"
    End

    # The background step reconciles first, and reconcile itself opens the
    # scheduled job's tab: the step must not open a second one.
    It 'opens one tab for the scheduled job when it reconciles first'
      once() {
        jobs_session
        id=$(run_job job::start --title "plan check" -- sleep 1) || return 1
        wait_log " follow $id" || return 2
        sleep 0.5
        echo "block_ls=$(grep -c ' block ls ' "$JOB_FAKE_REX_LOG")"
        echo "tabs=$(grep -c " follow $id" "$JOB_FAKE_REX_LOG")"
      }
      When call once
      The line 1 of output should equal "block_ls=1"
      The line 2 of output should equal "tabs=1"
    End

    It 'reopens another job that lost its tab when a job starts'
      repaired() {
        meta j2 "Two"
        jobs_session
        id=$(run_job job::start --title "plan check" -- sleep 1) || return 1
        wait_log " follow $id" || return 2
        sleep 0.5
        echo "j2=$(grep -c ' follow j2$' "$JOB_FAKE_REX_LOG")"
        echo "new=$(grep -c " follow $id" "$JOB_FAKE_REX_LOG")"
      }
      When call repaired
      The line 1 of output should equal "j2=1"
      The line 2 of output should equal "new=1"
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
        unset TMUX ZELLIJ
        run_tty job::start --modal --title "watched" -- sleep 1 || return 1
        id=$(ls "$JOB_STATE_ROOT" | grep '^[0-9]' | head -n1)
        [ "$(calls)" = "follow --inline $id" ] || { calls; return 2; }
        sleep 0.3
        echo "tabs=$(cat "$JOB_FAKE_REX_LOG" 2>/dev/null | grep -c ' follow ' || :)"
      }
      When call inline
      The output should equal "tabs=0"
    End

    # A tmux or zellij started inside a Rex pane inherits REX_BLOCK, but its
    # own panes are where we are: Rex is detected last.
    It 'opens the watch dashboard inside tmux or zellij in a Rex pane'
      nested() {
        export JOB_SANDBOX REX_BLOCK=block:x
        unset ZELLIJ
        TMUX="fake/sock,1,0" run_tty job::start --modal --title "watched" \
          -- sleep 1 || return 1
        unset TMUX
        ZELLIJ=0 run_tty job::start --modal --title "watched" \
          -- sleep 1 || return 2
        calls | sed 's/ *$//'
      }
      When call nested
      The output should equal "watch
watch"
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
        unset TMUX ZELLIJ
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

    # Callers read the id through $(…): the inline follower's log and
    # reports must reach the terminal, not that capture.
    It 'prints only the job id from a --modal job followed inline'
      captured() {
        local id
        export JOB_SANDBOX REX_BLOCK=block:x
        unset TMUX ZELLIJ
        script -q /dev/null zsh -f -c '
          source "$1" >/dev/null 2>&1 || exit 99
          job::follow() { print -r -- follower-marker; }
          jid=$(job::start --modal --title "watched" -- sleep 1)
          print -r -- "$jid" > "$JOB_SANDBOX/jid"
        ' -- "$JOBLIB" > "$JOB_SANDBOX/tty" 2>&1
        id=$(ls "$JOB_STATE_ROOT" | grep '^[0-9]' | head -n1)
        [ "$(cat "$JOB_SANDBOX/jid")" = "$id" ] && echo id-only \
          || echo "jid=$(cat "$JOB_SANDBOX/jid")"
        grep -c follower-marker "$JOB_SANDBOX/tty" || :
      }
      When call captured
      The output should equal "id-only
1"
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
