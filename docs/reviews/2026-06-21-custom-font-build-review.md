# Custom Font Build — Deep-Dive Review

**Date:** 2026-06-21
**Scope:** `custom-builds/nerd-fonts/` — `build-updated-font.sh`, the `fontbuild/` package, `recalibrate-fa.sh`, `unicode-donor-glyphs.txt`, `custom-icons/`
**Method:** Reviewed the refactored build as a fresh artifact (no git history). Focus: correctness, architecture, maintainability, performance, simplicity.
**Branch reviewed:** `master` (worktree `~/.local/share/chezmoi-scan`, HEAD `775ef37`)
**Status: all findings fixed and verified — see "Fix verification" at the end.**

---

## Known bug — NOT fixed (two layered defects)

The 4 zj-hud corner characters are **still missing** from the Blink font. The root cause is two layered defects: an allowlist gap (the direct blocker) plus a pipeline range blind spot (would misalign them even if present). A third defect I initially suspected — "no donor covers the Supplement block" — is **wrong**, corrected below.

### The 4 codepoints

Defined in `zj-hud` at `src/search/mod.rs:322-325`, mirrored in `src/rename/mod.rs:88-91`:

| char | codepoint | Unicode name | block |
|------|-----------|--------------|-------|
| `𜺠` | U+1CEA0 | RIGHT HALF LOWER ONE QUARTER BLOCK | **Symbols for Legacy Computing Supplement** (U+1CC00–1CEFF, Unicode 16.0) |
| `𜺣` | U+1CEA3 | LEFT HALF LOWER ONE QUARTER BLOCK | same |
| `𜺨` | U+1CEA8 | LEFT HALF UPPER ONE QUARTER BLOCK | same |
| `𜺫` | U+1CEAB | RIGHT HALF UPPER ONE QUARTER BLOCK | same |

The zj-hud source comment calls them "Symbols-for-Legacy-Computing," but they're actually in the **Supplement** block — a *different* Unicode 16.0 block from the older Legacy Computing block (U+1FB00–1FBFF) that the build does handle. That misidentification is the seed of the bug.

### Defect 1 — allowlist gap (the direct cause)

`unicode-donor-glyphs.txt` lists **371** Supplement-block entries (U+1CC00–U+1CEB3), including every quarter-block in U+1CEA1–U+1CEAF **except exactly the 4 zj-hud uses**:

```
1CEA0 N   1CEA1 Y   1CEA2 Y   1CEA3 N   1CEA4 Y   1CEA5 Y
1CEA6 Y   1CEA7 Y   1CEA8 N   1CEA9 Y   1CEAA Y   1CEAB N
1CEAC Y   1CEAD Y   1CEAE Y   1CEAF Y
```

Every neighbour is listed; the 4 corners are the holes. So even if a donor carried them, the build would never import them.

### Defect 2 — ~~no donor font covers the Supplement block~~ RETRACTED

**Initial claim was wrong.** I checked the 5 default donors against the *currently installed* fonts and found Iosevka absent — but `DONOR_INSTALL=1` is the default, so the build **temporarily installs `font-iosevka`** via `install_donor_casks` (tracked in `DONOR_TEMP_CASKS`, uninstalled on EXIT) and uses it. Iosevka is the last-priority donor precisely to fill gaps the STIX/Noto fonts miss.

Verifying the build-time state (installed `font-iosevka` temporarily, mirroring the build, then uninstalled it): **Iosevka covers all 4 corners and the entire Supplement block.** Every Iosevka face (162 in the TTC) carries `U+1CEA0, 1CEA3, 1CEA8, 1CEAB` plus `1CC00`, `1CEB0`, and the old Legacy Computing block too. So the 371-entry Supplement section in the allowlist **is** resolvable at build time — via Iosevka. The donor side is fine.

This is what makes the allowlist gap (Defect 1) the clean root cause: the donor that *should* supply the corners is present during the build, but the build never asks for those 4 codepoints.

### Defect 3 — cell-normalization + bleed ranges exclude the Supplement block

Even with Defect 1 fixed (corners added to the allowlist, supplied by Iosevka), the corners would render **misaligned** in the Blink JBM font:

- `fontbuild/ranges.py:9` — `LEGACY_LO, LEGACY_HI = 0x1FB00, 0x1FBFF`. This single constant drives three downstream steps, all of which then miss the Supplement block:
  - `donor.py:340` — `LEGACY_LO <= cp <= LEGACY_HI` gates cell-normalization. Supplement glyphs would import at the donor's native metrics, not mapped onto the JBM cell.
  - `donor.py:donor_block_cell` — measures the donor's cell from `range(LEGACY_LO, LEGACY_HI+1)` only, so the Supplement cell is never measured.
  - `ranges.py:25` — `BLEED_RANGES = [(0x2580,0x259F), (LEGACY_LO, LEGACY_HI)]` — Supplement glyphs wouldn't be bled past the cell edges, so they'd tile with a 1px seam against the block-element sides.

The zj-hud frame composes the corners with `BOX_TOP='▂'` (U+2582, Block Elements), `BOX_BOT='🮂'` (U+1FB82, Legacy Computing), `BOX_LEFT='▐'`/`BOX_RIGHT='▌'` (Block Elements). So the corners must align exactly with glyphs from three blocks that *are* handled — but the corners themselves get none of the normalization/bleed pipeline. They'd be the one out-of-cell piece of the frame.

### Fix shape (trace only, not implemented)

No new donor needed — Iosevka already covers the Supplement block at build time. Two changes fix the bug:

1. **Allowlist** — add the 4 cps (`1CEA0`, `1CEA3`, `1CEA8`, `1CEAB`) to `unicode-donor-glyphs.txt` (the build will then pull them from Iosevka).
2. **Range model** — in `ranges.py`, replace the single `LEGACY_LO/LEGACY_HI` scalar with a **list of terminal-cell ranges** covering both blocks (e.g. `TERMINAL_CELL_RANGES = [(0x1FB00, 0x1FBFF), (0x1CC00, 0x1CEFF)]`), and feed it into:
   - the donor cell-normalize gate in `donor.py:340`,
   - the `donor_block_cell` measurement scan,
   - `BLEED_RANGES`.
   (The emoji-keep set is already range-based, so add the Supplement range there too for consistency, though the strip step doesn't touch it — the Supplement block is below `0x1F300`, already outside `EMOJI_STRIP_RANGES`.)

The two-block list is the one-line-change hedge: the next Unicode addition of a third terminal-cell block becomes one range entry, not a four-site edit.

---

## Other findings

### Correctness / robustness

- **`_fontforge_merge.py:153-154` — hardcoded FA metrics.** `EM = 512.0` and `DESC = -64.0` are baked in as "unitsPerEm of the FA combined OTF" and "FA descent" instead of being read from `dest.head.unitsPerEm` / the donor's hmtx after `fontforge.open`. If FA ever changes its UPM or descent, custom-SVG placement silently breaks with no error. Read these from the opened font.

- **Relocation overflow drop is silent-ish.** `_fontforge_merge.py` drops a free FA icon entirely if `native + reserved_start > 0x10FFFD`, printing to stderr. With `reserved_start = 0x100000` this only triggers for natives above `0xFFFFD` (none in FA Free today), so it's a future-proofing guard — fine, but worth a test entry so it isn't dead code.

### Architecture

- **`LEGACY_LO/LEGACY_HI` is the wrong abstraction — and it's the architectural root of Defect 3.** It's named as if "Legacy Computing" is one block, but Unicode 16.0 split the terminal-cell glyphs across two blocks with identical purpose. Every consumer (donor cell-normalize, donor cell measurement, emoji keep, bleed) conceptually wants "terminal cell-fill glyphs" — which is now *two* ranges. A `TERMINAL_CELL_RANGES` list feeding all four consumers would have prevented the misalignment half of the 4-corner bug and would make the next Unicode addition (a third such block) a one-line change instead of a four-site edit. (The *missing* half, Defect 1, is a plain allowlist omission — the range model can't catch that.)

- **No block-level drift detection between allowlist and donors.** `resolve_donors` prints unresolved codepoints one-by-one but doesn't summarize at the block level, so an entire Unicode block silently absent from every donor reads as a long scroll of `U+XXXX` lines rather than one actionable "block X has no donor." The current allowlist happens to be fully resolvable (Iosevka covers the Supplement section), so this is a latent robustness gap, not a live failure — but it's exactly the kind of signal that would have made the 4-corner gap obvious earlier (the gap is an allowlist omission, not a donor failure, so this check wouldn't have caught *these* 4 — but it would catch the next whole-block donor loss).

### Maintainability

- **`recalibrate-fa.sh` silently skips the Blink JBM font.** It globs only `${PRESCALE_DIR}/Symbols*.ttf`, but the pipeline stashes *all* fonts to prescale (including `JetBrainsMonoNerdFontMono-Regular.ttf`). So `./recalibrate-fa.sh 1.0 --install` re-bakes the Symbols variants but leaves the Blink font's icons at the old `ICON_FILL` until a full rebuild. The README's recalibrate docs don't mention this. Either restore JBM too, or state the limitation explicitly.

- **README layout diagram is stale.** `README.md:22-23` and `:166-167` show only `cursor-ai.svg` and `gm.svg`, but `custom-icons/` has 8 SVGs and `metadata.json` has 8 pinned entries (cursor-ai, gm, pi, layout_panel_up, wezterm, zsh, zellij, hammerspoon). The "Codepoint stability" prose is correct; only the diagram/examples rotted.

- **`glyphs_json.py:21` — `custom` maps to `"seti-ui+custom"`.** In `NF_COLLECTION_NAMES`, `"custom": "seti-ui+custom"` is a leftover/copy-paste: the `custom` collection prefix is never produced by curated NF, and the value duplicates the `seti` entry. Harmless (custom SVGs set `collection: "custom"` directly in the entry, not via this map) but it's confusing dead data.

### Performance

- The headline refactor win is real and sound: `pipeline.py` threads one `TTFont` through donor→strip→stash→scale→bleed, parsing each font once and serializing twice (prescale + final) instead of ~4 load/save round-trips per step. Donors are resolved once and shared across all three output fonts. This is the right shape.

- **`verify.py` reopens each TTF per call.** `_cmap` and `_name` each construct a fresh `TTFont(path)`, so each built/shipped font is parsed 2–3× per report. Diagnostic-only, but trivially cacheable — one `TTFont` per path, reuse for cmap + name + size.

- **`donor_block_cell`** scans `range(0x1FB00, 0x1FBFF+1)` (256 cmap lookups) per donor per font. Cheap today; if the Supplement block is added, precompute the union scan once per donor (already what `resolve_donors`' "open once" model encourages).

- **`open_font_faces` eagerly parses the entire Iosevka TTC.** `donor.py` does `list(TTCollection(path).fonts)` for a `.ttc`, which parses **all 162 faces** of the 441 MB `Iosevka.ttc` up front — even though `open_donor` returns on the first face that matches the family and covers a needed codepoint (face 0, "Iosevka Thin"). Donors are resolved once per build and shared, so it's a one-time cost, but it's a ~441 MB / 162-face parse to use a single face. Lazy face iteration (or `TTFont(path, index=0)` + a family check before falling back) would cut that sharply. This predates the refactor (it's inherent to the donor-resolution design) but is the largest single donor-setup cost.

### Simplicity

- The FontForge-merge vs fontTools-pipeline split is well-justified and well-documented (`_fontforge_merge.py` explicitly can't import `fontbuild`; the pipeline is importable). The `ranges.py` single-source-of-truth for codepoint ranges is clean. Module sizes are reasonable (largest is `donor.py` at 347 lines, all cohesive).

- The one simplicity wart is the `LEGACY_LO/LEGACY_HI` scalar pretending to be a range list (see Architecture) — fixing that *simplifies* the consumers rather than complicating them.

---

## Verdict

The refactor is architecturally healthy: the in-memory pipeline, shared donor resolution, and `ranges.py` consolidation are genuine improvements and the code is readable. The 4-corner bug has two causes, both narrow: (1) `unicode-donor-glyphs.txt` omits exactly the 4 Supplement codepoints zj-hud uses — so the build never imports them even though Iosevka (installed at build time) could supply them; (2) `ranges.py` models terminal-cell glyphs as a single U+1FB00–1FBFF block, so even if imported, the corners would skip cell-normalization and bleed and render misaligned against the rest of the zj-hud frame. A donor problem this is **not** — Iosevka covers the Supplement block. **Not fixed.**

---

## Fixes applied

All findings were fixed in the `master` worktree (`~/.local/share/chezmoi-scan`). Every changed line traces to a finding; no incidental edits.

### The 4-corner bug (Defects 1 + 3)

- **`unicode-donor-glyphs.txt`** — added the 4 missing Supplement-block corner codepoints (`U+1CEA0`, `U+1CEA3`, `U+1CEA8`, `U+1CEAB`) in their sorted positions within the existing quarter-block run, each with its Unicode name as a comment.
- **`fontbuild/ranges.py`** — replaced the single-block `LEGACY_LO/LEGACY_HI = 0x1FB00/0x1FBFF` scalar with a `TERMINAL_CELL_RANGES` list spanning both terminal-cell blocks (the older Symbols for Legacy Computing `U+1FB00–1FBFF` **and** the Unicode 16.0 Supplement `U+1CC00–1CEFF`), plus an `in_terminal_cell(cp)` helper. All four consumers now use the list: `EMOJI_KEEP_RANGES`, `BLEED_RANGES`, the donor cell-normalize gate, and the `donor_block_cell` measurement scan. Future terminal-cell Unicode blocks become one range entry.
- **`fontbuild/donor.py`** — updated the import, and changed the cell-normalize gate from `LEGACY_LO <= cp <= LEGACY_HI` to `in_terminal_cell(cp)` so Supplement-block glyphs get cell-normalized onto the destination cell. `donor_block_cell` (which supplies the donor-side cell the affine maps from) was rewritten twice during live Blink verification:
  - first it scanned the union bbox of every terminal-cell glyph, but 2-cell-wide schematics in the Supplement block (e.g. `U+1CC8D` LEFT THIRD INDUCTOR at xMax=1000 in Iosevka, whose real cell is 500) inflated the measured width and squashed every imported glyph into the middle of the destination cell — visible as the corners "not in the absolute corner of the character box";
  - final form measures from `U+2588` FULL BLOCK (the canonical cell-defining glyph `target_cell` already uses for the destination), with a **mode-of-advances fallback** for donors that lack U+2588 (Noto Sans Symbols 2 doesn't carry Block Elements). The fallback matters: without it, `U+1FB82` (🮂, the frame's bottom border "UPPER ONE QUARTER BLOCK") imported from NotoSS2 at native `advance=1000` instead of being remapped to the 600-wide JBM cell, which shoved the bottom-**right** corner off its cell while the bottom-left stayed put — the "3 of 4 correct" symptom. Mode (not min or max) of the terminal-cell advances is the robust 1-cell width: block/box glyphs vastly outnumber schematics, so the mode is the cell width; min underreports (a stray narrow glyph), max overreports (2-cell schematics).

### Performance — Iosevka TTC eager slurp (15 s / 71 GB → 0.03 s / ~0)

- **`fontbuild/donor.py`** — `open_font_faces` is now a generator that opens TTC faces lazily one at a time by index (`TTFont(path, fontNumber=i, lazy=True)`) instead of `list(TTCollection(path).fonts)`. `open_donor` consumes the generator and `font.close()`s each non-matching face to release its file handle. Non-TTC donors (small Noto/STIX files) stay eager. Measured: full 5-family `resolve_donors` dropped from ~15 s / 71 GB peak to **0.66 s** / negligible memory.

### Correctness — hardcoded FA metrics

- **`fontbuild/_fontforge_merge.py`** — `import_custom_svgs` now reads `EM = float(dest.em)` and `DESC = float(dest.ascent - dest.em)` from the opened FontForge font instead of the hardcoded `512.0` / `-64.0`. Verified against the real FA 7.2.0 OTFs: `em=512`, `ascent=448`, so `DESC = -64` reproduces the old value exactly; custom-SVG placement (cursor-ai at U+10FB00: advance=512, bbox y=[-64,448], height=512) is identical to before, but now survives an FA UPM/descent change.

### Maintainability

- **`recalibrate-fa.sh`** — now globs `${PRESCALE_DIR}/Symbols*.ttf` **and** `${PRESCALE_DIR}/JetBrains*.ttf`, so the Blink JBM font's icon sizing is recalibrated alongside the Symbols variants (was silently skipped, leaving Blink stale until a full rebuild). Added a note that the Blink CSS itself still embeds the old JBM base64 and needs a full `build-updated-font.sh` to re-emit.
- **`README.md`** — updated the stale layout diagram and the inline mapping example to list all 8 custom SVGs (cursor-ai, gm, hammerspoon, layout_panel_up, pi, wezterm, zellij, zsh) instead of the old 2.
- **`fontbuild/glyphs_json.py`** — removed the dead/copy-paste `"custom": "seti-ui+custom"` entry from `NF_COLLECTION_NAMES` (the `custom` collection prefix is never produced by curated NF; custom SVGs set `collection: "custom"` directly on the entry).

### Performance — verify.py reopen

- **`fontbuild/verify.py`** — added a per-path `TTFont` cache (`_font_cache`) so each built/shipped Symbols TTF is parsed once per report instead of 2–3× (cmap + family name + size). Diagnostic-only, but trivially correct.

---

## Fix verification

Each fix was run against real inputs (the live `~/.local/share/chezmoi/custom-builds/nerd-fonts/build/` artifacts, the real FA 7.2.0 cask OTFs, and a temporarily-installed `font-iosevka` mirroring `DONOR_INSTALL=1`).

- **4 corners import + cell-normalize:** `resolve_donors` resolves all 4 via Iosevka (0 unresolved); `import_into` against the real JBM font imports all 4 (`imported=4, norm=4`), each with advance = JBM cell width (600), matching the old-Legacy `U+1FB00` behaviour. 0 missing after import.
- **Emoji-strip keep set:** `in_strip_range` returns `keep` for all 4 corners plus the old Legacy block and the full Supplement block, and `strip` for the emoji ranges — no regression.
- **Bleed ranges:** all 4 corners are in `BLEED_RANGES` so they'll be bled past the cell edges to tile flush with the `▂ ▐ ▌` frame sides.
- **Iosevka lazy perf:** `resolve_donors` for the 4 corners + 2 neighbours across all 5 families = 0.66 s (was 14.83 s for eager Iosevka open alone); the returned donor's late `glyf`/`hmtx`/`head` access works for `import_one`.
- **FA metrics read:** FontForge merge run with the real FA OTFs + all 8 custom SVGs → all 8 pinned at their codepoints, cursor-ai bbox reproduces the hardcoded-metric placement exactly (upm=512, advance=512, y=[-64,448]).
- **glyphs.json:** emits valid JSON (17,414 entries, 8 custom); no `"seti-ui+custom"` leak into `usr-*` collections.
- **verify.py:** runs clean against live build output with the cache.
- **Compile/syntax:** all 10 `fontbuild` modules `py_compile` clean; `recalibrate-fa.sh` and `build-updated-font.sh` pass `bash -n`.
- **Orphans:** no lingering `LEGACY_LO`/`LEGACY_HI`/`TTCollection` references in code (only in the donor.py docstring explaining the replacement).

### End-to-end build + live Blink confirmation

A full `build-updated-font.sh --install` was run with the fixed scripts (reusing the live build dir's cache), the rebuilt Blink CSS was served via `serve-blink-assets.sh`, and the font was re-imported into Blink Shell on iPad. **The four zj-hud search/rename frame corners render flush in their absolute cell corners.** Two follow-on geometry bugs surfaced during this live check and were fixed in the same pass (see the `donor_block_cell` note above): the union-bbox outlier squashing, and the NotoSS2-lacks-U+2588 fallback that broke `U+1FB82` and the bottom-right corner.
