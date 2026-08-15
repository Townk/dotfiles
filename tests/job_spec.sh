# job.zsh — submission, the sidecar progress protocol, and cancel, against a
# recording fake pueue (JOB_PUEUE_BIN seam). Hermetic: JOB_STATE_ROOT lives
# in a sandbox and no real daemon is consulted.
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
  follow) echo "log line one"; printf '%s' "${JOB_FAKE_FOLLOW_TAILFRAG:-}"; : > "${JOB_FAKE_FOLLOW_SENTINEL:-/dev/null}" 2>/dev/null; sleep "${JOB_FAKE_FOLLOW_SLEEP:-3}" ;;
esac
exit 0
EOF
    chmod +x "$JOB_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$JOB_SANDBOX/pueue"
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
  End

  # Phase 2 (spec §6): the modal viewer's pure composition helpers. Pure
  # string functions — no tty, no pueue, no seams needed.
  Describe 'job::watch composition helpers'
    It 'renders a proportional 24-char bar'
      When call run_job job::_watch_bar 50 24
      The output should equal '████████████············'
    End

    It 'clamps a full bar and renders indeterminate as all-empty'
      full_and_indet() {
        printf '%s|%s' \
          "$(run_job job::_watch_bar 100 8)" \
          "$(run_job job::_watch_bar -1 8)"
      }
      When call full_and_indet
      The output should equal '████████|········'
    End

    It 'composes the header from the message when one exists'
      When call run_job job::_watch_header "Build X" "step 3 of 9" 33 41
      The output should equal 'step 3 of 9 [███████·················] 33% 41s — q/ESC detach · ^C cancel'
    End

    It 'falls back to the title and renders --% when indeterminate'
      When call run_job job::_watch_header "Build X" "" -1 5
      The output should equal 'Build X [························] --% 5s — q/ESC detach · ^C cancel'
    End
  End

  Describe 'job::watch'
    It 'streams the log, detaches on q, and leaves the task alone'
      detach() {
        id=$(run_job job::start --title "W" -- sleep 9) || return 1
        # A `q` fed the instant the example starts would race the fake
        # follow's own write of "log line one" (no startup nap papers over
        # this any more — see I5). Feed it through a FIFO instead, from a
        # background writer that waits for a sentinel the fake follow only
        # touches AFTER its log line is written: the key is then physically
        # unable to arrive first.
        local sentinel="$JOB_SANDBOX/detach.ready" fifo="$JOB_SANDBOX/detach.fifo"
        mkfifo "$fifo"
        exec 3<>"$fifo"
        ( while [ ! -e "$sentinel" ]; do sleep 0.02; done; printf 'q' >&3 ) &
        local writer=$!
        JOB_FAKE_FOLLOW_SENTINEL="$sentinel" JOB_FAKE_FOLLOW_SLEEP=1 JOB_WATCH_FORCE=1 \
          run_job job::watch "$id" <&3 2>"$JOB_SANDBOX/watch.err" || return 2
        wait "$writer" 2>/dev/null
        exec 3>&-
        # The log line reached the screen (stderr), the follow child was
        # asked for task 7, and NO kill was ever issued (detach ≠ cancel).
        printf '%s|%s|%s' \
          "$(grep -c 'log line one' "$JOB_SANDBOX/watch.err")" \
          "$(grep -c '^follow 7$' "$JOB_FAKE_LOG")" \
          "$(grep -c '^kill' "$JOB_FAKE_LOG")"
      }
      When call detach
      The output should equal '1|1|0'
    End

    It 'returns immediately with the outcome when the job already finished'
      finished() {
        id=$(run_job job::start --title "Done job" -- true) || return 1
        printf '1 Success 0\n' > "$JOB_STATE_ROOT/$id/result"
        JOB_FAKE_FOLLOW_SLEEP=0 JOB_WATCH_FORCE=1 \
          run_job job::watch "$id" </dev/null 2>"$JOB_SANDBOX/watch.err" || return 2
        grep -c 'Success' "$JOB_SANDBOX/watch.err"
      }
      When call finished
      The output should equal '1'
    End

    It 'keeps a newline-less final log fragment visible after a result-file exit'
      tailfrag() {
        id=$(run_job job::start --title "TF" -- true) || return 1
        local sentinel="$JOB_SANDBOX/tailfrag.ready"
        # The result file lands only AFTER the fake follow has written and
        # touched the sentinel — the final "tail-frag" byte (no trailing
        # newline) is guaranteed to be sitting unflushed in job::watch's
        # `pending` buffer when the loop notices `result` and exits, which
        # is exactly the always-block's final-flush path.
        ( while [ ! -e "$sentinel" ]; do sleep 0.02; done
          printf '1 Success 0\n' > "$JOB_STATE_ROOT/$id/result" ) &
        local writer=$!
        JOB_FAKE_FOLLOW_SENTINEL="$sentinel" JOB_FAKE_FOLLOW_TAILFRAG="tail-frag" \
          JOB_FAKE_FOLLOW_SLEEP=1 JOB_WATCH_FORCE=1 \
          run_job job::watch "$id" </dev/null 2>"$JOB_SANDBOX/tailfrag.err" || return 2
        wait "$writer" 2>/dev/null
        # grep splits on \n only — \r and escape bytes are ordinary
        # characters to it. A completed row (the fix) leaves "tail-frag" as
        # the WHOLE of its own line; the pre-fix bug ran the closing
        # \r\e[K straight into it on the same unterminated line, so
        # "tail-frag" was never the last thing before a real newline.
        grep -c 'tail-frag$' "$JOB_SANDBOX/tailfrag.err"
      }
      When call tailfrag
      The output should equal '1'
    End

    It 'refuses an unknown job id'
      When call run_job job::watch no-such-job
      The status should equal 1
      The stderr should include 'unknown job'
    End

    It 'refuses without a tty unless forced'
      no_tty() {
        id=$(run_job job::start -- sleep 9) || return 1
        run_job job::watch "$id" </dev/null
      }
      When call no_tty
      The status should equal 1
      The stderr should include 'terminal'
    End
  End

  # mux::confirm is the house dialog layer (ask/ai-playbook floated in a mux
  # popup inside a session, inline input::confirm otherwise). The sandbox
  # here has no TMUX/ZELLIJ, so mux::confirm takes the inline input::confirm
  # path, which shells out to ai-playbook — AI_PLAYBOOK_INPUT_BIN is its
  # documented test seam (input-common.zsh's _input::bin).
  Describe 'job::_watch_confirm_cancel'
    confirm_setup() {
      unset TMUX ZELLIJ
      export JOB_FAKE_CONFIRM_LOG="$JOB_SANDBOX/confirm.log"
      cat > "$JOB_SANDBOX/ai-playbook" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_CONFIRM_LOG"
exit "${JOB_FAKE_CONFIRM_RC:-1}"
EOF
      chmod +x "$JOB_SANDBOX/ai-playbook"
      export AI_PLAYBOOK_INPUT_BIN="$JOB_SANDBOX/ai-playbook"
    }
    BeforeEach 'confirm_setup'

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
      The output should include '--affirmative Cancel job'
      The output should include '--negative Keep running'
      The output should include '--title Job runner'
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

  Describe 'job::start --modal'
    It 'prints the id on stdout and chains into the viewer'
      modal() {
        # Same sentinel-gated FIFO as the detach example (I5) — job::start
        # --modal chains straight into job::watch, so the same race applies.
        local sentinel="$JOB_SANDBOX/modal.ready" fifo="$JOB_SANDBOX/modal.fifo"
        mkfifo "$fifo"
        exec 3<>"$fifo"
        ( while [ ! -e "$sentinel" ]; do sleep 0.02; done; printf 'q' >&3 ) &
        local writer=$!
        JOB_FAKE_FOLLOW_SENTINEL="$sentinel" JOB_FAKE_FOLLOW_SLEEP=1 JOB_WATCH_FORCE=1 \
          run_job job::start --modal --title "M" -- sleep 9 \
          <&3 2>"$JOB_SANDBOX/modal.err"
        local rc=$?
        wait "$writer" 2>/dev/null
        exec 3>&-
        return $rc
      }
      When call modal
      The status should equal 0
      # stdout is EXACTLY the id — the viewer painted only stderr.
      The output should match pattern '[0-9]*-[0-9]*'
      The contents of file "$JOB_SANDBOX/modal.err" should include 'log line one'
    End
  End

  Describe 'libexec/job watch verb'
    JOBBIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_job"
    It 'dispatches watch through the front-end'
      When call zsh -f "$JOBBIN" watch no-such-job
      The status should equal 1
      The stderr should include 'unknown job'
    End
  End
End
