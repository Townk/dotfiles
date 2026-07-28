---
description: Dispatch an agent to the Terminal Time Machine backup silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **system-backup (Terminal Time Machine)** silo of this
chezmoi dotfiles repo.

> Tiered, encrypted restic snapshots with a terminal UX for what Time Machine
> does with a GUI: browse a timeline, diff a rung against now, restore a path,
> undo the restore, and see drift from the declared state.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_system-backup`, `system-backup-capture`,
  `system-backup-reconcile`
- `home/dot_local/libexec/executable_system-backup-tm`, `executable_tm-tab`
- `home/dot_local/lib/backup.zsh`, `backup-tm.zsh`, `backup-drift.zsh`
- `home/dot_config/backup/`
- `home/dot_local/share/zsh/site-functions/_system-backup*` (completions)
- `docs/system-backup-recovery.md` — the recovery runbook. It is read by a
  human whose machine is broken; keep it literal and current.

## Out of scope (do not edit — owned by other silos)

- `restic` itself and the storage backends (external).
- The **scrub session's** terminal chrome — `tmux-popup`, `tmux-modal`,
  `pty-frame`, `diffnav` wiring → **terminal-mux** / **preview**. You own what
  a rung *is*; they own the window it is drawn in.
- Yazi's `g-t` entry point → **yazi** (it calls you).
- The launchd/systemd timer *definitions* → **system-services**.
- `home/dot_local/libexec/executable_tmux-alert-notify` → **terminal-mux**.

## Contracts you must preserve

- **The snapshot tiers and their retention** — the rungs a restore can land
  on. Changing tiering silently changes what "yesterday" means.
- **Apply/undo symmetry**: every restore records enough to be undone. A
  restore that cannot be undone is a bug, not a feature.
- **Drift reporting** (`backup-drift.zsh`) — the banner other tools show.
- **The recovery runbook is a contract too.** It is followed on a machine that
  may not have this repo checked out; every command in it must work from a
  bare shell with restic and the passphrase.

## What you consume read-only

- **secrets**: the repository passphrase / credentials
- **utils**: `notify`, `wait-until`, `common.zsh`
- **terminal-mux**: popup + modal chrome for the scrub session
- **preview**: file rendering inside a diff

## Where to start

`bin/system-backup` (the command surface), `lib/backup.zsh` (the engine),
`lib/backup-tm.zsh` (the timeline), `docs/system-backup-recovery.md`.

## Setup — branch from the freshest master tip into an isolated worktree
```sh
# 1. Learn what origin has. Updates origin/master only — does NOT move local
#    master or touch any other worktree. Safe to run anytime.
git fetch origin master

# 2. Find the freshest master tip, wherever it lives.
ahead=$(git rev-list --count master..origin/master)
behind=$(git rev-list --count origin/master..master)
if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
  echo "master and origin/master diverged ($ahead ahead, $behind behind)." >&2
  echo "Reconcile master before dispatching. Stopping." >&2
  exit 1
elif [ "$ahead" -gt 0 ]; then
  base=origin/master
else
  base=master
fi

# 3. Unique-suffixed branch in a fresh worktree, rooted under chezmoi's
#    state dir (XDG-respecting, matches the repo's environment.sh). The
#    suffix lets two agents work this same silo concurrently without
#    colliding on the branch name. Never check out master itself.
WT_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/worktrees"
mkdir -p "$WT_ROOT"
suffix=$(date +%s)
git worktree add -b work-on-system-backup-$suffix "$WT_ROOT/work-on-system-backup-$suffix" "$base"
cd "$WT_ROOT/work-on-system-backup-$suffix"
```

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
- **Stop here — do not integrate.** A workflow started by `/work-on-<silo>`
  ends only when the human decides. Once your work is self-tested and
  committed on the `work-on-<silo>-<suffix>` branch, **stop** and leave the
  branch parked in its worktree. Do **not** load the `reconcile` skill or
  merge to master yourself. The human closes the session by typing
  **`/end-work`**, which loads the `reconcile` skill and lands the branch on
  `master` (`flock`-gated, ff-only, `make test` under the lock). Report that
  the branch is ready and stop.

## Verify before claiming done
- Exercise against a THROWAWAY repository, never the real one. A backup silo
  is the one place where a destructive test is not recoverable by rerunning it.
- Run the backup specs (`backup_spec.sh`, `backup_tm_spec.sh`,
  `backup_drift_spec.sh`, `backup_changes_spec.sh`) plus `make test`.
- If you touched restore: prove the undo path on the same run, not in theory.
- Your diff stays within the owner area above.

## Reference
`docs/system-backup-recovery.md` and `docs/chezmoi-silo-map.md`
(the "system-backup" section).
