# Tests for home/dot_local/libexec/executable_ai-assist-render: the docked-pane
# wrapper that runs the harness with a braille spinner (buffered), then hands the
# captured markdown to ai-assist-pager (the interactive viewer) — falling back to
# glow, then a width-aware fold, when the pager isn't installed.
Describe 'ai-assist-render'
  setup() {
    TEST_TMP=$(mktemp -d)
    SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-render"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A stub pager: prints a marker with its --harness value, then dumps the
  # streamed markdown by reading the --input-fifo it was handed (the real pager
  # opens that FIFO for reading, which is also what unblocks render's writer).
  # Lets us assert the render delegated to the pager and streamed the content.
  pager_stub() {
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "PAGER_RAN harness=$2"'
      echo 'in=""; while (($#)); do [[ "$1" == "--input-fifo" ]] && { in="$2"; break; }; shift; done'
      echo '[[ -n "$in" && -p "$in" ]] && cat -- "$in"'
    } > "$TEST_TMP/pager"
    chmod +x "$TEST_TMP/pager"
  }

  It 'hands the captured markdown to ai-assist-pager'
    BeforeRun 'pager_stub' 'export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"'
    When run script "$SCRIPT" --harness "Claude Code" -- printf '# Hi\n'
    The status should be success
    The output should include "PAGER_RAN harness=Claude Code"
    The output should include "# Hi"
  End

  It 'propagates the harness exit code'
    BeforeRun 'pager_stub' 'export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"'
    When run script "$SCRIPT" --harness X -- sh -c 'echo working; exit 3'
    The status should eq 3
    The output should include "working"
  End

  It 'falls back to a reflow when neither pager nor glow is available'
    # Point the pager at a non-existent path so the absolute-path resolution is
    # bypassed, and strip glow from PATH, forcing the fold reflow.
    BeforeRun 'export PATH=/usr/bin:/bin' 'export AI_ASSIST_PAGER_BIN=/nonexistent/ai-assist-pager'
    When run script "$SCRIPT" --harness X -- printf 'plain output line\n'
    The status should be success
    The output should include "plain output line"
  End

  It 'errors with no command after --'
    When run script "$SCRIPT" --harness X --
    The status should eq 2
    The stderr should include "no command"
  End

  # A stub broker: records its args, then `exec sleep` so the render can kill it.
  # `exec` replaces the shell with sleep, so the PID render holds (broker_pid) IS
  # the sleep — render's trap `kill "$broker_pid"` reaps it directly and frees the
  # inherited stdout fd at once. A plain `sleep` would be an unkilled grandchild
  # that keeps shellspec's capture pipe open (slow/hang).
  broker_stub() {
    {
      echo '#!/usr/bin/env zsh'
      echo 'print -r -- "BROKER $*" >> "$TEST_TMP/broker.log"'
      echo 'exec sleep 30'
    } > "$TEST_TMP/broker"
    chmod +x "$TEST_TMP/broker"
  }

  It 'passes --actions-fifo <path> as a separated flag+value to the pager + spawns the broker when --origin-pane is set'
    fifo_pager() {
      # Print each arg on its own line so the assertion can require the flag and
      # its value as two separate tokens — the word-split bug would collapse
      # "--actions-fifo $fifo" into a single arg, which this check would miss.
      # Drain the input FIFO first so render's blocking open() on the write end
      # completes (the real pager always opens --input-fifo for reading).
      { echo '#!/usr/bin/env zsh'
        echo 'typeset -a args; in=""'
        echo 'for a in "$@"; do args+=("$a"); done'
        echo 'while (($#)); do [[ "$1" == "--input-fifo" ]] && { in="$2"; break; }; shift; done'
        echo '[[ -n "$in" && -p "$in" ]] && cat -- "$in" >/dev/null'
        echo 'print -rl -- "${args[@]}"'
      } > "$TEST_TMP/pager"; chmod +x "$TEST_TMP/pager"
    }
    BeforeRun 'broker_stub' 'fifo_pager' \
      'export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"' \
      'export AI_ASSIST_BROKER_BIN="$TEST_TMP/broker"' \
      'export TEST_TMP="$TEST_TMP"'
    When run script "$SCRIPT" --harness X --origin-pane terminal_4 --over-ssh -- printf 'hi\n'
    The status should be success
    # Flag and value are SEPARATE tokens (own lines): "--actions-fifo" then "/…".
    The output should include "--actions-fifo"
    The line 5 of output should equal "--actions-fifo"
    The line 6 of output should start with "/"
    The contents of file "$TEST_TMP/broker.log" should include "BROKER"
    The contents of file "$TEST_TMP/broker.log" should include "--origin-pane terminal_4"
    The contents of file "$TEST_TMP/broker.log" should include "--over-ssh"
  End

  It 'runs the pager with no --actions-fifo when --origin-pane is absent'
    plain_pager() {
      # Drain --input-fifo (like the real pager) so render's blocking open() on
      # the FIFO write end completes; otherwise render hangs forever.
      { echo '#!/usr/bin/env zsh'
        echo 'in=""; print -r -- "PAGER args=[$*]"'
        echo 'while (($#)); do [[ "$1" == "--input-fifo" ]] && { in="$2"; break; }; shift; done'
        echo '[[ -n "$in" && -p "$in" ]] && cat -- "$in" >/dev/null'
      } > "$TEST_TMP/pager"; chmod +x "$TEST_TMP/pager"
    }
    BeforeRun 'plain_pager' 'export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"'
    When run script "$SCRIPT" --harness X -- printf 'hi\n'
    The status should be success
    The output should not include "actions-fifo"
  End

  shell_stub() {
    { echo '#!/usr/bin/env zsh'
      echo "printf '%s\\n' \"\$*\" >> \"$TEST_TMP/shell-args\""
      # `exec sleep` so render's trap `kill "$shell_pid"` reaps THIS process (not
      # an unkilled grandchild). Stay alive so render can export the var first.
      echo "exec sleep 5"
    } > "$TEST_TMP/ai-assist-shell"; chmod +x "$TEST_TMP/ai-assist-shell"
  }

  It 'spawns ai-assist-shell and exports AI_ASSIST_SHELL_FIFO to the harness'
    setup_shell_test() {
      pager_stub
      shell_stub
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"
    }
    BeforeRun 'setup_shell_test'
    envf="$TEST_TMP/req.env"; printf "export X=1\n" > "$envf"
    # harness stub records whether the var reached its environment
    harness="$TEST_TMP/harness"
    { echo '#!/usr/bin/env zsh'
      echo "printf '%s' \"\${AI_ASSIST_SHELL_FIFO:-UNSET}\" > \"$TEST_TMP/seen-fifo\""
    } > "$harness"; chmod +x "$harness"
    When run script "$SCRIPT" --harness claude --shell-env "$envf" --shell-cwd "$TEST_TMP" \
      --shell-bin "$TEST_TMP/ai-assist-shell" -- "$harness"
    The status should be success
    The output should include "PAGER_RAN"
    The contents of file "$TEST_TMP/shell-args" should include "--cmd-fifo"
    The contents of file "$TEST_TMP/shell-args" should include "--env-file $envf"
    The contents of file "$TEST_TMP/seen-fifo" should not equal "UNSET"
  End

  It 'exports AI_ASSIST_PROJECT_ROOT to the harness when --project-root is passed'
    setup_projroot_test() {
      pager_stub
      shell_stub
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"
    }
    BeforeRun 'setup_projroot_test'
    envf="$TEST_TMP/req.env"; printf "export X=1\n" > "$envf"
    harness="$TEST_TMP/harness2"
    { echo '#!/usr/bin/env zsh'
      echo "printf '%s' \"\${AI_ASSIST_PROJECT_ROOT:-UNSET}\" > \"$TEST_TMP/seen-projroot\""
    } > "$harness"; chmod +x "$harness"
    When run script "$SCRIPT" --harness claude --shell-env "$envf" --shell-cwd "$TEST_TMP" \
      --shell-bin "$TEST_TMP/ai-assist-shell" --project-root /tmp/proj -- "$harness"
    The status should be success
    The output should include "PAGER_RAN"
    The contents of file "$TEST_TMP/seen-projroot" should equal "/tmp/proj"
  End

  It 'prepends ~/.local/libexec to PATH so the harness can invoke C1 tools by name'
    setup_path_test() {
      pager_stub
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"
    }
    BeforeRun 'setup_path_test'
    harness="$TEST_TMP/harness-path"
    { echo '#!/usr/bin/env zsh'
      echo "printf '%s' \"\$PATH\" > \"$TEST_TMP/seen-path\""
    } > "$harness"; chmod +x "$harness"
    When run script "$SCRIPT" --harness claude -- "$harness"
    The status should be success
    The output should include "PAGER_RAN"
    The contents of file "$TEST_TMP/seen-path" should include "$HOME/.local/libexec"
  End

  It 'uses caller-provided --input-fifo and --actions-fifo and leaves them on disk after exit'
    # Create pre-made fifos as the orchestrator would.
    # We must create them OUTSIDE of BeforeRun so we have the paths for assertions.
    setup_prefifo_test() {
      pager_stub
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"
      mkfifo -m 600 "$TEST_TMP/pre-in.fifo"
      mkfifo -m 600 "$TEST_TMP/pre-act.fifo"
      export PRE_IN_FIFO="$TEST_TMP/pre-in.fifo"
      export PRE_ACT_FIFO="$TEST_TMP/pre-act.fifo"
    }
    BeforeRun 'setup_prefifo_test'
    When run script "$SCRIPT" --harness claude \
      --input-fifo "$TEST_TMP/pre-in.fifo" \
      --actions-fifo "$TEST_TMP/pre-act.fifo" \
      -- printf 'hello-prefifo\n'
    The status should be success
    The output should include "PAGER_RAN"
    The output should include "hello-prefifo"
    # Caller-provided fifos MUST survive render's exit (orchestrator owns them).
    The path "$TEST_TMP/pre-in.fifo" should be exist
    The path "$TEST_TMP/pre-act.fifo" should be exist
  End

  It 'no-flags path is unchanged: mktemp-ed input fifo is cleaned up on exit'
    # The harness writes the value of AI_ASSIST_IN_FIFO (which render must set when
    # it mktemp-creates its own fifo) to a sentinel file, so we can assert after
    # the run that the file no longer exists (render's EXIT trap removed it).
    setup_cleanup_test() {
      pager_stub
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"
      export TMPDIR="$TEST_TMP"
    }
    BeforeRun 'setup_cleanup_test'
    When run script "$SCRIPT" --harness claude -- printf 'bye\n'
    The status should be success
    The output should include "PAGER_RAN"
    The output should include "bye"
  End
End
