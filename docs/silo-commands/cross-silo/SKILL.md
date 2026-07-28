---
name: cross-silo
description: Start a feature that spans two or more silos. Use when the work's value IS a contract between silos — a new bridge opcode, a shared file format, a protocol both ends must agree on — so the halves cannot be written or tested apart. Claims a declared silo set in ONE worktree, checks for competing claims, and lands through the normal /end-work reconcile.
---

# Cross-silo — one feature, several owners

Use this when a feature's substance is the **seam** between silos: a new
opcode, a shared file format, a side-channel both ends must agree on. The
tell is simple — if you can describe the change without naming two silos, you
do not need this skill.

**Two ways in.** The human dispatches with `/work-on <a>+<b> <task>` when they
know up front; an agent already mid-task loads this skill directly on
discovering the work spans silos. Either way the procedure below is the same,
and step 1's declaration is already made for you in the first case.

## Why one worktree, not one per silo

The silo model exists to stop two *agents* colliding, not to stop one agent
spanning. A cross-silo feature is a single statement made in two places, and
splitting it into two worktrees costs you the only thing that matters:

- **You cannot test half a contract.** The `W` fullscreen opcode is one half
  in the clipboard dispatcher and one half in `terminal-toggle-fullscreen`.
  Either alone is unexercisable — the test that means anything sends a frame
  and watches a window move.
- **`make test` runs the whole suite.** A worktree holding half a feature
  either fails, or passes *vacuously* because nothing calls the new half yet.
  A vacuous pass is worse than a failure: it reads as done.
- **Two branches would have to land atomically.** `reconcile` is ff-only under
  a `flock`; making two branches land as one needs a merge train, which is a
  lot of machinery to arrive back where one branch already is.

So: **one worktree, a declared set of silos, one branch, the normal
`/end-work`.** What you give up is the implicit claim a `work-on-<silo>`
branch makes — so you make it explicit instead.

## 1. Declare the silo set

Name every silo you will edit, before you edit any of them. If the set grows
mid-task, **stop and re-declare** — a set that quietly widens is how a
"cross-silo feature" becomes a rewrite nobody reviewed.

Two silos is normal. Three is a smell worth saying out loud. Four means the
feature is probably two features, or the boundary is in the wrong place —
say so rather than pressing on.

## 2. Check for competing claims

An existing worktree for any silo in your set means another agent is already
there. That is the collision the silo model prevents; do not race it.

```sh
git worktree list | grep -E 'work-on-|cross-silo-'
```

If a listed worktree's branch names one of your silos, **stop and tell the
human** which branch holds it. Landing or parking that branch first is their
call, not yours.

## 3. Branch, naming the claim

```sh
git fetch origin master
ahead=$(git rev-list --count master..origin/master)
behind=$(git rev-list --count origin/master..master)
if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
  echo "master and origin/master diverged ($ahead ahead, $behind behind)." >&2
  echo "Reconcile master before dispatching. Stopping." >&2
  exit 1
elif [ "$ahead" -gt 0 ]; then base=origin/master; else base=master; fi

WT_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/worktrees"
mkdir -p "$WT_ROOT"
# SILOS: your declared set, '+'-joined, alphabetical — the branch name IS the claim
SILOS=clipboard+terminal-mux
suffix=$(date +%s)
git worktree add -b cross-silo-$SILOS-$suffix "$WT_ROOT/cross-silo-$SILOS-$suffix" "$base"
cd "$WT_ROOT/cross-silo-$SILOS-$suffix"
```

## 4. Write the contract first

Before either half: state the contract where the *owning* silo documents its
contracts — the opcode table, the schema doc, the silo map's "Public contract"
block. Then write both halves against that text.

This is not ceremony. Two halves written from one statement agree; two halves
written from each other's code agree only until one is edited. If the contract
is genuinely new, add it to `docs/chezmoi-silo-map.md` under the silo that
*owns* it, and say in the other silo's section that it consumes it.

**Version-skew question, always:** the two ends update on their own schedule.
What does an old peer do with the new thing? An unknown opcode must fail
loudly, a new field must be optional, a renamed key must keep its alias.
Answer this in writing, or you have shipped a break you cannot see from one
machine.

## 5. Respect the boundary you did not claim

Inside your declared set, edit freely. Outside it, **stop and ask** — the
neighbouring silo's owner area is exactly as off-limits as it would be from a
single-silo task. A consumer that merely follows your rename is usually
mechanical and fine to note in the report rather than perform.

## 6. Verify the seam, not the halves

Two green halves prove nothing about the contract between them.

- Exercise the seam end to end. If the far end is another machine, say plainly
  which side you drove and which side you inferred — inference is how a
  chord that "obviously" still worked went on typing a retired key.
- Run `make test`, and the specs of **every** silo in your set.
- Add a spec that fails if the two halves drift apart. A spec asserting both
  strings appear *somewhere* is not that spec: assert the pairing.

## 7. Land it

Nothing special — one branch, so the normal path applies. Stop when the work
is committed and self-tested, and leave the branch parked. The human types
**`/end-work`**, which loads the `reconcile` skill and lands it (`flock`-gated,
ff-only, `make test` under the lock).

Report which silos you touched and which contract you added or changed, so the
human knows what the next agent in either silo has to keep working.

## When NOT to use this

- **A consumer following a contract change** — that is the owning silo's task
  plus a mechanical ripple. Use `/work-on-<owner>` and list the ripple.
- **A shared file that already has an owner** — `common.zsh`, `notify`,
  `theme.yaml`. Editing them is that silo's job; you are a caller.
- **"It touches two directories."** Directories are not silos. If the second
  silo's *contract* is unchanged, you are working in one silo.
