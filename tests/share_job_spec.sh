# job:: integration. Uploads are long, network-bound, worth watching and worth
# cancelling — exactly what the job runner exists for, so share consumes it
# rather than inventing progress or process tracking. Completion toasts and
# process-group cancel come for free from job-callback.
#
# JOB_PUEUE_BIN is the job runner's own test seam, so a fake pueue asserts what
# share passes without a daemon running anywhere.

Describe 'share:: background sends'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-job"
    rm -rf "$SB"; mkdir -p "$SB/bin"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_STATE_DIR="$SB/state"
    JOB_STATE_ROOT="$SB/jobs"
    SHARE_PROFILE=personal
    printf '[drop]\nstore = "https://d.example.com"\nweb = true\nprofiles = ["personal"]\ndefault_for = ["personal"]\n[lan]\nrelay = ""\nlocal_only = true\nweb = false\nprofiles = ["personal"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    printf 'x' >"$SB/Report.pdf"
    # Secret files land in the sandbox, not the real state dir: these examples
    # mint live phrases, and without this they leave 0600 files behind in
    # ~/.local/state/share/live on the dev machine (they did — 44 of them).
    SHARE_LIVE_DIR="$SB/live"; export SHARE_LIVE_DIR
    cat >"$SB/fakepueue" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SHARE_PUEUE_CALLS"
case "$1" in
  add) printf '1\n' ;;
  *)   : ;;
esac
SH
    chmod +x "$SB/fakepueue"
    JOB_PUEUE_BIN="$SB/fakepueue"
    SHARE_PUEUE_CALLS="$SB/pueue-calls"; export SHARE_PUEUE_CALLS
    # job::start unconditionally calls job::_statusbar_sync, which resolves
    # ${JOB_TMUX_BIN:-tmux} and runs `refresh-client -S` against the DEFAULT
    # socket — same house rule as tests/job_spec.sh and
    # tests/job_callback_spec.sh: a test must never touch the live server.
    # Left unset here, every share::send_background call in this block
    # repaints this dev shell's real, attached tmux status bar.
    cat >"$SB/bin/tmux" <<'SH'
#!/bin/sh
exit 0
SH
    chmod +x "$SB/bin/tmux"
    JOB_TMUX_BIN="$SB/bin/tmux"

    # A fake pbcopy, and PATH ahead of the real one — same house rule as the
    # tmux stub above and for the same reason: share::clip now runs pbcopy on
    # every send, and on a dev machine that is the USER'S clipboard. It also
    # gives the live examples below something to assert against.
    cat >"$SB/bin/pbcopy" <<'SH'
#!/bin/sh
cat >"$SHARE_FAKE_CLIP"
SH
    chmod +x "$SB/bin/pbcopy"
    SHARE_FAKE_CLIP="$SB/clip.txt"; export SHARE_FAKE_CLIP
    PATH="$SB/bin:$PATH"
  }
  BeforeEach 'setup'

  It 'reports jobs available when pueue resolves and the daemon answers'
    When call share::jobs_available
    The status should be success
  End

  # F1 fix: share::jobs_available used to stop at job::_pueue, which only
  # resolves the BINARY (command -v, else a hardcoded fallback, then a plain
  # -x check) and never contacts the daemon — so with pueue installed but
  # pueued down, the guard passed, `job::start` ran `pueue add`, that failed,
  # and the whole send died instead of degrading to foreground. There is
  # still no seam that can force job::_pueue's own BINARY resolution to fail
  # on a host with pueue actually installed (JOB_PUEUE_BIN short-circuits
  # unconditionally with no executability check, and PATH=/nonexistent is
  # defeated by the hardcoded /opt/homebrew/bin/pueue fallback) — but probing
  # `pueue status` is a seam of this predicate's own, and IS satisfiable: a
  # fake pueue whose `status` exits non-zero.
  It 'reports jobs unavailable when pueue resolves but the daemon does not answer'
    cat >"$SB/deadpueue" <<'SH'
#!/bin/sh
case "$1" in
  status) exit 1 ;;
  *)      exit 0 ;;
esac
SH
    chmod +x "$SB/deadpueue"
    JOB_PUEUE_BIN="$SB/deadpueue"
    When call share::jobs_available
    The status should be failure
  End

  It 'enqueues the send into the share group'
    share::send_background --store "$SB/Report.pdf" >/dev/null
    When call cat "$SB/pueue-calls"
    The output should include 'group add share'
  End

  # job::start never passes --title to `pueue add` — the title lands only in
  # meta.json (pueue's own argv is --group/--label/--print-task-id -- the
  # cmdline). Asserting against pueue-calls would pass even if
  # share::send_background dropped --title entirely, since "Report.pdf" is
  # in that log anyway as the file being shared — so read meta.json's own
  # .title field, keyed off the id share::send_background prints.
  job_meta_title() {
    local id
    id="$(share::send_background --store "$SB/Report.pdf")" || return 1
    jq -r '.title' "$JOB_STATE_ROOT/$id/meta.json"
  }

  It 'titles the job with the file label so the completion toast is readable'
    When call job_meta_title
    The output should include 'Report.pdf'
  End

  It 'prints the job id so a caller can wait on it'
    When call share::send_background --store "$SB/Report.pdf"
    The output should not equal ''
  End

  It 'creates the job state directory the HUD watches'
    share::send_background --store "$SB/Report.pdf" >/dev/null
    When call test -d "$JOB_STATE_ROOT"
    The status should be success
  End

  # --- the live path: hand over the line, THEN enqueue ---------------------
  # This ordering is the entire point of the amendment. A backgrounded live
  # send must give the human something pasteable the instant the command
  # returns; letting the job mint the phrase would mean the line appears
  # whenever pueue happens to start the task, which is exactly the "too late
  # to be useful" failure the retired live template shipped with.

  It 'hands over the pasteable line before the job is even enqueued'
    When call share::send_background --to lan "$SB/Report.pdf"
    The stderr should include 'receive with:  croc'
    The output should not equal ''
  End

  # stdout is the JOB ID and nothing else. Regression: emit_live_blurb first
  # printed to stdout, so the CLI's `id="$(share::send_background …)"`
  # swallowed the pasteable line into the id variable and the human got
  # neither a usable id nor the line.
  It 'keeps the job id alone on stdout so the CLI can capture it'
    When call share::send_background --to lan "$SB/Report.pdf"
    The output should match pattern '*-*'
    The stderr should include 'receive with'
  End

  It 'puts the pasteable line on the clipboard'
    share::send_background --to lan "$SB/Report.pdf" >/dev/null 2>&1
    When call cat "$SB/clip.txt"
    The output should include 'receive with:  croc'
    The lines of output should equal 1
  End

  It 'carries the phrase to the job through a secret file, never on the command line'
    share::send_background --to lan "$SB/Report.pdf" >/dev/null 2>&1
    phrase_off_argv() {
      local code
      code="$(awk '{print $NF}' "$SB/clip.txt")"
      [ -n "$code" ] || return 1
      # The enqueued command names a --secret-file and NEVER the phrase itself:
      # pueue records its client's whole command line into state.json (and,
      # before commit 7e72661c, its whole environment too).
      grep -q -- '--secret-file' "$SB/pueue-calls" || return 1
      grep -q -- "$code" "$SB/pueue-calls" && return 1
      return 0
    }
    When call phrase_off_argv
    The status should be success
  End

  # An explicit --live is a statement about how the file must travel, so a
  # silent downgrade would be worse than a refusal — and it must refuse BEFORE
  # enqueuing, or the error surfaces as a failure toast minutes later instead
  # of immediately.
  It 'refuses an explicit --live to a store-only endpoint without enqueuing'
    When run share::send_background --live --to drop "$SB/Report.pdf"
    The status should be failure
    The stderr should include 'cannot carry a live transfer'
    The stdout should equal ''
  End

  It 'passes --modal through when asked to watch'
    JOB_FORCE_HOST=none
    share::send_background --watch "$SB/Report.pdf" >/dev/null 2>&1
    When call cat "$SB/pueue-calls"
    The output should include 'add'
  End

  # Judgement call (Task 9 brief): share::label fails closed on a bad path.
  # A naive `title="share $(share::label ...)"` swallows that failure (stderr
  # is not captured) and would enqueue a job titled "share " anyway — a job
  # that share::send itself will fail once it actually runs. Refuse to
  # enqueue instead, with the same clean error share::label already printed.
  It 'refuses to enqueue rather than swallow a bad path into a hollow title'
    When call share::send_background "$SB/does-not-exist.pdf"
    The status should be failure
    The stderr should include 'no such file'
    The path "$SB/pueue-calls" should not be exist
  End
End

# The acknowledgable toast is the ONE notification share adds. job-callback
# already handles failures with --ack, so this covers only the opposite case: a
# send that SUCCEEDED while nobody was looking. Without it, the link sits on a
# clipboard that may already have moved on, behind a toast that has evaporated —
# and for --store-downloads 1 that is a wasted upload to redo.
Describe 'share:: acknowledgable completion toast'
  Include home/dot_local/lib/share.zsh

  setup() {
    # Hermetic notify(), same pattern as job_callback_spec.sh: this suite's
    # own shell inherits a real SSH session + tmux server (dev-shell over
    # SSH), so left alone `notify`'s `_notify_bridge_target` reads it as
    # "remote" and `_notify_bridge_send` reaches for the REAL RECOB bridge —
    # exactly the live-server probe the house rule forbids. Unsetting the
    # SSH markers (+ NOTIFY_VIA_BRIDGE) keeps it on the local `hs` path,
    # which a fake stub then intercepts; NOTIFY_TMUX_BIN keeps the --ack
    # status-bar poke off the real tmux server too.
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY NOTIFY_VIA_BRIDGE
    SB="$SHELLSPEC_TMPBASE/share-ack"
    rm -rf "$SB"; mkdir -p "$SB/bin"
    SHARE_STATE_DIR="$SB/state"
    JOB_STATE_ROOT="$SB/jobs"
    NOTIFY_UNACKED_FILE="$SB/unacked"
    NOTIFY_HISTORY_FILE="$SB/history.jsonl"
    cat >"$SB/bin/hs" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${SHARE_FAKE_HS_LOG:-/dev/null}"
SH
    chmod +x "$SB/bin/hs"
    HS="$SB/bin/hs"
    SHARE_FAKE_HS_LOG="$SB/hs.log"
    cat >"$SB/bin/tmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${SHARE_FAKE_TMUX_LOG:-/dev/null}"
exit 0
SH
    chmod +x "$SB/bin/tmux"
    NOTIFY_TMUX_BIN="$SB/bin/tmux"
    SHARE_FAKE_TMUX_LOG="$SB/tmux.log"
  }
  BeforeEach 'setup'

  # A job's own environment: JOB_ID set, and a meta.json carrying the pueue id.
  in_job() {
    JOB_ID=job1
    mkdir -p -- "$JOB_STATE_ROOT/$JOB_ID"
    printf '{"pueue_id":7,"title":"share"}\n' >"$JOB_STATE_ROOT/$JOB_ID/meta.json"
  }

  It 'sends nothing when not inside a job'
    unset JOB_ID
    share::announce 'R.pdf → https://x/s/a#v1.k'
    When call test -f "$NOTIFY_UNACKED_FILE"
    The status should be failure
  End

  It 'writes no history entry when not inside a job'
    unset JOB_ID
    share::announce 'R.pdf → https://x/s/a#v1.k'
    When call test -f "$NOTIFY_HISTORY_FILE"
    The status should be failure
  End

  # shellspec 0.28.1's `When call` does not honor an inline `<file`
  # redirection on the command line itself (verified: it silently reads
  # empty stdin instead — `When call wc -l <"$f"` always reports 0
  # regardless of the file's real content). A same-scope helper function
  # sidesteps it: the redirection runs as ordinary shell syntax when the
  # function body itself executes.
  unacked_line_count() { wc -l <"$NOTIFY_UNACKED_FILE"; }

  It 'appends exactly one line to the unacked ledger from inside a job'
    in_job
    share::announce 'R.pdf → https://x/s/a#v1.k'
    When call unacked_line_count
    The output should include '1'
  End

  It 'records the blurb itself as the toast text, so history can recover the link'
    in_job
    share::announce 'R.pdf → https://x/s/a#v1.k'
    When call cat "$NOTIFY_HISTORY_FILE"
    The output should include 'https://x/s/a#v1.k'
  End

  # shellspec's `result` modifier takes a BARE function identifier
  # ([a-zA-Z_][a-zA-Z0-9_]*), so an inline "cmd | jq ..." string fails its
  # check. Read the single history entry through same-scope helpers instead.
  hist_ack()  { jq -r '.ack'  "$NOTIFY_HISTORY_FILE"; }
  hist_meta() { jq -r '.meta' "$NOTIFY_HISTORY_FILE"; }
  hist_kind() { jq -r '.kind' "$NOTIFY_HISTORY_FILE"; }
  hist_text() { jq -r '.text' "$NOTIFY_HISTORY_FILE"; }

  It 'marks the history entry acknowledgable'
    in_job
    share::announce 'R.pdf → https://x/s/a#v1.k'
    The result of function hist_ack should equal 'true'
  End

  It 'carries the pueue id so the history rows Ctrl-L opens the job log'
    in_job
    share::announce 'R.pdf → https://x/s/a#v1.k'
    The result of function hist_meta should include '7'
  End

  It 'tags the entry with the share kind'
    in_job
    share::announce 'R.pdf → https://x/s/a#v1.k'
    The result of function hist_kind should equal 'share'
  End

  It 'carries the full blurb as the toast text'
    in_job
    share::announce 'R.pdf → https://x/s/a#v1.k'
    The result of function hist_text should equal 'R.pdf → https://x/s/a#v1.k'
  End

  # Judgement call (Task 9 brief): meta.json's pueue_id is -1 until job::start
  # patches it AFTER `pueue add` returns — a job announcing (or racing) before
  # that patch must still emit valid, honest JSON: an empty meta object, not
  # {"pueue_id":-1} pretending -1 is a real pueue task id.
  It 'degrades to a valid empty meta object when the real pueue_id has not landed yet'
    JOB_ID=job2
    mkdir -p -- "$JOB_STATE_ROOT/$JOB_ID"
    printf '{"pueue_id":-1,"title":"share"}\n' >"$JOB_STATE_ROOT/$JOB_ID/meta.json"
    share::announce 'R.pdf → https://x/s/a#v1.k'
    When call hist_meta
    The output should equal '{}'
  End

  # F2 fix: share::announce is the LAST command in share::send, so before
  # this fix its own exit status became the send's — a failed RECOB bridge
  # hop, or simply no Hammerspoon on this host, marked a SUCCESSFUL transfer
  # as FAILED: pueue recorded Failed and job-callback fired its --ack
  # failure toast (red bell) for a share that actually worked. notify
  # documents itself as best-effort (common.zsh); that best-effort layer
  # must never decide the transfer's own success. The stubbed `hs` here
  # exits 1, reproducing "the toast could not be delivered" without needing
  # a real bridge or Hammerspoon.
  send_setup() {
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_PROFILE=personal
    printf '[drop]\nstore = "https://d.example.com"\nweb = true\nprofiles = ["personal"]\ndefault_for = ["personal"]\n' \
      >"$SHARE_ENDPOINTS_FILE"
    printf 'x' >"$SB/Report.pdf"
    cat >"$SB/bin/croc" <<'SH'
#!/bin/sh
printf 'https://d.example.com/s/abc#v1.KEY\ncroc-store-v1.b64.abc.KEY\n'
SH
    chmod +x "$SB/bin/croc"
    cat >"$SB/bin/hs" <<'SH'
#!/bin/sh
exit 1
SH
    chmod +x "$SB/bin/hs"
    HS="$SB/bin/hs"
    PATH="$SB/bin:$PATH"
    in_job
  }

  It 'still exits zero on a successful send when the completion toast fails to deliver'
    send_setup
    When call share::send "$SB/Report.pdf"
    The status should be success
    The output should include 'd.example.com/s/abc'
    The stderr should include 'sending to d.example.com'
  End

  It 'still writes the ledger row when the completion toast fails to deliver'
    send_setup
    send_and_count_ledger() {
      share::send "$SB/Report.pdf" >/dev/null
      share::ledger_list | jq 'length'
    }
    When call send_and_count_ledger
    The output should equal '1'
    The stderr should include 'sending to d.example.com'
  End
End
