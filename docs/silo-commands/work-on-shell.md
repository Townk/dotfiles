---
description: Dispatch an agent to the shell (zsh) bootstrap & widgets silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **shell (zsh) bootstrap & widgets** silo of this
chezmoi dotfiles repo.

> Framework-free, XDG-hardened zsh bootstrap with Zellij auto-attach; custom
> ZLE widgets (dir-navigation ring, smart-space, `super-cd`); the shared
> `common.zsh` stdlib, `prompt::*`, and `platform::*`.

## Your scope (owner area — safe to edit)

- `home/dot_config/zsh/` — `dot_zshrc` (rendered from `home/dot_zshrc`),
  `environment.sh`, `completion.sh`, `keybindings.sh`, `functions.d/`,
  `aliases.d/`
- `home/dot_zshrc`, `home/dot_zshenv`, `home/dot_p10k.zsh` (chezmoi
  top-level)
- `home/dot_local/lib/common.zsh` (stdlib — **shared, coordinate**),
  `prompt-common.zsh` (`prompt::*`), `platform.zsh` +
  `platform-{macos,linux}.zsh` (`platform::*`)

## Out of scope (do not edit — owned by other silos)

⚠ **Shared-file hazards:**
- `home/dot_config/zsh/functions.d/widgets.sh` — contains **both** this
  silo's widgets (dir-ring, smart-space) **and** **ai-harnesses**'
  `ai-assist-trigger` widget. If an **ai-harnesses** agent is running
  concurrently, **serialize** ai-harnesses↔shell or split the file first.
- `home/dot_local/lib/common.zsh` + `platform*.zsh` — shared with **utils**
  and sourced by **pick**/**ai-harnesses**/**secrets**. Any new shared
  primitive = a merge point; prefer a silo-local helper unless ≥2 silos need
  it.
- `home/dot_config/zsh/private_secrets.d/` → **secrets** (you own only the
  sourcing plumbing in `dot_zshrc`).

## Contracts you must preserve

- **`environment.sh`** — the single source of truth for XDG vars, sourced by
  both `.zshenv` and the `my.environment.variables` LaunchAgent
  (`launchctl setenv` to GUI apps). The **chezmoi** silo's
  `run_onchange_after_30-reload-environment-launchagent` hook re-boots that
  agent when `environment.sh`'s hash changes. Notable:
  `PIP_REQUIRE_VIRTUALENV=true`, static Homebrew PATH (no `brew shellenv`
  fork), `MISE_CARGO_HOME`/`RUSTUP_HOME`, `XDG_RUNTIME_DIR` auto-created for
  the `op` daemon.
- **`notify` primitive** in `common.zsh` — best-effort (returns non-zero
  quietly on missing `hs`); the `bin/notify` front-end (**utils**) wraps it
  with a hard error. Consumed on hot paths (**terminal-mux** `copy-pwd`).
  Icon/sound spec shape matches **hammerspoon**'s `hs` globals.
- **`prompt::*`** (`prompt-common.zsh`) — `required`/`default`/`secret`/
  `choice`/`confirm`, read from `/dev/tty`. `prompt::secret` does masked
  entry via `-echo -icanon` + `read -rk 1`. Consumed by **ai-harnesses**
  (`cagent`), **secrets** (`sec`).
- **`platform::*`** — `launch_gui`/`raise_app`; macOS `open -a`+AppleScript,
  Linux detached exec + hyprctl/swaymsg/wmctrl/xdotool. Consumed by
  **utils** `tab-edit`.
- **ZLE widgets**: dir-navigation ring (`_dir_ring`),
  `smart-space-expansion`, `super-cd` (aliased to `cd`). Bound to raw CSI
  sequences (WezTerm/Ghostty Shift+arrows, Shift+Tab=undo, Option+/=redo).
- **Zellij auto-attach** in `dot_zshrc` — "Main" session reuse logic,
  over-SSH scrollback wipe to suppress pam_motd flash, quick-launch recency
  seeding (calls into **terminal-mux**).

## What you consume read-only

- **terminal-mux**: Zellij auto-attach, quick-launch recency seeding
- **pick**: pick widget
- **preview**: fzf wired to `preview`
- **utils**: `notify`, `wait-until`
- External: z4h/p10k/zsh-defer/fzf/zoxide/atuin

## Where to start

`home/dot_config/zsh/dot_zshrc`, `environment.sh`, `functions.d/widgets.sh`,
`home/dot_local/lib/common.zsh`, `prompt-common.zsh`.

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
git worktree add -b work-on-shell-$suffix "$WT_ROOT/work-on-shell-$suffix" "$base"
cd "$WT_ROOT/work-on-shell-$suffix"
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
- Run `make test` (ShellSpec covers `common.zsh` primitives, `platform::*`,
  `for_each`).
- Reproduce in a fresh interactive zsh (`zsh -i`).
- The `notify` primitive and `environment.sh` XDG vars are public contracts
  (**terminal-mux**/**ai-harnesses**/**secrets**/**utils** consume them) —
  signatures unchanged.
- `functions.d/widgets.sh`: don't remove **ai-harnesses**'s
  `ai-assist-trigger` widget.
- The `my.environment.variables` LaunchAgent (**chezmoi**) watches
  `environment.sh`'s hash; if you change its content, note that a reload is
  triggered.
- Your diff stays within the owner area above.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "shell (zsh) bootstrap & widgets" section —
shell↔ai-harnesses `widgets.sh` hazard, shell↔utils `common.zsh` sharing).
