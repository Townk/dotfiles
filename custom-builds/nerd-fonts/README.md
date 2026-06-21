# custom-builds / nerd-fonts

This directory builds a personal copy of the **Symbols Nerd Font** family
(Mono + Propo variants) that bundles the latest Font Awesome icons on top
of the latest Nerd Fonts symbol collections.

It exists because the upstream Homebrew cask
`font-symbols-only-nerd-font` is pinned to the slow-moving Nerd Fonts
release cadence (currently FA 6.5.1 inside Nerd Fonts v3.4.0), so it lags
the FA cask (`font-fontawesome`) by entire major versions.

## Layout

```
custom-builds/nerd-fonts/
├── README.md                ← you are here
├── build-updated-font.sh    ← self-contained builder
├── recalibrate-fa.sh        ← fast re-bake of icon sizing (no patcher rerun)
├── unicode-donor-glyphs.txt ← small OFL donor-glyph allowlist
├── custom-icons/            ← local *.svg icons baked into the font
│   ├── metadata.json        ←   optional labels/keywords/shortcode/aliases/descriptions/code pins
│   ├── cursor-ai.svg        ←   -> usr-cursor-ai
│   ├── gm.svg               ←   -> usr-gm
│   ├── hammerspoon.svg      ←   -> usr-hammerspoon
│   ├── layout_panel_up.svg  ←   -> usr-layout_panel_up
│   ├── pi.svg               ←   -> usr-pi
│   ├── wezterm.svg          ←   -> usr-wezterm
│   ├── zellij.svg           ←   -> usr-zellij
│   └── zsh.svg              ←   -> usr-zsh
└── build/                   ← created at runtime, gitignored
    ├── nerd-fonts/          ← shallow clone of ryanoasis/nerd-fonts
    ├── work/                ← merged FA OTF, build logs
    ├── output/              ← the produced TTFs
    └── .venv/               ← fonttools venv for verification
```

`custom-builds/` lives at the **repo root** (outside chezmoi's `home/`
source dir), so **chezmoi never touches it**. Git tracks the scripts and
this README; everything under `build/` is .gitignored.

## How it gets invoked

Two paths, both end up running the same `build-updated-font.sh`:

1. **Automatically, change-driven** — via the chezmoi hooks under
   `~/.local/share/chezmoi/home/.chezmoiscripts/`:
   - `run_onchange_after_70-symbols-nerd-font.sh.tmpl` tracks static font
     inputs: `build-updated-font.sh`, `unicode-donor-glyphs.txt`, custom SVGs,
     and custom metadata `code` pins.
   - `run_onchange_after_60-symbols-db.sh.tmpl` tracks static DB inputs:
     `build-symbols-db.py` and the full custom metadata file.
   - `run_after_80-symbols-nerd-font-prompt.sh.tmpl` runs on every apply,
     detects host/runtime changes (`font-fontawesome` cask version and the
     shared WezTerm render signature), and prompts only when a marker is
     pending and a TTY is available.

   Metadata-only search edits rebuild the DB, not the font. Font rebuilds also
   rebuild the DB afterwards because `glyphs.json` changed. Declining a prompt
   clears the marker intentionally; build failures keep the marker so the next
   interactive apply can retry.

2. **Manually, any time you want** — just invoke the script directly:

   ```bash
   ~/.local/share/chezmoi/custom-builds/nerd-fonts/build-updated-font.sh --install
   # (custom-builds/ is at the repo root, not under home/)
   ```

   The script auto-detects the FA OTFs from the `font-fontawesome`
   cask's Caskroom, so re-running picks up whatever version brew last
   synced. It also fast-forwards the shallow `build/nerd-fonts/`
   clone to the latest `master`.

   To force the chezmoi hook to re-fire on the next apply (e.g. after
   wiping `~/Library/Fonts/Symbols*.ttf` and wanting the prompt back):

   ```bash
   chezmoi state delete-bucket --bucket=scriptState
   ```

## What it produces

```
build/output/SymbolsNerdFont-Regular.ttf      (variable-width / "Propo")
build/output/SymbolsNerdFontMono-Regular.ttf  (monospaced)
~/.local/share/fonts/nerd-font/glyphs.json    (glyph index, for pickers)
```

With `--install`, the two `.ttf` files are copied into `~/Library/Fonts/`
(replacing whatever the upstream cask put there, if anything). The
`glyphs.json` file always lands in `~/.local/share/fonts/nerd-font/`
regardless of `--install`. Override with `JSON_OUT_DIR=/some/where`,
or disable with `JSON_OUT_DIR=""`.

### Unicode donor glyphs

After the Nerd Fonts patcher runs, the build imports an explicit allowlist of
real Unicode symbols from OFL-licensed donor fonts into both Symbols variants.
This exists for keyboard/media/power glyphs, the exact Iosevka fallback delta,
and the current STIX/Noto runtime fallback rows that were useful in the terminal
but not worth keeping as broad runtime fallbacks in WezTerm's startup path.

Default donor order:

```
STIX Two Math
Noto Music
Noto Sans Symbols 2
Noto Sans Math
Iosevka
```

The imported codepoints live in `unicode-donor-glyphs.txt`. Codepoints already
present in Symbols Nerd Font are skipped. The Iosevka section was generated from
a fresh WezTerm render probe: `30,975` picker rows without Iosevka versus
`31,827` with Iosevka as the final fallback, for an exact `852` row delta. The
STIX/Noto section was generated from the current WezTerm resolver before pruning
those runtime fallbacks: `STIX Two Math` (`1,276` rows), `Noto Music` (`478`),
`Noto Sans Symbols 2` (`954`), and `Noto Sans Math` (`206`). Step 7 still strips
normal colour-emoji mappings so Apple Color Emoji can win, but it preserves
explicit donor entries from this file; that matters for non-emoji symbols in
`U+1Fxxx` blocks. Override with `DONOR_GLYPH_FILE=/path/to/list`, add temporary
build-only fonts with `DONOR_FONT_PATHS=/path/font.ttf:/path/font.otf`, or
disable the step with `DONOR_GLYPH_FILE=""`.

Missing Homebrew donor casks are installed non-interactively for the build by
default, then the script uninstalls only the casks it installed itself. Existing
user-installed fonts are left alone, whether they came from Homebrew or are just
present on disk. Set `DONOR_INSTALL=0` to use only fonts already present or
explicitly named in `DONOR_FONT_PATHS`. Iosevka is last on purpose, matching the
old fallback order: STIX/Noto win where they cover a glyph, and Iosevka fills
only the remaining gaps.

### `glyphs.json`

A single index of every glyph in the built font, with searchable
natural-language metadata. Top-level shape:

```json
{
  "schema_version": 1,
  "generated_at": "2026-05-28T...",
  "font_family": "Symbols Nerd Font",
  "sources": { "nerd_fonts_commit": "...", "font_awesome_version": "7.2.0", ... },
  "stats":   { "total_named_entries": 13115, "by_source": { ... } },
  "glyphs":  { "<name>": { "code": "f015", "char": "", ... } }
}
```

Each entry always has `code`, `char`, and `source`; optional fields
depend on the source:

| key prefix | source             | extra fields                                  |
|------------|--------------------|-----------------------------------------------|
| `nf-*`     | curated NF glyph   | `collection`, sometimes FA tags, `unicode_name` |
| `fa-*`     | FA 7 native add-in | `collection`, `label`, `styles`, `terms`, `aliases`, sometimes `relocated_from` |
| `usr-*`    | local custom SVG   | `source: custom-svg`, `collection: custom`, `label`, `keywords`, `shortcode`, `aliases`, `description` |
| `u-*`      | unicode fallback   | `unicode_name`                                |

The `fa-*` prefix is deliberate so FA 7 native additions never collide
with the curated `nf-fa-*` set even when both reference the same
codepoint. Local custom SVGs (see below) get their own `usr-*` namespace
so they're instantly distinguishable from the official FA / NF glyphs
(e.g. `usr-cursor-ai`, `usr-gm`).

## Custom SVG icons

Drop any `.svg` into `custom-icons/` and the build bakes it into the font
as a Plane-16 PUA glyph, keyed `usr-<filename>` in `glyphs.json`:

```
custom-icons/cursor-ai.svg       ->  usr-cursor-ai
custom-icons/gm.svg              ->  usr-gm
custom-icons/hammerspoon.svg      ->  usr-hammerspoon
custom-icons/layout_panel_up.svg  ->  usr-layout_panel_up
custom-icons/pi.svg               ->  usr-pi
custom-icons/wezterm.svg          ->  usr-wezterm
custom-icons/zellij.svg           ->  usr-zellij
custom-icons/zsh.svg              ->  usr-zsh
```

Each SVG is first normalized with [`usvg`](https://github.com/linebender/resvg)
(resolves CSS `<style>` fills, converts shapes to paths, bakes transforms,
resolves clips/masks) so it imports faithfully no matter where the source SVG
came from — you rarely control that. It's then imported and, like every other
icon, normalized in step 7b to the curated **md/oct box** (aspect preserved,
centred), so it lines up with its neighbours at one consistent size. Custom
icons are tagged `"source": "custom-svg"`, `"collection": "custom"`.

`usvg` is declared in `~/.config/packages/Cargofile` (`system-package cargo
sync`); the build also installs it on demand if missing. Without it, SVGs
import raw (less robust to source quirks).

### `metadata.json` (optional)

Drop a `custom-icons/metadata.json` next to the SVGs to give each icon proper
search metadata instead of the auto-derived filename guess (this is the
custom-icon analogue of FA's `icons.json`). It is keyed by icon name (the SVG
filename minus `.svg`), and every field is optional:

```json
{
  "_comment": "this header key is ignored (starts with _)",
  "cursor-ai": {
    "label": "Cursor",
    "keywords": ["cursor", "ai", "cube", "editor"],
    "shortcode": "cursor-editor",
    "aliases": ["anysphere"],
    "description": "Cursor (the AI code editor) brand cube logo"
  }
}
```

Every field maps 1:1 to a column in the final symbols DB, so it's obvious what
to add and where it lands:

| field         | effect                                                          |
|---------------|-----------------------------------------------------------------|
| `label`       | human title → the symbol's `name` (falls back to title-cased name)|
| `keywords`    | extra fuzzy-search terms → `keywords` (falls back to name split on `-`)|
| `shortcode`   | the single primary shortcode (`:like-this:`) → the `shortcode` column|
| `aliases`     | the extra shortcodes (`:like-this:`) → `extra_shortcodes`        |
| `description` | rich, human-written sentence → the rich-only `description` column|
| `code`        | hex codepoint to **pin** this icon to (e.g. `"10fb00"`)          |

The symbols-db build reads this file directly as the authoritative overlay for
custom glyphs, so editing it only needs a DB rebuild — not a full font rebuild.

Keys beginning with `_` or `$` are ignored (handy for a file header), and an
`{"icons": { … }}` wrapper is accepted if you prefer. Icons with no entry —
or SVGs added without touching this file — still build fine on the fallback
defaults.

## Codepoint stability (read before hard-coding in a TUI)

The stable identifier is always the `glyphs.json` **name** (`fa-house`,
`usr-cursor-ai`); resolve name → codepoint at build time if you can. If you must
hard-code a raw codepoint:

- **Native `fa-*`** (no `relocated_from`): FA's official PUA codepoint. Stable
  unless FA itself reassigns it, or a nerd-fonts update newly claims that
  codepoint for a curated glyph (which would push it into the relocated set).
- **Relocated `fa-*`** (`U+100000`+, has `relocated_from`): **stable.** The
  slot is `0x100000 + native_codepoint` — a pure function of the icon's own FA
  codepoint, independent of which *other* icons collide. So `fa-house` (`f015`)
  is always `U+10F015`. (Before 2026-06 these used a running counter and *did*
  shift on FA/NF updates — that's fixed.)
- **Custom** (`U+10fb00`+): **stable if pinned** with a `code` in
  `metadata.json`. Unpinned icons are auto-assigned in sorted-filename order,
  so adding/renaming a file can shift the unpinned ones. Pin anything a TUI
  depends on.

Auto-assigned custom codepoints start at `CUSTOM_START` (default `0x10fb00`),
which sits above the relocation landing zone (relocated FA icons use
`0x100000 + native`, i.e. up to ~`0x10f8ff`), so the two blocks never overlap.
Pinned `code` values share the same custom block. Override the source dir with
`CUSTOM_ICON_DIR=/path` or skip the step entirely with `CUSTOM_ICON_DIR=""`.

Caveats:
- A custom icon lives only in this font (like every PUA nerd icon); it is
  not portable as a raw codepoint — fine for a picker that copies the glyph.
- Multi-colour SVGs are flattened to a single monochrome outline (font
  glyphs have no colour). The fill / holes are derived from the path
  geometry, so a clean single-path logo works best. The `usvg` pre-pass
  resolves CSS fills, shapes, clips and transforms first, so messy exports
  (Illustrator, Figma) usually still import cleanly.
- Codepoint stability: pin a `code` in `metadata.json` for anything you hard-
  code. Unpinned icons are auto-assigned in sorted-filename order, so adding
  or renaming a file can shift the unpinned ones (their `usr-<name>` keys stay
  stable regardless). See "Codepoint stability" above.

**All free FA icons are included.** Roughly 1000 of FA Free's 1970 icons
have a native codepoint already owned by another Nerd Fonts collection;
the patcher's careful mode would drop them. The build relocates those to
a reserved **Plane-16 PUA** block (U+100000+) so they survive — such
entries carry a `relocated_from` field pointing at FA's original
codepoint. A relocated icon renders only via this font (like any PUA
nerd icon), which is exactly what a glyph picker needs.

**Icon sizing (step 7b).** Every icon is normalized to one consistent size so
nothing renders too big or bleeds out of the cell — and crucially this is baked
*into the font*, not left to the terminal. Ghostty re-sizes Nerd-Font icons by
codepoint at render time, but WezTerm does not, so a font tuned only for
Ghostty's render-time scaling looked wrong (oversized, bleeding) in WezTerm.

Step 7b measures the curated **Material-Design + Octicons** glyphs already in
the built font (their median box and vertical centre) and scales every Font
Awesome glyph — native *and* relocated — plus every custom SVG icon to that
box, aspect preserved, about its own centre, then drops it onto that centre.
Advance widths are untouched (with the Propo variant the only spill is harmless
horizontal right-overflow). Curated glyphs are the reference and are left
alone. md/oct is measured per-variant, so the Propo build lands at ≈0.83em and
the Mono build at ≈1.0em, each matching its own curated glyphs.

The fill fraction is a matter of taste, so tune it without a full rebuild:

```sh
./recalibrate-fa.sh 1.0 0.0 --install   # 1.0 = match md/oct exactly; install
./recalibrate-fa.sh 0.95 --install      # inset to 95% of the md/oct box
```

Once it looks right, set those numbers as the `ICON_FILL` / `ICON_DY` defaults
in `build-updated-font.sh` so a clean rebuild reproduces them. (Note for
Ghostty users: it still re-fits the curated + native-FA populations to its own
`icon_height` at render time — harmless — while showing the baked size for the
relocated + custom PUA glyphs.)

Wired for fzf via the example printed at the end of every build (and
shown again at the bottom of this README).

## Caveats worth remembering

1. `font-symbols-only-nerd-font` (the upstream Symbols cask) must **not**
   be in the chezmoi Brewfile. If it stays, `brew bundle` / `brew upgrade`
   will silently overwrite this script's output with the cask's stale
   bytes the next time the cask version moves.
2. `font-fontawesome` (the upstream FA cask) **should stay** — it's the
   default icon source for this builder.
3. FontForge is installed on demand via Homebrew during the build and is
   intentionally **not** in the chezmoi Brewfile (so it gets cleaned up
   on the next `system-package brew sync`).
4. `usvg` (custom-SVG normalizer) **is** declared in the chezmoi
   `Cargofile` — it's tiny and generally useful, unlike the heavyweight
   FontForge. The build also installs it on demand if missing, so a
   standalone run still works.
5. macOS-only. The build pipeline assumes Homebrew. Pull requests
   welcome if you'd like to teach it about Linux/apt.

See the comment block at the top of `build-updated-font.sh` for the
full set of overrides (`WORK_ROOT`, `FA_SRC_DIR`, `NERDFONTS_REF`,
`ASSUME_YES`, `INSTALL`, `JSON_OUT_DIR`, `DONOR_GLYPH_FILE`,
`DONOR_FONT_FAMILIES`, `DONOR_FONT_PATHS`, `DONOR_INSTALL`).

## Picker starter

A no-frills fzf wrapper that searches by glyph name, label, FA terms,
and aliases, and copies the chosen glyph to the clipboard:

```bash
jq -r '
  .glyphs | to_entries[]
  | [ .key,
      .value.char,
      (.value.label // .value.unicode_name // ""),
      (((.value.terms // []) + (.value.keywords // [])) | join(" ")),
      ((.value.aliases // []) | join(" ")),
      (.value.description // "")
    ] | @tsv
' ~/.local/share/fonts/nerd-font/glyphs.json \
| fzf --delimiter=$'\t' --with-nth=1,2,3 \
| awk -F'\t' '{print $2}' \
| tee /dev/tty | pbcopy   # Linux: xclip -selection clipboard
```

`--with-nth=1,2,3` shows the name, the glyph itself, and the
label/unicode name, while fzf still searches across all columns
(including the FA `terms` and `aliases`). Drop the `tee /dev/tty`
if you want the glyph copied silently.
