# Tests for pick-notifications (phase 3): row production from the history
# JSONL and the accept handler, through the --dump-rows/--act seams (the
# interactive picker itself is the pick::start engine, tested elsewhere).
Describe 'pick-notifications'
  PN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-notifications"

  # The three history lines are the same for every example: jq writes them
  # once, an example gets them from a variable (no fork).
  history_once() {
    PN_HISTORY=$(
      jq -nc '{ts:1755400000,icon:"i",text:"plain toast",sound:"",style:"plain",kind:"generic",source:"x"}'
      jq -nc '{ts:1755400100,icon:"c",text:"Build done",sound:"Glass",style:"plain",kind:"job",source:"job",meta:{job_id:"1-1",pueue_id:7,result:"Success"}}'
      jq -nc '{ts:1755400200,icon:"x",text:"Build\nfailed",sound:"Basso",style:"plain",kind:"job",source:"job",ack:true,meta:{job_id:"1-2",pueue_id:8,result:"Failed"}}'
    )
    # The desktop guard's stand-in for tmux (spec_helper.sh) is a new script
    # in every spec file, and macOS charges a script's first exec: paid here,
    # not in the one example whose picker repaints the status bar.
    "$NOTIFY_TMUX_BIN" >/dev/null 2>&1
    spec_desktop_reset
  }
  BeforeAll 'history_once'
  setup() {
    spec_sandbox pn; TEST_TMP=$SANDBOX
    # The libraries of this tree, not the applied ones under $HOME.
    export PICK_COMMON_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/pick-common.zsh"
    export NOTIFY_HISTORY_FILE="$TEST_TMP/history.jsonl"
    export JOB_PUEUE_LOG_DIR="$TEST_TMP/task_logs"
    # Dead-end the toast transports: the handler's notify calls must fall
    # through harmlessly (their history append is the observable).
    export CLIPBOARD_BRIDGE_SOCKET="$TEST_TMP/no-such-socket"
    export HS="$TEST_TMP/no-such-hs"
    unset TMUX 2>/dev/null || :
    mkdir -p "$JOB_PUEUE_LOG_DIR"
    print -r -- "$PN_HISTORY" >> "$NOTIFY_HISTORY_FILE"
    export NOTIFY_UNACKED_FILE="$TEST_TMP/unacked"
  }
  BeforeEach 'setup'

  Describe 'row production (--dump-rows)'
    strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }
    visible() { zsh -f "$PN" --dump-rows | strip_ansi | cut -d$'\x1f' -f1; }
    field() { zsh -f "$PN" --dump-rows | sed -n "$1p" | cut -d$'\x1f' -f2 | cut -d$'\x1e' -f"$2"; }

    It 'renders newest first with kind/result glyphs'
      When call visible
      The line 1 should include "✗"
      The line 1 should include "Build failed"
      The line 2 should include "✓"
      The line 2 should include "Build done"
      The line 3 should include "•"
      The line 3 should include "plain toast"
    End

    It 'flattens embedded newlines so one entry stays one row'
      count_rows() { zsh -f "$PN" --dump-rows | wc -l | tr -d ' '; }
      When call count_rows
      The output should equal "3"
    End

    It 'hidden fields carry the entry JSON and the log action'
      f_json() { field 1 2 | jq -r '.meta.result'; }
      When call f_json
      The output should equal "Failed"
    End

    It 'job rows carry log:<pueue_id>, generic rows a bare log:'
      f_log() { field 1 3; field 3 3; }
      When call f_log
      The line 1 should equal "log:8"
      The line 2 should equal "log:"
    End

    It 'ack-able entries carry the bell mark, plain ones do not'
      BELLG=$'\uF0F3'
      marks() { zsh -f "$PN" --dump-rows | strip_ansi | cut -d$'\x1f' -f1; }
      When call marks
      The line 1 should include "$BELLG Build failed"
      The line 2 should not include "$BELLG"
    End

    It 'opening the picker truncates the unacked ledger (acknowledgment)'
      ack_on_open() {
        printf 'x\ny\n' > "$NOTIFY_UNACKED_FILE"
        zsh -f "$PN" --dump-rows >/dev/null || return 1
        wc -c < "$NOTIFY_UNACKED_FILE" | tr -d ' '
      }
      When call ack_on_open
      The output should equal "0"
    End

    It 'exits 1 with a notice when there is no history'
      no_history() { NOTIFY_HISTORY_FILE="$TEST_TMP/empty.jsonl" zsh -f "$PN" --dump-rows; }
      When call no_history
      The status should eq 1
      The stderr should include "no notification history"
    End
  End

  Describe 'accept handler (--act)'
    It 'log:<pid> outside a mux prints the log path'
      : > "$JOB_PUEUE_LOG_DIR/8.log"
      When run zsh -f "$PN" --act "log:8"
      The output should equal "$JOB_PUEUE_LOG_DIR/8.log"
    End

    It 'a missing log falls back to the quiet notice (observable in history)'
      act_missing() { zsh -f "$PN" --act "log:99" || :; tail -n 1 "$NOTIFY_HISTORY_FILE"; }
      When call act_missing
      The output should include "Log no longer available"
      The output should include '"source":"pick-notifications"'
    End

    It 'a bare log: (non-job row) also lands on the notice, not a path'
      act_bare() { zsh -f "$PN" --act "log:" || :; tail -n 1 "$NOTIFY_HISTORY_FILE"; }
      When call act_bare
      The output should include "Log no longer available"
    End

    It 'a JSON entry re-shows: a fresh history append with the original kind'
      act_reshow() {
        local entry
        entry=$(tail -n 2 "$NOTIFY_HISTORY_FILE" | head -n 1)  # the Success job
        zsh -f "$PN" --act "$entry" || :
        tail -n 1 "$NOTIFY_HISTORY_FILE"
      }
      When call act_reshow
      The output should include '"text":"Build done"'
      The output should include '"kind":"job"'
      The output should include '"source":"pick-notifications"'
      # The dead-ended toast transport may grumble on stderr; the history
      # append above is the contract.
      The stderr should be defined
    End

    It 'anything else is a cancel (130)'
      When run zsh -f "$PN" --act "unexpected"
      The status should eq 130
    End
  End
End
