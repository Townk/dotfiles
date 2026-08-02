# Bug #4 — the AI-commit plan cache and pathspec handling.
#
# (a) STALE CACHE: claude/cursor accepted a cached plan purely on
#     `[[ -s "$cache_file" && force_refresh -eq 0 ]]` — the cache was never
#     bound to the git state it was generated for. Edit a planned file after a
#     dry-run, run normally, and the stale grouping/message staged the NEW
#     bytes. Scope flags weren't part of cache identity either. The fix binds
#     the cache to a `cagent::plan_fingerprint` (HEAD + scope + content
#     identity) and rejects a cache whose fingerprint no longer matches.
#
# (b) PATHSPEC MAGIC: `git add -- "${files[@]}"` stops OPTION parsing but does
#     NOT disable pathspec MAGIC, so a model-emitted `:(top,glob)**` (or
#     `:(exclude)`, …) expanded beyond the named files. The fix routes the
#     stage through `git --literal-pathspecs add`, so plan paths are literal.

# ─────────────────────────────────────────────────────────────────────────
# (b) cagent::stage_commit must not honour pathspec magic in plan paths.
# ─────────────────────────────────────────────────────────────────────────
Describe 'cagent::stage_commit pathspec magic (bug #4b)'
  Include home/dot_local/lib/commit-agent-common.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/pathspec"
    rm -rf "$SB"; mkdir -p "$SB"
    git -C "$SB" init -q
    git -C "$SB" config user.email t@example.com
    git -C "$SB" config user.name tester
    git -C "$SB" config commit.gpgsign false
    printf 'x\n' > "$SB/real.txt"
    git -C "$SB" add real.txt
    git -C "$SB" commit -qm init
    printf 'y\n' >> "$SB/real.txt"
    # Decoys a magic pathspec (`:(top,glob)**`) WOULD grab but the literal
    # name never should.
    printf 'SECRET\n' > "$SB/secret.env"
    printf 'evil\n'   > "$SB/evil.txt"
    PLAN="$SB/plan.json"
  }
  BeforeEach 'setup'

  # Run stage_commit in a subshell (so the cd never leaks) and report exactly
  # what ended up in the index.
  stage_then_list() (
    cd "$SB" || return 1
    cagent::stage_commit "$PLAN" 0 || true
    printf 'STAGED[%s]\n' "$(git diff --cached --name-only | paste -sd, -)"
  )

  It 'does not stage decoy files via a magic pathspec entry'
    printf '%s' '{"commits":[{"files":[":(top,glob)**"],"message":"m"}]}' > "$PLAN"
    When call stage_then_list
    The output should equal "STAGED[]"
    The stderr should be present
  End

  It 'still stages a literal, named path'
    printf '%s' '{"commits":[{"files":["real.txt"],"message":"m"}]}' > "$PLAN"
    When call stage_then_list
    The output should equal "STAGED[real.txt]"
  End
End

# ─────────────────────────────────────────────────────────────────────────
# (a) cagent::plan_fingerprint / cagent::cache_is_fresh — cache identity.
# ─────────────────────────────────────────────────────────────────────────
Describe 'cagent::cache_is_fresh cache binding (bug #4a)'
  Include home/dot_local/lib/commit-agent-common.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/fingerprint"
    rm -rf "$SB"; mkdir -p "$SB"
    git -C "$SB" init -q
    git -C "$SB" config user.email t@example.com
    git -C "$SB" config user.name tester
    git -C "$SB" config commit.gpgsign false
    printf 'one\n' > "$SB/file.txt"
    git -C "$SB" add file.txt
    git -C "$SB" commit -qm init
    printf 'two\n' >> "$SB/file.txt"
    CACHE="$SB/plan.json"
  }
  BeforeEach 'setup'

  # Write a cache whose stored fingerprint matches the CURRENT tree for the
  # given scope flag.
  build_cache() (
    cd "$SB" || return 1
    fp="$(cagent::plan_fingerprint "$1")"
    jq -n --arg fp "$fp" \
      '{fingerprint:$fp, commits:[{files:["file.txt"],message:"m"}]}' > "$CACHE"
  )

  check_fresh() ( cd "$SB" && cagent::cache_is_fresh "$CACHE" "$1" )

  It 'accepts an unchanged tree (cache fresh)'
    build_cache 0
    When call check_fresh 0
    The status should be success
  End

  It 'rejects the cache after a planned file is mutated'
    build_cache 0
    printf 'three\n' >> "$SB/file.txt"
    When call check_fresh 0
    The status should be failure
  End

  It 'rejects the cache when the scope flag changes'
    build_cache 0
    When call check_fresh 1
    The status should be failure
  End

  It 'rejects a cache with no stored fingerprint (legacy/bare)'
    printf '%s' '{"commits":[{"files":["file.txt"],"message":"m"}]}' > "$CACHE"
    When call check_fresh 0
    The status should be failure
  End
End

# ─────────────────────────────────────────────────────────────────────────
# (a) End-to-end: the claude/cursor workers must re-plan on a stale cache and
#     reuse it only when the tree + scope are unchanged.
# ─────────────────────────────────────────────────────────────────────────
Describe 'ai-commit cache binding end-to-end (bug #4a)'
  BINDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin"
  LIBDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    SANDBOX="$SHELLSPEC_TMPBASE/e2e"
    rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"

    FAKE_HOME="$SANDBOX/home"
    mkdir -p "$FAKE_HOME/.local"
    ln -s "$LIBDIR" "$FAKE_HOME/.local/lib"

    # Stub agent: records each invocation and writes a plan whose message
    # embeds the call number, so HEAD's subject reveals WHICH plan executed.
    STUBDIR="$SANDBOX/stub"
    mkdir -p "$STUBDIR"
    CALLS="$SANDBOX/calls"
    : > "$CALLS"
    for name in claude cursor-agent; do
      cat > "$STUBDIR/$name" <<'STUB'
#!/bin/sh
n=$(( $(wc -l < "$CALLS" 2>/dev/null || echo 0) + 1 ))
echo "call" >> "$CALLS"
plan=$(printf '%s\n' "$@" | grep -oE '/[^ `"]*plan\.json' | head -1)
[ -n "$plan" ] || { echo "stub: no plan path in prompt" >&2; exit 1; }
printf '{"commits":[{"files":["file.txt"],"message":"chore: plan call %s"}]}' "$n" > "$plan"
printf 'PLAN_WRITTEN\n'
STUB
      chmod +x "$STUBDIR/$name"
    done

    # cursor worker refuses to run without a readable commit skill.
    SKILL="$SANDBOX/skill.md"
    printf '# commit skill\n' > "$SKILL"

    REPO="$SANDBOX/repo"
    mkdir -p "$REPO"
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

  run_worker() {
    worker="$1"; shift
    ( cd "$REPO" \
      && HOME="$FAKE_HOME" \
         XDG_STATE_HOME="$FAKE_HOME/state" \
         XDG_CACHE_HOME="$FAKE_HOME/cache" \
         PATH="$STUBDIR:$PATH" \
         SPIN_PROGRESS=0 \
         CALLS="$CALLS" \
         AI_COMMIT_CLAUDE_BIN="$STUBDIR/claude" \
         AI_COMMIT_CURSOR_BIN="$STUBDIR/cursor-agent" \
         AI_COMMIT_CURSOR_SKILL_PATH="$SKILL" \
         zsh "$BINDIR/$worker" "$@" )
  }

  Describe 'ai-commit-claude'
    It 'forces a re-plan when a planned file changed after caching'
      run_worker executable_ai-commit-claude --dry-run >/dev/null 2>&1
      printf 'three\n' >> "$REPO/file.txt"
      When run run_worker executable_ai-commit-claude
      The status should be success
      The output should include "Planning commits with Claude"
      The output should include "chore: plan call 2"
      The output should not include "Using cached commit plan"
    End

    It 'reuses the cache when the tree is unchanged'
      run_worker executable_ai-commit-claude --dry-run >/dev/null 2>&1
      When run run_worker executable_ai-commit-claude
      The status should be success
      The output should include "Using cached commit plan"
      The output should include "chore: plan call 1"
      The output should not include "Planning commits with Claude"
    End

    It 'invalidates the cache when the scope flag changes'
      run_worker executable_ai-commit-claude --dry-run >/dev/null 2>&1
      When run run_worker executable_ai-commit-claude --untracked
      The status should be success
      The output should include "Planning commits with Claude"
      The output should include "chore: plan call 2"
      The output should not include "Using cached commit plan"
    End
  End

  Describe 'ai-commit-cursor'
    It 'forces a re-plan when a planned file changed after caching'
      run_worker executable_ai-commit-cursor --dry-run >/dev/null 2>&1
      printf 'three\n' >> "$REPO/file.txt"
      When run run_worker executable_ai-commit-cursor
      The status should be success
      The output should include "Planning commits with Cursor Agent"
      The output should include "chore: plan call 2"
      The output should not include "Using cached commit plan"
    End

    It 'reuses the cache when the tree is unchanged'
      run_worker executable_ai-commit-cursor --dry-run >/dev/null 2>&1
      When run run_worker executable_ai-commit-cursor
      The status should be success
      The output should include "Using cached commit plan"
      The output should include "chore: plan call 1"
      The output should not include "Planning commits with Cursor Agent"
    End
  End
End
