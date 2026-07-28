---
description: Dispatch an agent to a feature that spans several silos, in one isolated worktree
argument-hint: <silo>+<silo>[+…] <task description>
---
You are working on a feature that **spans several silos** of this chezmoi
dotfiles repo.

> `/work-on clipboard+terminal-mux add a W opcode for window actions`
>
> The first argument is the silo set, `+`-joined, no spaces. Everything after
> it is the task.

Use this when the work's substance is the **seam** between silos — a new
opcode, a shared file format, a side-channel both ends must agree on. If you
can describe the change without naming two silos, the single-silo command
gives you a better briefing: use `/work-on-<silo>` instead.

## 1. Parse and echo back

Split `$ARGUMENTS` on the first space: the leading token is the `+`-joined
silo set, the remainder is the task.

The set is one token on purpose. Silo names are ordinary English words —
`theme`, `pick`, `preview`, `shell`, `pi`, `cursor`, `utils`, `secrets` — so
space-separated names cannot be told from the start of a task description
(`pick preview shell out to X` has three readings). `+` removes the guess.

**Say what you parsed before doing anything**, so a mis-parse costs a
sentence rather than a worktree:

> Claiming **clipboard** + **terminal-mux**. Task: *add a W opcode for window
> actions*.

## 2. Validate the names

Every name must be one of:

`ai-harnesses` `chezmoi` `clipboard` `cursor` `custom-builds` `hammerspoon`
`neovim` `pi` `pick` `preview` `secrets` `shell` `system-backup`
`system-images` `system-packages` `system-services` `system-update`
`terminal-mux` `theme` `utils` `yazi`

- **Unknown name** → stop and ask. A typo silently claims nothing, which
  means the boundary that was supposed to be protected isn't.
- **Only one name** → stop and point at `/work-on-<silo>`. That template
  carries the silo's owner area, contracts and out-of-scope list *inline*;
  this one cannot (see step 4), so a single-silo task is strictly better
  served there.
- **Four or more** → say so before proceeding. Three is already a smell; four
  usually means the feature is two features, or a boundary is in the wrong
  place. Proceed only if the human confirms.

## 3. Load the `cross-silo` skill and follow it

The procedure lives there, not here — invoke `/skill:cross-silo` in pi,
`/cross-silo` in Claude Code, or read
`docs/silo-commands/cross-silo/SKILL.md`. It owns:

- the **claim check** (`git worktree list` — another agent already in one of
  your silos is the collision the model exists to prevent),
- the **branch and worktree** (`cross-silo-<a>+<b>-<suffix>` — the branch name
  *is* the claim, which is why the set is `+`-joined here too),
- **contract first**, then both halves — two halves written from one statement
  agree; two written from each other's code agree only until one is edited,
- the **version-skew question** (what does an old peer do with the new thing?),
- **verifying the seam**, not the halves.

## 4. Read your briefings — they are not in this file

A per-silo command hands you that silo's owner area, contracts, consume-list
and out-of-scope inline. This one can't: there are 21 silos, so 210 pairs and
1,330 triples, and none of that can be pre-written.

So go and read, for **each** silo in your set, its section in
[`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — owner area, "Public
contract (preserve)", and "Out of scope". Skipping this is how a cross-silo
task turns into an edit in a silo nobody claimed.

Inside your declared set, edit freely. Outside it, **stop and ask**: an
unclaimed silo's owner area is exactly as off-limits here as it would be from
a single-silo task.

## TASK

$ARGUMENTS

## Validate & integrate
- **Self-test (logic):** load the `validate` skill (Agent Skill — invoke
  `/skill:validate` in pi, `/validate` in Claude Code, or read its `SKILL.md`)
  and run **Mode A** — sandbox-`$HOME`, parallel, no lock, no clobber of real
  `$HOME`.
- **Human UX validation:** if the work needs eyeball judgment, ask the user
  whether to enter a UX session, then load the `validate` skill and run
  **Mode B** — the session merges your branch to master and you iterate live.
  The human is in the loop, so this is a human-decided integration.
- **Stop here — do not integrate.** A workflow started by `/work-on…` ends
  only when the human decides. Once your work is self-tested and committed on
  the `cross-silo-<set>-<suffix>` branch, **stop** and leave the branch parked
  in its worktree. Do **not** load the `reconcile` skill or merge to master
  yourself. The human closes the session by typing **`/end-work`**, which
  loads the `reconcile` skill and lands the branch on `master`
  (`flock`-gated, ff-only, `make test` under the lock). One branch, so nothing
  about integration differs from a single-silo task. Report that the branch is
  ready and stop.

## Verify before claiming done
- **Exercise the seam**, not each half. Two green halves prove nothing about
  the contract between them, and a half nothing calls yet passes *vacuously* —
  which reads as done.
- Run `make test` **and** the specs of every silo in your set.
- Add a spec that fails when the two halves drift apart. Asserting that both
  strings appear *somewhere* is not that spec — assert the pairing.
- Say plainly which side you drove and which you inferred. Inference is how a
  chord that "obviously" still worked went on typing a retired key.
- Report which silos you touched and which contract you added or changed, so
  the next agent in either silo knows what to keep working.

## Reference
`docs/silo-commands/cross-silo/SKILL.md` (the procedure),
`docs/chezmoi-silo-map.md` (every silo's owner area and contracts),
`docs/silo-commands/README.md` (the command index).
