---
description: Dispatch an agent to the system update orchestrator silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **system update orchestrator** sub-silo (part of the
system management area) of this chezmoi dotfiles repo.

> The "everything at latest" update orchestrator (`system-update`, 383
> lines) that sequences git/chezmoi/brew/mise/packages/services/yazi/nvim/pi.
> This is one of four independently-dispatchable sub-silos of the system
> management area.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_system-update` (383 lines)

## Out of scope (do not edit — owned by other silos)

- The package workers → **system-packages**
- `services.toml.tmpl` → **system-services**
- `images.toml` → **system-images**
- `common.zsh` → **shell**/**utils**

## Contracts you must preserve

- **Orchestrates** **system-packages**/**system-services** + external
  brew/mise/yazi/nvim/pi.
- **Ordering invariants** (preserve): `git fetch`+ff-only (no rebase) →
  `chezmoi apply` → **self re-exec** if source advanced
  (`SYSTEM_UPDATE_REEXECED`) → `brew update` → `mise install/upgrade/prune`
  **before** `system-package sync` (so npm globals don't orphan on a node
  upgrade) → `system-package sync` → `brew cleanup` → `pinentry-touchid -fix`
  (SSH-skipped) → `system-service sync` → `ya pkg upgrade` → yazi lockfile
  commit/push (copies `package.toml` into chezmoi source, not `chezmoi
  re-add`, to avoid the apply lock when invoked from chezmoi's own
  `run_once`) → `Lazy! sync`/`MasonToolsUpdateSync` → `pi update
  --extensions` → git-pull zsh plugins. Detects `CHEZMOI=1` re-entrancy.

## What you consume read-only

- **system-packages** / **system-services**: the sync commands this
  orchestrator calls
- **shell**/**utils**: `common.zsh`
- External: brew, mise, yazi, nvim, pi, git

## Where to start

`bin/system-update`.

## Shared across all system-* sub-silos

This sub-silo shares `home/dot_local/lib/system-package-common.zsh`
(`pkg::*`) with the other **system-packages** / **system-services** /
**system-images** sub-silos. **If another system-* agent runs concurrently
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
git worktree add -b work-on-system-update-$suffix "$WT_ROOT/work-on-system-update-$suffix" "$base"
cd "$WT_ROOT/work-on-system-update-$suffix"
```

## TASK

$ARGUMENTS

## Validate & integrate
- **Self-test (logic):** sandbox-`$HOME` per `docs/silo-commands/validate.md`
  (Mode A) — parallel, no lock, no clobber of real `$HOME`.
- **Human UX validation:** if the work needs eyeball judgment, ask the user
  whether to enter a UX session, then follow `docs/silo-commands/validate.md`
  (Mode B) — the session merges your branch to master and you iterate live.
- **Integrate (non-UX work):** follow `docs/silo-commands/reconcile.md` —
  `flock`-gated, on-demand `master-work`, ff-only automated / divergence
  human-gated, `make test` under the lock.

## Verify before claiming done
- Run `make test` (ShellSpec covers `pkg::*` and the package-domain helpers).
- Reproduce the behavior with `system-update --dry-run` (don't run a real
  full update casually — it touches many external systems).
- The ordering invariants above are preserved — especially `mise
  install/upgrade/prune` **before** `system-package sync` (npm-globals
  orphaning hazard).
- Your diff stays within your sub-silo's owner files (don't touch the other
  system-* sub-silos' files unless you've pre-agreed).

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "System management" section).
