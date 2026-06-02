# Hand-off — Symbols Nerd Font custom build

You're picking up an established project. This doc is for a new agent with
zero prior context. Read it before touching anything.

## TL;DR

This directory builds the user's personal copy of **Symbols Nerd Font**
(Mono + Propo variants) with the latest Font Awesome icons merged in on
top of the latest Nerd Fonts symbol collections. It is wired into
chezmoi via a `run_onchange_after_*` hook that re-fires whenever the
FA cask version or the builder script changes.

State as of 2026-05-28: complete and working. Last user request added a
`glyphs.json` index emission step for an fzf-style symbol picker.

## File map

```
/Users/user/.local/share/chezmoi/                       (chezmoi source root)
├── run_onchange_after_symbols-nerd-font.sh.tmpl          (the hook — fires the builder)
├── .chezmoiignore                                        (excludes `custom-builds/`)
└── custom-builds/nerd-fonts/                             (this directory)
    ├── HAND-OFF.md                                       (you are here)
    ├── README.md                                         (human-facing doc)
    ├── build-updated-font.sh                             (the builder, ~600 LoC bash)
    ├── .gitignore                                        (ignores ./build/)
    └── build/                                            (runtime artefacts, gitignored)
        ├── nerd-fonts/                                   (shallow clone of ryanoasis/nerd-fonts)
        ├── fontawesome/                                  (downloaded FA, only if no cask)
        ├── work/                                         (merged FA OTF, build.log, py scripts)
        ├── output/                                       (built .ttf files)
        └── .venv/                                        (fonttools venv for verify + JSON)
```

The builder also writes:

- `~/Library/Fonts/SymbolsNerdFont*.ttf` (only with `--install` / `INSTALL=1`)
- `~/.local/share/fonts/nerd-font/glyphs.json` (always, unless `JSON_OUT_DIR=""`)

## Core design decisions (why things are the way they are)

1. **FontForge installed via Homebrew, not pip.** FontForge's Python
   bindings are baked into its binary (`_fontforge.so`). They are not
   importable from a standard CPython, so `uv pip install fontforge`
   does not exist as a working option. The builder calls
   `brew install fontforge` on demand and uninstalls it via the user's
   normal `system-package brew sync` (it is intentionally NOT in the
   Brewfile).
2. **`--custom` is additive, not destructive.** We pass the merged FA 7
   OTF to `font-patcher --custom`, which layers FA's native codepoints
   on top of the existing curated Nerd Fonts layout in "careful" mode
   (no overwrites of the curated NF range). If you ever need to *replace*
   the curated FA 6.5.1 subset, you have to regenerate
   `src/glyphs/font-awesome/FontAwesome.otf` from scratch (much more
   invasive — icon renames/removals shift the historically-stable NF
   codepoints).
2b. **Colliding free FA icons are relocated, not dropped (since
   2026-05).** Careful mode would silently skip ~1000 of FA Free's 1970
   icons because their native codepoint is already owned by another NF
   collection (Powerline, Devicons, Seti, …). The merge step
   (`_merge_fa.py`) now detects these against the upstream-shipped
   curated cmap and copies each to a reserved **Plane-16 PUA** block
   starting at **U+100000**, writing a `native->relocated` map to
   `build/work/fa-map.json`. The patcher then imports the copies through
   its normal path, so all 1970 free icons end up present. The JSON step
   follows the map so every icon keeps its `fa-<name>` (relocated ones
   gain a `relocated_from` field). Trade-off: a relocated icon renders
   only via this font (like any PUA nerd icon) — fine for the picker,
   not portable as a bare codepoint.
2c. **FA glyph sizing — step 7b. Two populations, two treatments.**
   The catch is *how Ghostty sizes Nerd-Font icons*: it keys off the
   codepoint. Any glyph inside a range listed in Ghostty's generated
   `src/font/nerd_font_attributes.zig` gets the icon constraint
   (`size=.cover/.fit_cover1`, `height=.icon`) and is scaled at render
   time to `icon_height_single = (2·capHeight + faceHeight)/3` of the
   *primary* font. So:
     - **Native-codepoint FA glyphs** (and curated `nf-fa-*`) sit in those
       ranges → Ghostty sizes them → leave them at `FA_SCALE=1.0`. Baking
       a scale here just fights Ghostty.
     - **Relocated FA glyphs** (Plane-16 PUA, the ~870 collisions from 2b)
       are OUTSIDE every recognised range. Ghostty never upscales them —
       its PUA rule only ever scales such glyphs *down* to fit the cell —
       so they render noticeably smaller than their curated neighbours
       (this is why `fa-clipboard-check` looked smaller than
       `fa-clipboard_check`). We compensate by baking a uniform upscale
       into ONLY these glyphs via `FA_RELOCATED_SCALE` (default `1.20`,
       about each glyph's centre, advance untouched, fontTools).
   Why not just relocate into recognised codepoints instead? The font
   already fills essentially all of Ghostty's icon ranges (~9 free slots),
   so there's no room for ~870 glyphs. And why a tunable rather than an
   exact formula? Ghostty's render-time target depends on the primary
   font's metrics, line-height, and the following character (whitespace vs
   not), so the perceptual match is a constant you eyeball once.
   (Historical: a `0.83` default once shrank *all* FA glyphs — wrong on two
   counts: it scaled the native ones Ghostty already handles, and it used
   the global curated median, which Material Design etc. drag down.)

   **Recalibrating is cheap** — no patcher rerun. Step 7b stashes the
   pristine native-size TTFs under `build/work/prescale/`; `recalibrate-fa.sh
   <scale> --install` restores them, re-bakes the relocated upscale, and
   installs. Settle on a number, then make it the `FA_RELOCATED_SCALE`
   default in the builder.
3. **Two variants only: Mono + Propo.** Upstream's "Symbols Only"
   release also ships only these two — there is no plain
   "Symbols Nerd Font Base". The builder calls `font-patcher` twice with
   `--single-width-glyphs` and `--variable-width-glyphs` respectively.
4. **`fa-*` prefix for FA 7 native additions.** The curated NF set
   already uses `nf-fa-*` for the FA 6.5.1 icons it bakes in. The new
   FA 7 add-ins live at different codepoints (FA's native range) and
   get the `fa-<icon-name>` key in `glyphs.json` so they never collide
   with `nf-fa-*`. Some FA 7 icons share a codepoint with `nf-fa-*` —
   in that case both keys are emitted and refer to the same character.
5. **`glyphs.json` includes natural-language metadata.** Per the user's
   request (and matching wezterm's CharSelect popup UX), every FA entry
   carries `label`, `styles`, `search.terms`, and `aliases` from FA's
   `metadata/icons.json`. `nf-fa-*` entries inherit those tags by name
   lookup. Box-drawing-style codepoints get `unicode_name` from
   stdlib `unicodedata`.
6. **`JSON_OUT_DIR=~/.local/share/fonts/nerd-font/` by default.** User
   chose this path; the JSON is *not* a font, but it lives next to the
   Linux font conventions namespace for a reason: the user thinks of it
   as font-adjacent metadata. macOS still uses `~/Library/Fonts/` for
   the actual `.ttf` files.
7. **chezmoi `run_onchange_after_*` hook is fingerprint-driven.** The
   template at the chezmoi root embeds two values into its rendered
   content:
   - `brew list --versions --cask font-fontawesome`
   - SHA256 of `build-updated-font.sh`

   chezmoi hashes the *rendered* content and re-fires the hook when
   the hash changes. The hook itself prompts interactively on macOS and
   exits 0 on non-interactive / non-macOS contexts (with the new hash
   getting committed regardless, so we don't re-prompt for the same
   fingerprints).
8. **`custom-builds/` is `.chezmoiignore`'d.** The builder and this doc
   live in the source repo for git tracking, but chezmoi never renders
   them into `$HOME`. The hook accesses the builder via its absolute
   source-tree path (`{{ .chezmoi.sourceDir }}/custom-builds/...`).
9. **Emoji codepoints are stripped from the built TTFs (step 7/9).**
   The patcher emits a font that claims monochrome 1-cell glyphs for
   common emoji codepoints (♻ ✏ 🚀 etc.). When this font is in a
   terminal's `font-family` chain alongside Apple Color Emoji,
   ghostty's lookup walks the chain in order and wins on Symbols
   Nerd Font before ever reaching the system colour-emoji fallback.
   Result: column-aligned UIs (the gitmoji picker, primarily) get
   misaligned and ugly. Step 7 deletes the `cmap` mappings for
   `U+2600-U+27BF` and `U+1F300-U+1FFFF` so ghostty falls through
   to Apple Color Emoji for those codepoints. Arrows
   (`U+2B00-U+2BFF`) are deliberately *kept* — Apple Color Emoji
   renders ⬇⬆ uncomfortably small inside the cell, and the
   monochrome text-style arrows look better in a terminal.

   This is purely a font-lookup fix; ghostty still reports
   cursor-advance = 1 for default-text-presentation emoji even with
   VS16, so the gitmoji picker has its own width override map
   (`EMOJI_WIDTHS` in `~/.local/bin/pick-gitmoji`) that pads each
   row to keep columns aligned.

## Gotchas you would otherwise have to relearn

These have all bitten us at least once.

- **macOS bash is 3.2.** No `mapfile`, no `${var,,}`. The builder uses
  `shopt -s nullglob; for f in <glob>; do arr+=("$f"); done` and
  `tr '[:upper:]' '[:lower:]'` instead. Do not "modernise" away from
  these — they're deliberate.
- **`set -o pipefail` + empty glob = silent exit.** `ls -1d <glob>`
  returns non-zero when the glob matches nothing. With pipefail, that
  bubbles up and aborts the script. All `ls -1d` calls in the FA
  auto-detection block end in `|| true`. Keep that.
- **`fontforge` can disappear mid-run.** The user's environment runs
  `brew autoremove` periodically. The builder resolves
  `FONTFORGE_BIN=$(command -v fontforge)` once and uses the absolute
  path everywhere after; do not rely on `PATH` lookups in subshells.
- **Shallow clones can't `git pull`.** It hangs trying to negotiate
  history that isn't there. Use:
  ```bash
  git fetch --depth=1 --quiet origin "$NERDFONTS_REF" </dev/null
  git reset --hard --quiet FETCH_HEAD </dev/null
  ```
  Stdin redirection from `/dev/null` is load-bearing — it prevents git
  from blocking on a credential prompt when run under chezmoi.
- **`font-symbols-only-nerd-font` Homebrew cask conflicts with the
  build.** It writes the same filenames into `~/Library/Fonts/` and a
  later `brew bundle` will silently overwrite this script's output.
  Tell the user to keep that cask OUT of their Brewfile. The
  `font-fontawesome` cask, on the other hand, should STAY — the
  builder uses it as the default FA source.
- **The `--custom` patcher prints a lot.** The builder pipes its
  output through `grep -E '===>|WARNING:|ERROR'` to keep the console
  readable; full output still lands in `build/work/build.log`.
- **chezmoi diff for `run_onchange_*` shows the rendered script as a
  "new file"** every time the embedded fingerprint changes. That's
  normal — chezmoi compares against its stored hash, not against a
  file in `$HOME`.

## How to invoke

### Automatically (the design)

```bash
chezmoi apply
```

Whenever FA cask version or the builder script's SHA256 changes, the
hook prompts the user to rebuild. Declining is sticky for that
fingerprint pair (chezmoi stores the new hash on exit-0 either way).

### Manually

```bash
~/.local/share/chezmoi/custom-builds/nerd-fonts/build-updated-font.sh --install
# or:  --yes  for unattended,  JSON_OUT_DIR=""  to skip the JSON,
#      FA_SRC_DIR=/path/to/otfs  to pin a specific FA version
```

### Force the chezmoi hook to re-prompt without changing anything

```bash
chezmoi state delete-bucket --bucket=scriptState
```

## Verifying the state

```bash
# Builder unchanged?
shasum -a 256 ~/.local/share/chezmoi/custom-builds/nerd-fonts/build-updated-font.sh

# Hook fingerprint?
chezmoi cat ~/.cache/chezmoi/dummy 2>/dev/null  # n/a, just illustrative
chezmoi diff | head -5

# FA cask version?
brew list --versions --cask font-fontawesome

# Built fonts installed?
ls -1 ~/Library/Fonts/SymbolsNerdFont*-Regular.ttf

# JSON index present?
jq '.stats' ~/.local/share/fonts/nerd-font/glyphs.json
```

## Open follow-ups / known unknowns

- ~~**Unicode coverage in `glyphs.json` is partial.**~~ Resolved
  2026-05-28 at picker time, not in the font builder. The picker
  now ships a sibling `pick-glyph-build-suppl` that enumerates
  every codepoint Python's `unicodedata.name()` knows about (BMP
  + symbols-heavy SMP planes up to U+30000, minus algorithmic
  blocks like CJK Unified / Hangul / Tangut). Result is cached at
  `$XDG_CACHE_HOME/pick-glyph/unicode-suppl.json` (~35k entries,
  ~3MB) and merged into the picker via `jq --slurpfile`, with the
  font-derived primary winning on codepoint collisions. Box
  Drawing, IPA, Mathematical Operators, Geometric Shapes, and
  currency are all reachable now. Bump `SUPPL_VERSION` in
  `dot_local/bin/executable_pick-glyph-build-suppl` if you change
  the SKIP_PREFIXES set; the picker invalidates the cache on a
  version mismatch.
- **No Linux test path.** The builder has `case "$(uname -s)"` branches
  for Linux (font dir, fc-cache) but it has only ever been run on
  macOS. Treat Linux paths as plausible-but-untested.
- ~~**No automated fzf wrapper script.**~~ Resolved 2026-05-28: see
  `dot_local/bin/executable_pick-glyph` (deployed as `pick-glyph` in
  `~/.local/bin/`). It renders the JSON as `<glyph>  <name> (U+XXXX)
  <description>` lines through fzf, with `--source` filters for
  fa/nf-curated/unicode, optional `--multi`, `--copy` (pbcopy /
  wl-copy / xclip), and `--query` seeding. FA search terms / styles
  ride along in a hidden field after `\x1f` so queries like `rocket`
  or `solid` still match.   Emoji-range codepoints (SMP 0x1F000–
  0x1FFFF and BMP 0x2600–0x27BF) get a synthetic `EMOJI-<HEXCODE>`
  display name; other plain Unicode entries (anything from the
  `unicode-only` or `unicode-stdlib` sources) get `UNICODE-<HEXCODE>`.
  Curated entries (`nerd-fonts-curated`, `font-awesome-7`) keep
  their JSON key. So typing `EMOJI` narrows to emoji, `UNICODE`
  narrows to non-nerd-font Unicode. The original key is preserved
  in the hidden search blob so `u-2500` and friends still match.

  Three submit-with-format keys (via `--expect`) decide the output
  shape: `Enter` / `Ctrl-G` → raw glyph (default), `Ctrl-N` →
  canonical name (`nf-cod-account` for curated NF, `fa-rocket` for
  FA-7 native, the Unicode name for `unicode-*`), `Ctrl-U` →
  `\u{HEX}` escape syntax. The static header beneath the prompt
  acts as the mode indicator. `--mode glyph|name|unicode` bypasses
  the interactive submit for scripting.

  The hidden tail of each picker line is now structured
  (`<key>\x1e<source>\x1e<code>\x1e<uniname>\x1e<terms>`) so the
  shell can reconstruct the chosen representation after fzf
  returns. fzf only sees the leading `\x1f` as a delimiter, so the
  internal `\x1e` subfields stay searchable as ordinary text.

  UI flags mirror `_z4h_fzf_common_flags` from `~/.zshrc` minus the
  `--preview-window` line (this picker has no preview).

## When in doubt

1. Read the header comment block of `build-updated-font.sh` — it
   documents every override and the full step sequence.
2. Re-read the `README.md` next to this file for the human-facing
   summary the user sees.
3. The chezmoi root has `AGENTS.md`: **always `chezmoi apply` after
   editing files in this repo**, but use `--exclude=scripts` if your
   edits would otherwise consume a `run_onchange` fingerprint that the
   user is supposed to see interactively.
