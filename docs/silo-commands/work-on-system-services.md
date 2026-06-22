---
description: Dispatch an agent to the system services silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **system services** sub-silo (part of the system
management area) of this chezmoi dotfiles repo.

> Unified launchd+brew service manager via `system-service*` and the
> `services.toml.tmpl` manifest. This is one of four independently-
> dispatchable sub-silos of the system management area.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_system-service`,
  `system-service-{launchd,brew}`
- `home/dot_config/packages/services.toml.tmpl`

## Out of scope (do not edit — owned by other silos)

- The package workers → **system-packages**
- `system-update` → **system-update**
- `common.zsh` → **shell**/**utils**

## Contracts you must preserve

- **`services.toml.tmpl` schema** — TOML sections → launchd user agents
  rendered to plists (`yq`/`jq`), `~`-expansion + `command -v` resolution of
  `cmd[0]`, working/log dirs auto-created, bootstrapped into
  `gui/$(id -u)`. OS-aware cache dir (Library/Caches on macOS, `~/.cache`
  elsewhere). `restart-for <pkg>...` maps a package name to services (launchd
  by key or `cmd[0]` basename, brew by name) and restarts **only if currently
  running** — this is the receiver of **system-packages**'s
  `pkg::restart_services_for`.
- **Note:** `services.toml.tmpl` declares agents owned by *other* silos:
  `clipboard-bridge` (**terminal-mux** protocol, **system-services** plist),
  `images-automount` (**system-images** consumer), `llama-sswap`/
  `local-llm-gateway`/`headroom` (local-LLM stack). Editing the plist fields
  for these is this silo's job; changing the *protocol* they expose is the
  other silo's. Pre-agree if both touch the same section.

## What you consume read-only

- **shell**/**utils**: `common.zsh`
- External: launchd, brew services

## Where to start

`bin/system-service-launchd`, `services.toml.tmpl`.

## Shared across all system-* sub-silos

This sub-silo shares `home/dot_local/lib/system-package-common.zsh`
(`pkg::*`) with the other **system-packages** / **system-images** /
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
git worktree add -b work-on-system-services-$suffix "$WT_ROOT/work-on-system-services-$suffix" "$base"
cd "$WT_ROOT/work-on-system-services-$suffix"
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
- Reproduce the behavior with a real `system-service list` / `restart-for`.
- The `pkg::restart_services_for` → `system-service restart-for` seam still
  holds (only running services restart).
- Your diff stays within your sub-silo's owner files (don't touch the other
  system-* sub-silos' files unless you've pre-agreed).

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "System management" section, incl. the
system-packages↔system-services `restart-for` seam and the
system-management↔terminal-mux `services.toml` shared sections).
