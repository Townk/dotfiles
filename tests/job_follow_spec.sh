# job/follow.zsh — the OSC 7501 status report for a job's state, and the
# follower that runs in a job's Rex tab. Hermetic: JOB_STATE_ROOT lives in a
# sandbox; job state dirs are written directly; pueue and rex are recording
# fakes (JOB_PUEUE_BIN, JOB_REX_BIN).
Describe 'job/follow.zsh'
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    JOB_SANDBOX=$(mktemp -d)
    export JOB_STATE_ROOT="$JOB_SANDBOX/state"
    export JOB_FAKE_LOG="$JOB_SANDBOX/pueue.log"
    # `follow` prints one log line and exits — or, with
    # JOB_FAKE_FOLLOW_PIDFILE set, records its pid and stays alive the way
    # a real `pueue follow` on a running task does. `status` takes
    # JOB_FAKE_STATUS_DELAY seconds when that is set.
    cat > "$JOB_SANDBOX/pueue" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in
  follow)
    echo "log of task $2"
    if [ -n "${JOB_FAKE_FOLLOW_PIDFILE:-}" ]; then
      echo $$ > "$JOB_FAKE_FOLLOW_PIDFILE"
      exec sleep 30
    fi
    ;;
  status)
    [ -n "${JOB_FAKE_STATUS_DELAY:-}" ] && sleep "$JOB_FAKE_STATUS_DELAY"
    echo '{}'
    ;;
esac
exit 0
EOS
    chmod +x "$JOB_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$JOB_SANDBOX/pueue"
    # rex: records argv. `whoami --json` answers the server instance id —
    # from JOB_FAKE_REX_INSTANCE_FILE when it exists (so a test can restart
    # the "server" under a running follower), else JOB_FAKE_REX_INSTANCE —
    # and exits JOB_FAKE_REX_WHOAMI_RC. Everything else exits
    # JOB_FAKE_REX_RC (3 = block gone, 4 = server unreachable, 0 = block
    # still there) — read from JOB_FAKE_REX_RC_FILE when it exists, so a
    # test can change the answer while a hangup is being decided. Every
    # call also writes the JOB_CLI it sees to JOB_FAKE_REX_CLI_SEEN. With
    # JOB_FAKE_REX_OUT naming the follower's output file, the first whoami
    # notes in <that file>.at-whoami whether a report was in it by then.
    export JOB_FAKE_REX_LOG="$JOB_SANDBOX/rex.log"
    export JOB_FAKE_REX_INSTANCE=srv-1
    export JOB_FAKE_REX_CLI_SEEN="$JOB_SANDBOX/cli.seen"
    cat > "$JOB_SANDBOX/rex" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_REX_LOG"
printf '%s\n' "${JOB_CLI-unset}" > "$JOB_FAKE_REX_CLI_SEEN"
case "$*" in
  *' whoami '*)
    if [ -n "${JOB_FAKE_REX_OUT:-}" ] && [ ! -e "$JOB_FAKE_REX_OUT.at-whoami" ]; then
      if grep -q ']7501;' "$JOB_FAKE_REX_OUT" 2>/dev/null; then
        echo reported
      else
        echo silent
      fi > "$JOB_FAKE_REX_OUT.at-whoami"
    fi
    [ "${JOB_FAKE_REX_WHOAMI_RC:-0}" = 0 ] || exit "$JOB_FAKE_REX_WHOAMI_RC"
    inst="$JOB_FAKE_REX_INSTANCE"
    [ -n "${JOB_FAKE_REX_INSTANCE_FILE:-}" ] && [ -f "$JOB_FAKE_REX_INSTANCE_FILE" ] \
      && inst=$(cat "$JOB_FAKE_REX_INSTANCE_FILE")
    printf '{"instance_id":"%s","session":"Jobs"}\n' "$inst"
    exit 0
    ;;
esac
[ -n "${JOB_FAKE_REX_RC_FILE:-}" ] && [ -f "$JOB_FAKE_REX_RC_FILE" ] \
  && exit "$(cat "$JOB_FAKE_REX_RC_FILE")"
exit "${JOB_FAKE_REX_RC:-0}"
EOS
    chmod +x "$JOB_SANDBOX/rex"
    export JOB_REX_BIN="$JOB_SANDBOX/rex"
    export JOB_FAKE_OPEN_LOG="$JOB_SANDBOX/opened"
    # job::_rex_log writes under $XDG_CACHE_HOME/jobs, never the real cache.
    export XDG_CACHE_HOME="$JOB_SANDBOX/cache"
    # The hangup decision waits a second before asking the server; only the
    # examples that prove the wait keep it.
    export JOB_FOLLOW_HUP_WAIT=0
    # The CLI a follower starts its detached hangup decision through: the
    # front-end under `zsh -f`, so this repo's ~/.zshenv cannot re-export
    # XDG vars over the sandbox.
    printf '#!/bin/sh\nexec zsh -f "%s" "$@"\n' \
      "$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_job" \
      > "$JOB_SANDBOX/job"
    chmod +x "$JOB_SANDBOX/job"
    export JOB_CLI="$JOB_SANDBOX/job"
    : > "$JOB_FAKE_LOG"
    mkdir -p "$JOB_STATE_ROOT/j1"
  }
  cleanup() { rm -rf "$JOB_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # -f: this repo's ~/.zshenv would re-export XDG vars over the sandbox.
  run_job() {
    zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift; "$@"' \
      -- "$JOBLIB" "$@"
  }
  b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  meta() { printf '{"title":"%s","notify":"%s","pueue_id":7}\n' "$1" "${2:-all}" > "$JOB_STATE_ROOT/j1/meta.json"; }
  report() { run_job job::_follow_report j1 "$1"; }

  Describe 'job::_follow_report'
    It 'reports a queued job'
      meta "Remux"
      When call report queued
      The output should equal "state=working:app=job:msg=$(b64 queued)"
    End

    It 'reports progress with a percentage'
      meta "Remux"
      echo "1700000000 40 remuxing" > "$JOB_STATE_ROOT/j1/progress"
      When call report running
      The output should equal "state=working:app=job:progress=40:msg=$(b64 remuxing)"
    End

    It 'omits progress when indeterminate'
      meta "Remux"
      echo "1700000000 -1 scanning files" > "$JOB_STATE_ROOT/j1/progress"
      When call report running
      The output should equal "state=working:app=job:msg=$(b64 'scanning files')"
    End

    It 'prefixes the message while waiting'
      meta "Remux"
      echo "1700000000 -1 for disk" > "$JOB_STATE_ROOT/j1/progress"
      echo waiting > "$JOB_STATE_ROOT/j1/phase"
      When call report running
      The output should equal "state=working:app=job:msg=$(b64 'waiting: for disk')"
    End

    It 'reports success as done'
      meta "Remux"
      echo "1700000000 Success 0" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal "state=done:app=job:msg=$(b64 'Remux completed')"
    End

    It 'stays silent on success when notify is failures'
      meta "Remux" failures
      echo "1700000000 Success 0" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal ""
    End

    It 'stays silent when the job was killed'
      meta "Remux"
      echo "1700000000 Killed 137" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal ""
    End

    It 'reports a failure with its exit code'
      meta "Remux"
      echo "1700000000 Failed 2" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal "state=error:app=job:msg=$(b64 'Remux failed (exit 2)')"
    End

    It 'reports a failure without an exit code'
      meta "Remux"
      echo "1700000000 Failed" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal "state=error:app=job:msg=$(b64 'Remux failed')"
    End

    It 'falls back to the title before any progress exists'
      meta "Remux"
      When call report running
      The output should equal "state=working:app=job:msg=$(b64 Remux)"
    End

    # meta.json always has a title when job::start wrote it; one that
    # cannot be read must not give a message starting with a space.
    It 'names the job when it has no title'
      meta ""
      echo "1700000000 Success 0" > "$JOB_STATE_ROOT/j1/result"
      When call report running
      The output should equal "state=done:app=job:msg=$(b64 'job completed')"
    End

    It 'sanitizes with neither perl nor iconv installed'
      meta "Remux"
      printf '1700000000 -1 a\tb\302\205c\n' > "$JOB_STATE_ROOT/j1/progress"
      check() {
        local body tool
        mkdir "$JOB_SANDBOX/bin"
        for tool in zsh jq base64 tr cat; do
          ln -s "$(command -v "$tool")" "$JOB_SANDBOX/bin/$tool" || return 1
        done
        body=$(PATH="$JOB_SANDBOX/bin" report running) || return 1
        printf '%s' "${body##*msg=}" | base64 -D
      }
      When call check
      The output should equal "a b c"
    End

    It 'sanitizes a message Rex would reject'
      meta_hostile() {
        local t
        t=$(printf 'line1\nline2\tx\302\205y%s' "$(printf 'a%.0s' $(seq 3000))")
        jq -n --arg t "$t" '{title:$t,notify:"all"}' > "$JOB_STATE_ROOT/j1/meta.json"
        echo "1700000000 Success 0" > "$JOB_STATE_ROOT/j1/result"
      }
      check() {
        local body bad n
        meta_hostile
        body=$(report running) || return 1
        # Any line still holding a control character: C0, DEL, or C1
        # (U+0080-U+009F, which UTF-8 writes as C2 80-9F).
        bad=$(printf '%s' "${body##*msg=}" | base64 -D | perl -CS -ne 'print if /[\x00-\x1f\x7f-\x9f]/')
        [ -z "$bad" ] || { echo "control chars"; return 0; }
        n=$(printf '%s' "${body##*msg=}" | base64 -D | wc -c | tr -d ' ')
        [ "$n" -le 2048 ] && echo ok || echo "too long $n"
      }
      When call check
      The output should equal ok
    End

    It 'cuts on a character boundary'
      meta "Remux"
      printf '1700000000 -1 %s\n' "$(printf 'é%.0s' $(seq 1500))" > "$JOB_STATE_ROOT/j1/progress"
      check() {
        local body
        body=$(report running) || return 1
        printf '%s' "${body##*msg=}" | base64 -D | iconv -f UTF-8 -t UTF-8 >/dev/null && echo valid
      }
      When call check
      The output should equal valid
    End
  End

  Describe 'job::_follow_emit'
    It 'wraps the body in one OSC 7501 sequence'
      emit() { run_job job::_follow_emit "state=working:app=job" | od -An -c | tr -d ' \n'; }
      When call emit
      The output should equal '033]7501;state=working:app=job033\'
    End
  End

  # A job::_rex_open_tab stub: the real one belongs to the Rex tab layer.
  run_job_stubbed() {
    zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift
      job::_rex_open_tab() { print -r -- "$1" >> "$JOB_FAKE_OPEN_LOG"; }
      "$@"' -- "$JOBLIB" "$@"
  }
  result() { echo "1700000000 $1 $2" > "$JOB_STATE_ROOT/j1/result"; }
  kills() { grep -c '^kill\|^remove' "$JOB_FAKE_LOG" || :; }

  Describe 'job::_follow_end'
    It 'exits an inline follower'
      meta "Remux"; result Success 0
      When call run_job job::_follow_end j1 1
      The output should equal exit
    End

    It 'exits when the job was killed'
      meta "Remux"; result Killed 137
      When call run_job job::_follow_end j1 0
      The output should equal exit
    End

    It 'exits on success when notify is failures'
      meta "Remux" failures; result Success 0
      When call run_job job::_follow_end j1 0
      The output should equal exit
    End

    It 'waits for a key on success'
      meta "Remux"; result Success 0
      When call run_job job::_follow_end j1 0
      The output should equal key
    End

    It 'stays open on failure'
      meta "Remux"; result Failed 2
      When call run_job job::_follow_end j1 0
      The output should equal stay
    End
  End

  Describe 'job::_follow_on_hup'
    hup() {
      REX_BLOCK="${HUP_BLOCK-blk-1}" \
        run_job_stubbed job::_follow_on_hup j1 "${1:-0}" "${HUP_INSTANCE-srv-1}"
      print -r -- "rc=$? kills=$(kills)"
    }
    rexlog() { sed 's/^[^ ]* //' "$XDG_CACHE_HOME/jobs/rex.log" 2>/dev/null; }

    It 'cancels when the server says the tab is gone'
      meta "Remux"
      check() {
        JOB_FAKE_REX_RC=3 hup
        grep -c '^kill 7$' "$JOB_FAKE_LOG"
        cat "$JOB_FAKE_REX_LOG"
      }
      When call check
      The output should equal "rc=0 kills=1
1
--autostart=false --timeout 3s block inspect blk-1
--autostart=false --timeout 3s whoami --json"
    End

    It 'does not cancel when a restarted server says the tab is gone'
      meta "Remux"; result Failed 2
      check() {
        JOB_FAKE_REX_RC=3 JOB_FAKE_REX_INSTANCE=srv-2 hup
        [ -e "$JOB_STATE_ROOT/j1/dismissed" ] && echo dismissed || echo kept
      }
      When call check
      The output should equal "rc=0 kills=0
kept"
    End

    It 'does not cancel when a restarted server says an unfinished job tab is gone'
      meta "Remux"
      export JOB_FAKE_REX_RC=3 JOB_FAKE_REX_INSTANCE=srv-2
      When call hup
      The output should equal "rc=0 kills=0"
    End

    It 'does not cancel without a recorded server instance'
      meta "Remux"
      # A server that reports no instance id would compare equal to the
      # empty one recorded at start.
      export JOB_FAKE_REX_RC=3 HUP_INSTANCE="" JOB_FAKE_REX_INSTANCE=""
      When call hup
      The output should equal "rc=0 kills=0"
    End

    It 'does not cancel when the server instance cannot be read'
      meta "Remux"
      export JOB_FAKE_REX_RC=3 JOB_FAKE_REX_WHOAMI_RC=4
      When call hup
      The output should equal "rc=0 kills=0"
    End

    It 'does not cancel when the server is unreachable'
      meta "Remux"
      export JOB_FAKE_REX_RC=4
      When call hup
      The output should equal "rc=0 kills=0"
    End

    It 'does not cancel when the block still exists'
      meta "Remux"
      export JOB_FAKE_REX_RC=0
      When call hup
      The output should equal "rc=0 kills=0"
    End

    # A stopping server can hang up its tabs while it still answers: rc 3
    # from the same instance, then rc 4 once it is gone. The wait before
    # asking lets it go.
    It 'waits before asking, so a stopping server is gone by then'
      meta "Remux"
      stopping() {
        local rcf="$JOB_SANDBOX/rc"
        echo 3 > "$rcf"
        ( sleep 0.5; echo 4 > "$rcf.tmp"; mv -f "$rcf.tmp" "$rcf" ) &
        JOB_FAKE_REX_RC_FILE="$rcf" hup
        wait
      }
      check() {
        ( unset JOB_FOLLOW_HUP_WAIT; stopping )
        JOB_FOLLOW_HUP_WAIT=0 stopping
      }
      When call check
      The output should equal "rc=0 kills=0
rc=0 kills=1"
    End

    # A tab reconcile closes hangs up its follower exactly like its owner
    # closing it: rc 3 from the same instance. Reconcile lists the block in
    # .rex_closing first.
    It 'does not cancel a tab reconcile is closing'
      meta "Remux"
      check() {
        echo "$(date +%s) blk-1" > "$JOB_STATE_ROOT/.rex_closing"
        JOB_FAKE_REX_RC=3 hup
        rexlog
      }
      When call check
      The output should equal "rc=0 kills=0
job j1: hangup of blk-1: closed by reconcile: nothing"
    End

    It 'does not dismiss a failed job whose tab reconcile is closing'
      meta "Remux"; result Failed 2
      check() {
        printf '%s blk-0\n%s blk-1\n' "$(date +%s)" "$(date +%s)" \
          > "$JOB_STATE_ROOT/.rex_closing"
        JOB_FAKE_REX_RC=3 hup
        [ -e "$JOB_STATE_ROOT/j1/dismissed" ] && echo dismissed || echo kept
      }
      When call check
      The output should equal "rc=0 kills=0
kept"
    End

    It 'cancels when reconcile listed the tab more than 60 s ago'
      meta "Remux"
      check() {
        echo "$(( $(date +%s) - 61 )) blk-1" > "$JOB_STATE_ROOT/.rex_closing"
        JOB_FAKE_REX_RC=3 hup
      }
      When call check
      The output should equal "rc=0 kills=1"
    End

    It 'does not cancel without a block to ask about'
      meta "Remux"
      check() {
        JOB_FAKE_REX_RC=3 HUP_BLOCK="" hup
        [ -e "$JOB_FAKE_REX_LOG" ] && echo asked || echo not-asked
      }
      When call check
      The output should equal "rc=0 kills=0
not-asked"
    End

    It 'marks a failed job dismissed when its tab is closed'
      meta "Remux"; result Failed 2
      check() {
        JOB_FAKE_REX_RC=3 hup
        [ -e "$JOB_STATE_ROOT/j1/dismissed" ] && echo dismissed || echo kept
      }
      When call check
      The output should equal "rc=0 kills=0
dismissed"
    End

    It 'leaves a finished job alone when its tab is closed'
      meta "Remux"; result Success 0
      check() {
        JOB_FAKE_REX_RC=3 hup
        [ -e "$JOB_STATE_ROOT/j1/dismissed" ] && echo dismissed || echo kept
      }
      When call check
      The output should equal "rc=0 kills=0
kept"
    End

    It 'never cancels from an inline follower'
      meta "Remux"
      check() {
        JOB_FAKE_REX_RC=3 hup 1
        cat "$JOB_FAKE_OPEN_LOG"
      }
      When call check
      The output should equal "rc=0 kills=0
j1"
    End

    It 'opens no tab from an inline follower once the job is done'
      meta "Remux"; result Success 0
      check() {
        JOB_FAKE_REX_RC=3 hup 1
        [ -e "$JOB_FAKE_OPEN_LOG" ] && echo opened || echo not-opened
      }
      When call check
      The output should equal "rc=0 kills=0
not-opened"
    End

    It 'logs a cancel with the inspect rc and the instance match'
      meta "Remux"
      check() { JOB_FAKE_REX_RC=3 hup >/dev/null; rexlog; }
      When call check
      The output should equal "job j1: hangup of blk-1: inspect rc=3, instance same: cancelled"
    End

    It 'logs a restart as doing nothing'
      meta "Remux"; result Failed 2
      check() { JOB_FAKE_REX_RC=3 JOB_FAKE_REX_INSTANCE=srv-2 hup >/dev/null; rexlog; }
      When call check
      The output should equal "job j1: hangup of blk-1: inspect rc=3, instance different: nothing"
    End

    It 'logs a dismissal'
      meta "Remux"; result Failed 2
      check() { JOB_FAKE_REX_RC=3 hup >/dev/null; rexlog; }
      When call check
      The output should equal "job j1: hangup of blk-1: inspect rc=3, instance same: dismissed"
    End

    It 'logs a block that still exists without asking the instance'
      meta "Remux"
      check() { JOB_FAKE_REX_RC=0 hup >/dev/null; rexlog; }
      When call check
      The output should equal "job j1: hangup of blk-1: inspect rc=0, instance unasked: nothing"
    End

    It 'logs nothing for an inline follower'
      meta "Remux"
      check() { JOB_FAKE_REX_RC=3 hup 1 >/dev/null; rexlog; echo end; }
      When call check
      The output should equal "end"
    End
  End

  Describe 'job::follow'
    # Run through the CLI front-end, so the loop is exercised under its
    # `set -eu`. Every background follower has a hard bound: follow_wait
    # kills it after 5s and reports "timeout".
    JOBBIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_job"
    OSC="$(printf '\033]7501;')"
    follow_bg() {
      JOB_FOLLOW_POLL=0.1 JOB_FOLLOW_DONE_TTL=0 REX_BLOCK=blk-1 \
        zsh -f "$JOBBIN" follow "$@" \
        > "$JOB_SANDBOX/out" 2> "$JOB_SANDBOX/err" < /dev/null &
      FPID=$!
    }
    follow_wait() {
      local i=0
      while kill -0 "$FPID" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 50 ]; then
          kill -9 "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null
          echo timeout; return 1
        fi
        sleep 0.1
      done
      wait "$FPID"; echo "rc=$?"
    }
    wait_for() {
      local i=0
      until [ -e "$1" ]; do
        i=$((i + 1)); [ "$i" -gt 50 ] && return 1
        sleep 0.1
      done
    }
    reports() { grep -o "${OSC}[^$(printf '\033')]*" "$JOB_SANDBOX/out" | sed "s/^${OSC}//"; }
    # The hangup decision runs detached, after the follower has exited:
    # bounded poll (5 s) until it has logged its outcome.
    decided() {
      local i=0
      until grep -q ': hangup of blk-1: \(inspect\|closed\)' \
        "$XDG_CACHE_HOME/jobs/rex.log" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -gt 50 ] && { echo undecided; return 1; }
        sleep 0.1
      done
    }
    # Bounded poll (5 s) until the pueue log has a line matching $1.
    pueue_logged() {
      local i=0
      until grep -q -- "$1" "$JOB_FAKE_LOG" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -gt 50 ] && return 1
        sleep 0.1
      done
    }

    It 'reports progress, then done, then exits'
      meta "Remux"
      check() {
        local follower out working done_at
        follow_bg j1
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        follower=$(cat "$JOB_STATE_ROOT/j1/follower")
        echo "1700000000 40 a" > "$JOB_STATE_ROOT/j1/progress"
        sleep 0.4
        result Success ""
        follow_wait || return 1
        [ "$follower" = "blk-1 $FPID" ] && echo follower-ok || echo "follower=$follower"
        working=$(reports | grep -n "^state=working:app=job:progress=40:msg=$(b64 a)\$" | cut -d: -f1)
        done_at=$(reports | grep -n "^state=done:app=job:msg=$(b64 'Remux completed')\$" | cut -d: -f1)
        [ -n "$working" ] && [ -n "$done_at" ] && [ "$working" -lt "$done_at" ] \
          && echo ordered || echo "working=$working done=$done_at"
        grep -c '^follow 7$' "$JOB_FAKE_LOG"
        [ -e "$JOB_STATE_ROOT/j1/follower" ] && echo follower-left || echo follower-gone
        cat "$JOB_SANDBOX/err"
      }
      When call check
      The output should equal "rc=0
follower-ok
ordered
1
follower-gone"
    End

    It 'exits quietly when the state dir disappears'
      meta "Remux"
      check() {
        follow_bg j1
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        sleep 0.2
        rm -rf "$JOB_STATE_ROOT/j1"
        follow_wait || return 1
        cat "$JOB_SANDBOX/err"
        kills
      }
      When call check
      The output should equal "rc=0
0"
    End

    It 'does not re-send an unchanged report'
      meta "Remux"
      check() {
        follow_bg j1
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        sleep 0.5
        result Killed 137
        follow_wait || return 1
        reports | wc -l | tr -d ' '
      }
      When call check
      The output should equal "rc=0
1"
    End

    It 'leaves no log follower behind'
      meta "Remux"
      check() {
        export JOB_FAKE_FOLLOW_PIDFILE="$JOB_SANDBOX/follow.pid"
        follow_bg j1
        wait_for "$JOB_FAKE_FOLLOW_PIDFILE" || { echo no-child; return 1; }
        result Success 0
        follow_wait || return 1
        kill -0 "$(cat "$JOB_FAKE_FOLLOW_PIDFILE")" 2>/dev/null && echo child-alive || echo child-gone
      }
      When call check
      The output should equal "rc=0
child-gone"
    End

    It 'passes --inline through the front-end and ends without waiting'
      meta "Remux"; result Success 0
      check() {
        follow_bg --inline j1
        follow_wait || return 1
        grep -c 'press any key' "$JOB_SANDBOX/out" || :
      }
      When call check
      The output should equal "rc=0
0"
    End

    It 'cancels the job when its tab is closed'
      meta "Remux"
      check() {
        export JOB_FAKE_REX_RC=3 JOB_FAKE_FOLLOW_PIDFILE="$JOB_SANDBOX/follow.pid"
        follow_bg j1
        wait_for "$JOB_FAKE_FOLLOW_PIDFILE" || { echo no-child; return 1; }
        kill -HUP "$FPID"
        follow_wait
        decided || return 1
        grep -c '^kill 7$' "$JOB_FAKE_LOG" || :
        kill -0 "$(cat "$JOB_FAKE_FOLLOW_PIDFILE")" 2>/dev/null && echo child-alive || echo child-gone
        [ -e "$JOB_STATE_ROOT/j1/follower" ] && echo follower-left || echo follower-gone
      }
      When call check
      The output should equal "rc=129
1
child-gone
follower-gone"
    End

    It 'keeps the job when the server restarts'
      meta "Remux"
      check() {
        export JOB_FAKE_REX_RC=4
        follow_bg j1
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        kill -HUP "$FPID"
        follow_wait
        decided || return 1
        kills
        cat "$JOB_FAKE_REX_LOG"
      }
      When call check
      The output should equal "rc=129
0
--autostart=false --timeout 3s whoami --json
--autostart=false --timeout 3s block inspect blk-1"
    End

    It 'keeps the job when the tab is gone from a server that restarted'
      meta "Remux"
      check() {
        export JOB_FAKE_REX_RC=3 JOB_FAKE_REX_INSTANCE_FILE="$JOB_SANDBOX/instance"
        echo srv-1 > "$JOB_FAKE_REX_INSTANCE_FILE"
        follow_bg j1
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        sleep 0.3
        echo srv-2 > "$JOB_FAKE_REX_INSTANCE_FILE"
        kill -HUP "$FPID"
        follow_wait
        decided || return 1
        kills
      }
      When call check
      The output should equal "rc=129
0"
    End

    It 'stays on failure until the tab is closed, then marks it dismissed'
      meta "Remux"; result Failed 2
      check() {
        export JOB_FAKE_REX_RC=3
        follow_bg j1
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        sleep 0.5
        kill -0 "$FPID" 2>/dev/null && echo staying || echo gone-early
        kill -HUP "$FPID"
        follow_wait
        decided || return 1
        kills
        [ -e "$JOB_STATE_ROOT/j1/dismissed" ] && echo dismissed || echo kept
        reports | grep -c "^state=error:" || :
      }
      When call check
      The output should equal "staying
rc=129
0
dismissed
1"
    End

    # Rex sends a closed tab's processes SIGHUP, then kills them about a
    # second later: the decision must outlive the follower and its group.
    # The follower runs in a process group of its own here, as in a tab.
    It 'cancels the job even when the tab is killed during the hangup wait'
      meta "Remux"
      check() {
        export JOB_FAKE_REX_RC=3 JOB_FOLLOW_HUP_WAIT=1
        JOB_FOLLOW_POLL=0.1 REX_BLOCK=blk-1 \
          perl -e 'setpgrp(0, 0); exec @ARGV or die' -- zsh -f "$JOBBIN" follow j1 \
          > "$JOB_SANDBOX/out" 2> "$JOB_SANDBOX/err" < /dev/null &
        FPID=$!
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        kill -HUP "$FPID"
        sleep 0.3
        kill -9 -- "-$FPID" 2>/dev/null
        kill -9 "$FPID" 2>/dev/null
        wait "$FPID" 2>/dev/null
        pueue_logged '^kill 7$' && echo cancelled || echo kept
        decided || return 1
      }
      When call check
      The output should equal "cancelled"
    End

    It 'exits at once on hangup while the decision is still running'
      meta "Remux"
      check() {
        local t0
        zmodload zsh/datetime
        export JOB_FAKE_REX_RC=3 JOB_FOLLOW_HUP_WAIT=2
        follow_bg j1
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        t0=$EPOCHREALTIME
        kill -HUP "$FPID"
        while kill -0 "$FPID" 2>/dev/null && (( EPOCHREALTIME - t0 < 3 )); do
          sleep 0.05
        done
        (( EPOCHREALTIME - t0 < 0.5 )) && echo prompt || echo slow
        wait "$FPID" 2>/dev/null
        kills
        decided || return 1
        kills
      }
      When call check
      The output should equal "prompt
0
1"
    End

    # A $(…) in the follower's loop is a subshell with the same traps, in
    # the same process group: the tab's hangup reaches it too. The slow
    # status keeps one in flight.
    It 'decides a hangup once when a subshell of the follower is hung up too'
      meta "Remux"
      check() {
        export JOB_FAKE_REX_RC=3 JOB_FAKE_STATUS_DELAY=1
        export JOB_FAKE_FOLLOW_PIDFILE="$JOB_SANDBOX/follow.pid"
        JOB_FOLLOW_POLL=0.1 REX_BLOCK=blk-1 \
          perl -e 'setpgrp(0, 0); exec @ARGV or die' -- zsh -f "$JOBBIN" follow j1 \
          > "$JOB_SANDBOX/out" 2> "$JOB_SANDBOX/err" < /dev/null &
        FPID=$!
        wait_for "$JOB_FAKE_FOLLOW_PIDFILE" || { echo no-child; return 1; }
        sleep 0.3
        kill -HUP -- "-$FPID"
        wait "$FPID" 2>/dev/null
        decided || return 1
        sleep 0.5
        grep -c ': deciding$' "$XDG_CACHE_HOME/jobs/rex.log"
      }
      When call check
      The output should equal 1
    End

    # The whoami can take its whole 3 s timeout.
    It 'sends the first report before asking the server who it is'
      meta "Remux"
      check() {
        export JOB_FAKE_REX_OUT="$JOB_SANDBOX/out"
        follow_bg j1
        wait_for "$JOB_SANDBOX/out.at-whoami" || echo no-whoami
        cat "$JOB_SANDBOX/out.at-whoami" 2>/dev/null
        result Success 0
        follow_wait
      }
      When call check
      The output should equal "reported
rc=0"
    End

    # `read` drops a leading space: an empty block would make the pid read
    # as the block, and the follower look dead.
    It 'records - as its block when it is not in a Rex pane'
      meta "Remux"
      check() {
        local block pid
        JOB_FOLLOW_POLL=0.1 JOB_FOLLOW_DONE_TTL=0 zsh -f "$JOBBIN" follow j1 \
          > "$JOB_SANDBOX/out" 2> "$JOB_SANDBOX/err" < /dev/null &
        FPID=$!
        wait_for "$JOB_STATE_ROOT/j1/follower" || echo no-follower
        read -r block pid < "$JOB_STATE_ROOT/j1/follower"
        echo "block=$block"
        [ "$pid" = "$FPID" ] && echo own-pid || echo "pid=$pid"
        result Success 0
        follow_wait
      }
      When call check
      The output should equal "block=-
own-pid
rc=0"
    End

    It 'exits quietly when the state dir of a failed job disappears'
      meta "Remux"; result Failed 2
      check() {
        follow_bg j1
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        sleep 0.3
        rm -rf "$JOB_STATE_ROOT/j1"
        follow_wait || return 1
        cat "$JOB_SANDBOX/err"
        kills
      }
      When call check
      The output should equal "rc=0
0"
    End

    It 'detaches an inline follower on Ctrl+C into a tab of its own'
      meta "Remux"
      # A `&` child starts with SIGINT ignored, and a shell cannot trap a
      # signal ignored on entry; a real inline follower runs in the
      # foreground, so restore the default before the follower starts.
      check() {
        JOB_FOLLOW_POLL=0.1 REX_BLOCK=blk-1 \
          perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die' -- zsh -f -c '
          source "$1" >/dev/null 2>&1 || exit 99; shift
          job::_rex_open_tab() { print -r -- "$1" >> "$JOB_FAKE_OPEN_LOG"; }
          "$@"' -- "$JOBLIB" job::follow --inline j1 \
          > "$JOB_SANDBOX/out" 2> "$JOB_SANDBOX/err" < /dev/null &
        FPID=$!
        wait_for "$JOB_STATE_ROOT/j1/follower" || { echo no-follower; return 1; }
        kill -INT "$FPID"
        follow_wait
        kills
        cat "$JOB_FAKE_OPEN_LOG"
        [ -e "$JOB_STATE_ROOT/j1/follower" ] && echo follower-left || echo follower-gone
      }
      When call check
      The output should equal "rc=0
0
j1
follower-gone"
    End

    # One follower per job: a second one waits up to 3 s for a live one to
    # go (an inline follower handing off exits promptly), else leaves it be.
    It 'leaves a live follower in place and exits'
      meta "Remux"
      check() {
        echo "blk-0 $$" > "$JOB_STATE_ROOT/j1/follower"
        follow_bg j1
        follow_wait || return 1
        cat "$JOB_STATE_ROOT/j1/follower"
        grep -c 'already being followed' "$JOB_SANDBOX/out" || :
        grep -c '^follow ' "$JOB_FAKE_LOG" || :
      }
      When call check
      The output should equal "rc=0
blk-0 $$
1
0"
    End

    It 'does not cancel on hangup while a live follower holds the job'
      meta "Remux"
      check() {
        export JOB_FAKE_REX_RC=3
        echo "blk-0 $$" > "$JOB_STATE_ROOT/j1/follower"
        follow_bg j1
        sleep 0.5
        kill -HUP "$FPID"
        # No trap yet: the default hangup ends it (its status depends on
        # what zsh was doing).
        follow_wait > /dev/null || return 1
        kills
        cat "$JOB_STATE_ROOT/j1/follower"
      }
      When call check
      The output should equal "0
blk-0 $$"
    End

    It 'takes over from a follower that exits within the wait'
      meta "Remux"
      check() {
        local holder i=0
        # Orphaned at once, so it is reaped (not a zombie) when it exits.
        holder=$(sh -c 'sleep 1 >/dev/null 2>&1 & echo $!')
        echo "blk-0 $holder" > "$JOB_STATE_ROOT/j1/follower"
        follow_bg j1
        until [ "$(cat "$JOB_STATE_ROOT/j1/follower" 2>/dev/null)" = "blk-1 $FPID" ]; do
          i=$((i + 1)); [ "$i" -gt 50 ] && { echo no-takeover; break; }
          sleep 0.1
        done
        result Success 0
        follow_wait || return 1
        grep -c 'already being followed' "$JOB_SANDBOX/out" || :
        reports | grep -c '^state=done:' || :
      }
      When call check
      The output should equal "rc=0
0
1"
    End

    # In a ( … ) subshell zsh's $$ is the parent shell's pid: a follower
    # file naming it would look live for as long as that shell lives.
    It 'records its own pid, not the calling shell'"'"'s, when inline'
      meta "Remux"
      check() {
        JOB_FOLLOW_POLL=0.1 REX_BLOCK=blk-1 zsh -f -c '
          source "$1" >/dev/null 2>&1 || exit 99
          job::_rex_open_tab() { :; }
          ( job::follow --inline j1 ) > /dev/null &
          i=0
          until [ -s "$JOB_STATE_ROOT/j1/follower" ]; do
            (( ++i > 50 )) && { echo no-follower; exit 1; }
            sleep 0.1
          done
          read -r block pid < "$JOB_STATE_ROOT/j1/follower"
          [ "$pid" != "$$" ] && echo not-caller || echo caller
          echo "1700000000 Success 0" > "$JOB_STATE_ROOT/j1/result"
          wait
          kill -0 "$pid" 2>/dev/null && echo alive || echo gone
        ' -- "$JOBLIB"
      }
      When call check
      The output should equal "not-caller
gone"
    End

    It 'asks for a key after success'
      meta "Remux"; result Success 0
      check() {
        follow_bg j1
        follow_wait || return 1
        grep -c 'done — press any key to close' "$JOB_SANDBOX/out"
      }
      When call check
      The output should equal "rc=0
1"
    End
  End

  # The verb a follower's SIGHUP handler starts detached: the same decision
  # (job::_follow_on_hup), run where the tab's death cannot reach it.
  Describe 'job hup-decide'
    JOBBIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_job"
    decide() { REX_BLOCK=blk-1 zsh -f "$JOBBIN" hup-decide j1 0 srv-1; }
    rexlog() { sed 's/^[^ ]* //' "$XDG_CACHE_HOME/jobs/rex.log" 2>/dev/null; }

    It 'cancels when the tab is gone, logging that it started'
      meta "Remux"
      check() {
        JOB_FAKE_REX_RC=3 decide
        echo "rc=$? kills=$(kills)"
        rexlog
      }
      When call check
      The output should equal "rc=0 kills=1
job j1: hangup of blk-1: deciding
job j1: hangup of blk-1: inspect rc=3, instance same: cancelled"
    End

    It 'does not cancel a block reconcile is closing'
      meta "Remux"
      check() {
        echo "$(date +%s) blk-1" > "$JOB_STATE_ROOT/.rex_closing"
        JOB_FAKE_REX_RC=3 decide
        echo "rc=$? kills=$(kills)"
        rexlog
      }
      When call check
      The output should equal "rc=0 kills=0
job j1: hangup of blk-1: deciding
job j1: hangup of blk-1: closed by reconcile: nothing"
    End

    # An override the follower's shell did not export (an inline follower
    # in a shell that set it by hand) must still reach the decision, which
    # is another process. XDG_STATE_HOME: where the decision would look
    # without it — never the real state root.
    It 'gets the follower'"'"'s state root when that is not exported'
      check() {
        local alt="$JOB_SANDBOX/alt"
        mkdir -p "$alt/j1"
        printf '{"title":"Remux","notify":"all","pueue_id":7}\n' > "$alt/j1/meta.json"
        JOB_FAKE_REX_RC=3 REX_BLOCK=blk-1 XDG_STATE_HOME="$JOB_SANDBOX/xdg" zsh -f -c '
          source "$1" >/dev/null 2>&1 || exit 99
          typeset +x JOB_STATE_ROOT
          JOB_STATE_ROOT="$2"
          job::_follow_hup_detach j1 0 srv-1' -- "$JOBLIB" "$alt"
        local i=0
        until grep -q ': hangup of blk-1: inspect' "$XDG_CACHE_HOME/jobs/rex.log" 2>/dev/null; do
          i=$((i + 1)); [ "$i" -gt 30 ] && { echo undecided; return 0; }
          sleep 0.1
        done
        echo "kills=$(kills)"
      }
      When call check
      The output should equal "kills=1"
    End

    # A process-group leader cannot setsid; with job control on, a
    # background child is one. The stand-in CLI records its own ps state,
    # where a lowercase s marks a session leader.
    It 'runs in a session of its own even when started as a group leader'
      check() {
        printf '#!/bin/sh\nps -o stat= -p $$ > "%s"\n' "$JOB_SANDBOX/stat" > "$JOB_SANDBOX/cli"
        chmod +x "$JOB_SANDBOX/cli"
        JOB_CLI="$JOB_SANDBOX/cli" with_tty zsh -f -c '
          setopt monitor
          source "$1" >/dev/null 2>&1 || exit 99
          job::_follow_hup_detach j1 0 srv-1
          sleep 0.5' -- "$JOBLIB" > /dev/null 2>&1 < /dev/null
        case "$(cat "$JOB_SANDBOX/stat" 2>/dev/null)" in
          *s*) echo session-leader ;;
          *) echo "stat=$(cat "$JOB_SANDBOX/stat" 2>/dev/null)" ;;
        esac
      }
      When call check
      The output should equal session-leader
    End

    It 'exports JOB_CLI as its own path when unset'
      meta "Remux"
      check() {
        unset JOB_CLI
        decide
        cat "$JOB_FAKE_REX_CLI_SEEN"
      }
      When call check
      The output should equal "${JOBBIN:A}"
    End

    It 'leaves a preset JOB_CLI alone'
      meta "Remux"
      check() {
        JOB_CLI=/preset/job decide
        cat "$JOB_FAKE_REX_CLI_SEEN"
      }
      When call check
      The output should equal "/preset/job"
    End
  End
End
