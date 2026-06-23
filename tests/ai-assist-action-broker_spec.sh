# Tests for home/dot_local/libexec/executable_ai-assist-action-broker: reads
# <kind>US<id>US<payload>RS action records and performs copy (clipboard / OSC 52)
# or play (zellij write-chars + CR into the origin pane), or run (execute via
# ai-assist-run and emit a result record on the results FIFO).
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
    AI_ASSIST_BROKER_LOG="$TEST_TMP/broker.log"
    . "$SCRIPT"
    zj="$TEST_TMP/zellij"
    clip="pbcopy"
    origin="terminal_7"
    results=""
    shell_fifo=""
  }

  It 'copies to the local clipboard (not over SSH)'
    drive() { load_broker; over_ssh=0; broker::dispatch "copy${US}b1${US}echo hi${RS}"; }
    When call drive
    The status should be success
    The contents of file "$TEST_TMP/clip.out" should equal "echo hi"
  End

  It 'copies via OSC 52 over SSH (base64 of payload to the tty)'
    drive() {
      load_broker; over_ssh=1
      AI_ASSIST_BROKER_TTY="$TEST_TMP/tty.out"
      broker::dispatch "copy${US}b1${US}echo hi${RS}"
      # extract the base64 between ';c;' and the BEL, decode it
      perl -0777 -ne 'print $1 if /\]52;c;([^\a]*)\a/' "$TEST_TMP/tty.out" | base64 -d
    }
    When call drive
    The output should equal "echo hi"
  End

  It 'plays by bracketed-pasting into the origin pane then sending CR'
    drive() { load_broker; over_ssh=0; broker::dispatch "play${US}b1${US}make all${RS}"; }
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
    drive() { load_broker; over_ssh=0; broker::dispatch "bogus${US}b1${US}x${RS}"; }
    When call drive
    The status should be success
    The path "$TEST_TMP/clip.out" should not be exist
  End

  It 'runs a block via ai-assist-run and writes a result record'
    load_broker
    results="$TEST_TMP/results.fifo"; mkfifo "$results"
    shell_fifo="$TEST_TMP/shell.fifo"; mkfifo "$shell_fifo"
    # stub ai-assist-run: echo, exit 0
    printf '#!/usr/bin/env zsh\nprint -r -- "ran:$*" \nexit 0\n' > "$TEST_TMP/airun"
    chmod +x "$TEST_TMP/airun"; AI_ASSIST_RUN_BIN="$TEST_TMP/airun"
    ( cat "$results" > "$TEST_TMP/results.out" ) &
    broker::dispatch "run${US}fix${US}echo hi${RS}"
    sleep 0.3
    The contents of file "$TEST_TMP/results.out" should include "fix"
    The contents of file "$TEST_TMP/results.out" should include "$(printf '\x1f')0$(printf '\x1f')"
  End

  It 'run with no shell_fifo writes a failure result record'
    load_broker
    results="$TEST_TMP/results.fifo"; mkfifo "$results"
    shell_fifo=""   # no shell attached
    ( cat "$results" > "$TEST_TMP/results.out" ) &
    broker::dispatch "run${US}noshell${US}echo hi${RS}"
    sleep 0.1
    The contents of file "$TEST_TMP/results.out" should include "noshell"
    The contents of file "$TEST_TMP/results.out" should include "$(printf '\x1f')1$(printf '\x1f')"
  End

  It 'diff action opens a zellij 90% floating pane on the patch'
    load_broker
    broker::dispatch "diff${US}d1${US}--- a\n+++ b${RS}"
    The contents of file "$TEST_TMP/zj.log" should include "new-pane"
    The contents of file "$TEST_TMP/zj.log" should include "--floating"
    The contents of file "$TEST_TMP/zj.log" should include "--width 90%"
    The contents of file "$TEST_TMP/zj.log" should include "--height 90%"
    The contents of file "$TEST_TMP/zj.log" should include "--cwd"
  End

  It 'diff action uses hunk patch --mode split (side-by-side) when hunk is available'
    load_broker
    printf '#!/usr/bin/env zsh\nprint -r -- "hunk $*"\n' > "$TEST_TMP/hunk"; chmod +x "$TEST_TMP/hunk"
    hunk_bin="$TEST_TMP/hunk"
    broker::open_diff d3 "--- a"$'\n'"+++ b"
    The contents of file "$TEST_TMP/zj.log" should include "new-pane"
    The contents of file "$TEST_TMP/zj.log" should include "--floating"
    The contents of file "$TEST_TMP/zj.log" should include "--width 90%"
    The contents of file "$TEST_TMP/zj.log" should include "--height 90%"
    The contents of file "$TEST_TMP/zj.log" should include "--cwd"
    The contents of file "$TEST_TMP/zj.log" should include "hunk patch --mode split"
  End

  It 'view-diff alias routes to open_diff (back-compat)'
    load_broker
    printf '#!/usr/bin/env zsh\nprint -r -- "hunk $*"\n' > "$TEST_TMP/hunk"; chmod +x "$TEST_TMP/hunk"
    hunk_bin="$TEST_TMP/hunk"
    broker::dispatch "view-diff${US}d4${US}--- a\n+++ b${RS}"
    The contents of file "$TEST_TMP/zj.log" should include "hunk patch --mode split"
  End

  It 'review-diff alias routes to open_diff (back-compat)'
    load_broker
    printf '#!/usr/bin/env zsh\nprint -r -- "hunk $*"\n' > "$TEST_TMP/hunk"; chmod +x "$TEST_TMP/hunk"
    hunk_bin="$TEST_TMP/hunk"
    broker::dispatch "review-diff${US}d5${US}--- a\n+++ b${RS}"
    The contents of file "$TEST_TMP/zj.log" should include "hunk patch --mode split"
  End

  It 'open_diff falls back to viewer (no hunk) and uses delta --side-by-side when delta is viewer'
    load_broker
    hunk_bin=""   # no hunk
    viewer="/opt/homebrew/bin/delta --paging=always"
    broker::open_diff d6 "--- a"$'\n'"+++ b"
    The contents of file "$TEST_TMP/zj.log" should include "new-pane"
    The contents of file "$TEST_TMP/zj.log" should include "--width 90%"
    The contents of file "$TEST_TMP/zj.log" should include "--height 90%"
    The contents of file "$TEST_TMP/zj.log" should include "delta --side-by-side"
    The contents of file "$TEST_TMP/zj.log" should not include "hunk"
  End

  It 'apply-diff runs git apply via ai-assist-run and writes a result record'
    load_broker
    results="$TEST_TMP/results.fifo"; mkfifo "$results"
    shell_fifo="$TEST_TMP/shell.fifo"; mkfifo "$shell_fifo"
    printf '#!/usr/bin/env zsh\nprint -r -- "$*" >> "%s/ranlog"\nexit 0\n' "$TEST_TMP" > "$TEST_TMP/airun"
    chmod +x "$TEST_TMP/airun"; AI_ASSIST_RUN_BIN="$TEST_TMP/airun"
    ( cat "$results" > "$TEST_TMP/results.out" ) &
    broker::dispatch "apply-diff${US}d2${US}--- a\n+++ b${RS}"
    sleep 0.1
    The contents of file "$TEST_TMP/results.out" should include "d2"
    The path "$TEST_TMP/airun" should be exist
    The contents of file "$TEST_TMP/ranlog" should include "git apply"
  End

End
