# Reconcile — land non-UX-validated work into master

Follow this when your silo work is **logic/test-validated** and does not need
human eyeball judgment (UX validation uses `validate.md` Mode B instead).

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

## Procedure

Run this from the agent's worktree (`$WT_ROOT/work-on-<silo>-<suffix>`), on
the `work-on-<silo>-<suffix>` branch, with all work committed.

```sh
LOCK="$(git rev-parse --git-common-dir)/silo-integration.lock"

exec 9>"$LOCK"

# 1. Mutual lock check — refuse if a UX session is active (don't block for it).
UX_LOCK="$(git rev-parse --git-common-dir)/silo-ux-session.lock"
if [ -e "$UX_LOCK" ]; then
  echo "UX session in progress ($UX_LOCK present). Wait for it to end." >&2
  exit 1
fi

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

# 8. Cleanup — commits are on master now.
git worktree remove "$WT_ROOT/master-work"
cd - >/dev/null
exec 9>&-   # release integration lock

# 9. Remove the agent's worktree + branch (branch -d refuses if unmerged).
git worktree remove "$WT_ROOT/work-on-<silo>-<suffix>"
git branch -d work-on-<silo>-<suffix>
```

## Why no auto-rebase

Rebasing the agent branch onto a moving master rewrites SHAs and, on conflict,
leaves a half-applied tree that automation can't safely resolve. Merge-with-
merge-commit preserves both histories; the human decides on conflict.
`--ff-only` on the clean case means automation can never accidentally create a
merge commit or overwrite diverged history. No `--force` anywhere.
