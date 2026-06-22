---
description: Dispatch an agent to the system disk images silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **system disk images** sub-silo (part of the system
management area) of this chezmoi dotfiles repo.

> macOS-only APFS sparse disk-image manager via `system-images` and
> `images.toml`. This is one of four independently-dispatchable sub-silos of
> the system management area.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_system-images`
- `home/dot_config/packages/images.toml.example` (loose/local-only,
  chezmoiignored)

## Out of scope (do not edit — owned by other silos)

- The package workers → **system-packages**
- `services.toml.tmpl` → **system-services**
- `system-update` → **system-update**
- `common.zsh` → **shell**/**utils**

## Contracts you must preserve

- macOS-only. Each TOML section key is the source of truth for image file /
  `-volname` / mount dir. `sync` is create-missing + automount, **never
  deletes**; `remove` is the separate destructive path. Login automount via
  the `[images-automount]` launchd agent in `services.toml`
  (**system-services** owns the plist).

## What you consume read-only

- **system-services**: the `[images-automount]` launchd plist
- **shell**/**utils**: `common.zsh`
- External: macOS `hdiutil`, APFS

## Where to start

`bin/system-images`.

## Shared across all system-* sub-silos

This sub-silo shares `home/dot_local/lib/system-package-common.zsh`
(`pkg::*`) with the other **system-packages** / **system-services** /
**system-update** sub-silos. **If another system-* agent runs concurrently
and either edits `pkg::*`, serialize that edit.**

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
git worktree add -b work-on-system-images-$suffix "$WT_ROOT/work-on-system-images-$suffix" "$base"
cd "$WT_ROOT/work-on-system-images-$suffix"
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
- **Integrate (non-UX work):** load the `reconcile` skill and follow it —
  `flock`-gated, on-demand `master-work`, ff-only automated / divergence
  human-gated, `make test` under the lock.

## Verify before claiming done
- Run `make test` (ShellSpec covers `pkg::*` and the package-domain helpers).
- Reproduce the behavior with `system-images` (or `system-update --dry-run`
  if relevant).
- Your diff stays within your sub-silo's owner files (don't touch the other
  system-* sub-silos' files unless you've pre-agreed).

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "System management" section).
