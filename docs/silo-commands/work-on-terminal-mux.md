---
description: Dispatch an agent to the terminal & multiplexer integration silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **terminal & multiplexer integration** silo of this
chezmoi dotfiles repo.

> WezTerm + Ghostty + Zellij cooperation: clipboard bridges, link dispatch,
> fullscreen/status side-channels, plugin loading, floating modal pickers,
> nested-session passthrough, image-protocol negotiation.

## Your scope (owner area — safe to edit)

- `home/dot_config/wezterm/` (all lua)
- `home/dot_config/ghostty/config`
- `home/dot_config/zellij/config.kdl.tmpl`, `layouts/default.kdl.tmpl`,
  `quick-launch/` (incl. `default.yaml.tmpl`, `launch.d/`),
  `scripts/` (backend-private: zellij-modal, pick-*-zellij,
  quick-launch-zellij, `lib/zellij-session.zsh`)
- `home/dot_config/mux/scripts/` (backend-neutral: quick-launch{,-pick,-window},
  mux-open, mux-preview-{file,image}, mux-quit-confirm, mux-modal, tmux-modal,
  tmux-popup, mux-{search,stack,whichkey,rename,copy-object,scroll-cursor},
  copy-pwd, edit-terminal-config, terminal-toggle-fullscreen,
  nested-session-check, resolve-terminal-location,
  `lib/{config,command,dispatch,dispatch-tmux,terminal-location}.zsh`)
- `home/dot_config/tmux/` (tmux.conf, keymap-base, keymap, status)
- `home/dot_local/lib/zellij.zsh` (`zj::*`)
- `home/dot_local/lib/image-protocol-support.zsh`
- `home/dot_config/zellij/zellij-plugin-path.tmpl` (shared resolver —
  coordinate with the **chezmoi** silo if you change the path resolution
  logic)

## Out of scope (do not edit — owned by other silos)

- The custom Zellij wasm plugin **sources** (`zj-hud`, `zj-promptjump`,
  `zj-context-keys`, `vim-navigator`) live **outside this repo** under
  `~/Projects/apps/zellij/`. You own only the KDL that *loads* them and the
  scripts they *invoke*.
- The patched font + `symbols.db` → **custom-builds**. You reference built
  artifacts by family name / DB path only.
- nvim's SSH-paste *client* → **neovim**. You own the socket protocol the
  client reads.
- The `clipboard-bridge` launchd *service definition* in
  `home/dot_config/packages/services.toml.tmpl` → **system-services**. You
  own the `~/.local/state/runtime/chezmoi-system/clipboard-bridge.sock`
  protocol; **system-services** owns the plist fields.
- The `pick::` engine and `pick-glyph`/`pick-gitmoji` libexec → **pick**. You
  own the `zj::pick` adapter and the `pick-*-zellij` modal adapters that call
  them.
- chezmoi run-scripts under `home/.chezmoiscripts/` → **chezmoi** (the
  `run_after_45-grant-zellij-plugin-permissions` and
  `run_onchange_after_40-install-snaps` triggers).

## Contracts you must preserve

- **`zj::pick`** — drop-in for `pick::start` (**pick**). Same argv; floats in
  a Zellij pane when `$ZELLIJ` set, else inline. Consumed by `ai-assist`/
  `ai-commit` (**ai-harnesses**) and `quick-launch-pick`.
- **`resolve_session <client_pid>`** / **`zellij_wezterm_sessions`** in
  `zellij/scripts/lib/zellij-session.zsh` — unix-socket session resolver.
  Consumed by `mux-open`, `tab-edit` (**utils**), quick-launch.
- **OSC 52 clipboard protocol**: `copy_command` intentionally unset in
  `config.kdl.tmpl`; copy is origin-relative via re-emitted OSC 52. The SSH
  paste-back reads `~/.local/state/runtime/chezmoi-system/clipboard-bridge.sock`
  (served by **system-services**' `clipboard-bridge` agent); nvim
  (**neovim**) implements the client.
- **Workspace-rename side-channel**: `__TOGGLE_FULLSCREEN__` /
  `__QL_FOCUS__=<id>` workspace names drive WezTerm handlers. Your
  `terminal-toggle-fullscreen` and quick-launch depend on these exact
  sentinel strings.
- **Fullscreen-state mirror file**:
  `~/.local/state/wezterm/fullscreen_state` (atomic write-on-change) — read
  by the zj-hud bar.
- **`get_terminal_image_protocol()`** in `image-protocol-support.zsh` —
  returns Kitty/iTerm2/Sixel capability list constrained through Zellij.
  Consumed by `preview` (**preview**).
- **`zellij-plugin-path.tmpl`** — resolves managed plugin `file:` paths; the
  **chezmoi** silo's permission-grant hook and your `ensure-plugins` must
  agree with `config.kdl`'s loaded paths.

## What you consume read-only

- **pick**: `pick::start`, `pick-glyph`, `pick-gitmoji`, `pick-list`
- **custom-builds**: patched font (family name), `symbols.db` at
  `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db`
- **shell**: `environment.sh` XDG vars, the `notify` primitive in `common.zsh`
- **utils**: `notify` bin, `platform::*`, `tab-edit`
- **system-services**: `services.toml` `clipboard-bridge` agent
- **chezmoi**: hooks that trigger plugin perms / snaps

## Where to start

`wezterm.lua`, `config.kdl.tmpl`, `zellij.zsh`, `mux/scripts/lib/dispatch.zsh`,
`zellij/scripts/lib/zellij-session.zsh`.

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
git worktree add -b work-on-terminal-mux-$suffix "$WT_ROOT/work-on-terminal-mux-$suffix" "$base"
cd "$WT_ROOT/work-on-terminal-mux-$suffix"
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
- Reproduce the behavior you changed (don't guess).
- If you touched `lib/mux.zsh`, `lib/mux/*.zsh` or `mux/scripts/lib/*.zsh`, run
  `make test` (ShellSpec, pinned `--shell zsh`).
- Confirm `zj::pick`/`resolve_session`/`@window:<id>`/sentinel-string
  contracts still hold.
- Your diff stays within the owner area above.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "Terminal & multiplexer integration" section).
