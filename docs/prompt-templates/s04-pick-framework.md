# Silo S4 — pick framework + symbols pickers

> The from-scratch fzf picker engine (`pick::*`) that standardizes every
> fuzzy picker, plus the symbols.db-backed glyph/gitmoji pickers. The single
> largest custom subsystem; consumed by S1, S6.

## Setup

```sh
git worktree add ../s04-pick-work master
cd ../s04-pick-work
```

## Your scope (owner area — safe to edit)

- `home/dot_local/lib/pick-common.zsh` (`pick::*`), `pick.jq`
- `home/dot_local/lib/pick-symbols-common.zsh` (`pick_symbols::*`)
- `home/dot_local/libexec/executable_pick-list`, `pick-glyph`, `pick-gitmoji`

## Out of scope (do not edit — owned by other silos)

- `zj::pick` (the Zellij floating adapter) → **S1** (it's a thin drop-in that
  *calls* `pick-list`/`pick::start`).
- The Zellij modal adapters `pick-{glyph,gitmoji}-zellij` → **S1**.
- The `symbols.db` *builder* → **S5**. You read the DB; you don't build it.
- Consumers in S6 (`ai-assist`/`ai-commit` pickers) and S1
  (`quick-launch-pick`) — they call `pick::start`/`zj::pick`.
- `home/dot_local/lib/common.zsh` → **S9/S13** (you source it read-only for
  `require_cmd`/`die`).

## Contracts you must preserve

These are load-bearing for ≥3 silos (S1, S6, and the glyph/gitmoji pickers):

- **`pick::start [flags] LINES_CACHE_OR_STDIN`** — the core entry. Flags
  include `--cache-usage` (recency), `--cache-state`/`--resume` (cursor
  restore), `--selector`/`--selector-shortcuts`/`--selector-nav`,
  `--key-background` (insert-without-dismiss FIFO broker),
  `--key-output <key>:<kind>:<field>`, `--multi[=SEP]`, `--copy-only`,
  `--on-items-picked <cmd>`, `--output`, `--name`. Also `pick::line`,
  `pick::run`, `pick::feed`, `pick::clipboard`, `pick::record`.
- **Wire format** (shared with `pick.jq`): each line
  `<visible>\x1f<tail[0]>\x1e<tail[1]>…`. US (`\x1f`) splits the ANSI-colored
  visible display (fzf renders via `--with-nth=1`) from the hidden plain-text
  tail; RS (`\x1e`) splits tail fields. Last tail field = raw glyph by
  convention (so ANSI never leaks to stdout). `pick.jq` defines the canonical
  Catppuccin SGR sequences + `emit_line`.
- **Recency**: file-based for non-DB pickers (`--cache-usage`), SQLite
  `last_used` via `--on-items-picked` for DB pickers.
- **`PICK_INJECT_PANE` / `PICK_INJECT_ZELLIJ`** env — the `--key-background`
  FIFO broker injects into these.
- **`PICK_GLYPH_DB`** env (default
  `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db`) — the DB
  path contract with S5.

## What you consume read-only

- S5: `symbols.db` at `PICK_GLYPH_DB` (schema owned by S5 — if you need new
  columns, coordinate with S5)
- S9: `common.zsh` stdlib
- S1: `zj::pick` adapter, `zellij-modal --capture` FIFO for floating pickers

## Where to start

`pick-common.zsh` (`pick::start` at ~line 650), `pick.jq`, `libexec/pick-glyph`.

## TASK

> _<describe the assignment — e.g. "Review the `pick::` engine for
> performance; large pickers (e.g. the 29k-row glyph picker) feel sluggish" >_

**Verify before claiming done:**
- Run the relevant ShellSpec: `make test` (covers the `lib/` primitives).
- Reproduce with a real picker (e.g. `Ctrl+Shift+u` glyph picker in Zellij,
  or `pick-list` standalone).
- The wire format (`\x1f`/`\x1e`) and `pick::start` flag set are a public
  contract — confirm S1's `quick-launch-pick` and S6's `ai-assist`/`ai-commit`
  pickers still work unchanged.
- Your diff stays within the owner area above.

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S4 (note the S4↔S5
  symbols.db schema contract — the tightest cross-silo seam).
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #49–#51.
