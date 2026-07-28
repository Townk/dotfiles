---
description: Dispatch an agent to the theme single-source silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **theme** silo of this chezmoi dotfiles repo.

> One palette, projected into every tool that draws colour. `theme.yaml` is
> the only place a hex literal is allowed to exist; a lint fails the build if
> one appears anywhere else. Fourteen generated projections keep tmux, Zellij,
> WezTerm, Ghostty, bat, glow, yazi, zsh, nvim, pi and Claude Code agreeing on
> what "surface" or "attention" means.

## Your scope (owner area — safe to edit)

- `home/.chezmoidata/theme.yaml` — **the single source**. Slots
  (`roles.*`, `extended.*`, `palette.*`) are the vocabulary every consumer
  names; renaming one is a breaking change across every projection.
- `custom-builds/theme/generate-theme.sh` + `custom-builds/theme/templates/`
  — the generator and one template per projection
- `home/dot_local/lib/theme-common.zsh` — the runtime reader
- `home/dot_local/libexec/executable_theme-apply`,
  `home/dot_local/bin/executable_theme-reset`
- `home/.chezmoiscripts/run_onchange_after_54-generate-theme.sh.tmpl` (the
  *logic*; hook ordering and hash triggers are **chezmoi**'s)
- `tests/lint-theme.sh` — the fence that keeps hex out of everything else

## Out of scope (do not edit — owned by other silos)

- The *consumers* of a projection. If tmux's ribbon or yazi's flavour looks
  wrong, the fix is usually a slot or a template here — but the file that
  *reads* it belongs to that silo (**terminal-mux**, **yazi**, **neovim**,
  **preview**, **shell**, **pi**).
- Generated outputs under `~/.config/theme/`, `~/.config/*/themes/` — these
  are build products, never edited by hand. Change the template.
- `custom-builds/` other than `theme/` → **custom-builds**.

## Contracts you must preserve

- **No raw hex outside `theme.yaml`.** `make test` runs `lint-theme.sh`; it is
  the reason the palette can move at all. A colour that "just this once" gets
  written into a consumer is a colour that silently stops following the theme.
- **The projections and their paths** (see `generate-theme.sh`): the JSON at
  `~/.config/theme/chezmoi-system.json` is the machine-readable one — shell
  and POSIX consumers read it with `jq` rather than sourcing anything.
  Removing or renaming a projection breaks the consumer that reads it,
  usually at *render* time rather than at build time.
- **Slot names are an API.** `roles.ui.bg`, `roles.mode.*`, `extended.tab.*`,
  `extended.dialog.*` are referenced by path from shell, Lua and Rust.
- **Regeneration is automatic**: `chezmoi apply` triggers
  `run_onchange_after_54-generate-theme.sh` when the data or a template
  changes. A tmux/Zellij *reload* is separate (see terminal-mux).

## What you consume read-only

- **chezmoi**: template rendering and the run-script hash triggers
- **shell**: `common.zsh`, `environment.sh` XDG vars
- **utils**: `notify`

## Where to start

`.chezmoidata/theme.yaml` (the vocabulary), `custom-builds/theme/generate-theme.sh`
(what is projected where), then the template of whichever consumer you are chasing.

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
git worktree add -b work-on-theme-$suffix "$WT_ROOT/work-on-theme-$suffix" "$base"
cd "$WT_ROOT/work-on-theme-$suffix"
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
- Regenerate and diff the projections — a template edit that changes ten files
  is normal; one that changes *none* means you edited a build product.
- `make test` (includes `lint-theme.sh` and `theme_apply_tmux_spec.sh`).
- Check at least one consumer actually renders the change; a valid file that
  nothing reads is the usual failure here.
- Your diff stays within the owner area above.

## Reference
`docs/theme-unification.md` and `docs/chezmoi-silo-map.md` (the "theme" section).
