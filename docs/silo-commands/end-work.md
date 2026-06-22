---
description: End a /work-on-<silo> session — integrate the agent's worktree branch to master via the reconcile skill
argument-hint: [<silo> <suffix>]
---
You are closing out a `/work-on-<silo>` session: landing the completed work on
the agent's `work-on-<silo>-<suffix>` branch back onto `master`.

`/end-work` is the symmetric counterpart to `/work-on-<silo>`: the setup
command branches off master into an isolated worktree; this command integrates
that branch back onto master. It does so by loading the **`reconcile`** skill
— the `flock`-gated, ff-only-automated / divergence-human-gated integration
procedure with `make test` run under the lock.

## When to use this command vs. the `validate` skill

- **`/end-work` (this command)** — the work is **logic/test-validated** and
  does not need human eyeball judgment. Load the `reconcile` skill and follow
  it. This is the default end-of-session path.
- **`validate` skill Mode B** — the work needs eyeball judgment (neovim UX, a
  new zsh widget, a zellij layout, a picker's feel). Do **not** run `/end-work`;
  instead load the `validate` skill and run Mode B — the UX session *is* the
  integration for human-validated work, so there is no separate `/end-work`
  step after it.

If you are unsure which applies, ask the user before proceeding.

## Resolve the silo + suffix

The `reconcile` skill's procedure is parameterized by `<silo>` and `<suffix>`
(the branch is `work-on-<silo>-<suffix>`). Resolve them in this order:

1. **From the current branch (preferred).** If `git branch --show-current`
   matches `work-on-<silo>-<suffix>`, parse it. The suffix is the final
   `-<digits>` segment; the silo is everything between `work-on-` and that
   suffix. Silo names may contain hyphens (e.g. `system-packages`), so split
   on the *last* hyphen, not the first:
   ```sh
   branch=$(git branch --show-current)
   case "$branch" in
     work-on-*-*)
       rest=${branch#work-on-}
       suffix=${rest##*-}
       silo=${rest%-*}
       ;;
   esac
   ```
   This is the common case — the `/work-on-<silo>` setup left you inside the
   worktree on this branch.
2. **From `$ARGUMENTS`** (see the Arguments section below) if you are not on
   a `work-on-*` branch — e.g. you `cd`'d to the live tree. The arguments are
   `<silo> <suffix>`. If `<suffix>` is omitted and more than one
   `work-on-<silo>-*` worktree exists, list them (`git worktree list`) and ask
   the user which to integrate.
3. **If neither resolves a branch**, stop and tell the user — do not guess.

## Pre-flight

Before loading the `reconcile` skill:

- **Be in the agent worktree** on the `work-on-<silo>-<suffix>` branch. If you
  are not, `cd` into `$WT_ROOT/work-on-<silo>-<suffix>` where
  `WT_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/worktrees"`.
- **Commit any uncommitted work.** The `reconcile` skill re-runs
  `git commit -am "work-on-<silo>: finalize before integrate"` as a safety net,
  but stage and commit intentionally first — don't rely on the net.
- **Confirm the work is tested.** `make test` runs under the lock during
  integration; surfacing failures earlier is cheaper.

## Integrate

Load the **`reconcile`** skill and follow its full procedure, substituting the
resolved `<silo>` and `<suffix>` into every `work-on-<silo>-<suffix>`
placeholder (branch name, worktree path, commit message, merge/reflog
commands). Invoke the skill by:
- **pi:** `/skill:reconcile`
- **Claude Code:** `/reconcile`
- **or read its `SKILL.md`** at `docs/silo-commands/reconcile/SKILL.md`.

Do **not** short-circuit the skill. Run its procedure as a **single process**
(the `flock` serialization depends on the fd staying open for the whole
critical section), let it create the on-demand `master-work` worktree, perform
the ff-only merge (or report divergence for human review), run `make test`
under the lock, and clean up the agent worktree + branch on success.

## After integration

The `reconcile` skill leaves `master` advanced and the agent worktree + branch
removed. Report to the user:
- the new `master` tip (`git log -1 --oneline master`);
- whether `master` is ahead of `origin/master` — pushing is a separate,
  explicit step, so do **not** push unless the user asks;
- any divergence that needs human review (if the skill reported it).

## Arguments

$ARGUMENTS
