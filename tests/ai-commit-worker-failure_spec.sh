# HI-3: an AI-commit worker must surface a diagnostic (and a log pointer) when
# its agent binary fails — not exit silently.
#
# Each worker runs `set -eu -o pipefail`. The status capture was written as a
# bare command, not in a condition context:
#
#     wait "$pid"; rc=$?                       # background/non-verbose branch
#     "$BIN" ... | tee -a "$log"; rc=${pipestatus[1]}   # verbose branch
#
# so a non-zero agent trips ERR_EXIT and aborts the script BEFORE rc is
# assigned. In default (non-verbose) mode the agent's output is already
# redirected to the log, so the user sees the spinner and then nothing: no
# error, no "see <log>" pointer. The `die "... failed (see <log>)"` line is
# unreachable.
#
# These specs stub the agent binary to exit non-zero and assert the worker
# (a) exits non-zero AND (b) prints the "failed (see <log>)" diagnostic — i.e.
# the die is now reached — in BOTH the non-verbose and verbose paths.
Describe 'ai-commit worker agent-failure handling (HI-3)'
  BINDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin"
  LIBDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    SANDBOX="$SHELLSPEC_TMPBASE/hi3"
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX"

    # Fake $HOME whose .local/lib resolves the worker's
    #   source "$HOME/.local/lib/commit-agent-common.zsh"
    FAKE_HOME="$SANDBOX/home"
    mkdir -p "$FAKE_HOME/.local"
    ln -s "$LIBDIR" "$FAKE_HOME/.local/lib"

    # Stubs: a failing agent, plus a `pi` (the pi worker calls it by name).
    STUBDIR="$SANDBOX/stub"
    mkdir -p "$STUBDIR"
    printf '#!/bin/sh\nexit 3\n' > "$STUBDIR/agent-fail"
    printf '#!/bin/sh\nexit 3\n' > "$STUBDIR/pi"
    chmod +x "$STUBDIR/agent-fail" "$STUBDIR/pi"

    # The cursor worker refuses to run without a readable code-commit skill.
    SKILL="$SANDBOX/skill.md"
    printf '# commit skill\n' > "$SKILL"

    # A git repo with one tracked, unstaged modification so the worker reaches
    # the agent-invocation block (have_modified=1, nothing staged).
    REPO="$SANDBOX/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name tester
    printf 'one\n' > "$REPO/file.txt"
    git -C "$REPO" add file.txt
    git -C "$REPO" -c commit.gpgsign=false commit -qm init
    printf 'two\n' >> "$REPO/file.txt"
  }
  BeforeEach 'setup'

  # Invoke a worker from inside the repo with a failing agent and no spinner.
  worker() {
    worker_name="$1"; shift
    ( cd "$REPO" \
      && HOME="$FAKE_HOME" \
         XDG_STATE_HOME="$FAKE_HOME/state" \
         XDG_CACHE_HOME="$FAKE_HOME/cache" \
         PATH="$STUBDIR:$PATH" \
         SPIN_PROGRESS=0 \
         AI_COMMIT_CLAUDE_BIN="$STUBDIR/agent-fail" \
         AI_COMMIT_CURSOR_BIN="$STUBDIR/agent-fail" \
         AI_COMMIT_CURSOR_SKILL_PATH="$SKILL" \
         zsh "$BINDIR/$worker_name" "$@" )
  }

  Describe 'ai-commit-claude'
    It 'reports the failure (non-verbose)'
      When run worker executable_ai-commit-claude
      The status should be failure
      The stderr should include "claude failed (see"
      The output should be present
    End
    It 'reports the failure (verbose)'
      When run worker executable_ai-commit-claude --verbose
      The status should be failure
      The stderr should include "claude failed (see"
      The output should be present
    End
  End

  Describe 'ai-commit-cursor'
    It 'reports the failure (non-verbose)'
      When run worker executable_ai-commit-cursor
      The status should be failure
      The stderr should include "cursor-agent failed (see"
      The output should be present
    End
    It 'reports the failure (verbose)'
      When run worker executable_ai-commit-cursor --verbose
      The status should be failure
      The stderr should include "cursor-agent failed (see"
      The output should be present
    End
  End

  Describe 'ai-commit-pi'
    It 'reports the failure (non-verbose)'
      When run worker executable_ai-commit-pi
      The status should be failure
      The stderr should include "pi-coding-agent failed (see"
      The output should be present
    End
    It 'reports the failure (verbose)'
      When run worker executable_ai-commit-pi --verbose
      The status should be failure
      The stderr should include "pi-coding-agent failed (see"
      The output should be present
    End
  End
End
