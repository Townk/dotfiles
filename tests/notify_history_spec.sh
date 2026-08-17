# Tests for notify()'s notification history (phase 3, job-runner spec §8):
# sender-side JSONL append before dispatch, --kind/--source/--meta tagging,
# size-capped rotation, and the never-fail-the-toast guarantee.
Describe 'notify history'
  Include home/dot_local/lib/common.zsh

  setup() {
    TEST_TMP="$(mktemp -d)"
    export NOTIFY_HISTORY_FILE="$TEST_TMP/history.jsonl"
    # No bridge, no hs: dispatch is expected to fail — history must not care.
    export CLIPBOARD_BRIDGE_SOCKET="$TEST_TMP/no-such-socket"
    export HS="$TEST_TMP/no-such-hs"
  }
  cleanup() {
    rm -rf "$TEST_TMP"
    unset NOTIFY_HISTORY_FILE CLIPBOARD_BRIDGE_SOCKET HS
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  last_entry() { tail -n 1 "$NOTIFY_HISTORY_FILE"; }

  It 'appends a JSON line even when delivery fails (sender-side, pre-dispatch)'
    do_notify() { notify --icon "🔔" --sound Ping "hello world" || :; }
    When call do_notify
    The path "$NOTIFY_HISTORY_FILE" should be exist
    The result of function last_entry should include '"text":"hello world"'
    The result of function last_entry should include '"icon":"🔔"'
    The result of function last_entry should include '"sound":"Ping"'
    The result of function last_entry should include '"kind":"generic"'
  End

  It 'records --kind/--source/--meta and keeps meta as structured JSON'
    do_notify() {
      notify --kind job --source job-callback \
        --meta '{"job_id":"123-1","pueue_id":7,"result":"Success"}' \
        --icon "✓" "Task done" || :
    }
    check_meta() { tail -n 1 "$NOTIFY_HISTORY_FILE" | jq -r '.meta.pueue_id'; }
    When call do_notify
    The result of function last_entry should include '"kind":"job"'
    The result of function last_entry should include '"source":"job-callback"'
    The result of function check_meta should equal "7"
  End

  It 'drops invalid --meta silently instead of failing the append'
    do_notify() { notify --meta 'not json at all' "still recorded" || :; }
    check_no_meta() { tail -n 1 "$NOTIFY_HISTORY_FILE" | jq 'has("meta")'; }
    When call do_notify
    The result of function last_entry should include '"text":"still recorded"'
    The result of function check_no_meta should equal "false"
  End

  It 'every line is valid JSON with a numeric ts'
    do_notify() {
      notify "one" || :
      notify --ansi --icon "x" "two" || :
    }
    all_valid() { jq -es 'all(.ts | type == "number")' "$NOTIFY_HISTORY_FILE"; }
    When call do_notify
    The result of function all_valid should equal "true"
  End

  It 'rotates past the size cap down to the last 1000 lines'
    do_rotate() {
      # Seed an oversized file (one long line body pushes it past 512KB
      # quickly), then one real notify triggers the rotation.
      local pad; pad=$(printf 'x%.0s' {1..600})
      local i
      for i in {1..1200}; do
        print -r -- "{\"ts\":$i,\"text\":\"$pad\"}" >> "$NOTIFY_HISTORY_FILE"
      done
      notify "the straw" || :
      wc -l < "$NOTIFY_HISTORY_FILE" | tr -d ' '
    }
    When call do_rotate
    The output should equal "1000"
    # The failed local-dispatch attempt (no hs on this seam) may grumble on
    # stderr; the assertion above is the contract, the grumble is noise.
    The stderr should be defined
  End

  It 'the rotated tail keeps the newest entries (the straw survives)'
    do_rotate() {
      local pad; pad=$(printf 'x%.0s' {1..600})
      local i
      for i in {1..1200}; do
        print -r -- "{\"ts\":$i,\"text\":\"$pad\"}" >> "$NOTIFY_HISTORY_FILE"
      done
      notify "the straw" || :
    }
    When call do_rotate
    The result of function last_entry should include '"text":"the straw"'
  End

  It 'a toast with no text and no icon still exits 2 and appends nothing'
    do_notify() { notify --kind job; }
    When call do_notify
    The status should eq 2
    The path "$NOTIFY_HISTORY_FILE" should not be exist
  End
End
