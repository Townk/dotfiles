# backup_drift_spec.sh — freshness heartbeat + prompt drift banner.
Describe 'backup-drift.zsh'
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup_fix() {
    FIX=$(mktemp -d)
    export BKP_DRIFT_STATE="$FIX/state"
    export BKP_CAPTURE_CADENCE=1800
    export BKP_CATCHUP_GRACE=300
  }
  cleanup_fix() {
    rm -rf "$FIX"
    unset BKP_DRIFT_STATE BKP_CAPTURE_CADENCE BKP_CATCHUP_GRACE
  }
  BeforeEach 'setup_fix'
  AfterEach 'cleanup_fix'

  Describe 'bkp::drift::assess (pure, fake clock)'
    # NOW is a fixed wall clock; epochs are offsets back from it.
    NOW=1000000

    It 'is silent within the cadence window'
      run_it() {
        source "$LIB/backup-drift.zsh"
        # 20 min old, cadence 30 min → healthy
        bkp::drift::assess $NOW $(( NOW - 1200 )) 0 1800
      }
      When run run_it
      The status should be success
      The output should equal ""
    End

    It 'warns once capture is over 2x the cadence overdue'
      run_it() {
        source "$LIB/backup-drift.zsh"
        # 4h old → warn
        bkp::drift::assess $NOW $(( NOW - 14400 )) 0 1800
      }
      When run run_it
      The status should be success
      The output should include "warn"
      The output should include "backup: last capture 4h ago (expected every 30m)"
    End

    It 'escalates to crit past 24h'
      run_it() {
        source "$LIB/backup-drift.zsh"
        bkp::drift::assess $NOW $(( NOW - 100000 )) 0 1800
      }
      When run run_it
      The status should be success
      The output should include "crit"
    End

    It 'is crit and named a failure when the last phase rc is nonzero'
      run_it() {
        source "$LIB/backup-drift.zsh"
        # recent but failed → crit, even inside the window
        bkp::drift::assess $NOW $(( NOW - 60 )) 1 1800
      }
      When run run_it
      The status should be success
      The output should include "crit"
      The output should include "failed"
    End

    It 'is silent for age nag while a catch-up stamp is inside the grace window'
      run_it() {
        source "$LIB/backup-drift.zsh"
        # 4h stale, but catchup started 30s ago with 300s grace → silent
        bkp::drift::assess $NOW $(( NOW - 14400 )) 0 1800 $(( NOW - 30 )) 300
      }
      When run run_it
      The status should be success
      The output should equal ""
    End

    It 'still warns for age nag after the catch-up grace expires'
      run_it() {
        source "$LIB/backup-drift.zsh"
        bkp::drift::assess $NOW $(( NOW - 14400 )) 0 1800 $(( NOW - 400 )) 300
      }
      When run run_it
      The status should be success
      The output should include "warn"
    End

    It 'still surfaces a failed stamp even during catch-up'
      run_it() {
        source "$LIB/backup-drift.zsh"
        bkp::drift::assess $NOW $(( NOW - 60 )) 1 1800 $(( NOW - 10 )) 300
      }
      When run run_it
      The status should be success
      The output should include "crit"
      The output should include "failed"
    End
  End

  Describe 'bkp::drift::stamp'
    It 'records a phase line and rewrites it in place'
      run_it() {
        source "$LIB/backup-drift.zsh"
        bkp::drift::stamp capture 0
        bkp::drift::stamp reconcile 1
        bkp::drift::stamp capture 0   # rewrite, not duplicate
        grep -c '^capture ' "$BKP_DRIFT_STATE/heartbeat"
        grep -c '^reconcile ' "$BKP_DRIFT_STATE/heartbeat"
      }
      When run run_it
      The status should be success
      The line 1 should equal 1
      The line 2 should equal 1
    End
  End

  Describe 'bkp::drift::clear'
    It 'removes a phase line without touching others'
      run_it() {
        source "$LIB/backup-drift.zsh"
        bkp::drift::stamp capture 0
        bkp::drift::stamp catchup 0
        bkp::drift::clear catchup
        grep -c '^catchup ' "$BKP_DRIFT_STATE/heartbeat" || true
        grep -c '^capture ' "$BKP_DRIFT_STATE/heartbeat"
      }
      When run run_it
      The status should be success
      The line 1 should equal 0
      The line 2 should equal 1
    End
  End

  Describe 'bkp::drift::last'
    It 'echoes epoch and rc for a recorded phase'
      run_it() {
        source "$LIB/backup-drift.zsh"
        bkp::drift::stamp reconcile 1
        bkp::drift::last reconcile
      }
      When run run_it
      The status should be success
      The word 1 should match pattern '[0-9]*'
      The word 2 should equal 1
    End

    It 'returns nonzero when the heartbeat or phase is absent'
      run_it() {
        source "$LIB/backup-drift.zsh"
        bkp::drift::last capture && print present || print absent
        bkp::drift::stamp capture 0
        bkp::drift::last reconcile && print present || print absent
      }
      When run run_it
      The line 1 should equal absent
      The line 2 should equal absent
    End
  End

  Describe 'bkp::drift::banner (prompt hook)'
    It 'prints nothing when there is no heartbeat yet'
      run_it() {
        source "$LIB/backup-drift.zsh"
        bkp::drift::banner
      }
      When run run_it
      The status should be success
      The output should equal ""
    End

    It 'prints nothing when the last capture is fresh'
      run_it() {
        source "$LIB/backup-drift.zsh"
        bkp::drift::stamp capture 0   # now
        bkp::drift::banner
      }
      When run run_it
      The status should be success
      The output should equal ""
    End

    It 'prints a banner when the heartbeat is stale'
      run_it() {
        source "$LIB/backup-drift.zsh"
        mkdir -p "$BKP_DRIFT_STATE"
        # hand-write a capture 5h in the past
        print -r -- "capture $(( EPOCHSECONDS - 18000 )) 0" > "$BKP_DRIFT_STATE/heartbeat"
        bkp::drift::banner
      }
      When run run_it
      The status should be success
      The output should include "backup: last capture"
      The output should include "expected every 30m"
    End

    It 'prints nothing when stale but a fresh catchup stamp is present'
      run_it() {
        source "$LIB/backup-drift.zsh"
        mkdir -p "$BKP_DRIFT_STATE"
        print -r -- "capture $(( EPOCHSECONDS - 18000 )) 0
catchup $EPOCHSECONDS 0" > "$BKP_DRIFT_STATE/heartbeat"
        bkp::drift::banner
      }
      When run run_it
      The status should be success
      The output should equal ""
    End
  End
End
