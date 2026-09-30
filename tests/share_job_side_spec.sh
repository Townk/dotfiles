# The JOB side of a share: `share send --foreground` running INSIDE a job:: job.
#
# Mode B (2026-09-29): a live send showed no "waiting" state — the job had no
# progress file and no phase file at all. share::_progress and share::_waiting
# are guarded on the job:: functions being DEFINED, but only the enqueuing side
# (share::_load_jobs) ever sourced job.zsh; the process pueue runs never did, so
# both were silent no-ops in every real job (rclone's percent included). The
# specs never saw it because they define a stub job::progress themselves.
# These examples run in a FRESH zsh with nothing preloaded — like the real job.

Describe 'share inside a job (job.zsh not preloaded)'
  setup() {
    SB="$SHELLSPEC_TMPBASE/share-job-side"; rm -rf "$SB"; mkdir -p "$SB/jobs/j1"
    export JOB_STATE_ROOT="$SB/jobs" SHARE_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/share.zsh"
  }
  BeforeEach 'setup'

  in_job() {  # in_job <share function> [args…] — fresh zsh, JOB_ID set
    JOB_ID=j1 zsh -f -c '
      source "$SHARE_LIB" || exit 9
      "$@"
      print -r -- "rc=$?"
    ' _ "$@"
  }

  It 'declares waiting: writes the -1 line and the waiting phase'
    check() {
      in_job share::_waiting "waiting for recipient"
      print -r -- "phase=$(<"$SB/jobs/j1/phase")"
      print -r -- "progress=${$(<"$SB/jobs/j1/progress")#* }"
    }
    When call check
    The line 1 should equal 'rc=0'
    The line 2 should equal 'phase=waiting'
    The line 3 should equal 'progress=-1 waiting for recipient'
  End

  It 'reports progress (and clears the phase)'
    check() {
      in_job share::_waiting "waiting for recipient" >/dev/null
      in_job share::_progress 40 "sending big.bin" >/dev/null
      print -r -- "progress=${$(<"$SB/jobs/j1/progress")#* }"
      [[ -e "$SB/jobs/j1/phase" ]] && print -r -- "phase=present" || print -r -- "phase=gone"
    }
    When call check
    The line 1 should equal 'progress=40 sending big.bin'
    The line 2 should equal 'phase=gone'
  End

  It 'stays a silent no-op outside a job'
    outside() { zsh -f -c 'source "$SHARE_LIB"; share::_waiting x; share::_progress 5 y; print -r -- "rc=$?"'; }
    When call outside
    The output should equal 'rc=0'
    The path "$SB/jobs/j1/progress" should not be exist
  End
End
