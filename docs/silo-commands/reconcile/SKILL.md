---
name: reconcile
description: Land non-UX-validated silo work into master. Use after completing a /work-on-<silo> task whose changes are logic/test-validated and don't need human eyeball judgment. Serialized by flock against concurrent integrations and UX sessions; ff-only automated merge when master hasn't moved, divergence human-gated, make test run under the lock before master advances.
---

# Reconcile — land non-UX-validated work into master

Follow this when your silo work is **logic/test-validated** and does not need
human eyeball judgment (UX validation uses the `validate` skill, Mode B, instead).

The procedure is serialized by `flock` so concurrent integrations (and UX
sessions) can't interleave and poison each other's test runs. `master` is
**never** auto-rebased and **never** force-updated.

## Resolve `flock` (util-linux is keg-only on macOS)

```sh
FLOCK="$(command -v flock || echo "$(brew --prefix util-linux 2>/dev/null || echo /opt/homebrew/opt/util-linux)/bin/flock")"
[ -x "$FLOCK" ] || { echo "flock not found — brew install util-linux" >&2; exit 1; }
```

## Worktree root

```sh
WT_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/worktrees"
mkdir -p "$WT_ROOT"
```

## Lock dir

The flock lockfiles live under the chezmoi **state** dir (machine-local
runtime locks, not repo content) — **not** in `.git/`. They are 2 fixed-path
0-byte fixtures, reused every run; they are never unlinked (unlinking a
flock lockfile breaks mutual exclusion under concurrency — two processes
end up holding "the lock" on different inodes). `mkdir -p` the dir once.

```sh
LOCKS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/locks"
mkdir -p "$LOCKS_DIR"
```

## Procedure

**Run this as a single shell script / single process.** `flock` only
holds the lock for the lifetime of the process that opened the file
descriptor — if you run the steps across separate shell invocations, the
lock silently releases between them and the serialization is lost. The
entire critical section (acquire → create master-work → merge → test →
cleanup → release) must be one process. Save the block below as a script,
substitute your silo name + suffix, and run it once.

Run this from the agent's worktree
(`$WT_ROOT/work-on-<silo>-<suffix>`), on the `work-on-<silo>-<suffix>`
branch, with all work committed.

```sh
LOCK="$LOCKS_DIR/silo-integration.lock"

exec 9>"$LOCK"

# 1. Mutual lock check — refuse if a UX session is active (don't block for it).
#    Probe the lock STATE, not the lockfile's existence: `flock` does not
#    remove the lockfile on release, so `[ -e ]` would false-positive on a
#    stale file left by a crashed run and block all future integrations.
#    `flock -n` returns non-zero immediately if the lock is held; it succeeds
#    on a free lock (including a stale-but-unlocked file). Release the probe
#    fd right after — we only wanted to check, not hold.
UX_LOCK="$LOCKS_DIR/silo-ux-session.lock"
exec 8>"$UX_LOCK"
if ! "$FLOCK" -n 8; then
  echo "UX session in progress. Wait for it to end." >&2
  exit 1
fi
exec 8>&-

# 2. Acquire the integration lock (blocking — integration is our purpose).
"$FLOCK" 9 || { echo "could not acquire integration lock" >&2; exit 1; }

# 3. Commit any uncommitted work on the agent branch.
git commit -am "work-on-<silo>: finalize before integrate" 2>/dev/null || true

# 4. Learn the current state of master. Never rebase, never move master blindly.
git fetch origin master
local_ahead=$(git rev-list --count master..HEAD)        # agent's new commits
master_ahead=$(git rev-list --count HEAD..master)       # commits master gained

# 5. Create on-demand master-work checkout.
if [ -e "$WT_ROOT/master-work" ]; then
  echo "$WT_ROOT/master-work exists — another integration is mid-flight." >&2
  echo "The flock should have prevented this. Refusing to proceed." >&2
  exit 1
fi
git worktree add "$WT_ROOT/master-work" master
cd "$WT_ROOT/master-work"

# 6. Merge.
if [ "$master_ahead" -eq 0 ]; then
  # Master hasn't moved → clean fast-forward. Safe to automate.
  git merge --ff-only work-on-<silo>-<suffix>
elif [ "$local_ahead" -eq 0 ]; then
  echo "Nothing to integrate (agent made no commits beyond master)." >&2
  git worktree remove "$WT_ROOT/master-work"
  exit 0
else
  # Master moved while the agent worked. Do NOT auto-resolve.
  echo "master has advanced by $master_ahead commits since this branch started." >&2
  echo "Review manually:" >&2
  echo "  git log --oneline master..work-on-<silo>-<suffix>   # agent's commits" >&2
  echo "  git diff master...work-on-<silo>-<suffix>           # what would land" >&2
  echo "Then either:" >&2
  echo "  git merge work-on-<silo>-<suffix>                   # merge commit" >&2
  echo "  # or, if you prefer linear history and there are no conflicts:" >&2
  echo "  git rebase work-on-<silo>-<suffix> master && git checkout master" >&2
  git worktree remove "$WT_ROOT/master-work"
  exit 1
fi

# 7. make test under the lock. Master advances only after tests pass.
make test
test_rc=$?
if [ "$test_rc" -ne 0 ]; then
  # Roll back BEFORE releasing the lock so the next agent sees a clean master.
  git reset --hard ORIG_HEAD 2>/dev/null || git reset --hard master@{1}
  git worktree remove "$WT_ROOT/master-work"
  cd - >/dev/null
  echo "make test failed ($test_rc); master NOT advanced. Rolled back." >&2
  exit "$test_rc"
fi

# 8. Remove the agent WORKTREE first. This releases the branch checkout
#    so step 9 can delete it. Run `git worktree remove` with the absolute
#    path WHILE STILL IN master-work (a valid worktree) — do NOT `cd` to
#    $WT_ROOT first, because $WT_ROOT is not a worktree and `git` commands
#    would fail with "not a git repository" there.
git worktree remove "$WT_ROOT/work-on-<silo>-<suffix>"

# 9. Delete the agent BRANCH. Still inside master-work (HEAD is master),
#    so `git branch -d` sees the branch as merged and succeeds. Two
#    constraints make the order matter: (a) `-d` refuses if the branch is
#    checked out in any worktree — so the agent worktree (step 8) must be
#    gone first; (b) `-d` refuses if the branch isn't merged into the current
#    HEAD — so this must run with HEAD=master (from master-work, NOT from
#    the live tree which may be on a feature branch).
git branch -d work-on-<silo>-<suffix>

# 10. Remove master-work. We're standing in it, so cd to its parent first
#     (or the live tree) — `git worktree remove` refuses to remove the
#     worktree you're inside.
cd "$HOME/.local/share/chezmoi"
git worktree remove "$WT_ROOT/master-work"

# 11. Release the integration lock (fd 9 closes).
exec 9>&-
```

## When `master` is already checked out in the live tree

Step 5's `git worktree add "$WT_ROOT/master-work" master` **fails** if
`master` is already checked out in any other worktree — and in this repo
the live tree at `~/.local/share/chezmoi` normally sits on `master`, so
this is the *common* state here, not an edge case. The failure is loud:

```
fatal: 'master' is already used by worktree at '/Users/thiago/.local/share/chezmoi'
```

Two independent problems compound that failure if you let the script
continue (the canonical block above has no `set -e`):

- `cd "$WT_ROOT/master-work"` then fails (no such directory), so the
  subsequent `git merge --ff-only` runs **in the agent worktree** (HEAD
  is the agent branch, not `master`) and merges nothing;
- `make test` runs in the agent worktree, not against advanced `master`;
- `git worktree remove` of the agent worktree succeeds, but
  `git branch -d` correctly refuses (the branch isn't merged into `master`),
  so the agent commit survives — `master` was never advanced.

**Recover by ff-merging in the live tree directly.** Only do this when the
live tree is on `master` with no **tracked** modifications (an untracked
scratch dir like `docs/plans/` is fine — a fast-forward doesn't touch it).
Run it as one process under the same `flock`, substituting `<silo>` and
`<suffix>`:

```sh
# Acquire the integration lock exactly as in the main procedure (steps 1-2):
# exec 9>"$LOCKS_DIR/silo-integration.lock"; UX-check on fd 8; flock 9.

cd "$HOME/.local/share/chezmoi"

# Guard: live tree must be on master with no tracked modifications.
[ "$(git branch --show-current)" = master ] || { echo "live tree not on master" >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "live tree has tracked mods" >&2; exit 1; }

git fetch origin master
local_ahead=$(git rev-list --count master..work-on-<silo>-<suffix>)
master_ahead=$(git rev-list --count work-on-<silo>-<suffix>..master)

if [ "$master_ahead" -eq 0 ] && [ "$local_ahead" -gt 0 ]; then
  git merge --ff-only work-on-<silo>-<suffix>
elif [ "$local_ahead" -eq 0 ]; then
  echo "Nothing to integrate." >&2; exit 0
else
  echo "master advanced by $master_ahead — divergence, review manually." >&2; exit 1
fi

make test
test_rc=$?
if [ "$test_rc" -ne 0 ]; then
  git reset --hard ORIG_HEAD 2>/dev/null || git reset --hard master@{1}
  echo "make test failed ($test_rc); master NOT advanced. Rolled back." >&2
  exit "$test_rc"
fi

# Remove the agent WORKTREE first (releases the branch checkout), then
# delete the branch. We're in the live tree (HEAD=master), so `git branch -d`
# sees the branch as merged. Order matters for the same reasons as steps 8-9.
git worktree remove "$WT_ROOT/work-on-<silo>-<suffix>"
git branch -d work-on-<silo>-<suffix>

exec 9>&-
```

No `master-work` worktree is created or removed in this variant, so skip
canonical steps 5 (create `master-work`) and 10 (remove `master-work`).
Everything else — lock acquisition, UX mutual-exclusion, `--ff-only`,
`make test` under the lock, rollback on test failure, agent-worktree
removal (step 8), branch deletion (step 9) — is identical.

If `master` is checked out in a worktree that is **not** the live tree, or
the live tree has tracked modifications, do **not** ff-merge in place —
stash/commit or move master first, then re-run the canonical procedure.

## Why no auto-rebase

Rebasing the agent branch onto a moving master rewrites SHAs and, on conflict,
leaves a half-applied tree that automation can't safely resolve. Merge-with-
merge-commit preserves both histories; the human decides on conflict.
`--ff-only` on the clean case means automation can never accidentally create a
merge commit or overwrite diverged history. No `--force` anywhere.
