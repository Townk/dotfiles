# Silo S11 — Yazi

> Yazi file manager config + custom plugins (folder-rules, parent-arrow),
> macOS tag integration, rich previewer wiring, `$NVIM` nested integration.

## Setup

```sh
git worktree add ../s11-yazi-work master
cd ../s11-yazi-work
```

## Your scope (owner area — safe to edit)

- `home/dot_config/yazi/` — `init.lua`, `yazi.toml`, `keymap.toml`,
  `plugins/{folder-rules,parent-arrow}.yazi/`

## Out of scope (do not edit — owned by other silos)

- `home/dot_config/zellij/scripts/executable_zellij-open` → **S1** (opens
  dirs in a Yazi tab via that script; you own the Yazi side it targets).
- The `preview` backend + libexec viewers → **S10** (you *call* them via the
  previewer wiring; you don't own the viewers).
- `mactag`/`bypass`/`smart-switch`/`full-border`/`git` plugins are external
  Yazi plugins — you own only their config here.

## Contracts you must preserve

- **Previewer wiring** in `yazi.toml`/`init.lua` — prepend_previewers route
  to `ouch`/`mediainfo`/`rich`/the S10 libexec viewers. `preview` (S10) is
  the backend.
- **`cd` event plugins** (`folder-rules`) — Downloads→mtime reverse (dirs
  not first), else alphabetical dirs-first.
- **`$NVIM` detection** — auto-toggles min-preview when nested under nvim
  (cooperates with S2). Preserve this signal.
- **keymap contract** — `K`/`J` parent-arrow, `H`/`L` bypass, color-tag keys
  (r/o/y/g/b/p), `qlmanage -p` on Ctrl+Space.

## What you consume read-only

- S10: `preview` + `libexec/*-view`
- S1: `zellij-open`
- S2: `$NVIM` env signal
- External: Yazi plugins (mactag/bypass/smart-switch/full-border/git)

## Where to start

`home/dot_config/yazi/init.lua`, `yazi.toml`, `keymap.toml`, `plugins/`.

## TASK

> _<describe the assignment — e.g. "Review Yazi preview performance; large
> directories lag" >_

**Verify before claiming done:**
- Reproduce in a real Yazi session (`ya` inside Zellij).
- The previewer routes to S10's `preview`/libexec viewers — those are
  read-only for you; don't duplicate their logic.
- Preserve the `$NVIM` min-preview toggle (cooperates with S2).
- Your diff stays within `home/dot_config/yazi/`.

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S11.
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #73–#75.
