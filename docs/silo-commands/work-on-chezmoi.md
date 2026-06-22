---
description: Dispatch an agent to the chezmoi orchestration & run-scripts silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **chezmoi orchestration & run-scripts** silo of this
chezmoi dotfiles repo.

> The chezmoi bootstrap, run-script ordering, hash-baked change triggers,
> profile/os gating, and the Open-in-NeoVim Finder droplet generator.

## Your scope (owner area — safe to edit)

- `.setup.sh`, `Makefile`, `README.md`, `.chezmoiroot`, `.chezmoiignore.tmpl`,
  `.chezmoi.toml.tmpl`, `.chezmoidata/*.yaml`, `.shellspec`, `.gitattributes`,
  `.gitignore`
- `home/.chezmoiscripts/run_*` — **all** the numbered run-scripts
- `home/dot_config/zellij/zellij-plugin-path.tmpl` (shared resolver — also
  used by **terminal-mux**; coordinate if you change the path resolution
  logic)

## Out of scope (do not edit — owned by other silos)

- The *logic* each run-script invokes belongs to its feature silo:
  - **custom-builds** owns the custom-build *builders* (`custom-builds/`)
  - **secrets** owns the GPG/secrets logic
  - **system-packages** owns the snap sync content
  - **terminal-mux** owns the zellij plugin-perm *protocol*
- You own the **trigger mechanics**: the numeric ordering, the hash-baking
  into rendered comments (so `run_onchange` re-fires on source change), the
  `run_after` vs `run_once` vs `run_onchange` choice, and the
  interactive-prompt gating (TTY + not-CI + `CHEZMOI_NONINTERACTIVE`).

## Contracts you must preserve

- **Numeric prefix ordering** (`run_*_after_NN-…`): chezmoi runs `after`
  scripts in alphabetical order, so the prefix fixes execution order.
  Current map (don't renumber without tracing deps):
  `05` op-daemon reaper (**secrets**), `10` bootstrap-tools, `15` dev-shell
  tools, `20` system-settings, `25` GPG key (**secrets**), `30` env
  LaunchAgent reload, `34` sudo touchid, `35` open-in-neovim app
  (**terminal-mux**/**neovim**) + dev-shell sudo links, `36` tab-edit desktop
  (**terminal-mux**/**utils**), `40` snaps (**system-packages**), `45` zellij
  plugin perms (**terminal-mux**), `50` custom zsh build (**custom-builds**),
  `60` symbols-db mark (**custom-builds**), `70` symbols-nerd-font mark
  (**custom-builds**), `80` symbols font/DB prompt (**custom-builds**), `90`
  dev-shell prune.
- **Hash-baking**: `run_onchange` scripts bake a SHA256 of their inputs
  (builder, donor glyphs, custom-SVG `code` pins, manifest content) into
  rendered comments so chezmoi re-runs on change. Editing a builder
  (**custom-builds**) without updating the baked hash logic breaks the
  trigger.
- **Open-in-NeoVim app generator** (`run_onchange_after_35`): builds the
  `.app` via `osacompile`, stamps `neovim-hicontrast.icns`, registers
  `CFBundleDocumentTypes`, and **queries nvim's filetype registry headlessly**
  (`vim.filetype.inspect().extension` + `mdls`) — a hard dependency on
  **neovim**'s filetype map.
- **`.chezmoiignore.tmpl`** — the profile/os gating that makes dev-shell
  headless (excludes `hammerspoon`/`wezterm`/`ghostty`/`espanso`/
  `llama-swap` etc. on dev-shell).

## What you consume read-only

- Every feature silo (the run-scripts trigger their builds/imports/
  permissions). **neovim**'s `vim.filetype.inspect()` for the app generator.

## Where to start

`.setup.sh`, `home/.chezmoiscripts/`, `.chezmoiignore.tmpl`, `.chezmoidata/`.

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
git worktree add -b work-on-chezmoi-$suffix "$WT_ROOT/work-on-chezmoi-$suffix" "$base"
cd "$WT_ROOT/work-on-chezmoi-$suffix"
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
- Run `chezmoi apply --dry-run` (or a real apply in the worktree) and confirm
  the run-script ordering is as intended.
- The hash-baking in `run_onchange` scripts is the trigger contract with
  **custom-builds** — if you change how hashes are computed, **custom-builds**'s
  builders must still re-fire on real input changes (and not fire spuriously).
- The `run_after_35` open-in-neovim generator still depends on **neovim**'s
  `vim.filetype.inspect()` — preserve that headless query.
- `.chezmoiignore.tmpl` profile/os gating must keep dev-shell headless.
- Your diff stays within the owner area above (a feature silo's run-script
  *content* is jointly owned with that silo — coordinate if you edit the
  logic, not just the trigger).

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "chezmoi orchestration & run-scripts"
section — the run-script → feature-silo ownership map).
