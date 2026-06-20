# Silo S5 — Custom builds

> The custom Symbols Nerd Font builder (~2740 lines), the `symbols.db`
> generator (~46K Python), and the non-unicode9 zsh build. Exists to fix
> terminal rendering bugs the upstreams won't (FA version lag, post-2016
> emoji widths).

## Setup

```sh
git worktree add ../s05-custom-builds-work master
cd ../s05-custom-builds-work
```

## Your scope (owner area — safe to edit)

- `custom-builds/nerd-fonts/` — `build-updated-font.sh`, `recalibrate-fa.sh`,
  `custom-icons/*.{svg,metadata.json}`, `unicode-donor-glyphs.txt`,
  `symbols-db/build-symbols-db.py` + `README.md`
- `custom-builds/zsh/` — `build-zsh.sh` + `README.md`

The **build-trigger chezmoiscripts** live in S12 (`run_onchange_after_70-
symbols-nerd-font`, `run_onchange_after_60-symbols-db`, `run_after_80-
symbols-nerd-font-prompt`, `run_onchange_after_50-custom-build-zsh`). The
*trigger logic* (hash-baked fingerprints) is S12; the *builder* is S5. If you
need to change what inputs trigger a rebuild, coordinate with S12.

## Out of scope (do not edit — owned by other silos)

- Font *consumers*: S1's WezTerm `font_with_fallback` chain + Ghostty
  `font-codepoint-map`, S3's OSD glyph rendering — they reference built
  artifacts by family name/path; you only owe them a stable artifact path +
  format.
- The pickers (S4) read `symbols.db` — you owe them a stable schema.
- chezmoi run-scripts under `home/.chezmoiscripts/` → **S12**.

## Contracts you must preserve

- **`symbols.db`** at `${XDG_DATA_HOME:-~/.local/share}/fonts/nerd-font/symbols.db`
  — single flat `symbols` table, one row per symbol, faceted columns (primary
  shortcode by source priority `gitmoji>github>slack>emoticon`,
  `extra_shortcodes`, `source_keys`, `keywords`, `tags`, `last_used`). Schema
  is consumed read-only by S4 (`pick-glyph`/`pick-gitmoji`) and S3 (OSD
  `glyph:` resolver). **Schema changes require coordinating S4.**
- **Renderability probe**: `wezterm ls-fonts --text` oracle (drops `.notdef`),
  CoreText fallback; verdicts cached under `$XDG_CACHE_HOME/symbols-db/`.
  Re-running preserves `last_used`.
- **Patched font artifacts**: the Symbols Nerd Font (and the JetBrains-Mono
  NF for Blink) installed to the user font dir; the Blink CSS (embedded fonts
  + Noto OT-SVG). S1's font chains reference these by family name; the
  custom-icons `code` pins in `metadata.json` must stay stable (S1/S3 glyph
  lookups depend on them).
- **Custom `zsh`** at `~/.local/opt/zsh` + symlink `~/.local/bin/zsh`,
  registered in `/etc/shells` + `chsh`. Built *without* `--enable-unicode9`.
  macOS work/personal only (template-gated).

## What you consume read-only

- S12: chezmoi `run_onchange` triggers + the hash-baked fingerprints
- Upstream: zsh source, Font Awesome, Nerd-Fonts patcher, `wezterm ls-fonts`
  (oracle)

## Where to start

`custom-builds/nerd-fonts/build-updated-font.sh`,
`custom-builds/nerd-fonts/symbols-db/build-symbols-db.py`,
`custom-builds/zsh/build-zsh.sh`.

## TASK

> _<describe the assignment — e.g. "The custom Nerd Font build is too slow;
> investigate what is going on and propose/make improvements" >_

**Verify before claiming done:**
- Actually run the build end-to-end and time it (`chezmoi apply` with the
  font/DB markers triggered, or invoke the builder directly).
- Confirm the output contract: `symbols.db` still opens and its schema is
  unchanged (S4 pickers still work); the patched font family name + custom-icon
  `code` pins are unchanged (S1 font chain still resolves glyphs).
- Don't commit built artifacts (they're gitignored / outside the repo).
- Your diff stays within `custom-builds/` (coordinate S12 if a trigger hash
  must change).

## Reference

- [`../chezmoi-silo-map.md`](../chezmoi-silo-map.md) — §S5 (S5↔S4 schema
  contract, S5↔S1 font-pin contract).
- [`../chezmoi-unique-features.md`](../chezmoi-unique-features.md) — features
  #61–#63.
