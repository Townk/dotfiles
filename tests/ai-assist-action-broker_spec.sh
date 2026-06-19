# Tests for home/dot_local/libexec/executable_ai-assist-action-broker: reads
# <kind>US<payload>RS action records and performs copy (clipboard / OSC 52) or
# play (zellij write-chars + CR into the origin pane).
Describe 'ai-assist-action-broker'
  US=$(printf '\037'); RS=$(printf '\036')
  setup() {
    TEST_TMP=$(mktemp -d)
    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-action-broker"
    # zellij stub: append its args to zj.log
    printf '#!/usr/bin/env zsh\nprint -r -- "$*" >> "%s/zj.log"\n' "$TEST_TMP" > "$TEST_TMP/zellij"
    chmod +x "$TEST_TMP/zellij"
    # pbcopy stub: capture stdin to clip.out
    printf '#!/usr/bin/env zsh\ncat > "%s/clip.out"\n' "$TEST_TMP" > "$TEST_TMP/pbcopy"
    chmod +x "$TEST_TMP/pbcopy"
    PATH="$TEST_TMP:$PATH"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Source the broker without running its FIFO loop, then drive its functions.
  load_broker() {
    AI_ASSIST_BROKER_NORUN=1
    . "$SCRIPT"
    zj="$TEST_TMP/zellij"
    clip="pbcopy"
    origin="terminal_7"
  }

  It 'copies to the local clipboard (not over SSH)'
    drive() { load_broker; over_ssh=0; broker::dispatch "copy${US}echo hi${RS}"; }
    When call drive
    The status should be success
    The contents of file "$TEST_TMP/clip.out" should equal "echo hi"
  End

  It 'copies via OSC 52 over SSH (base64 of payload to the tty)'
    drive() {
      load_broker; over_ssh=1
      AI_ASSIST_BROKER_TTY="$TEST_TMP/tty.out"
      broker::dispatch "copy${US}echo hi${RS}"
      # extract the base64 between ';c;' and the BEL, decode it
      perl -0777 -ne 'print $1 if /\]52;c;([^\a]*)\a/' "$TEST_TMP/tty.out" | base64 -d
    }
    When call drive
    The output should equal "echo hi"
  End

  It 'plays by bracketed-pasting into the origin pane then sending CR'
    drive() { load_broker; over_ssh=0; broker::dispatch "play${US}make all${RS}"; }
    When call drive
    The status should be success
    # ESC[200~ paste-start, the payload, ESC[201~ paste-end, then CR — so a
    # multi-line block enters as one command buffer (like a terminal paste).
    The contents of file "$TEST_TMP/zj.log" should include "action write --pane-id terminal_7 27 91 50 48 48 126"
    The contents of file "$TEST_TMP/zj.log" should include "action write-chars --pane-id terminal_7 -- make all"
    The contents of file "$TEST_TMP/zj.log" should include "action write --pane-id terminal_7 27 91 50 48 49 126"
    The contents of file "$TEST_TMP/zj.log" should include "action write --pane-id terminal_7 13"
  End

  It 'ignores an unknown kind'
    drive() { load_broker; over_ssh=0; broker::dispatch "bogus${US}x${RS}"; }
    When call drive
    The status should be success
    The path "$TEST_TMP/clip.out" should not be exist
  End
End
