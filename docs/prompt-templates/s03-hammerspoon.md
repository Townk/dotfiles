# Silo S3 — Hammerspoon

> macOS automation engine: declarative modal keybindings w/ WebView which-key
> overlay, Stream Deck+ runtime, canvas OSD widget, optimistic system
> controls + media-key interception, audio device abstraction, Cmd+drag
> window moving, app-launcher integrations.

## Setup

```sh
git worktree add ../s03-hammerspoon-work master
cd ../s03-hammerspoon-work
```

## Your scope (owner area — safe to edit)

- `home/dot_config/hammerspoon/` — `init.lua`,
  `modules/{keybindings,streamdeck,osd,system,audio,windows,apps,clipboard,bootstrap,lifecycle}/*.lua`,
  `Assets/` (html/which-key-overlay, icons, backgrounds)

## Out of scope (do not edit — owned by other silos)

- The `notify` *sender* in `home/dot_local/lib/common.zsh` + `bin/notify` →
  **S9/S13**. You own the *receiver* (`hs` CLI globals `notify`/`notifyAnsi`).
- `symbols.db` → **S5** (your OSD `glyph:` resolver *queries* it read-only).
- Stream Deck hardware / Elgato app (external).
- Raycast/Shottr/ColorSlurp/PixelSnap (external apps — only URL-scheme
  integration here).

## Contracts you must preserve

- **`hs` CLI globals `notify` / `notifyAnsi`** — the OSD entry points invoked
  by `common.zsh`'s `notify` primitive (S9/S13) via `hs -c`. Arg shape: Lua
  string literals (env vars are invisible inside the running HS process —
  that's why `notify` serializes env to literals). Icon specs:
  `glyph:<name>` (resolved via symbols.db query), `swatch:#RRGGBB`, SVG name.
  Sound names. **This is the single most important S3 seam.**
- **`optimistic_state`** generic (`modules/system/optimistic_state.lua`) —
  reused by controls + Stream Deck re-render-on-external-change.
- **Keybinding tree shape** (`modules/keybindings/init.lua` `kb.setup{...}`) —
  numeric actions = macOS symbolic hotkeys managed via `system_shortcuts.lua`
  plist diffing + `activateSettings -u` (no logout).
- **Media-key interception** (`lifecycle.lua` `systemDefined` eventtap) —
  routes SOUND/BRIGHTNESS to controls.

## What you consume read-only

- S5: `symbols.db` for `glyph:<name>` icons
- S9/S13: the `notify` senders (call your `hs` globals)
- External apps via URL schemes/AppleScript

## Where to start

`init.lua`, `modules/keybindings/`, `modules/streamdeck/`, `modules/osd/`.

## TASK

> _<describe the assignment — e.g. "Review the Stream Deck+ engine for
> performance; button images stutter on profile switch" >_

**Verify before claiming done:**
- Reload Hammerspoon and reproduce the behavior (config-reload OSD should
  fire).
- Confirm the `hs` CLI `notify`/`notifyAnsi` global contract still works from
  a shell `notify --icon glyph:cod-check "test"` call.
- The `onChange` callback Stream Deck subscribes to from
  `modules/system/controls.lua` must still fire on external volume/brightness
  changes.
- Your diff stays within `home/dot_config/hammerspoon/`.

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S3.
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #38–#48.
