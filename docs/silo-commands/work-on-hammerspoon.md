---
description: Dispatch an agent to the Hammerspoon silo in an isolated worktree
argument-hint: <task description>
---
You are working on the **Hammerspoon** silo of this chezmoi dotfiles repo.

> macOS automation engine: declarative modal keybindings w/ WebView which-key
> overlay, Stream Deck+ runtime, canvas OSD widget, optimistic system
> controls + media-key interception, audio device abstraction, Cmd+drag
> window moving, app-launcher integrations.

## Your scope (owner area — safe to edit)

- `home/dot_config/hammerspoon/` — `init.lua`,
  `modules/{keybindings,streamdeck,osd,system,audio,windows,apps,clipboard,bootstrap,lifecycle}/*.lua`,
  `Assets/` (html/which-key-overlay, icons, backgrounds)

## Out of scope (do not edit — owned by other silos)

- The `notify` *sender* in `home/dot_local/lib/common.zsh` + `bin/notify` →
  **shell** / **utils**. You own the *receiver* (`hs` CLI globals
  `notify`/`notifyAnsi`).
- `symbols.db` → **custom-builds** (your OSD `glyph:` resolver *queries* it
  read-only).
- Stream Deck hardware / Elgato app (external).
- Raycast/Shottr/ColorSlurp/PixelSnap (external apps — only URL-scheme
  integration here).

## Contracts you must preserve

- **`hs` CLI globals `notify` / `notifyAnsi`** — the OSD entry points invoked
  by `common.zsh`'s `notify` primitive (**shell**/**utils**) via `hs -c`. Arg
  shape: Lua string literals (env vars are invisible inside the running HS
  process — that's why `notify` serializes env to literals). Icon specs:
  `glyph:<name>` (resolved via symbols.db query), `swatch:#RRGGBB`, SVG name.
  Sound names. **This is the single most important Hammerspoon seam.**
- **`optimistic_state`** generic (`modules/system/optimistic_state.lua`) —
  reused by controls + Stream Deck re-render-on-external-change.
- **Keybinding tree shape** (`modules/keybindings/init.lua` `kb.setup{...}`) —
  numeric actions = macOS symbolic hotkeys managed via `system_shortcuts.lua`
  plist diffing + `activateSettings -u` (no logout).
- **Media-key interception** (`lifecycle.lua` `systemDefined` eventtap) —
  routes SOUND/BRIGHTNESS to controls.

## What you consume read-only

- **custom-builds**: `symbols.db` for `glyph:<name>` icons
- **shell** / **utils**: the `notify` senders (call your `hs` globals)
- External apps via URL schemes/AppleScript

## Where to start

`init.lua`, `modules/keybindings/`, `modules/streamdeck/`, `modules/osd/`.

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
git worktree add -b work-on-hammerspoon-$suffix "$WT_ROOT/work-on-hammerspoon-$suffix" "$base"
cd "$WT_ROOT/work-on-hammerspoon-$suffix"
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
- Reload Hammerspoon and reproduce the behavior (config-reload OSD should
  fire).
- Confirm the `hs` CLI `notify`/`notifyAnsi` global contract still works from
  a shell `notify --icon glyph:cod-check "test"` call.
- The `onChange` callback Stream Deck subscribes to from
  `modules/system/controls.lua` must still fire on external volume/brightness
  changes.
- Your diff stays within `home/dot_config/hammerspoon/`.

## Reference
For the full integration map and concurrency/collision matrix, see
`docs/chezmoi-silo-map.md` (the "Hammerspoon" section).
