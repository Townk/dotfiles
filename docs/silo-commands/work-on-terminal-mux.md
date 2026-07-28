---
description: Dispatch an agent to the terminal & multiplexer integration silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **terminal & multiplexer integration** silo of this
chezmoi dotfiles repo.

> WezTerm + Ghostty over **tmux or Zellij**: clipboard bridges, link dispatch,
> fullscreen/status side-channels, the mode stack and which-key panel, floating
> modal pickers, nested-session passthrough, image-protocol negotiation.
>
> **tmux is the default backend** (Phase 7, 2026-07-27); Zellij is one knob
> away (`print -r -- zellij > ~/.config/mux/backend`) and stays fully
> supported. Anything you add to one backend needs an answer for the other —
> `docs/mux-parity.md` is the ledger where those answers live, including the
> gotchas that cost real debugging time.

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
- `home/dot_config/tmux/` (tmux.conf, keymap-base, keymap, status, themes)
- `home/.chezmoidata/keymap.yaml` — the SINGLE SOURCE for the tmux key tables
  *and* the which-key panel. Never hand-edit the generated `keymap.conf` or
  `whichkey.data`; note the panel reads keys from two places in this file
  (the entries, and `which_key.groups` for layout)
- `home/dot_local/lib/mux.zsh` (`mux::*` — the public shim) and
  `home/dot_local/lib/mux/{tmux,zellij,stack,mode,dialog}.zsh` (backends and
  the shared mode-stack / compact-dialog machinery)
- `home/dot_local/lib/zellij.zsh` — a COMPAT SHIM that sources `mux.zsh`;
  the `zj::*` names are permanent aliases. Nothing new should call them
- `home/dot_local/libexec/tmux-status-right` — the ribbon renderer
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
  own the `mux::pick` adapter and the modal adapters that call it.
- chezmoi run-scripts under `home/.chezmoiscripts/` → **chezmoi** (the
  `run_after_45-grant-zellij-plugin-permissions` and
  `run_onchange_after_40-install-snaps` triggers).

## Contracts you must preserve

- **`mux::pick`** — drop-in for `pick::start` (**pick**). Same argv; floats in
  a popup on either backend, else inline. Consumed by `ai-assist`/`ai-commit`
  (**ai-harnesses**) and `quick-launch-pick`. `zj::pick` remains as a
  permanent alias — keep it working, do not build on it.
- **`mux::resolve_session <client_pid>`** / **`mux::client_sessions`** in
  `~/.local/lib/mux.zsh` — backend-dispatching session resolvers (Zellij scans
  unix sockets; tmux asks the server). Consumed by `mux-open`, `tab-edit`
  (**utils**), quick-launch. The Zellij half still lives in
  `zellij/scripts/lib/zellij-session.zsh`.
- **OSC 52 clipboard protocol**: `copy_command` intentionally unset in
  `config.kdl.tmpl`; copy is origin-relative via re-emitted OSC 52. The SSH
  paste-back reads `~/.local/state/runtime/chezmoi-system/clipboard-bridge.sock`
  (served by **system-services**' `clipboard-bridge` agent); nvim
  (**neovim**) implements the client.
- **Workspace-rename side-channel**: `__TOGGLE_FULLSCREEN__` /
  `__QL_FOCUS__=<id>` workspace names drive WezTerm handlers. Your
  `terminal-toggle-fullscreen` and quick-launch depend on these exact
  sentinel strings.
- **Fullscreen-state mirrors** — one per terminal, both read by the tmux
  ribbon and the zj-hud bar, both written atomically:
  `~/.local/state/wezterm/fullscreen_state` (pushed by `wezterm.lua` on every
  window event) and `~/.local/state/mux/ghostty_fullscreen` (Ghostty has no
  such hook, so `mux-fullscreen-probe` fills it from the `client-resized`
  tmux hook). **Nothing in the ribbon renderer may ask the system a question
  that blocks**: tmux will not re-run a `#()` job while one is in flight, so a
  slow render stops the bar being re-expanded at all — a 4-11s accessibility
  probe there made every mode pill vanish (`docs/mux-parity.md`).
- **`W` window opcode** on the clipboard bridge — `fullscreen-toggle
  <ghostty|wezterm>` and `fullscreen-state`, letting a session reach the
  terminal on the machine it came from over SSH. You own the mux half; the
  wire protocol is **clipboard**'s (`docs/clipboard-universal-project.md`).
- **`get_terminal_image_protocol()`** in `image-protocol-support.zsh` —
  returns the Kitty/iTerm2/Sixel capability list as constrained by whichever
  multiplexer is in play (the two clamp differently). Consumed by `preview`
  (**preview**).
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

`lib/mux.zsh` (what every consumer sees), `lib/mux/{tmux,zellij}.zsh` (how each
backend answers), `.chezmoidata/keymap.yaml` (both key planes),
`mux/scripts/lib/dispatch.zsh`, `wezterm.lua`, `config.kdl.tmpl`.

Read `docs/mux-parity.md` before changing behaviour: it is the parity ledger
AND the gotcha record — popups are client-side overlays that `capture-pane`
cannot see, `send-keys -K` does not reliably traverse key tables, a `#()` job
that blocks freezes the whole bar, and terminals disagree about ctrl+shift
encodings (three spellings per chord).

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
- Confirm `mux::pick`/`mux::resolve_session`/`@window:<id>`/sentinel-string
  contracts still hold, and that `zj::*` aliases still resolve.
- Behaviour changes need an answer on BOTH backends, or an explicit ledger row
  saying why not. Drive the real thing: a nested client for tmux, and boot
  Zellij with the config rather than trusting `zellij setup --check`, which
  accepts unknown action names without complaint.
- Your diff stays within the owner area above.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "Terminal & multiplexer integration" section).
