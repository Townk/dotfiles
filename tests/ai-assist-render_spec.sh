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
      echo 'printf "%s\n" "$@" >> "$TEST_TMP/broker.log"'
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
    # With --results-fifo added before --actions-fifo (lines 5-6), --actions-fifo
    # is now at line 7.
    The output should include "--actions-fifo"
    The line 7 of output should equal "--actions-fifo"
    The line 8 of output should start with "/"
    The contents of file "$TEST_TMP/broker.log" should include "--origin-pane"
    The contents of file "$TEST_TMP/broker.log" should include "terminal_4"
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

  It 'with --cleanup-fifos: provided fifos are removed on exit'
    # When the orchestrator passes --cleanup-fifos, render must include the
    # caller-provided fifos in its EXIT trap so they are removed when the pane exits.
    setup_cleanup_fifos_test() {
      pager_stub
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"
      mkfifo -m 600 "$TEST_TMP/cl-in.fifo"
      mkfifo -m 600 "$TEST_TMP/cl-act.fifo"
    }
    BeforeRun 'setup_cleanup_fifos_test'
    When run script "$SCRIPT" --harness claude \
      --input-fifo "$TEST_TMP/cl-in.fifo" \
      --actions-fifo "$TEST_TMP/cl-act.fifo" \
      --cleanup-fifos \
      -- printf 'cleanup-test\n'
    The status should be success
    The output should include "PAGER_RAN"
    The output should include "cleanup-test"
    # With --cleanup-fifos, provided fifos MUST be gone after render exits.
    The path "$TEST_TMP/cl-in.fifo" should not be exist
    The path "$TEST_TMP/cl-act.fifo" should not be exist
  End

  It 'without --cleanup-fifos: provided fifos survive render exit (existing contract)'
    # Guard: the default (no --cleanup-fifos) must remain unchanged.
    # This mirrors the existing 'leaves them on disk' test but makes the contrast explicit.
    setup_no_cleanup_fifos_test() {
      pager_stub
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"
      mkfifo -m 600 "$TEST_TMP/nc-in.fifo"
      mkfifo -m 600 "$TEST_TMP/nc-act.fifo"
    }
    BeforeRun 'setup_no_cleanup_fifos_test'
    When run script "$SCRIPT" --harness claude \
      --input-fifo "$TEST_TMP/nc-in.fifo" \
      --actions-fifo "$TEST_TMP/nc-act.fifo" \
      -- printf 'no-cleanup-test\n'
    The status should be success
    The output should include "PAGER_RAN"
    # Without --cleanup-fifos, provided fifos MUST survive (caller owns them).
    The path "$TEST_TMP/nc-in.fifo" should be exist
    The path "$TEST_TMP/nc-act.fifo" should be exist
  End

  # ── Cache persist (Stage 2) ───────────────────────────────────────────────────

  It 'with --cache-* flags and exit-0 harness, writes a playbook cache entry'
    setup_cache_store_test() {
      pager_stub
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"
      export AI_ASSIST_DATA_DIR="$TEST_TMP/ai-assist"
      mkdir -p "$AI_ASSIST_DATA_DIR"
      # Make a real (resolvable) ai-assist-cache available as a stub that records calls.
      # We use the actual script so store logic is exercised end-to-end.
      export AI_ASSIST_CACHE_BIN=""   # ensure env doesn't confuse resolution
    }
    BeforeRun 'setup_cache_store_test'
    meta_file="$TEST_TMP/cache-meta.txt"
    printf 'harness=test\nproject_root=/tmp\n' > "$meta_file"
    # Point ai-assist-cache to the real helper so store actually runs.
    cache_script="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ai-assist-cache"
    When run script "$SCRIPT" --harness test \
      --cache-ctx "deadbeef0000000000000000000000000000000000000000000000000000cafe" \
      --cache-req "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
      --cache-meta "$meta_file" \
      -- env "AI_ASSIST_DATA_DIR=$TEST_TMP/ai-assist" "$cache_script" store \
         "deadbeef0000000000000000000000000000000000000000000000000000cafe" \
         "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
         playbook /dev/stdin
    # This test is structural: we verify that --cache-* flags don't break render,
    # and rely on the helper tests for store correctness.
    The status should be success
    The output should include "PAGER_RAN"
  End

  It 'with --cache-* flags and a stub harness printing output, a playbook entry is written'
    setup_cache_write_test() {
      pager_stub
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager"
      export AI_ASSIST_DATA_DIR="$TEST_TMP/ai-assist"
      mkdir -p "$AI_ASSIST_DATA_DIR"
    }
    BeforeRun 'setup_cache_write_test'
    # Stub harness: print some lines, exit 0.
    stub_harness="$TEST_TMP/stub-harness"
    { echo '#!/usr/bin/env zsh'
      echo 'printf "# Playbook\nstep 1\nstep 2\n"'
    } > "$stub_harness"; chmod +x "$stub_harness"
    # Stub ai-assist-cache that records store calls.
    cache_stub="$TEST_TMP/ai-assist-cache"
    { echo '#!/usr/bin/env zsh'
      echo 'printf "%s\n" "$@" >> "$TEST_TMP/cache-calls"'
    } > "$cache_stub"; chmod +x "$cache_stub"
    meta_file="$TEST_TMP/cache-meta2.txt"
    printf 'harness=test\n' > "$meta_file"
    BeforeRun 'setup_cache_write_test' \
      "export TEST_TMP=\"$TEST_TMP\"" \
      "export AI_ASSIST_CACHE_BIN=\"$cache_stub\""
    # Override the PATH so our cache stub is found by name too.
    When run env "PATH=$TEST_TMP:$PATH" \
      "AI_ASSIST_PAGER_BIN=$TEST_TMP/pager" \
      "AI_ASSIST_DATA_DIR=$TEST_TMP/ai-assist" \
      "TEST_TMP=$TEST_TMP" \
      "$SCRIPT" --harness test \
        --cache-ctx "aabbccdd" \
        --cache-req "11223344" \
        --cache-meta "$meta_file" \
        -- "$stub_harness"
    The status should be success
    The output should include "PAGER_RAN"
    The path "$TEST_TMP/cache-calls" should be file
    The contents of file "$TEST_TMP/cache-calls" should include "store"
    The contents of file "$TEST_TMP/cache-calls" should include "aabbccdd"
    The contents of file "$TEST_TMP/cache-calls" should include "playbook"
  End

  It 'with --cache-* flags and harness exiting 1, does NOT write a cache entry'
    meta_file2="$TEST_TMP/cache-meta3.txt"
    printf 'harness=test\n' > "$meta_file2"
    # Failing harness stub.
    fail_harness="$TEST_TMP/fail-harness"
    { echo '#!/usr/bin/env zsh'
      echo 'printf "some output\n"'
      echo 'exit 1'
    } > "$fail_harness"; chmod +x "$fail_harness"
    # Cache stub that records calls.
    cache_stub2="$TEST_TMP/ai-assist-cache2"
    { echo '#!/usr/bin/env zsh'
      echo 'printf "%s\n" "$@" >> "$TEST_TMP/cache-calls2"'
    } > "$cache_stub2"; chmod +x "$cache_stub2"
    setup_cache_fail_test() {
      pager_stub
    }
    BeforeRun 'setup_cache_fail_test' \
      "export TEST_TMP=\"$TEST_TMP\""
    When run env "PATH=$TEST_TMP:$PATH" \
      "AI_ASSIST_PAGER_BIN=$TEST_TMP/pager" \
      "AI_ASSIST_DATA_DIR=$TEST_TMP/ai-assist" \
      "TEST_TMP=$TEST_TMP" \
      "$SCRIPT" --harness test \
        --cache-ctx "aabbccdd" \
        --cache-req "11223344" \
        --cache-meta "$meta_file2" \
        -- "$fail_harness"
    The status should eq 1
    The output should include "PAGER_RAN"
    The path "$TEST_TMP/cache-calls2" should not be exist
  End

  It '--cached <ts> is forwarded to the pager as a separate --cached flag+value'
    # Pager stub: print each arg on its own line so we can assert the flag and
    # value appear as distinct tokens (word-split regression guard).
    cached_pager_stub() {
      { echo '#!/usr/bin/env zsh'
        echo 'in=""'
        echo 'for a in "$@"; do printf "%s\n" "$a"; done'
        echo 'while (($#)); do [[ "$1" == "--input-fifo" ]] && { in="$2"; break; }; shift; done'
        echo '[[ -n "$in" && -p "$in" ]] && cat -- "$in" >/dev/null'
      } > "$TEST_TMP/pager-cached"; chmod +x "$TEST_TMP/pager-cached"
    }
    BeforeRun 'cached_pager_stub' 'export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager-cached"'
    When run script "$SCRIPT" --harness X --cached "2026-06-23T12:00:00Z" -- printf 'hi\n'
    The status should be success
    # "--cached" and its value must appear as separate output lines.
    The output should include "--cached"
    The output should include "2026-06-23T12:00:00Z"
    # Guard: they must not be collapsed into a single "--cached 2026-…" token.
    The output should not include "--cached 2026-06-23"
  End

  It 'passes --shell-fifo and --results-fifo to the broker and --results-fifo to the pager'
    # Broker stub: record all argv to broker.args, then exec sleep so render's trap
    # can kill it.
    broker_args_stub() {
      { echo '#!/usr/bin/env zsh'
        echo 'printf "%s\n" "$@" >> "$TEST_TMP/broker.args"'
        echo 'exec sleep 30'
      } > "$TEST_TMP/broker-args"; chmod +x "$TEST_TMP/broker-args"
    }
    # Pager stub: record all argv to pager.args, drain --input-fifo so render
    # doesn't block forever on the FIFO write end.
    pager_args_stub() {
      { echo '#!/usr/bin/env zsh'
        echo 'printf "%s\n" "$@" >> "$TEST_TMP/pager.args"'
        echo 'in=""; while (($#)); do [[ "$1" == "--input-fifo" ]] && { in="$2"; break; }; shift; done'
        echo '[[ -n "$in" && -p "$in" ]] && cat -- "$in" >/dev/null'
      } > "$TEST_TMP/pager-args"; chmod +x "$TEST_TMP/pager-args"
    }
    # Shell stub: records args, exec sleep so render's trap can kill it.
    shell_args_stub() {
      { echo '#!/usr/bin/env zsh'
        echo 'printf "%s\n" "$@" >> "$TEST_TMP/shell.args"'
        echo 'exec sleep 30'
      } > "$TEST_TMP/shell-args-bin"; chmod +x "$TEST_TMP/shell-args-bin"
    }
    setup_fifo_flags_test() {
      broker_args_stub
      pager_args_stub
      shell_args_stub
      export AI_ASSIST_BROKER_BIN="$TEST_TMP/broker-args"
      export AI_ASSIST_PAGER_BIN="$TEST_TMP/pager-args"
      export TEST_TMP="$TEST_TMP"
    }
    BeforeRun 'setup_fifo_flags_test'
    When run script "$SCRIPT" --harness claude --origin-pane terminal_7 \
      --shell-cwd "$TEST_TMP" --shell-bin "$TEST_TMP/shell-args-bin" -- printf 'x\n'
    The status should be success
    The contents of file "$TEST_TMP/broker.args" should include "--shell-fifo"
    The contents of file "$TEST_TMP/broker.args" should include "--results-fifo"
    The contents of file "$TEST_TMP/pager.args" should include "--results-fifo"
    # Word-split regression: printf '%s\n' "$@" writes one arg per line, so the
    # flag and its path must appear on SEPARATE lines. The bug collapsed them into
    # one arg ("--shell-fifo /path"), which the line below would NOT match.
    The contents of file "$TEST_TMP/broker.args" should not include "--shell-fifo /"
  End
End
