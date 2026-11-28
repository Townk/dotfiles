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

# Prompt parity. The planning prompt is behaviour — it is what the model is
# told — and the three per-worker copies had drifted: pi had lost the "Do not
# include files outside the requested scope" rule, the write-operation ban and
# `git log`, and worded the path rule differently. The body now lives once in
# cagent::plan_prompt; each worker passes only its conventions paragraph and
# its tool wording. These examples render each worker's REAL prompt (a stub
# agent saves its last argument) and check that the shared rules reached the
# agent, that the worker's own preamble survived, and that the rule section is
# byte-identical across the three.
Describe 'ai-commit worker prompt parity'
  BINDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin"
  LIBDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    SANDBOX="$SHELLSPEC_TMPBASE/prompt-parity"
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX"

    FAKE_HOME="$SANDBOX/home"
    mkdir -p "$FAKE_HOME/.local"
    ln -s "$LIBDIR" "$FAKE_HOME/.local/lib"

    # Stub agent: save the prompt (always the last argument), then write a
    # valid plan where the prompt says to so the worker finishes cleanly.
    STUBDIR="$SANDBOX/stub"
    mkdir -p "$STUBDIR"
    cat > "$STUBDIR/agent" <<'SH'
#!/bin/sh
for arg; do prompt=$arg; done
printf '%s\n' "$prompt" > "$PROMPT_OUT"
plan=$(printf '%s' "$prompt" | grep -oE '/[^ `]*/plan\.json' | head -1)
printf '{"commits":[{"files":["file.txt"],"message":"test: stub plan"}]}' > "$plan"
SH
    chmod +x "$STUBDIR/agent"
    cp "$STUBDIR/agent" "$STUBDIR/pi"

    SKILL="$SANDBOX/code-commit-skill.md"
    printf '# commit skill\n' > "$SKILL"

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

  # render <worker> [args…] — run the worker against the stub agent; its
  # prompt lands in $SANDBOX/prompt-<worker>.
  render() {
    render_name="$1"; shift
    ( cd "$REPO" \
      && HOME="$FAKE_HOME" \
         XDG_STATE_HOME="$FAKE_HOME/state" \
         PATH="$STUBDIR:$PATH" \
         SPIN_PROGRESS=0 \
         AI_COMMIT_CLAUDE_BIN="$STUBDIR/agent" \
         AI_COMMIT_CURSOR_BIN="$STUBDIR/agent" \
         AI_COMMIT_CURSOR_SKILL_PATH="$SKILL" \
         PROMPT_OUT="$SANDBOX/prompt-$render_name" \
         zsh "$BINDIR/executable_ai-commit-$render_name" --dry-run --force-refresh "$@" ) >/dev/null 2>&1
  }

  # show <worker> [args…] — render, then print the prompt the agent received.
  show() {
    render "$@" || return 1
    cat "$SANDBOX/prompt-$1"
  }

  # Every rule each agent must be told, whatever the worker. Prints the rules
  # MISSING from <worker>'s rendered prompt, one per line (nothing = all there).
  # (No rule line may start with a shellspec DSL word such as `The`: the
  # translator rewrites it even inside a here-document.)
  missing_shared_rules() {
    render "$1" || { echo "render of $1 failed"; return 1; }
    # The worker names the root as git resolves it (symlinks, `//` collapsed).
    repo_root="$(git -C "$REPO" rev-parse --show-toplevel)"
    while IFS= read -r rule; do
      grep -qF -- "$rule" "$SANDBOX/prompt-$1" || printf 'missing: %s\n' "$rule"
    done <<RULES
You are PLANNING a series of git commits for the repository at:
\`$repo_root\`
or other write operation in the repository.
only file you may create or modify is the JSON plan file below:
\`git log\`, and per-file reads as needed. Scope: modified (tracked) files only.
commit when changes are coherent; only split when topics are
"files": ["relative/path/one", "relative/path/two"],
exactly as \`git status --short\` would
- Every in-scope changed file must appear in exactly one commit's
- Do not include files outside the requested scope.
- Do NOT add a \`Co-Authored-By\`, \`Signed-off-by\`, or any AI/agent
- Do NOT stage. Do NOT commit. Do NOT push.
- When you are done, reply with the literal text \`PLAN_WRITTEN\` and
RULES
  }

  Describe 'shared rules'
    Parameters
      claude
      cursor
      pi
    End

    It "reach the $1 agent in full"
      When call missing_shared_rules "$1"
      The status should be success
      The output should equal ''
    End
  End

  It 'keeps the claude preamble: plain Conventional Commits and the Write tool'
    When call show claude
    The status should be success
    The output should include 'Follow Conventional Commits conventions for every message'
    The output should include '4. Use the Write tool to save the plan as JSON at the absolute path'
  End

  It 'keeps the cursor preamble: the code-commit skill it must read'
    When call show cursor
    The status should be success
    The output should include 'Before planning, read and follow the Cursor Agent skill at:'
    The output should include "$SKILL"
    The output should include 'draft a polished message per the code-commit skill'
    The output should include '4. Write the plan as JSON at the absolute path'
  End

  It 'keeps the pi preamble: the project commit skill and the Write tool'
    When call show pi
    The status should be success
    The output should include "Use the project's **commit** skill for message-format conventions"
    The output should include 'draft a polished message per the commit skill'
    The output should include '4. Use the **Write** tool to save the plan as JSON at the absolute path'
  End

  It 'widens the scope clause and appends caller guidance in every worker'
    scoped() {
      for scoped_w in claude cursor pi; do
        show "$scoped_w" -u -- only docs JIRA-1 || return 1
      done | grep -cE '^(   .*Scope: modified files AND untracked files\.|only docs JIRA-1)$'
    }
    When call scoped
    The output should equal 6
  End

  It 'gives all three workers a byte-identical rule section'
    # Everything from "Rules:" on carries no per-worker text, so any
    # difference here is drift.
    rules_of() { sed -n '/^Rules:$/,$p' "$SANDBOX/prompt-$1"; }
    distinct_rule_sections() {
      for distinct_w in claude cursor pi; do
        render "$distinct_w" || return 1
        rules_of "$distinct_w" | cksum
      done | sort -u | wc -l | tr -d ' '
    }
    When call distinct_rule_sections
    The output should equal 1
  End
End
