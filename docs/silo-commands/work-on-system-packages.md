---
description: Dispatch an agent to the system packages silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **system packages** sub-silo (part of the system
management area) of this chezmoi dotfiles repo.

> Multi-ecosystem package sync (brew/cargo/go/npm/snap/uv) via the
> `pkg::*` library and per-ecosystem workers. This is one of four
> independently-dispatchable sub-silos of the system management area.

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_system-package`,
  `system-package-{brew,cargo,go,npm,snap,uv}`
- `home/dot_local/lib/system-package-common.zsh` (`pkg::*`)
- `home/dot_config/packages/{Brewfile,Brewfile.bootstrap,Cargofile,Gofile,Npmfile,Snapfile,Uvfile}.tmpl`

## Out of scope (do not edit — owned by other silos)

- `services.toml.tmpl` → **system-services**
- `system-update` → **system-update**
- `images.toml` → **system-images**
- The package ecosystems themselves (brew/cargo/go/npm/snap/uv — external);
  mise-managed runtimes (external, but the brew worker guards them)
- chezmoi run-scripts → **chezmoi** (the Snapfile onchange hook
  `run_onchange_after_40` is **chezmoi**'s trigger; this silo owns the
  Snapfile content)
- `common.zsh` → **shell**/**utils**

## Contracts you must preserve

- **Cross-seam contract:** `pkg::restart_services_for <pkg>...` → calls
  `system-service restart-for "$@"` (**system-services** owns the receiver).
  It restarts only services whose backing package was upgraded, only if
  currently running. `pkg::restart_changed <before> <after>` diffs version
  snapshots and restarts only changed. **Preserve this seam.**
- **Manifest grammar** (`pkg::manifest_read`): comment-stripping,
  canonical-name tokenizer (`${(z)}`), `<name> -- <spec>` alternate install
  form for git/local. Shared across all 6 ecosystem workers.
- **Worker contract:** `list [-u|--update] [-a|--all]` TSV rows + `sync`
  (install declared / uninstall extras, strict where safe). Brew worker
  merges `Brewfile.bootstrap`+`Brewfile`, guards mise-owned runtimes
  (`^(go|python|node|...)@?`), tracks taps. Snap worker intentionally does
  **not** remove undeclared (snapd auto-installs base/platform snaps).

## What you consume read-only

- **shell**/**utils**: `common.zsh`
- **chezmoi**: Snapfile hook
- External: brew/cargo/go/npm/snap/uv/mise

## Where to start

`system-package-common.zsh`, `bin/system-package`, `bin/system-package-brew`.
Each worker's `list -u` fans out parallel outdated-checks to registries — a
good performance starting point.

## Shared across all system-* sub-silos

This sub-silo shares `home/dot_local/lib/system-package-common.zsh`
(`pkg::*`) with the other **system-services** / **system-images** /
**system-update** sub-silos. Per `bin/README.md`, this lib also backs
`system-service` and `system-images`. **If another system-* agent runs
concurrently and either edits `pkg::*`, serialize that edit.**

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
git worktree add -b work-on-system-packages-$suffix "$WT_ROOT/work-on-system-packages-$suffix" "$base"
cd "$WT_ROOT/work-on-system-packages-$suffix"
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
- Reproduce the behavior with a real `system-package <eco> list -u` / `sync`.
- The `pkg::restart_services_for` → `system-service restart-for` seam still
  holds (only running services restart).
- Your diff stays within your sub-silo's owner files (don't touch the other
  system-* sub-silos' files unless you've pre-agreed).

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "System management" section, incl. the
system-packages↔system-services `restart-for` seam and the
system-management↔terminal-mux `services.toml` shared sections).
