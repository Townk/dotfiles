# ai-commit worker parity: the pi worker runs on the same shared plan-cache
# machinery as claude/cursor (M1/M2 consolidation). Before this, the cache
# trio + --force-refresh existed only as per-worker copies in claude/cursor
# and the pi worker had neither — `ai-commit pi --force-refresh` died with
# "unknown flag" while its siblings accepted it.
#
# Harness (same shape as ai-commit-worker-failure_spec): fake $HOME resolving
# the shared lib, a stub `pi` that extracts the plan path from the prompt,
# writes a valid one-commit plan, and bumps an invocation counter.
Describe 'ai-commit-pi plan-cache parity'
  BINDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin"
  LIBDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    SANDBOX="$SHELLSPEC_TMPBASE/pi-parity"
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX"

    FAKE_HOME="$SANDBOX/home"
    mkdir -p "$FAKE_HOME/.local"
    ln -s "$LIBDIR" "$FAKE_HOME/.local/lib"

    export COUNT_FILE="$SANDBOX/invocations"
    : > "$COUNT_FILE"

    STUBDIR="$SANDBOX/stub"
    mkdir -p "$STUBDIR"
    cat > "$STUBDIR/pi" <<'SH'
#!/bin/sh
echo x >> "$COUNT_FILE"
plan=$(printf '%s' "$*" | grep -oE '/[^ `]*/plan\.json' | head -1)
printf '{"commits":[{"files":["file.txt"],"message":"test: stub plan"}]}' > "$plan"
SH
    chmod +x "$STUBDIR/pi"

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

  worker() {
    ( cd "$REPO" \
      && HOME="$FAKE_HOME" \
         XDG_STATE_HOME="$FAKE_HOME/state" \
         PATH="$STUBDIR:$PATH" \
         SPIN_PROGRESS=0 \
         zsh "$BINDIR/executable_ai-commit-pi" "$@" )
  }

  invocations() { wc -l < "$COUNT_FILE" | tr -d ' '; }

  It 'saves a plan cache on --dry-run'
    When run worker --dry-run
    The status should be success
    The output should include 'Planned 1 commit'
    The output should include 'saved commit plan cache'
  End

  It 'reuses the cached plan without re-invoking the agent'
    run_twice() { worker --dry-run >/dev/null 2>&1; worker --dry-run; }
    When run run_twice
    The status should be success
    The output should include 'Using cached commit plan'
    The result of function invocations should equal 1
  End

  It 'accepts --force-refresh and re-plans'
    run_refresh() { worker --dry-run >/dev/null 2>&1; worker --dry-run --force-refresh; }
    When run run_refresh
    The status should be success
    The output should include 'Planned 1 commit'
    The result of function invocations should equal 2
  End

  It 'still accepts the pi-specific --thinking flag through the shared parser'
    When run worker --dry-run --thinking low
    The status should be success
    The output should include 'thinking: low'
  End
End
