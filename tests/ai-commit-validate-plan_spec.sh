# cagent::validate_plan — the shared AI-commit plan-shape contract.
#
# claude and cursor each carried a byte-identical private `validate_plan`
# enforcing that `.commits` is a non-empty array and every group has a
# non-empty `files` array and a non-empty `message` string. Hoisting it into
# `commit-agent-common.zsh` collapses the two copies (and, in a following
# change, gives the pi worker the predicate it was missing). These specs pin
# the contract so the hoisted function is a faithful replacement.

Describe 'cagent::validate_plan'
  Include home/dot_local/lib/commit-agent-common.zsh

  It 'rejects a group with no message key'
    plan="$SHELLSPEC_TMPBASE/no-message.json"
    printf '%s' '{"commits":[{"files":["a.txt"]}]}' > "$plan"
    When call cagent::validate_plan "$plan"
    The status should be failure
  End

  It 'rejects a group with an empty message string'
    plan="$SHELLSPEC_TMPBASE/empty-message.json"
    printf '%s' '{"commits":[{"message":"","files":["a.txt"]}]}' > "$plan"
    When call cagent::validate_plan "$plan"
    The status should be failure
  End

  It 'rejects a group with an empty files array'
    plan="$SHELLSPEC_TMPBASE/no-files.json"
    printf '%s' '{"commits":[{"message":"feat: x","files":[]}]}' > "$plan"
    When call cagent::validate_plan "$plan"
    The status should be failure
  End

  It 'accepts a well-formed plan'
    plan="$SHELLSPEC_TMPBASE/good.json"
    printf '%s' '{"commits":[{"message":"feat: x","files":["a.txt"]}]}' > "$plan"
    When call cagent::validate_plan "$plan"
    The status should be success
  End
End

Describe 'ai-commit-pi plan validation & repo-root staging (MED-7)'
  BINDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin"
  LIBDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    SANDBOX="$SHELLSPEC_TMPBASE/med7"
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX"

    # Fake $HOME whose .local/lib resolves the worker's
    #   source "$HOME/.local/lib/commit-agent-common.zsh"
    FAKE_HOME="$SANDBOX/home"
    mkdir -p "$FAKE_HOME/.local"
    ln -s "$LIBDIR" "$FAKE_HOME/.local/lib"

    # Stub `pi`: extract the plan-file path the worker embedded in the prompt
    # and write $PLAN_CONTENT to it, mimicking a successful planning run.
    STUBDIR="$SANDBOX/stub"
    mkdir -p "$STUBDIR"
    cat > "$STUBDIR/pi" <<'STUB'
#!/bin/sh
plan=$(printf '%s\n' "$@" | grep -oE '/[^ `"]*plan\.json' | head -1)
[ -n "$plan" ] || { echo "stub-pi: no plan path in prompt" >&2; exit 1; }
printf '%s' "$PLAN_CONTENT" > "$plan"
printf 'PLAN_WRITTEN\n'
STUB
    chmod +x "$STUBDIR/pi"

    REPO="$SANDBOX/repo"
    mkdir -p "$REPO/sub"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name tester
    git -C "$REPO" config commit.gpgsign false
    printf 'one\n' > "$REPO/file.txt"
    git -C "$REPO" add file.txt
    git -C "$REPO" commit -qm init
    printf 'two\n' >> "$REPO/file.txt"
  }
  BeforeEach 'setup'

  # Run the pi worker from $workdir with the stubbed agent + a given plan body,
  # then report the resulting HEAD subject so the assertions can see whether a
  # commit slipped through.
  run_pi() {
    workdir="$1"; content="$2"
    ( cd "$workdir" \
      && HOME="$FAKE_HOME" \
         XDG_STATE_HOME="$FAKE_HOME/state" \
         XDG_CACHE_HOME="$FAKE_HOME/cache" \
         PATH="$STUBDIR:$PATH" \
         SPIN_PROGRESS=0 \
         PLAN_CONTENT="$content" \
         zsh "$BINDIR/executable_ai-commit-pi" )
    rc=$?
    echo "HEAD_SUBJECT=$(git -C "$REPO" log -1 --pretty=%s)"
    return $rc
  }

  It 'rejects a message-less plan instead of committing subject "null"'
    When run run_pi "$REPO" '{"commits":[{"files":["file.txt"]}]}'
    The status should be failure
    The stderr should include "invalid plan"
    The output should include "HEAD_SUBJECT=init"
    The output should not include "HEAD_SUBJECT=null"
  End

  It 'stages against the repo root when run from a subdirectory'
    When run run_pi "$REPO/sub" '{"commits":[{"files":["file.txt"],"message":"chore: root file"}]}'
    The status should be success
    The output should include "HEAD_SUBJECT=chore: root file"
  End
End
