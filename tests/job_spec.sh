# job.zsh — submission, the sidecar progress protocol, cancel, and the
# troupe-dashboard driver (spec §6 revision: persistent dialog), against a
# recording fake pueue (JOB_PUEUE_BIN), a fake troupe (JOB_TROUPE_BIN), and
# the existing fake mux-modal/tmux seams. Hermetic: JOB_STATE_ROOT lives in
# a sandbox and no real daemon, troupe binary, or mux backend is ever
# consulted.
Describe 'job.zsh'
  JOBLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/job.zsh"

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY NOTIFY_VIA_BRIDGE
    JOB_SANDBOX=$(mktemp -d)
    export JOB_STATE_ROOT="$JOB_SANDBOX/state"
    export JOB_FAKE_LOG="$JOB_SANDBOX/pueue.log"
    cat > "$JOB_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
[ -n "${JOB_FAKE_RC:-}" ] && exit "$JOB_FAKE_RC"
case "$1" in
  add) echo "7" ;;
  status) cat "${JOB_FAKE_STATUS:-/dev/null}" 2>/dev/null || :; [ -n "${JOB_FAKE_STATUS:-}" ] || echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$JOB_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$JOB_SANDBOX/pueue"

    # FAKE troupe (troupe-design.md §6's `troupe jobs`): records argv, then
    # emits either the next queued action popped off a rotating actions file
    # (JOB_FAKE_TROUPE_ACTIONS — one action per line, a scenario's whole
    # popup sequence) or a single JOB_FAKE_TROUPE_ACTION; ALWAYS exits 0 —
    # the widget's own contract, dismissed/cancel/logs/empty are all reached
    # via stdout, never a nonzero rc. A `--measure` call is answered
    # separately (a plain height number, JOB_FAKE_TROUPE_MEASURE) and never
    # touches the actions queue — real troupe's --measure is its own code
    # path, not "another dashboard launch", and job::_dashboard_float issues
    # one per float on top of the real launch.
    export JOB_FAKE_TROUPE_LOG="$JOB_SANDBOX/troupe.log"
    cat > "$JOB_SANDBOX/troupe" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_TROUPE_LOG"
case " $* " in
  *' --measure '*)
    printf '%s' "${JOB_FAKE_TROUPE_MEASURE:-15}"
    exit 0
    ;;
  *' --follow '*)
    # Pane host (job-runner design §6 rev 4): --follow streams every queued
    # line (each its own "verb\tid" line, unlike the one-shot actions file
    # this same fake pops ONE-per-relaunch below) and then exits — real
    # troupe would exit only on ESC/q, but the pane host has no relaunch
    # loop to feed a second time anyway, so "print everything queued, then
    # exit" IS the whole streamed run for a test scenario.
    if [ -n "${JOB_FAKE_TROUPE_FOLLOW_ACTIONS:-}" ] && [ -s "$JOB_FAKE_TROUPE_FOLLOW_ACTIONS" ]; then
      cat "$JOB_FAKE_TROUPE_FOLLOW_ACTIONS"
    fi
    exit 0
    ;;
esac
if [ -n "${JOB_FAKE_TROUPE_ACTIONS:-}" ] && [ -s "$JOB_FAKE_TROUPE_ACTIONS" ]; then
  line=$(head -n1 "$JOB_FAKE_TROUPE_ACTIONS")
  tail -n +2 "$JOB_FAKE_TROUPE_ACTIONS" > "$JOB_FAKE_TROUPE_ACTIONS.next"
  mv "$JOB_FAKE_TROUPE_ACTIONS.next" "$JOB_FAKE_TROUPE_ACTIONS"
  printf '%s' "$line"
else
  printf '%s' "${JOB_FAKE_TROUPE_ACTION:-}"
fi
exit 0
EOF
    chmod +x "$JOB_SANDBOX/troupe"
    export JOB_TROUPE_BIN="$JOB_SANDBOX/troupe"

    # FAKE mux-modal: records argv, then behaves like tmux-modal's own
    # --capture mode — runs the trailing command and writes its stdout to
    # the --capture path — so the SAME fake troupe above is exercised
    # uniformly whether job::watch floats it or runs it inline.
    export JOB_FAKE_MODAL_LOG="$JOB_SANDBOX/modal.log"
    cat > "$JOB_SANDBOX/modal" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_MODAL_LOG"
capture=""
while [ $# -gt 0 ]; do
  case "$1" in
    --capture) capture="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
out=$("$@")
[ -n "$capture" ] && printf '%s' "$out" > "$capture"
exit 0
EOF
    chmod +x "$JOB_SANDBOX/modal"
    export JOB_MUX_MODAL_BIN="$JOB_SANDBOX/modal"

    # FAKE tab-SPAWN seam (job::_open_log_tab's JOB_MUX_NEW_TAB_BIN — one
    # level lower than the whole function): records argv, then BACKGROUNDS
    # the wrapped command exactly like the real mux::new_tab/tmux
    # new-window does (the spawn call returns at once; the spawned command
    # keeps running independently) and records its PID, so a test can kill
    # that process later to simulate the tab closing — the driver's own
    # FIFO-wait code in job::_open_log_tab genuinely runs and genuinely
    # unblocks, instead of the whole function being bypassed.
    export JOB_FAKE_NEWTAB_LOG="$JOB_SANDBOX/newtab.log"
    export JOB_FAKE_NEWTAB_PID="$JOB_SANDBOX/newtab.pid"
    cat > "$JOB_SANDBOX/newtab" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_NEWTAB_LOG"
rm -f "$JOB_FAKE_NEWTAB_PID"
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    *) shift ;;
  esac
done
"$@" &
echo "$!" > "$JOB_FAKE_NEWTAB_PID"
exit 0
EOF
    chmod +x "$JOB_SANDBOX/newtab"
    export JOB_MUX_NEW_TAB_BIN="$JOB_SANDBOX/newtab"
    export JOB_PUEUE_LOG_DIR="$JOB_SANDBOX/pueue-logs"

    # FAKE pane-SPAWN seam (job::_watch_pane's JOB_MUX_FLOAT_PANE_BIN — one
    # level lower than the whole function, same shape as JOB_MUX_NEW_TAB_BIN
    # above): records argv, BACKGROUNDS the wrapped command exactly like the
    # real mux::float_pane/tmux new-pane does (the spawn call returns at
    # once; the spawned command — the fake troupe --follow above, streaming
    # into job::_watch_pane's own FIFO — keeps running independently), and
    # prints a fake pane id so the driver's re-summon state file gets a
    # real value to record.
    export JOB_FAKE_FLOATPANE_LOG="$JOB_SANDBOX/floatpane.log"
    export JOB_FAKE_FLOATPANE_PID="$JOB_SANDBOX/floatpane.pid"
    cat > "$JOB_SANDBOX/floatpane" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_FLOATPANE_LOG"
rm -f "$JOB_FAKE_FLOATPANE_PID"
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    *) shift ;;
  esac
done
# Unlike the newtab fake above (called for its exit status only, never
# through a `$(...)`), job::_float_pane's caller captures THIS script's
# stdout to get the pane id back — and a plain `"$@" &` leaves the
# backgrounded grandchild holding the SAME stdout pipe (inherited, unless
# detached), so the outer `$(...)` blocks past this script's own exit,
# waiting for that orphan to close it too — real tmux `new-pane` never hits
# this (the pane's process lives under the SERVER, not this CLIENT), so
# only the fake needs the explicit detach.
"$@" </dev/null >/dev/null 2>&1 &
echo "$!" > "$JOB_FAKE_FLOATPANE_PID"
printf '%s' "${JOB_FAKE_FLOATPANE_ID:-%9}"
exit 0
EOF
    chmod +x "$JOB_SANDBOX/floatpane"
    export JOB_MUX_FLOAT_PANE_BIN="$JOB_SANDBOX/floatpane"

    # FAKE focus-pane seam (job::_focus_pane_if_alive's
    # JOB_MUX_FOCUS_PANE_BIN): records argv, exits per JOB_FAKE_FOCUS_RC
    # (0 = "found it, focused" — the re-summon path; nonzero = "gone" — the
    # driver launches fresh).
    export JOB_FAKE_FOCUS_LOG="$JOB_SANDBOX/focus.log"
    cat > "$JOB_SANDBOX/focuspane" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_FOCUS_LOG"
exit "${JOB_FAKE_FOCUS_RC:-1}"
EOF
    chmod +x "$JOB_SANDBOX/focuspane"
    export JOB_MUX_FOCUS_PANE_BIN="$JOB_SANDBOX/focuspane"

    # FAKE ai-playbook: the house confirm's inline widget backend
    # (input-common's documented seam), used by job::_watch_confirm_cancel
    # (mux.zsh degrades to it whenever no float backend is active).
    export JOB_FAKE_CONFIRM_LOG="$JOB_SANDBOX/confirm.log"
    cat > "$JOB_SANDBOX/ai-playbook" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_CONFIRM_LOG"
exit "${JOB_FAKE_CONFIRM_RC:-1}"
EOF
    chmod +x "$JOB_SANDBOX/ai-playbook"
    export AI_PLAYBOOK_INPUT_BIN="$JOB_SANDBOX/ai-playbook"
  }
  cleanup() { rm -rf "$JOB_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # -f: this repo's ~/.zshenv would re-export XDG vars over the sandbox.
  run_job() {
    zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99; shift; "$@"' \
      -- "$JOBLIB" "$@"
  }

  Describe 'job::start'
    It 'prints an id, writes meta.json, and enqueues a labeled quoted command'
      started() {
        id=$(run_job job::start --group heavy --title "Build X" \
          --icon "glyph:nf-md-wrench" -- echo "a b") || return 1
        dir="$JOB_STATE_ROOT/$id"
        [ -f "$dir/meta.json" ] || return 2
        # The enqueued command line must carry JOB_ID=<the id THIS run
        # produced> — checked and folded into a stable yes/no here rather
        # than re-deriving the id from $(ls "$JOB_STATE_ROOT") at assertion
        # time, which is fragile (ordering/timing) once more than one job
        # dir could ever exist.
        local job_id_match="no"
        grep -q "JOB_ID=$id" "$JOB_FAKE_LOG" && job_id_match="yes"
        printf '%s|%s|%s|%s|%s' \
          "$(jq -r .title "$dir/meta.json")" \
          "$(jq -r .pueue_id "$dir/meta.json")" \
          "$(jq -r .progress "$dir/meta.json")" \
          "$(grep -c "add --group heavy --label job:$id" "$JOB_FAKE_LOG" | tr -d '\n')" \
          "$job_id_match"
      }
      When call started
      The output should equal 'Build X|7|expected|1|yes'
    End

    It 'defaults the title to the command and the group to default'
      titled() {
        id=$(run_job job::start -- sleep 5) || return 1
        printf '%s|%s' \
          "$(jq -r .title "$JOB_STATE_ROOT/$id/meta.json")" \
          "$(jq -r .group "$JOB_STATE_ROOT/$id/meta.json")"
      }
      When call titled
      The output should equal 'sleep|default'
    End

    It 'creates the heavy group before enqueueing into it'
      grouped() {
        run_job job::start --group heavy -- true >/dev/null || return 1
        # group add first, then the parallelism pin, then the add.
        awk '{print $1, $2}' "$JOB_FAKE_LOG" | paste -sd'|' -
      }
      When call grouped
      The output should equal 'group add|parallel 1|add --group'
    End

    It 'dies loudly naming the service when pueued is unreachable'
      down() { JOB_FAKE_RC=1 run_job job::start -- true; }
      leftover() { ls "$JOB_STATE_ROOT" 2>/dev/null; }
      When call down
      The status should equal 1
      The stderr should include "system-service start pueued"
      # The half-created job dir must not survive a failed submit.
      The result of function leftover should equal ""
    End

    # Regression (Mode B 2026-08-15): <epoch>-<pid> collided when one process
    # started several jobs inside the same second — three heavy jobs shared
    # one state dir and the HUD stacked a single capsule. Ids are µs-based
    # now; two starts from the SAME shell must never collide.
    It 'gives same-process starts distinct ids'
      twice() {
        zsh -f -c 'source "$1" >/dev/null 2>&1 || exit 99
                   a=$(job::start -- true) || exit 98
                   b=$(job::start -- true) || exit 97
                   [ "$a" != "$b" ] && echo distinct' -- "$JOBLIB"
      }
      When call twice
      The output should equal 'distinct'
    End
  End

  Describe 'job::progress'
    It 'atomically rewrites the single-line sidecar'
      prog() {
        id=$(run_job job::start -- true) || return 1
        JOB_ID="$id" run_job job::progress 40 "step two" || return 2
        line="$(cat "$JOB_STATE_ROOT/$id/progress")"
        # <epoch> <pct> <message>
        printf '%s' "$line" | sed 's/^[0-9][0-9]* //'
      }
      When call prog
      The output should equal '40 step two'
    End

    It 'accepts -1 as indeterminate'
      indet() {
        id=$(run_job job::start -- true) || return 1
        JOB_ID="$id" run_job job::progress -1 "preparing" || return 2
        sed 's/^[0-9][0-9]* //' "$JOB_STATE_ROOT/$id/progress"
      }
      When call indet
      The output should equal '-1 preparing'
    End

    It 'returns 1 with no JOB_ID in the environment'
      When call run_job job::progress 10 "orphan"
      The status should equal 1
    End
  End

  Describe 'job::cancel'
    It 'kills the recorded pueue task id'
      cancel() {
        id=$(run_job job::start -- sleep 99) || return 1
        run_job job::cancel "$id" || return 2
        grep -c '^kill 7$' "$JOB_FAKE_LOG"
      }
      When call cancel
      The output should equal '1'
    End
  End

  Describe 'job::list'
    It 'merges meta, sidecar line, done flag, and pueue status'
      listed() {
        id=$(run_job job::start --title "T" -- true) || return 1
        JOB_ID="$id" run_job job::progress 30 "warming" || return 2
        printf '%s\n' '{"tasks":{}}' > "$JOB_SANDBOX/status.json"
        export JOB_FAKE_STATUS="$JOB_SANDBOX/status.json"
        out=$(run_job job::list) || return 3
        printf '%s|%s|%s' \
          "$(printf '%s' "$out" | jq -r '.jobs[0].title')" \
          "$(printf '%s' "$out" | jq -r '.jobs[0].progress_line' | sed 's/^[0-9]* //')" \
          "$(printf '%s' "$out" | jq -r '.jobs[0].done')"
      }
      When call listed
      The output should equal 'T|30 warming|false'
    End

    It 'flags a job with a result file as done'
      done_flag() {
        id=$(run_job job::start -- true) || return 1
        printf '1 Success 0\n' > "$JOB_STATE_ROOT/$id/result"
        run_job job::list | jq -r '.jobs[0].done'
      }
      When call done_flag
      The output should equal 'true'
    End
  End

  Describe 'job::hud'
    It 'sends one require("jobs") call through hs'
      hud() {
        mkdir -p "$JOB_SANDBOX/bin"
        cat > "$JOB_SANDBOX/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$JOB_SANDBOX/hs.log"
EOF
        chmod +x "$JOB_SANDBOX/bin/hs"
        HS="$JOB_SANDBOX/bin/hs" run_job job::hud show || return 1
        cat "$JOB_SANDBOX/hs.log"
      }
      When call hud
      The output should equal '-q -c require("jobs").show()'
    End
  End

  Describe 'libexec/job front-end'
    JOBBIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_job"
    It 'dispatches verbs to the library'
      When call zsh -f "$JOBBIN" start --title "Via CLI" -- true
      The status should equal 0
      The output should match pattern '*-*'
    End
    It 'rejects unknown verbs with usage'
      When call zsh -f "$JOBBIN" frobnicate
      The status should equal 1
      The stderr should include 'usage: job'
    End
    It 'dispatches watch through the front-end (no up-front empty scan — the dashboard launches and owns the empty state)'
      no_jobs_dispatch() {
        export JOB_FAKE_TROUPE_ACTION=""
        zsh -f "$JOBBIN" watch
        rc=$?
        printf 'rc=%s|calls=%s' "$rc" "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")"
      }
      When call no_jobs_dispatch
      The output should equal 'rc=0|calls=1'
    End
  End

  # The troupe-dashboard driver (spec §6 revision: persistent dialog):
  # job::watch floats `troupe jobs` through mux-modal under tmux, or runs it
  # directly outside a mux session, and loops on the widget's one-line
  # action protocol (troupe-design.md §6): empty stdout (ESC/q, dismissed)
  # means done — a literal "empty" line is tolerated the same way, for
  # binary-skew compat with an older troupe that still emits the retired
  # ~1s completed-beat action. "cancel <id>" routes through the house
  # confirm and job::cancel, then ALWAYS relaunches (even as the last live
  # job — the dashboard just renders its own empty state); "logs <id>"
  # opens a tab tailing the task's pueue log and relaunches once that tab
  # closes.
  Describe 'job::watch — the troupe dashboard driver'
    It 'floats troupe through mux-modal under tmux — single chrome, sized+themed — and stops on a dismissed (blank) action'
      float_dismiss() {
        id=$(run_job job::start -- sleep 9) || return 1
        export JOB_FAKE_TROUPE_ACTION=""
        # Pinned to the popup path (job-runner design §6 rev 4 added a real
        # pane-host probe ahead of this loop — JOB_FORCE_HOST=popup skips it
        # outright, so this example stays exactly what it always was
        # regardless of what this box's real tmux happens to support).
        JOB_FORCE_HOST=popup TMUX="fake/sock,1,0" run_job job::watch 2>"$JOB_SANDBOX/watch.err"
        rc=$?
        # Single chrome: troupe draws its OWN framed "Task runner" box
        # (troupe-design.md §6), so mux-modal gets --borderless --no-chrome
        # and NO --title (a second frame would double it — Mode B regression
        # on the ask/dialog floats). Sized from troupe's own --measure (fake
        # default 15) with NO padding — interior == outer with -B +
        # --no-chrome (no border of any kind consumes cells), so padding
        # would hand troupe a pty larger than its self-drawn box, a visible
        # gap band; --width 57 also rides the REAL launch (not just
        # --measure) so the measured height and the actual render agree.
        # Themed: theme::args flags ride the troupe command line (env cannot
        # cross the popup — display-popup runs from the SERVER's
        # environment). The real launch also carries --launched-height, set
        # to the SAME measured value the popup was actually sized to (the
        # resize wire's whole premise: troupe can only detect drift against
        # the height it was launched at) — no --select on this first launch
        # (no prior selection to carry forward).
        local geom="no" themed="no" no_title="yes"
        grep -qF -- "--borderless --no-chrome --width 57 --height 15 --capture" "$JOB_FAKE_MODAL_LOG" \
          && geom="yes"
        grep -qF -- "jobs --state-root $JOB_STATE_ROOT --width 57 --launched-height 15 --theme-accent" "$JOB_FAKE_MODAL_LOG" \
          && themed="yes"
        grep -q -- '--title' "$JOB_FAKE_MODAL_LOG" && no_title="no"
        printf 'rc=%s|geom=%s|themed=%s|no_title=%s|calls=%s|kills=%s' "$rc" "$geom" "$themed" "$no_title" \
          "$(grep -c "jobs --state-root $JOB_STATE_ROOT" "$JOB_FAKE_TROUPE_LOG")" \
          "$(grep -c '^kill' "$JOB_FAKE_LOG")"
      }
      When call float_dismiss
      The output should equal 'rc=0|geom=yes|themed=yes|no_title=yes|calls=1|kills=0'
    End

    It 'runs troupe directly outside tmux — themed — and stops on a dismissed (blank) action'
      inline_dismiss() {
        id=$(run_job job::start -- sleep 9) || return 1
        export JOB_FAKE_TROUPE_ACTION=""
        run_job job::watch 2>"$JOB_SANDBOX/watch.err"
        rc=$?
        local themed="no"
        grep -qF -- "jobs --state-root $JOB_STATE_ROOT --theme-accent" "$JOB_FAKE_TROUPE_LOG" \
          && themed="yes"
        printf 'rc=%s|themed=%s|calls=%s|modal_calls=%s' "$rc" "$themed" \
          "$(grep -c "jobs --state-root $JOB_STATE_ROOT" "$JOB_FAKE_TROUPE_LOG")" \
          "$([ -f "$JOB_FAKE_MODAL_LOG" ] && wc -l < "$JOB_FAKE_MODAL_LOG" | tr -d ' ' || echo 0)"
      }
      When call inline_dismiss
      The output should equal 'rc=0|themed=yes|calls=1|modal_calls=0'
    End

    It 'treats a literal "empty" action the same as dismissed — done, one invocation (binary-skew compat with an older troupe)'
      literal_empty() {
        id=$(run_job job::start -- true) || return 1
        export JOB_FAKE_TROUPE_ACTION="empty"
        run_job job::watch
        rc=$?
        printf 'rc=%s|calls=%s' "$rc" "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")"
      }
      When call literal_empty
      The output should equal 'rc=0|calls=1'
    End

    It 'cancel action: Keep running declines the confirm — no kill, relaunches (two invocations)'
      keep_running() {
        id=$(run_job job::start --title "C" -- sleep 9) || return 1
        printf 'cancel\t%s\n\n' "$id" > "$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_TROUPE_ACTIONS="$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_CONFIRM_RC=1
        run_job job::watch
        rc=$?
        printf 'rc=%s|kills=%s|calls=%s' "$rc" \
          "$(grep -c '^kill' "$JOB_FAKE_LOG")" \
          "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")"
      }
      When call keep_running
      The output should equal 'rc=0|kills=0|calls=2'
    End

    It 'cancel action: confirmed with another job live — kills once and relaunches (two invocations)'
      cancel_other_live() {
        id=$(run_job job::start --title "C" -- sleep 9) || return 1
        id2=$(run_job job::start --title "Other" -- sleep 9) || return 2
        printf 'cancel\t%s\n\n' "$id" > "$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_TROUPE_ACTIONS="$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_CONFIRM_RC=0
        run_job job::watch
        rc=$?
        printf 'rc=%s|kills=%s|calls=%s' "$rc" \
          "$(grep -c '^kill 7$' "$JOB_FAKE_LOG")" \
          "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")"
      }
      When call cancel_other_live
      The output should equal 'rc=0|kills=1|calls=2'
    End

    It 'cancel action: confirmed as the LAST live job — kills once and STILL relaunches (two invocations; the dashboard shows its own empty state instead of auto-closing)'
      cancel_last_job() {
        id=$(run_job job::start --title "C" -- sleep 9) || return 1
        printf 'cancel\t%s\n\n' "$id" > "$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_TROUPE_ACTIONS="$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_CONFIRM_RC=0
        run_job job::watch
        rc=$?
        printf 'rc=%s|kills=%s|calls=%s' "$rc" \
          "$(grep -c '^kill 7$' "$JOB_FAKE_LOG")" \
          "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")"
      }
      When call cancel_last_job
      The output should equal 'rc=0|kills=1|calls=2'
    End

    # The tab-open seam (JOB_MUX_NEW_TAB_BIN) only stubs the SPAWN step —
    # job::_open_log_tab's real mkfifo/argv-build/bounded-read body runs
    # here, so this exercises the actual choreography, not a bypass: the
    # fake backgrounds the wrapped `exec 3>fifo; exec tail -f logfile`
    # command (real mux::new_tab is fire-and-forget the same way) and a
    # background killer simulates the user closing the tab (Ctrl+C/pane
    # close) once it is actually running — job::_open_log_tab's FIFO wait
    # must genuinely unblock from THAT (fd-close-on-death), not from
    # `tail -f` reaching some EOF of its own, which never happens.
    It 'logs action: opens the resolved pueue log in a mux tab, relaunches once it closes (two invocations)'
      logs_action() {
        id=$(run_job job::start --title "L" -- sleep 9) || return 1
        mkdir -p "$JOB_PUEUE_LOG_DIR"
        : > "$JOB_PUEUE_LOG_DIR/7.log"
        printf 'logs\t%s\n\n' "$id" > "$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_TROUPE_ACTIONS="$JOB_SANDBOX/troupe-actions"
        # Wait past the writer/reader FIFO rendezvous (a bare "PID exists"
        # can fire while the wrapped `exec 3>fifo` is still blocked mid-open
        # — killing THAT early races the open itself, not a live writer) so
        # the kill lands on a genuinely-running tail -f, matching C1's real
        # scenario (a signal hitting an ALREADY-open write end).
        ( while [ ! -s "$JOB_FAKE_NEWTAB_PID" ]; do sleep 0.02; done
          sleep 0.3
          kill -TERM "$(cat "$JOB_FAKE_NEWTAB_PID")" 2>/dev/null ) &
        local killer=$!
        run_job job::watch
        rc=$?
        wait "$killer" 2>/dev/null
        # The wrapped sh -c script's argv is logged VERBATIM (unexpanded —
        # "$1"/"$2" resolve only when sh actually runs it), so "tail -f"
        # appears literally and the resolved log path appears separately as
        # its own trailing positional arg; check both rather than one
        # contiguous string.
        local match="no"
        grep -qF -- 'tail -f "$1"' "$JOB_FAKE_NEWTAB_LOG" \
          && grep -qF -- "$JOB_PUEUE_LOG_DIR/7.log" "$JOB_FAKE_NEWTAB_LOG" \
          && match="yes"
        printf 'rc=%s|match=%s|tabs=%s|calls=%s' "$rc" "$match" \
          "$(wc -l < "$JOB_FAKE_NEWTAB_LOG" | tr -d ' ')" \
          "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")"
      }
      When call logs_action
      The output should equal 'rc=0|match=yes|tabs=1|calls=2'
    End

    # The resize wire (job-runner design §6 rev 2026-08-16 "adopt
    # resize\t<h>"): height now rides the wire FIRST — `resize\t<h>[\t<id>]`
    # — so a resize-triggered relaunch skips the `--measure` round trip
    # entirely and uses the wire's height verbatim; <id> (when present)
    # still rides back through --select so the new instance's cursor starts
    # where the old one left off. The INITIAL launch (before any resize)
    # still measures for real — only the relaunch immediately following a
    # resize action skips it — so exactly ONE --measure call total proves
    # the re-measure round trip was genuinely skipped, not just uncounted.
    It 'resize action: relaunches immediately using the WIRE height (no re-measure), --select forwarded'
      resize_then_dismiss() {
        id=$(run_job job::start --title "R" -- sleep 9) || return 1
        printf 'resize\t20\t%s\n\n' "$id" > "$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_TROUPE_ACTIONS="$JOB_SANDBOX/troupe-actions"
        JOB_FORCE_HOST=popup TMUX="fake/sock,1,0" run_job job::watch
        rc=$?
        local second_select="no" second_height="no"
        # The SECOND real-launch line (skip the first launch) must carry
        # --select <id>; the SECOND modal-launch line's --height must be
        # the WIRE's height (20) — a value the fake --measure call was
        # never even asked to return — proving the relaunch used the wire,
        # not a re-measurement.
        second_select=$(grep -F -- 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG" \
          | sed -n '2p' | grep -qF -- "--select $id" && echo yes || echo no)
        second_height=$(grep -F -- '--capture' "$JOB_FAKE_MODAL_LOG" \
          | sed -n '2p' | grep -qF -- '--height 20' && echo yes || echo no)
        printf 'rc=%s|launches=%s|measures=%s|select=%s|height=%s' "$rc" \
          "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")" \
          "$(grep -c -- '--measure' "$JOB_FAKE_TROUPE_LOG")" \
          "$second_select" "$second_height"
      }
      When call resize_then_dismiss
      The output should equal 'rc=0|launches=2|measures=1|select=yes|height=yes'
    End

    It 'resize action with no selected job: relaunches with a bare resize (no --select), wire height used, no re-measure'
      resize_no_selection() {
        run_job job::start --title "R" -- sleep 9 >/dev/null || return 1
        printf 'resize\t20\n\n' > "$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_TROUPE_ACTIONS="$JOB_SANDBOX/troupe-actions"
        JOB_FORCE_HOST=popup TMUX="fake/sock,1,0" run_job job::watch
        rc=$?
        local second_no_select="no" second_height="no"
        second_no_select=$(grep -F -- 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG" \
          | sed -n '2p' | grep -qF -- '--select' && echo no || echo yes)
        second_height=$(grep -F -- '--capture' "$JOB_FAKE_MODAL_LOG" \
          | sed -n '2p' | grep -qF -- '--height 20' && echo yes || echo no)
        printf 'rc=%s|launches=%s|measures=%s|no_select=%s|height=%s' "$rc" \
          "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")" \
          "$(grep -c -- '--measure' "$JOB_FAKE_TROUPE_LOG")" \
          "$second_no_select" "$second_height"
      }
      When call resize_no_selection
      The output should equal 'rc=0|launches=2|measures=1|no_select=yes|height=yes'
    End

    # >5 consecutive resize actions with no other action in between must
    # bail out rather than spin forever (loop-termination note above
    # job::watch). The fake troupe's actions file rotates one "resize" per
    # popup call, so 6 queued resizes exercise the bailout on the 6th; none
    # of the 6 relaunches re-measures (every one carries a height on the
    # wire), so the measure count stays pinned at the initial launch's 1.
    It 'resize action: bails out past 5 consecutive resizes with no other action (log_error, rc 1), never re-measures'
      resize_bailout() {
        id=$(run_job job::start --title "R" -- sleep 9) || return 1
        local i
        for i in 1 2 3 4 5 6; do
          printf 'resize\t20\t%s\n' "$id"
        done > "$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_TROUPE_ACTIONS="$JOB_SANDBOX/troupe-actions"
        JOB_FORCE_HOST=popup TMUX="fake/sock,1,0" run_job job::watch 2>"$JOB_SANDBOX/watch.err"
        rc=$?
        printf 'rc=%s|launches=%s|measures=%s|err=%s' "$rc" \
          "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")" \
          "$(grep -c -- '--measure' "$JOB_FAKE_TROUPE_LOG")" \
          "$(grep -c 'resize loop bailout' "$JOB_SANDBOX/watch.err")"
      }
      When call resize_bailout
      The output should equal 'rc=1|launches=6|measures=1|err=1'
    End

    # A non-resize action (cancel/logs) between resizes must reset the
    # streak — proven by interleaving one resize, one declined cancel (no
    # kill, just a relaunch), then 6 more resizes: the bailout must still
    # fire (the streak wasn't secretly carried across the cancel), not
    # short-circuit early from the first resize's count alone.
    It 'resize action: a cancel in between resets the consecutive-resize streak'
      resize_streak_resets() {
        id=$(run_job job::start --title "R" -- sleep 9) || return 1
        {
          printf 'resize\t20\t%s\n' "$id"
          printf 'cancel\t%s\n' "$id"
          local i
          for i in 1 2 3 4 5 6; do
            printf 'resize\t20\t%s\n' "$id"
          done
        } > "$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_TROUPE_ACTIONS="$JOB_SANDBOX/troupe-actions"
        export JOB_FAKE_CONFIRM_RC=1
        JOB_FORCE_HOST=popup TMUX="fake/sock,1,0" run_job job::watch 2>"$JOB_SANDBOX/watch.err"
        rc=$?
        # 8 queued actions (1 resize + 1 cancel + 6 resize), each consumed
        # by exactly one launch, bailing out right after the 8th (the
        # streak's 6th CONSECUTIVE resize since the cancel reset it) — no
        # 9th launch ever happens.
        printf 'rc=%s|launches=%s|err=%s' "$rc" \
          "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")" \
          "$(grep -c 'resize loop bailout' "$JOB_SANDBOX/watch.err")"
      }
      When call resize_streak_resets
      The output should equal 'rc=1|launches=8|err=1'
    End

    It 'no live jobs: launches the dashboard anyway (it owns the empty state) — one invocation, dismiss ends rc 0'
      no_jobs() {
        export JOB_FAKE_TROUPE_ACTION=""
        run_job job::watch
        rc=$?
        printf 'rc=%s|calls=%s' "$rc" "$(grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG")"
      }
      When call no_jobs
      The output should equal 'rc=0|calls=1'
    End

    It 'dies naming the install command when troupe is not on PATH'
      missing_troupe() {
        id=$(run_job job::start -- true) || return 1
        # HOME is sandboxed too: job::_troupe now falls back to
        # $HOME/.local/share/go/bin (the tmux-server-PATH fix), so a bare
        # PATH strip would find the real install and never die.
        zsh -f -c '
          PATH="/usr/bin:/bin"
          HOME="$2"
          unset JOB_TROUPE_BIN
          source "$1" >/dev/null 2>&1 || exit 99
          job::watch
        ' -- "$JOBLIB" "$JOB_SANDBOX"
      }
      When call missing_troupe
      The status should equal 1
      The stderr should include 'go install github.com/Townk/troupe/cmd/troupe@latest'
    End
  End

  # job-runner design §6 rev 2026-08-16 ("the floating-pane host"):
  # job::watch hosts the dashboard in a REAL tmux pane instead of a popup
  # when job::_use_pane_host says so — JOB_FORCE_HOST=pane|popup is the
  # test seam (see job::_use_pane_host below), so these examples never
  # depend on what THIS box's real tmux happens to support. The pane never
  # relaunches: troupe streams cancel/logs as line-buffered FIFO lines
  # while it keeps running, and EOF (troupe exits on ESC/q, closing its
  # stdout) is the one and only end condition.
  Describe 'job::_use_pane_host'
    It 'JOB_FORCE_HOST=pane wins outright, even with no TMUX at all'
      selects() { JOB_FORCE_HOST=pane run_job job::_use_pane_host; }
      When call selects
      The status should be success
    End

    It 'JOB_FORCE_HOST=popup always declines, even under TMUX'
      declines_forced() { JOB_FORCE_HOST=popup TMUX="fake/sock,1,0" run_job job::_use_pane_host; }
      When call declines_forced
      The status should be failure
    End

    It 'declines outside TMUX with no force (no session to float a pane in)'
      declines_no_tmux() { run_job job::_use_pane_host; }
      When call declines_no_tmux
      The status should be failure
    End
  End

  Describe 'job::_watch_pane — the pane-host driver body'
    It 'streams cancel (declined) then logs then EOF: one launch, confirm once, tab opened once, no respawn, cleanup'
      choreography() {
        id=$(run_job job::start --title "C" -- sleep 9) || return 1
        lid=$(run_job job::start --title "L" -- sleep 9) || return 2
        mkdir -p "$JOB_PUEUE_LOG_DIR"
        : > "$JOB_PUEUE_LOG_DIR/7.log"
        printf 'cancel\t%s\nlogs\t%s\n' "$id" "$lid" > "$JOB_SANDBOX/follow-actions"
        export JOB_FAKE_TROUPE_FOLLOW_ACTIONS="$JOB_SANDBOX/follow-actions"
        export JOB_FAKE_CONFIRM_RC=1
        # Same rendezvous as the popup path's logs_action example: wait for
        # the tab-open FIFO to be genuinely held open before killing it, not
        # just for the PID file to exist (see that example's own comment).
        ( while [ ! -s "$JOB_FAKE_NEWTAB_PID" ]; do sleep 0.02; done
          sleep 0.3
          kill -TERM "$(cat "$JOB_FAKE_NEWTAB_PID")" 2>/dev/null ) &
        local killer=$!
        JOB_FORCE_HOST=pane run_job job::watch
        rc=$?
        wait "$killer" 2>/dev/null
        local statefile_gone="no"
        [ ! -e "$JOB_STATE_ROOT/.dashboard-pane" ] && statefile_gone="yes"
        printf 'rc=%s|confirms=%s|tabs=%s|launches=%s|statefile_gone=%s' "$rc" \
          "$(wc -l < "$JOB_FAKE_CONFIRM_LOG" | tr -d ' ')" \
          "$(wc -l < "$JOB_FAKE_NEWTAB_LOG" | tr -d ' ')" \
          "$(grep -c -- '--follow' "$JOB_FAKE_FLOATPANE_LOG")" \
          "$statefile_gone"
      }
      When call choreography
      The output should equal 'rc=0|confirms=1|tabs=1|launches=1|statefile_gone=yes'
    End

    It 'a confirmed cancel calls job::cancel — troupe keeps streaming, no relaunch (one launch total)'
      confirmed_cancel() {
        id=$(run_job job::start --title "K" -- sleep 9) || return 1
        printf 'cancel\t%s\n' "$id" > "$JOB_SANDBOX/follow-actions"
        export JOB_FAKE_TROUPE_FOLLOW_ACTIONS="$JOB_SANDBOX/follow-actions"
        export JOB_FAKE_CONFIRM_RC=0
        JOB_FORCE_HOST=pane run_job job::watch
        rc=$?
        printf 'rc=%s|kills=%s|launches=%s' "$rc" \
          "$(grep -c '^kill 7$' "$JOB_FAKE_LOG")" \
          "$(grep -c -- '--follow' "$JOB_FAKE_FLOATPANE_LOG")"
      }
      When call confirmed_cancel
      The output should equal 'rc=0|kills=1|launches=1'
    End

    It 'a live pane on record is focused instead of launching a second dashboard'
      focus_not_respawn() {
        mkdir -p "$JOB_STATE_ROOT"
        printf '%s' '%42' > "$JOB_STATE_ROOT/.dashboard-pane"
        export JOB_FAKE_FOCUS_RC=0
        JOB_FORCE_HOST=pane run_job job::watch
        rc=$?
        printf 'rc=%s|focus=%s|launches=%s' "$rc" \
          "$(tr -d '\n' < "$JOB_FAKE_FOCUS_LOG" 2>/dev/null)" \
          "$([ -f "$JOB_FAKE_FLOATPANE_LOG" ] && wc -l < "$JOB_FAKE_FLOATPANE_LOG" | tr -d ' ' || echo 0)"
      }
      When call focus_not_respawn
      The output should equal 'rc=0|focus=%42|launches=0'
    End

    # The state file is removed on close (EOF), same as job::_open_log_tab's
    # own fifo/sentinel — so "the new id is recorded" can only be observed
    # WHILE the pane is still up, not after job::watch returns. A scripted
    # "logs" action gives a window: job::_open_log_tab blocks inside it
    # (same kill-on-open rendezvous as the logs_action/choreography
    # examples), and a background peek during that window reads the state
    # file before the eventual EOF cleanup removes it.
    It 'a stale pane id on record is cleaned up, a fresh pane launches, and the new id is recorded while it runs'
      stale_pane() {
        mkdir -p "$JOB_STATE_ROOT"
        printf '%s' '%99' > "$JOB_STATE_ROOT/.dashboard-pane"
        export JOB_FAKE_FOCUS_RC=1
        id=$(run_job job::start --title "S" -- sleep 9) || return 1
        mkdir -p "$JOB_PUEUE_LOG_DIR"
        : > "$JOB_PUEUE_LOG_DIR/7.log"
        printf 'logs\t%s\n' "$id" > "$JOB_SANDBOX/follow-actions"
        export JOB_FAKE_TROUPE_FOLLOW_ACTIONS="$JOB_SANDBOX/follow-actions"
        ( while [ ! -s "$JOB_FAKE_NEWTAB_PID" ]; do sleep 0.02; done
          cat "$JOB_STATE_ROOT/.dashboard-pane" > "$JOB_SANDBOX/statefile-midflight" 2>/dev/null
          sleep 0.3
          kill -TERM "$(cat "$JOB_FAKE_NEWTAB_PID")" 2>/dev/null ) &
        local killer=$!
        JOB_FORCE_HOST=pane run_job job::watch
        rc=$?
        wait "$killer" 2>/dev/null
        printf 'rc=%s|launches=%s|midflight=%s|final=%s' "$rc" \
          "$(grep -c -- '--follow' "$JOB_FAKE_FLOATPANE_LOG")" \
          "$(cat "$JOB_SANDBOX/statefile-midflight" 2>/dev/null)" \
          "$([ -e "$JOB_STATE_ROOT/.dashboard-pane" ] && echo present || echo absent)"
      }
      When call stale_pane
      The output should equal 'rc=0|launches=1|midflight=%9|final=absent'
    End

    It 'sizes the float from --measure and wires --follow + TROUPE_RESIZE_CMD (via $TMUX_PANE) into the pane command'
      wiring() {
        run_job job::start --title "W" -- sleep 9 >/dev/null || return 1
        export JOB_FAKE_TROUPE_MEASURE=9
        export JOB_FAKE_TROUPE_FOLLOW_ACTIONS=""
        JOB_FORCE_HOST=pane run_job job::watch >/dev/null
        rc=$?
        local geom="no" resize_cmd="no" follow="no" measure_frameless="no" follow_frameless="no"
        grep -qF -- '57 9 --' "$JOB_FAKE_FLOATPANE_LOG" && geom="yes"
        grep -qF -- 'export TROUPE_RESIZE_CMD="tmux resize-pane -t \"\$TMUX_PANE\" -y %h"' \
          "$JOB_FAKE_FLOATPANE_LOG" && resize_cmd="yes"
        grep -qF -- 'jobs --follow --no-frame --state-root' "$JOB_FAKE_FLOATPANE_LOG" && follow="yes"
        # --no-frame (troupe-design.md §6 rev, frameless pane host) must ride
        # BOTH the --measure sizing call and the real --follow launch, or the
        # measured height and the actually-rendered height disagree (measure
        # parity): the popup path never carries --no-frame (mux-modal's own
        # -B/--no-chrome IS that frame there), only the pane host does.
        grep -qF -- '--measure --no-frame' "$JOB_FAKE_TROUPE_LOG" && measure_frameless="yes"
        grep -qF -- '--follow --no-frame' "$JOB_FAKE_FLOATPANE_LOG" && follow_frameless="yes"
        printf 'rc=%s|geom=%s|resize_cmd=%s|follow=%s|measure_frameless=%s|follow_frameless=%s' \
          "$rc" "$geom" "$resize_cmd" "$follow" "$measure_frameless" "$follow_frameless"
      }
      When call wiring
      The output should equal 'rc=0|geom=yes|resize_cmd=yes|follow=yes|measure_frameless=yes|follow_frameless=yes'
    End

    It 'a failed pane launch is reported and leaves no fifo/state file behind'
      launch_fails() {
        cat > "$JOB_SANDBOX/failpane" <<'INNER'
#!/bin/sh
exit 1
INNER
        chmod +x "$JOB_SANDBOX/failpane"
        # Steer the real mkfifo location into THIS test's own sandbox (same
        # convention as mux_float_launch_spec.sh's leak guard) — the bare
        # system TMPDIR is shared across the whole suite/session, and a
        # leftover from an unrelated run would false-positive the check.
        local fifo_tmp="$JOB_SANDBOX/tmpdir"
        mkdir -p "$fifo_tmp"
        TMPDIR="$fifo_tmp" JOB_MUX_FLOAT_PANE_BIN="$JOB_SANDBOX/failpane" JOB_FORCE_HOST=pane \
          run_job job::watch 2>"$JOB_SANDBOX/pane.err"
        rc=$?
        local leaks="no"
        local -a stray=("$fifo_tmp"/job-pane-fifo.*(N))
        (( ${#stray} )) && leaks="yes"
        printf 'rc=%s|err=%s|leaks=%s|statefile=%s' "$rc" \
          "$(grep -c 'failed to open the floating pane' "$JOB_SANDBOX/pane.err")" \
          "$leaks" \
          "$([ -e "$JOB_STATE_ROOT/.dashboard-pane" ] && echo present || echo absent)"
      }
      When call launch_fails
      The output should equal 'rc=1|err=1|leaks=no|statefile=absent'
    End
  End

  # C1 (Critical, fixed): the tab-open FIFO wait used to deadlock on every
  # realistic tab exit — a bare `tail -f "$1"; printf x >"$2"` never runs
  # its printf when a signal kills the whole `sh -c` first (Ctrl+C, a
  # pane's SIGHUP on close). The fix holds the FIFO's write end open for
  # the wrapped process's whole life (`exec 3>fifo; exec tail -f logfile`)
  # and relies on fd-close-on-death, which the kernel guarantees
  # unconditionally. These two examples call job::_open_log_tab directly
  # (not through the whole job::watch loop) so the regression is pinned
  # tightly: unblocks on a kill, and gives up on a bound when nothing ever
  # spawns.
  Describe 'job::_open_log_tab'
    It 'unblocks the moment the spawned tab process dies from a signal (C1 regression pin)'
      ctrlc_unblocks() {
        : > "$JOB_SANDBOX/ctrlc.log"
        # See the logs_action example: wait past the writer/reader FIFO
        # rendezvous, not just "the PID exists", so the kill lands on a
        # genuinely-open write end (C1's real scenario), not a race against
        # the wrapped command's own still-blocked `exec 3>fifo`.
        ( while [ ! -s "$JOB_FAKE_NEWTAB_PID" ]; do sleep 0.02; done
          sleep 0.3
          kill -TERM "$(cat "$JOB_FAKE_NEWTAB_PID")" 2>/dev/null ) &
        local killer=$!
        run_job job::_open_log_tab "L" "$JOB_SANDBOX/ctrlc.log"
        rc=$?
        wait "$killer" 2>/dev/null
        printf 'rc=%s' "$rc"
      }
      When call ctrlc_unblocks
      The output should equal 'rc=0'
    End

    It 'gives up after the bound instead of hanging forever when nothing ever holds the FIFO open'
      timeout_path() {
        # A spawner that "succeeds" (mux::new_tab-equivalent returns 0) but
        # never actually runs anything holding the FIFO open — a wedged or
        # silently-failed real spawn looks exactly like this from
        # job::_open_log_tab's side. JOB_LOGTAB_TIMEOUT_S keeps the bound
        # short here (real default: 10s) so the regression fails fast
        # instead of hanging the suite if the bound ever regresses away.
        cat > "$JOB_SANDBOX/deadnewtab" <<'EOF'
#!/bin/sh
exit 0
EOF
        chmod +x "$JOB_SANDBOX/deadnewtab"
        JOB_MUX_NEW_TAB_BIN="$JOB_SANDBOX/deadnewtab" JOB_LOGTAB_TIMEOUT_S=1 \
          run_job job::_open_log_tab "L" "$JOB_SANDBOX/never.log" 2>"$JOB_SANDBOX/timeout.err"
        rc=$?
        printf 'rc=%s|%s' "$rc" "$(grep -c 'timed out' "$JOB_SANDBOX/timeout.err")"
      }
      When call timeout_path
      The output should equal 'rc=1|1'
    End
  End

  # mux::confirm is the house dialog layer (ask/ai-playbook floated in a mux
  # popup inside a session, inline input::confirm otherwise). The sandbox
  # here has no TMUX/ZELLIJ (spec_helper.sh unsets both suite-wide), so
  # mux::confirm takes the inline input::confirm path, which shells out to
  # ai-playbook — AI_PLAYBOOK_INPUT_BIN is its documented test seam
  # (input-common.zsh's _input::bin).
  Describe 'job::_watch_confirm_cancel'
    It 'cancels on confirm (rc 0) and asks with the danger-palette flags'
      confirmed() {
        id=$(run_job job::start --title "C" -- sleep 9) || return 1
        JOB_FAKE_CONFIRM_RC=0 run_job job::_watch_confirm_cancel "$id" "C"
        rc=$?
        kills=$(grep -c '^kill 7$' "$JOB_FAKE_LOG")
        printf '%s|%s|%s' "$rc" "$kills" "$(cat "$JOB_FAKE_CONFIRM_LOG")"
      }
      When call confirmed
      The output should include '0|1|'
      The output should include '--type confirm'
      The output should include '--danger'
      The output should include '--affirmative Cancel task'
      The output should include '--negative Keep running'
      The output should include '--title Task runner'
      The output should include '--inset 1'
    End

    It 'declines on rc 1 — no kill, rc 1'
      declined() {
        id=$(run_job job::start --title "C" -- sleep 9) || return 1
        JOB_FAKE_CONFIRM_RC=1 run_job job::_watch_confirm_cancel "$id" "C"
        rc=$?
        kills=$(grep -c '^kill' "$JOB_FAKE_LOG")
        printf '%s|%s' "$rc" "$kills"
      }
      When call declined
      The output should equal '1|0'
    End

    It 'declines on rc 130 (ESC cancel) — no kill, rc 1'
      esc_cancelled() {
        id=$(run_job job::start --title "C" -- sleep 9) || return 1
        JOB_FAKE_CONFIRM_RC=130 run_job job::_watch_confirm_cancel "$id" "C"
        rc=$?
        kills=$(grep -c '^kill' "$JOB_FAKE_LOG")
        printf '%s|%s' "$rc" "$kills"
      }
      When call esc_cancelled
      The output should equal '1|0'
    End

    # I4: job::cancel's own rc must not be swallowed — a confirmed cancel
    # whose `pueue kill` itself fails is NOT a successful cancel (the job
    # genuinely still runs), so the caller must relaunch rather than close
    # the dashboard believing the job is gone. JOB_FAKE_RC is the existing
    # fake-pueue seam (job::start already ran with it unset, so this only
    # fails the one `pueue kill` call job::cancel makes here).
    It 'propagates a failed cancel (pueue kill nonzero) — treated as not-cancelled, rc 1'
      cancel_fails() {
        id=$(run_job job::start --title "C" -- sleep 9) || return 1
        JOB_FAKE_CONFIRM_RC=0 JOB_FAKE_RC=1 \
          run_job job::_watch_confirm_cancel "$id" "C" 2>"$JOB_SANDBOX/cc.err"
        rc=$?
        printf '%s|%s' "$rc" "$(grep -c 'cancel failed' "$JOB_SANDBOX/cc.err")"
      }
      When call cancel_fails
      The output should equal '1|1'
    End

    # Regression: pick-common.zsh (pulled in transitively by mux.zsh) runs
    # `require_cmd fzf` AT SOURCE TIME and dies (exit 1) when fzf is missing
    # from PATH. Sourcing mux.zsh unguarded from job::_watch_confirm_cancel
    # would let that `exit` escape past the function entirely and kill the
    # WHOLE invoking shell (a real Ctrl+C-during-watch, over SSH on a box with
    # no fzf, would take the caller's session down with it). PATH is stripped
    # to a minimal bin dir carrying only `dirname` (the one external command
    # the mux.zsh/pick-common.zsh source chain needs before it reaches the
    # `require_cmd fzf` check) — fzf itself is absent. A sentinel echoed AFTER
    # the call, in the SAME zsh process, is the proof the process survived:
    # a bare `source` escape would take the whole script down before ever
    # reaching it.
    It 'survives a source-time exit from the widget stack when fzf is missing (never crashes the caller)'
      crash_guard() {
        id=$(run_job job::start --title "C" -- sleep 9) || return 1
        mkdir -p "$JOB_SANDBOX/minbin"
        ln -sf "$(command -v dirname)" "$JOB_SANDBOX/minbin/dirname"
        zsh -f -c '
          PATH="$1"; shift
          source "$1" >/dev/null 2>&1 || { print -r -- "JOBLIB-SOURCE-FAILED"; exit 99; }
          shift
          job::_watch_confirm_cancel "$1" "$2"
          print -r -- "SENTINEL:$?"
        ' -- "$JOB_SANDBOX/minbin" "$JOBLIB" "$id" "C"
        printf 'outer_exit=%s\n' "$?"
        printf 'kills=%s\n' "$(grep -c '^kill' "$JOB_FAKE_LOG")"
      }
      When call crash_guard
      The output should include 'SENTINEL:1'
      The output should include 'outer_exit=0'
      The output should include 'kills=0'
    End
  End

  # I5 (promoted): job::start --modal must never attempt to drive the
  # dashboard headless — troupe's own no-tty behavior is untrusted (could
  # error, could hang), and the job is already enqueued regardless, so a
  # headless call used to "die nonzero" from the caller's perspective (a
  # hang reads as a timeout-kill externally) even though the job itself
  # was fine. Every shellspec example runs with no tty on stderr, so THIS
  # is the only automatically-testable shape of `job::start --modal` —
  # driving-when-a-tty-exists has no force seam by design (troupe/the
  # dashboard loop already has full direct coverage via `job::watch`
  # itself in the Describe above; only the modal-chain's headless guard
  # needed pinning here).
  Describe 'job::start --modal (headless)'
    It 'prints exactly the id, skips the dashboard, rc 0 — zero troupe invocations'
      headless() { run_job job::start --modal --title "M" -- sleep 9 </dev/null; }
      calls() { grep -c 'jobs --state-root' "$JOB_FAKE_TROUPE_LOG" 2>/dev/null || echo 0; }
      When call headless
      The status should equal 0
      The output should match pattern '[0-9]*-[0-9]*'
      The stderr should include 'headless: the GUI HUD is the surface'
      The result of function calls should equal '0'
    End
  End

  Describe 'job::log'
    It 'passes through to pueue log for a known id'
      known() {
        id=$(run_job job::start -- true) || return 1
        run_job job::log "$id" >/dev/null
        grep -c '^log 7$' "$JOB_FAKE_LOG"
      }
      When call known
      The output should equal '1'
    End

    It 'rejects an unknown id'
      When call run_job job::log no-such-job
      The status should equal 1
      The stderr should include 'unknown job'
    End
  End
End
