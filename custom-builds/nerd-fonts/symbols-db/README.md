# custom-builds / nerd-fonts / symbols-db

Builds a **SQLite database of every glyph worth picking in a terminal** — the
custom Nerd Font build, the standard Unicode repertoire, and emoji
shortcode/metadata sets (gemoji, iamcal emoji-data, gitmoji) — for an fzf-based
symbol picker.

The output is a **single flat `symbols` table** tuned for the picker: one row
per symbol, no joins, streams straight off the recency index. The rich upstream
sources are merged down at build time into the few columns the picker needs.

## Usage

```bash
# Full build to the default location (next to glyphs.json):
#   $XDG_DATA_HOME/fonts/nerd-font/symbols.db
./build-symbols-db.py

# Common flags
./build-symbols-db.py --refresh           # re-fetch upstream emoji sources
./build-symbols-db.py --offline           # use cached upstream copies only
./build-symbols-db.py --no-render-filter   # keep all codepoints (skip CoreText)
./build-symbols-db.py --refresh-render     # re-probe renderability
./build-symbols-db.py --sources unicode,gemoji   # subset of sources
./build-symbols-db.py --db /tmp/test.db   # alternate output
```

Pure Python 3 standard library (`sqlite3` / `unicodedata` / `urllib`) plus an
optional `swift` for the macOS renderability probe — no pip dependencies, no
venv.

## Sources (upstream material, not picker caches)

| source key          | material                                              |
|---------------------|-------------------------------------------------------|
| `nerd-fonts-curated`| `glyphs.json` (this directory's font build artifact)  |
| `font-awesome-7`    | `glyphs.json`                                          |
| `custom-svg`        | `glyphs.json`                                          |
| `unicode-stdlib`    | Python `unicodedata` (not the picker's suppl cache)   |
| `gemoji`            | `github/gemoji` `db/emoji.json` (→ `github` shortcodes)|
| `iamcal`            | `iamcal/emoji-data` `emoji.json` (→ `slack`/`emoticon`)|
| `gitmoji`           | `carloscuesta/gitmoji` `gitmojis.json` (→ `gitmoji`)  |

Re-running reconciles the DB to the current material and **preserves recency**
(`last_used`, keyed by the stable `symbol` string; migrates the older
`last_selected_at` column automatically). Downloaded sources and the
renderability probe are cached under `$XDG_CACHE_HOME/symbols-db/`.

## Design decisions

- **Single table.** Sources are merged into one denormalized row per symbol.
  Internally the merge still dedups on `code_seq` (the uppercase hyphen-joined
  hex sequence with variation selectors stripped); that key is not stored.
- **Base-only codepoints.** `code_point` is the base integer (rendered as
  `U+XXXX`); skin-tone variants are not exploded into rows.
- **One primary shortcode, faceted extras.** `shortcode` is a single value
  chosen by source priority **gitmoji > github > slack > emoticon**. The rest of
  the searchable metadata is split into typed facet columns so a picker can
  anchor on each: `extra_shortcodes` (other platforms' codes), `source_keys`
  (icon-font glyph keys like `cod-account` / `fa-rocket` / `iec-power`; the raw
  `u-<hex>` Unicode keys are dropped as they only re-encode the code point), and
  `keywords` (upstream terms/categories). `tags` is the collection facet
  (`emoji`, `gitmoji`, `nerd-font`, `fontawesome`, `custom`, `unicode`).
- **`description` is rich-only.** It holds genuine human-written prose and
  nothing else — only `custom-svg` (curated `description`) and `gitmoji` (intent
  text, e.g. *"Fix a bug."*) populate it (`RICH_DESC_SOURCES`). Name-ish text
  from other sources (gemoji CLDR names, FA labels) is folded into `keywords`
  instead, so it stays searchable without polluting the column. This keeps the
  column reusable elsewhere (e.g. backing the gitmoji picker off this DB).
- **Custom icons are overlaid from source.** `build-symbols-db.py` reads
  `custom-icons/metadata.json` directly (`--custom-meta`) as the authoritative
  source for custom glyphs, mapped 1:1 (`label`→`name`, `description`,
  `keywords`, `shortcode`→primary `shortcode`, `aliases`→`extra_shortcodes`);
  `glyphs.json` only supplies their codepoint.
  So editing custom metadata needs just a DB rebuild, not a full font rebuild.
- **`name` is never empty.** Official name (Unicode name, or a custom icon's
  `label`) when available, otherwise a source key (so PUA icons read as
  `fa-rocket` / `nf-...`), otherwise the glyph.
- **Non-drawing categories dropped.** Symbols whose base codepoint is an
  invisible control/format/separator or a standalone combining mark
  (`DROP_CATEGORIES`: Cc/Cf/Cs/Cn/Zl/Zp/Zs/Mn/Me/Mc) are filtered at the merge
  step. Private use (Co) is kept.
- **Baked host renderability.** `RENDER_EXCLUSIONS` ranges are dropped from
  every source; the Unicode enumeration is additionally gated by a
  renderability probe (PUA and emoji-dataset rows bypass it). The resulting DB
  is **host-specific** — rebuild per machine.
  - **Probe = your terminal, not the system cascade.** When `wezterm` is
    present it's the oracle: `wezterm ls-fonts --text` reports the glyph it
    resolves per codepoint, and anything that comes back `.notdef` (tofu) is
    dropped — so the DB matches what *this terminal* can actually draw, not just
    what some installed font covers. The probe runs at the runtime
    `custom_block_glyphs` setting and counts a codepoint renderable if WezTerm
    paints it with its built-in box/block/braille/legacy renderer (`drawn by
    wezterm …`) **or** the font fallback has a real glyph. That single pass
    handles the natively-drawn ranges correctly — no force-keep list — so e.g.
    sextants/octants/diagonals WezTerm supports stay while the Unicode-16
    diagonal/circle fragments it can't draw (and no font has) are dropped.
    Falls back to the macOS CoreText probe (broader) when `wezterm` is absent,
    or no filter when neither is available. Verdicts are cached per mode under
    `$XDG_CACHE_HOME/symbols-db/render-cache-<mode>.json`; the first run is slow
    (the probe batches through WezTerm's glyph atlas), subsequent runs reuse the
    cache.

## Schema

```sql
CREATE TABLE symbols (
  symbol           TEXT PRIMARY KEY,          -- the glyph
  code_point       INTEGER NOT NULL,          -- base integer, rendered as U+%04X
  display_width    INTEGER NOT NULL DEFAULT 1, -- 1 or 2 cells, for picker padding
  name             TEXT NOT NULL DEFAULT '',  -- official name / label / source key / glyph
  description      TEXT NOT NULL DEFAULT '',  -- rich prose only (custom + gitmoji)
  shortcode        TEXT NOT NULL DEFAULT '',  -- single primary, by source priority
  extra_shortcodes TEXT NOT NULL DEFAULT '',  -- other platforms' shortcodes (search)
  source_keys      TEXT NOT NULL DEFAULT '',  -- icon-font glyph keys: cod-/fa-/iec-...
  keywords         TEXT NOT NULL DEFAULT '',  -- upstream terms/categories (search)
  tags             TEXT NOT NULL DEFAULT '',  -- collection facet (e.g. "emoji gitmoji")
  last_used        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_symbols_recency  ON symbols(last_used DESC, name ASC);
CREATE INDEX idx_symbols_shortcode ON symbols(shortcode);
```

## Example queries

```sql
-- recency-ordered picker stream (the picker assembles the display line itself)
SELECT symbol, name, code_point, description, shortcode,
       extra_shortcodes, source_keys, keywords, tags
FROM symbols ORDER BY last_used DESC, name ASC;

-- resolve a shortcode to its glyph (primary first, then the extras)
SELECT symbol, name FROM symbols
WHERE shortcode = 'rocket'
   OR (' '||extra_shortcodes||' ') LIKE '% rocket %';

-- bump recency when a symbol is picked
UPDATE symbols SET last_used = strftime('%s','now') WHERE symbol = '🚀';
```

## Status / follow-ups

- Current build (WezTerm probe, this host): ~29k symbols — PUA nerd/FA icons
  ~11.6k, plus the renderable Unicode + emoji repertoire; ~1.65k carry a
  shortcode. The probe drops ~18k Unicode codepoints that tofu in WezTerm
  (unrenderable scripts like Adlam, etc.).
- The picker query is a single index scan (`idx_symbols_recency`, no SORT step),
  so rows stream to fzf immediately — see `~/glyph-test.zsh`.
- The Enclosed Alphanumeric Supplement (`U+1F100..U+1F1FF`) is a candidate
  additional `RENDER_EXCLUSIONS` range — left out pending confirmation.
