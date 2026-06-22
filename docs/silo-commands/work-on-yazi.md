---
description: Dispatch an agent to the Yazi silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **Yazi** silo of this chezmoi dotfiles repo.

> Yazi file manager config + custom plugins (folder-rules, parent-arrow),
> macOS tag integration, rich previewer wiring, `$NVIM` nested integration.

## Your scope (owner area — safe to edit)

- `home/dot_config/yazi/` — `init.lua`, `yazi.toml`, `keymap.toml`,
  `plugins/{folder-rules,parent-arrow}.yazi/`

## Out of scope (do not edit — owned by other silos)

- `home/dot_config/zellij/scripts/executable_zellij-open` → **terminal-mux**
  (opens dirs in a Yazi tab via that script; you own the Yazi side it
  targets).
- The `preview` backend + libexec viewers → **preview** (you *call* them via
  the previewer wiring; you don't own the viewers).
- `mactag`/`bypass`/`smart-switch`/`full-border`/`git` plugins are external
  Yazi plugins — you own only their config here.

## Contracts you must preserve

- **Previewer wiring** in `yazi.toml`/`init.lua` — prepend_previewers route
  to `ouch`/`mediainfo`/`rich`/the **preview** libexec viewers. `preview`
  (**preview**) is the backend.
- **`cd` event plugins** (`folder-rules`) — Downloads→mtime reverse (dirs
  not first), else alphabetical dirs-first.
- **`$NVIM` detection** — auto-toggles min-preview when nested under nvim
  (cooperates with **neovim**). Preserve this signal.
- **keymap contract** — `K`/`J` parent-arrow, `H`/`L` bypass, color-tag keys
  (r/o/y/g/b/p), `qlmanage -p` on Ctrl+Space.

## What you consume read-only

- **preview**: `preview` + `libexec/*-view`
- **terminal-mux**: `zellij-open`
- **neovim**: `$NVIM` env signal
- External: Yazi plugins (mactag/bypass/smart-switch/full-border/git)

## Where to start

`home/dot_config/yazi/init.lua`, `yazi.toml`, `keymap.toml`, `plugins/`.

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
git worktree add -b work-on-yazi-$suffix "$WT_ROOT/work-on-yazi-$suffix" "$base"
cd "$WT_ROOT/work-on-yazi-$suffix"
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
- Reproduce in a real Yazi session (`ya` inside Zellij).
- The previewer routes to **preview**'s `preview`/libexec viewers — those are
  read-only for you; don't duplicate their logic.
- Preserve the `$NVIM` min-preview toggle (cooperates with **neovim**).
- Your diff stays within `home/dot_config/yazi/`.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "Yazi" section).
