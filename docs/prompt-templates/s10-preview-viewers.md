# Silo S10 — File preview & terminal viewers

> The universal `preview` backend for fzf/Yazi, plus the stdlib-Python
> "card" viewers for iCalendar / SQLite / macOS disk images.

## Setup

```sh
git worktree add ../s10-preview-work master
cd ../s10-preview-work
```

## Your scope (owner area — safe to edit)

- `home/dot_local/bin/executable_preview` (15K),
  `executable_fzf-tab-preview-open`
- `home/dot_local/libexec/executable_ics-view`, `sqlite-view`,
  `disk-image-view` (Python stdlib)

## Out of scope (do not edit — owned by other silos)

- `home/dot_local/lib/image-protocol-support.zsh` → **S1** (you *source* it
  read-only and call `get_terminal_image_protocol()`). If you need a new
  protocol capability, hand that request to S1 — don't edit it here.
- Yazi's previewer *wiring* → **S11** (S11 calls `preview`/the libexec
  viewers; you own the viewers themselves).
- fzf, bat, chafa, mediainfo, ouch, rich, hexyl, figlet (external).

## Contracts you must preserve

- **`preview` as the universal `--preview` backend** — invoked by fzf
  (`FZF_DEFAULT_OPTS`) and Yazi. Routing order: pre-guards
  (empty/dir/missing/zero-byte) → by-extension (`.ipynb` despite json MIME,
  csv/md/json/yaml/xml/ics/sqlite/archive/pdf) → by-MIME (image via
  chafa/Kitty graphics, audio/video via mediainfo, disk images) → binary
  hexdump → `bat`. Lives as a *script* (not a zsh function) so fzf's
  non-interactive preview subshell finds it via PATH.
- **`stamp-msg()`** figlet banners (custom `phm-minecraft.flf` font,
  true-footprint measurement, plain-text fallback on overflow).
- **libexec viewer contract**: stdin = file path, stdout = rendered card;
  rounded Unicode box-drawing, Catppuccin Mocha truecolor, Nerd Font icons.
  Consumed by `preview` and Yazi (S11).

## What you consume read-only

- S1: `get_terminal_image_protocol()` (Kitty/iTerm2/Sixel constrained through
  Zellij)
- External: bat/chafa/mediainfo/ouch/rich/hexyl/figlet

## Where to start

`home/dot_local/bin/executable_preview`, `libexec/{ics,sqlite,disk-image}-view`.

## TASK

> _<describe the assignment — e.g. "Add a previewer for `.ics` files that
> handles recurring events with timezones" or "Preview is slow on large
> SQLite DBs" >_

**Verify before claiming done:**
- Reproduce with a real `preview <file>` invocation and via fzf's `--preview`.
- If you add a viewer, follow the libexec viewer contract (stdin path →
  stdout card, Catppuccin styling) so Yazi (S11) picks it up unchanged.
- `image-protocol-support.zsh` (S1) is read-only — call
  `get_terminal_image_protocol`, don't modify it.
- Your diff stays within the owner area above.

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S10.
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #70–#72.
