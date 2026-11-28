# A test never waits on the real clock — the lint behind that policy
# (tests/README-scaffolding.md, tests/no-real-waits.sh).
#
# While the old waits are being converted, tests/no-real-waits.baseline holds
# the count each file still has. The rule is a ratchet: a file may not gain a
# wait, and a file that lost one must have its line lowered, so progress
# cannot slip back. When the last line goes, delete the baseline: the rule is
# then simply "none".
Describe 'no real waits in the tests'
  COUNTER="$SHELLSPEC_PROJECT_ROOT/tests/no-real-waits.sh"
  BASELINE="$SHELLSPEC_PROJECT_ROOT/tests/no-real-waits.baseline"

  current() { zsh "$COUNTER" "$SHELLSPEC_PROJECT_ROOT/tests"; }
  allowed() { [ -f "$BASELINE" ] && command grep -v -E '^[[:space:]]*(#|$)' "$BASELINE" | sort; }

  # Lines are "<file> <waits> <clock-reads>". Prints what differs, with the
  # reason, and nothing when the two agree.
  drift() {
    join -a1 -a2 -e 0 -o '0,1.2,1.3,2.2,2.3' <(current) <(allowed) | awk '
      $2 > $4 || $3 > $5 {
        printf "%s: %d wait(s) and %d clock read(s), %d and %d allowed - a test must not wait on the real clock; use spec_clock_*, wait <pid> or a counted fake\n", $1, $2, $3, $4, $5; next }
      $2 < $4 || $3 < $5 {
        printf "%s: now %d wait(s) and %d clock read(s) - lower its line in tests/no-real-waits.baseline (or remove it at 0 0)\n", $1, $2, $3 }'
  }

  It 'finds no test file with more real waits than its baseline, and no stale baseline line'
    When call drift
    The output should equal ""
  End

  Describe 'the counter'
    count() {  # count <line…> — what the counter makes of a file holding those lines
      command rm -rf "$SHELLSPEC_TMPBASE/nrw" && mkdir -p "$SHELLSPEC_TMPBASE/nrw"
      printf '%s\n' "$@" >"$SHELLSPEC_TMPBASE/nrw/x_spec.sh"
      zsh "$COUNTER" "$SHELLSPEC_TMPBASE/nrw"
    }

    It 'counts a wait wherever a command can start'
      When call count '  sleep 0.3' 'a; sleep 1' 'x && /bin/sleep 2' '( sleep 1; kill $p ) &' \
        'timeout 5 cmd' 'r=$(gtimeout 2 cmd)' 'if true; then sleep 1; fi' 'read -t 2 line'
      The output should equal "x_spec.sh 8 0"
    End

    It 'does not count the words where nothing waits'
      # A comment, a title, a flag being asserted, a job that sleeps as its own
      # work, a pane told to run one.
      When call count '# sleep 5 was here' "It 'does not sleep or timeout'" \
        "The output should include '--timeout 3s'" 'job::start -- sleep 5' \
        '"args":["sleep 60"]' "mux::new_tab -- sh -c 'sleep 30'" 'spec_clock_advance 5'
      The output should equal ""
    End

    It 'counts reads of the real clock'
      When call count 'local t0=$EPOCHREALTIME' '(( EPOCHREALTIME - t0 < 3 ))' 'print $SECONDS'
      The output should equal "x_spec.sh 0 3"
    End

    It 'leaves the harness that implements the fake sleep alone'
      exempt() {
        mkdir -p "$SHELLSPEC_TMPBASE/nrw2"
        print -r -- 'sleep 1' >"$SHELLSPEC_TMPBASE/nrw2/spec_helper.sh"
        print -r -- 'sleep 1' >"$SHELLSPEC_TMPBASE/nrw2/spec_helper_spec.sh"
        zsh "$COUNTER" "$SHELLSPEC_TMPBASE/nrw2"
      }
      When call exempt
      The output should equal ""
    End
  End
End
