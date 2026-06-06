#!/usr/bin/env python3
"""Build the terminal-symbols SQLite database.

A source-driven database of every glyph worth picking in a terminal: the custom
Nerd Font build, the standard Unicode repertoire, and emoji shortcode/metadata
sets (gemoji, iamcal emoji-data, gitmoji).

Output is a single flat `symbols` table tuned for an fzf picker: one row per
unique symbol, no joins, streams straight off the recency index.

Design:

  * SINGLE TABLE. The rich sources are merged down to one denormalized row per
    symbol. Internally the merge still dedups on a normalized codepoint sequence
    (`code_seq`); the table only stores what the picker needs.
  * BASE-ONLY codepoints. `code_point` is the base/primary integer (rendered as
    U+XXXX); skin-tone variants are not exploded into rows.
  * ONE shortcode per row, chosen by source priority (gitmoji > github > slack >
    emoticon). Every other shortcode, source key, and search term is folded into
    `aliases` so a search still finds them.
  * SOURCE MATERIAL inputs, re-runnable. Inputs are upstream source material,
    NOT the picker's on-demand caches: glyphs.json (a font-build artifact),
    Python `unicodedata` for the Unicode block, and the gemoji / iamcal /
    gitmoji upstream JSON. Re-running rebuilds the DB and preserves `last_used`.
  * BAKED host renderability. Codepoints in the render-exclusion ranges are
    dropped; the standard-Unicode enumeration is additionally gated by probing
    the terminal itself -- WezTerm when available (it reports both its built-in
    block/box/braille renderer AND font-fallback coverage), else the macOS
    CoreText cascade. PUA and emoji-dataset rows bypass the probe. The resulting
    DB is therefore host-specific.

Pure stdlib (sqlite3 / unicodedata / urllib) plus an optional `swift` for the
renderability probe -- no pip dependencies, no venv.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unicodedata
import urllib.request
from dataclasses import dataclass, field

# --- paths ----------------------------------------------------------------

XDG_DATA = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
XDG_CACHE = os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache"))
DEFAULT_DB = os.path.join(XDG_DATA, "fonts", "nerd-font", "symbols.db")
DEFAULT_GLYPHS_JSON = os.path.join(XDG_DATA, "fonts", "nerd-font", "glyphs.json")
# Authoritative overlay for custom-svg glyph metadata, alongside this script in
# the repo (../custom-icons/metadata.json).
DEFAULT_CUSTOM_META = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "custom-icons", "metadata.json"))
CACHE_DIR = os.path.join(XDG_CACHE, "symbols-db")

# --- upstream source material ---------------------------------------------

UPSTREAM = {
    "gemoji": "https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json",
    "iamcal": "https://raw.githubusercontent.com/iamcal/emoji-data/master/emoji.json",
    "gitmoji": "https://raw.githubusercontent.com/carloscuesta/gitmoji/master/packages/gitmojis/src/gitmojis.json",
}

# Canonical scalar-field priority when sources disagree (highest first).
NAME_PRIORITY = ["unicode-stdlib", "iamcal", "unicode-only",
                 "font-awesome-7", "nerd-fonts-curated", "custom-svg"]
# Sources whose `description` is genuine human-written prose, not a name. Only
# these populate the rich-only `description` column (highest first); every other
# source's description text is folded into `keywords` so it stays searchable.
RICH_DESC_SOURCES = ["custom-svg", "gitmoji"]
# When `name` has no official Unicode name, fall back to a source key in this
# order (so PUA icons display as fa-rocket / nf-..., not the bare glyph).
SOURCE_KEY_PRIORITY = ["font-awesome-7", "nerd-fonts-curated", "custom-svg",
                       "gemoji", "iamcal", "gitmoji"]
# Which platform wins for the single `shortcode` column. The losers stay
# searchable in `aliases`.
SHORTCODE_PRIORITY = ["custom", "gitmoji", "github", "slack", "emoticon"]

# --- renderability filter -------------------------------------------------

# Deterministic, source-level exclusions. Applied to EVERY source by base
# codepoint. (lo, hi), inclusive.
RENDER_EXCLUSIONS = [
    (0x1F1E6, 0x1F1FF),  # regional indicators: combine into flags; poor standalone
]

# Private Use Areas: rendered explicitly by Symbols Nerd Font, so the system
# font cascade would wrongly drop them. They bypass the CoreText probe.
PUA_RANGES = [(0xE000, 0xF8FF), (0xF0000, 0xFFFFD), (0x100000, 0x10FFFD)]

# Codepoints treated as emoji for tagging/search faceting (broad blocks).
EMOJI_RANGES = [(0x2600, 0x27BF), (0x1F000, 0x1FAFF)]

# Emoji_Presentation codepoints: those that default to a 2-cell color glyph.
# Loaded from Unicode's emoji-data.txt at build time and used for ACCURATE
# display width -- the broad EMOJI_RANGES above are far too wide for widths
# (most of 2600-27BF are 1-cell text symbols like CHECK MARK / BALLOT X).
EMOJI_DATA_URL = "https://www.unicode.org/Public/UCD/latest/ucd/emoji/emoji-data.txt"
EMOJI_PRESENTATION: set[int] = set()
# Codepoints with the Emoji property. Superset of Emoji_Presentation: includes
# text-default emoji (✈ ♻ ✏) which THIS terminal force-colors (see wezterm.lua),
# so their true cell width is uncertain and must be measured, not assumed.
EMOJI: set[int] = set()

# Unicode general categories that never produce a standalone, drawable glyph in
# the picker: invisible controls/format/separators, and combining marks (which
# render on a dotted circle). Co (private use = nerd/FA icons) is deliberately
# NOT here. Applied to every source by the symbol's base codepoint.
DROP_CATEGORIES = {"Cc", "Cf", "Cs", "Cn", "Zl", "Zp", "Zs", "Mn", "Me", "Mc"}


def _is_vs(o: int) -> bool:
    """Variation selector (stripped from the canonical key; base-only)."""
    return 0xFE00 <= o <= 0xFE0F or 0xE0100 <= o <= 0xE01EF


def _in_ranges(cp: int, ranges) -> bool:
    return any(lo <= cp <= hi for lo, hi in ranges)


# Renderability probe (macOS CoreText). Reads hex codepoints on stdin, echoes
# back only those that AT LEAST ONE of the terminal's CONFIGURED fonts can draw
# (PROBE_FONTS). This deliberately does NOT walk the macOS system cascade: the
# terminal only renders with the fonts in its fallback list, so a glyph that
# exists only in some unrelated system font (e.g. Bopomofo in Arial Unicode MS,
# which the GUI never loads) is tofu and must be dropped. Coverage is checked
# per font with CTFontGetGlyphsForCharacters (no fallback), and a requested font
# that doesn't actually resolve (wrong/absent family) is skipped, not silently
# replaced by Helvetica.
SWIFT_PROBE = r'''
import CoreText
import Foundation

func norm(_ s: String) -> String {
    s.lowercased().replacingOccurrences(of: " ", with: "")
}

var fonts: [CTFont] = []
for fam in CommandLine.arguments.dropFirst() {
    let f = CTFontCreateWithName(fam as CFString, 13.0, nil)
    let actual = CTFontCopyFamilyName(f) as String
    if norm(actual) == norm(fam) {
        fonts.append(f)
    } else {
        FileHandle.standardError.write(
            "skip font '\(fam)': resolved to '\(actual)' (not installed)\n"
                .data(using: .utf8)!)
    }
}
if fonts.isEmpty {
    FileHandle.standardError.write("no probe fonts resolved\n".data(using: .utf8)!)
    exit(2)
}

func covered(_ cp: UInt32) -> Bool {
    guard let scalar = Unicode.Scalar(cp) else { return false }
    var u16 = Array(String(scalar).utf16)
    var g = [CGGlyph](repeating: 0, count: u16.count)
    for f in fonts {
        if CTFontGetGlyphsForCharacters(f, &u16, &g, u16.count) { return true }
    }
    return false
}

while let line = readLine() {
    let t = line.trimmingCharacters(in: .whitespaces)
    if let cp = UInt32(t, radix: 16), covered(cp) { print(t) }
}
'''


# --- logging --------------------------------------------------------------

def log(msg: str) -> None:
    print(f"[symbols-db] {msg}", file=sys.stderr)


def warn(msg: str) -> None:
    print(f"[symbols-db] WARN: {msg}", file=sys.stderr)


def die(msg: str) -> None:
    print(f"[symbols-db] FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


# --- canonical key (internal dedup only) ----------------------------------

def canonical_key(scalars):
    """(code_seq, code_point) from codepoint ints, stripping variation
    selectors. Returns (None, None) if nothing remains."""
    core = [o for o in scalars if not _is_vs(o)]
    if not core:
        return None, None
    return "-".join(format(o, "X") for o in core), core[0]


def scalars_of_string(s: str):
    return [ord(c) for c in s]


def scalars_of_unified(unified: str):
    return [int(h, 16) for h in unified.split("-") if h]


def render_width(symbol: str, cp: int) -> int:
    """Terminal cell width of the stored symbol: 0 for combining, else 1 or 2.

    Mirrors how WezTerm/wcwidth size a cell: a glyph is double-width when it has
    default emoji presentation, carries an emoji variation selector (VS16), or is
    East-Asian Wide/Fullwidth; everything else is single-width. (Color vs. mono
    font choice does NOT change the cell count.)"""
    if unicodedata.category(chr(cp)) in ("Mn", "Me", "Mc", "Cf"):
        return 0
    if "\uFE0F" in symbol:
        return 2
    if cp in EMOJI_PRESENTATION:
        return 2
    if unicodedata.east_asian_width(chr(cp)) in ("W", "F"):
        return 2
    return 1


def is_excluded(cp: int) -> bool:
    return _in_ranges(cp, RENDER_EXCLUSIONS)


def is_emoji(cp: int) -> bool:
    return _in_ranges(cp, EMOJI_RANGES)


# --- a single source's claim on a symbol ----------------------------------

@dataclass
class Contribution:
    code_seq: str
    code_point: int
    symbol: str
    source: str
    source_key: str = ""
    official_name: str | None = None
    description: str = ""
    tags: list = field(default_factory=list)
    shortcodes: list = field(default_factory=list)  # (platform, code, is_primary)
    keywords: list = field(default_factory=list)


# --- source ingest: glyphs.json -------------------------------------------

GLYPHS_TAG = {
    "nerd-fonts-curated": "nerd-font",
    "font-awesome-7": "fontawesome",
    "custom-svg": "custom",
    "unicode-only": "unicode",
}

# Sources whose `source_key` is a human-meaningful glyph key worth surfacing as
# an `@`-anchor (cod-account, fa-rocket, iec-power, usr-cursor-ai). Excludes
# unicode-stdlib (key is just `u-<hex>`, i.e. the code point) and the emoji
# sources (their keys are shortcodes, already surfaced via
# `shortcode`/`extra_shortcodes`).
ICON_KEY_SOURCES = {"nerd-fonts-curated", "font-awesome-7", "custom-svg"}


def load_custom_meta(path: str) -> dict:
    """Flat {icon-name: fields} from custom-icons/metadata.json (or {} if
    absent/invalid). Accepts an "icons" wrapper and ignores header keys that
    start with _ or $. This is the authoritative overlay for custom glyphs, so
    editing it + rebuilding the DB reflects changes without a full font build."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if isinstance(data.get("icons"), dict):
        data = data["icons"]
    return {k: v for k, v in data.items()
            if isinstance(v, dict) and not k.startswith(("_", "$"))}


def ingest_glyphs_json(path: str, custom_meta: dict | None = None) -> list:
    custom_meta = custom_meta or {}
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    out = []
    for key, v in data.get("glyphs", {}).items():
        code = v.get("code")
        char = v.get("char")
        if not code or char is None:
            continue
        code_seq, code_point = canonical_key(scalars_of_string(char))
        if code_seq is None or is_excluded(code_point):
            continue
        src = v.get("source") or "unicode-only"
        # glyphs.json's u-* rows are the standard Unicode block; map to the
        # unicode-stdlib source so they merge with the unicodedata enumeration.
        source = "unicode-stdlib" if src == "unicode-only" else src
        tag = GLYPHS_TAG.get(src, "")

        if src == "custom-svg":
            # metadata.json is authoritative; glyphs.json supplies code/char.
            # The glyphs.json key is `<prefix>-<iconname>` (usr-cursor-ai);
            # metadata.json is keyed by the bare icon name. Strip whatever
            # prefix the font build used so a prefix change can't break the
            # overlay (and old `fa-`-keyed builds keep matching).
            name = key.split("-", 1)[1] if "-" in key else key
            m = custom_meta.get(name, {})
            label = m.get("label") or v.get("label")
            # Explicit 1:1 field mapping: `shortcode` -> the primary `shortcode`
            # column (platform "custom" leads SHORTCODE_PRIORITY); `aliases` ->
            # `extra_shortcodes`. Either may be omitted/empty.
            primary = m.get("shortcode") or v.get("shortcode") or ""
            extras = m.get("aliases")
            if extras is None:
                extras = v.get("aliases") or []
            shortcodes = [("custom", str(primary), True)] if primary else []
            shortcodes += [("custom", str(a), False) for a in extras if a]
            out.append(Contribution(
                code_seq=code_seq,
                code_point=code_point,
                symbol=char,
                source=source,
                source_key=key,
                official_name=label,
                description=str(m.get("description")
                                or v.get("description") or v.get("comment") or ""),
                tags=[tag] if tag else [],
                shortcodes=shortcodes,
                keywords=[str(t) for t in (m.get("keywords")
                                           or v.get("keywords")
                                           or v.get("terms") or [])],
            ))
            continue

        desc_parts = [p for p in (v.get("label"), v.get("comment")) if p]
        keywords = [str(t) for t in (v.get("terms") or [])]
        keywords += [str(a) for a in (v.get("aliases") or [])]
        out.append(Contribution(
            code_seq=code_seq,
            code_point=code_point,
            symbol=char,
            source=source,
            source_key=key,
            official_name=v.get("unicode_name"),
            description=" - ".join(desc_parts),
            tags=[tag] if tag else [],
            keywords=keywords,
        ))
    return out


# --- source ingest: unicode (python unicodedata) --------------------------

# Algorithmic-name blocks: huge ranges where the "name" is just block + cp.
SKIP_PREFIXES = (
    "CJK UNIFIED IDEOGRAPH-", "CJK COMPATIBILITY IDEOGRAPH-",
    "HANGUL SYLLABLE ", "TANGUT IDEOGRAPH-", "TANGUT COMPONENT-",
    "KHITAN SMALL SCRIPT CHARACTER-", "NUSHU CHARACTER-",
    "EGYPTIAN HIEROGLYPH ", "ANATOLIAN HIEROGLYPH ", "VARIATION SELECTOR-",
)


def ingest_unicode(renderable_fn) -> list:
    candidates = []
    for cp in range(0x20, 0x30000):
        ch = chr(cp)
        try:
            name = unicodedata.name(ch)
        except ValueError:
            continue
        if name.startswith(SKIP_PREFIXES) or is_excluded(cp):
            continue
        candidates.append((cp, ch, name))

    keep = renderable_fn([cp for cp, _, _ in candidates])

    out = []
    for cp, ch, name in candidates:
        if keep is not None and cp not in keep:
            continue
        out.append(Contribution(
            code_seq=format(cp, "X"),
            code_point=cp,
            symbol=ch,
            source="unicode-stdlib",
            source_key="u-{:04x}".format(cp),
            official_name=name,
            tags=["emoji"] if is_emoji(cp) else ["unicode"],
        ))
    return out


# --- source ingest: gemoji ------------------------------------------------

def ingest_gemoji(rows) -> list:
    out = []
    for r in rows:
        emoji = r.get("emoji")
        if not emoji:
            continue
        code_seq, code_point = canonical_key(scalars_of_string(emoji))
        if code_seq is None or is_excluded(code_point):
            continue
        aliases = [str(a) for a in (r.get("aliases") or [])]
        shortcodes = [("github", a, i == 0) for i, a in enumerate(aliases)]
        keywords = [str(t) for t in (r.get("tags") or [])]
        if r.get("category"):
            keywords.append(str(r["category"]))
        out.append(Contribution(
            code_seq=code_seq,
            code_point=code_point,
            symbol=emoji,
            source="gemoji",
            source_key=aliases[0] if aliases else "",
            description=str(r.get("description") or ""),
            tags=["emoji"],
            shortcodes=shortcodes,
            keywords=keywords,
        ))
    return out


# --- source ingest: iamcal emoji-data -------------------------------------

def ingest_iamcal(rows) -> list:
    out = []
    for r in rows:
        unified = r.get("unified")
        if not unified:
            continue
        scalars = scalars_of_unified(unified)
        code_seq, code_point = canonical_key(scalars)
        if code_seq is None or is_excluded(code_point):
            continue
        symbol = "".join(chr(o) for o in scalars)
        short_names = [str(s) for s in (r.get("short_names") or [])]
        shortcodes = [("slack", s, i == 0) for i, s in enumerate(short_names)]
        texts = [str(t) for t in (r.get("texts") or []) if t]
        if r.get("text"):
            texts.append(str(r["text"]))
        shortcodes += [("emoticon", t, False) for t in dict.fromkeys(texts)]
        keywords = [str(w) for w in (r.get("category"), r.get("subcategory")) if w]
        out.append(Contribution(
            code_seq=code_seq,
            code_point=code_point,
            symbol=symbol,
            source="iamcal",
            source_key=short_names[0] if short_names else "",
            official_name=str(r.get("name")) if r.get("name") else None,
            tags=["emoji"],
            shortcodes=shortcodes,
            keywords=keywords,
        ))
    return out


# --- source ingest: gitmoji -----------------------------------------------

def ingest_gitmoji(rows) -> list:
    out = []
    for r in rows:
        emoji = r.get("emoji")
        if not emoji:
            continue
        code_seq, code_point = canonical_key(scalars_of_string(emoji))
        if code_seq is None or is_excluded(code_point):
            continue
        name = str(r.get("name") or "").strip(":")
        out.append(Contribution(
            code_seq=code_seq,
            code_point=code_point,
            symbol=emoji,
            source="gitmoji",
            source_key=name,
            description=str(r.get("description") or ""),
            tags=["gitmoji"],
            shortcodes=[("gitmoji", name, True)] if name else [],
        ))
    return out


# --- network fetch with cache ---------------------------------------------

def fetch_json(name: str, url: str, offline: bool, refresh: bool):
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache = os.path.join(CACHE_DIR, f"{name}.json")
    if not offline and (refresh or not os.path.exists(cache)):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "symbols-db"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
            with open(cache, "wb") as fh:
                fh.write(raw)
            log(f"  fetched {name} ({len(raw):,} bytes)")
        except Exception as exc:  # noqa: BLE001 -- network boundary
            if os.path.exists(cache):
                warn(f"{name} fetch failed ({exc}); using cached copy")
            else:
                die(f"{name} fetch failed and no cache at {cache}: {exc}")
    if not os.path.exists(cache):
        die(f"{name} unavailable (offline and no cache at {cache})")
    with open(cache, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


def load_emoji_data(offline: bool, refresh: bool) -> None:
    """Populate EMOJI and EMOJI_PRESENTATION from Unicode's emoji-data.txt
    (cached). On any failure, leave them empty -- render_width then falls back to
    East-Asian width, which still gets the common cases right."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache = os.path.join(CACHE_DIR, "emoji-data.txt")
    if not offline and (refresh or not os.path.exists(cache)):
        try:
            req = urllib.request.Request(EMOJI_DATA_URL,
                                         headers={"User-Agent": "symbols-db"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
            with open(cache, "wb") as fh:
                fh.write(raw)
            log(f"  fetched emoji-data.txt ({len(raw):,} bytes)")
        except Exception as exc:  # noqa: BLE001 -- network boundary
            if not os.path.exists(cache):
                warn(f"emoji-data.txt fetch failed ({exc}); widths use EAW only")
                return
            warn(f"emoji-data.txt fetch failed ({exc}); using cached copy")
    if not os.path.exists(cache):
        warn("emoji-data.txt unavailable; widths use East-Asian width only")
        return
    props = {"Emoji": EMOJI, "Emoji_Presentation": EMOJI_PRESENTATION}
    with open(cache, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line or ";" not in line:
                continue
            rng, prop = (p.strip() for p in line.split(";")[:2])
            target = props.get(prop)
            if target is None:
                continue
            lo, _, hi = rng.partition("..")
            target.update(range(int(lo, 16),
                                (int(hi, 16) if hi else int(lo, 16)) + 1))
    log(f"  Emoji: {len(EMOJI):,}, Emoji_Presentation: "
        f"{len(EMOJI_PRESENTATION):,} codepoints")


# --- terminal width measurement (DSR) -------------------------------------

# Width is ground-truthed by asking the terminal itself. wcwidth heuristics
# can't predict how THIS terminal advances the cursor for emoji-presentation
# overrides (wezterm.lua force-colors text-default emoji) or whether a ZWJ
# sequence ligates into one glyph. So for the uncertain set -- anything with the
# Emoji property, a variation selector, or more than one (non-VS) scalar -- we
# print the glyph and read the cursor's column before and after via DSR
# (ESC [ 6 n -> ESC [ row ; col R), exactly like pick-gitmoji-measure-widths.


def needs_measure(symbol: str, cp: int) -> bool:
    if cp in EMOJI or any(_is_vs(ord(c)) for c in symbol):
        return True
    return len([c for c in symbol if not _is_vs(ord(c))]) > 1


def _measure_via_tty(symbols):
    """Return {symbol: cursor-advance width}. Empty dict if there's no
    interactive terminal or it doesn't answer DSR (e.g. headless/cron build)."""
    import select
    import termios
    import time
    import tty

    try:
        fd = os.open("/dev/tty", os.O_RDWR)
    except OSError:
        return {}
    try:
        old_attr = termios.tcgetattr(fd)
    except termios.error:
        os.close(fd)
        return {}

    def col():
        os.write(fd, b"\x1b[6n")
        buf = b""
        deadline = time.time() + 0.5
        while time.time() < deadline:
            if select.select([fd], [], [], 0.05)[0]:
                ch = os.read(fd, 1)
                buf += ch
                if ch == b"R":
                    break
        s = buf.decode("latin-1", "replace")
        if s.startswith("\x1b[") and s.endswith("R"):
            try:
                return int(s[2:-1].split(";")[1])
            except (IndexError, ValueError):
                return None
        return None

    out = {}
    tty.setraw(fd)
    try:
        os.write(fd, b"\r\x1b[K")
        if col() is None:
            return {}  # terminal doesn't speak DSR; bail to heuristic
        for sym in symbols:
            os.write(fd, b"\r\x1b[K")
            c1 = col()
            os.write(fd, sym.encode("utf-8"))
            c2 = col()
            os.write(fd, b"\r\x1b[K")
            if c1 is not None and c2 is not None:
                out[sym] = c2 - c1
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, old_attr)
        os.close(fd)
    return out


def measure_widths(symbols, remeasure: bool):
    """Measured cursor-advance width per symbol, cached across rebuilds (keyed by
    the codepoint sequence). Only newly-seen symbols are re-measured."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache_path = os.path.join(CACHE_DIR, "width-cache.json")
    cache = {}
    if not remeasure and os.path.exists(cache_path):
        try:
            with open(cache_path) as fh:
                cache = {k: int(v) for k, v in json.load(fh).items()}
        except (OSError, ValueError):
            cache = {}

    def key(s):
        return "-".join(format(ord(c), "X") for c in s)

    todo = [s for s in symbols if key(s) not in cache]
    if todo:
        log(f"  measuring {len(todo):,} symbol widths via /dev/tty (DSR)...")
        measured = _measure_via_tty(todo)
        if not measured:
            warn("no interactive terminal for DSR; keeping heuristic widths "
                 "(run the build inside your terminal to measure + prune)")
            return {}
        cache.update({key(s): w for s, w in measured.items()})
        try:
            with open(cache_path, "w") as fh:
                json.dump(cache, fh)
        except OSError:
            pass
    return {s: cache[key(s)] for s in symbols if key(s) in cache}


# --- renderability probe (cached) -----------------------------------------

def _wezterm_probe_signature():
    """Fingerprint of everything that can flip the wezterm probe's verdict: the
    WezTerm version (its built-in block/box renderer evolves between releases)
    and the live resolved font fallback (`ls-fonts` lists every family + the
    file it resolved to). Editing the fallback in wezterm.lua, adding/removing
    a font, or upgrading WezTerm all shift this hash -- so the render cache
    auto-invalidates and the next build re-probes, with no manual
    --refresh-render. The probe never keeps a font list of its own: it asks the
    live `wezterm` binary, so the two can't drift. Returns None when the
    fingerprint can't be taken (cache is then reused as-is, old behaviour)."""
    try:
        ver = subprocess.run(["wezterm", "--version"],
                             capture_output=True, text=True, timeout=30)
        fonts = subprocess.run(["wezterm", "ls-fonts"],
                               capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if ver.returncode != 0 or fonts.returncode != 0:
        return None
    payload = ver.stdout.strip() + "\n" + fonts.stdout.replace("\x00", "")
    return hashlib.sha256(payload.encode("utf-8", "replace")).hexdigest()[:16]


def make_renderable_fn(no_filter: bool, refresh_render: bool):
    """Return (fn, mode). fn(cps) -> set of renderable cps, or None to keep all.

    Probe preference: the terminal's own resolver (`wezterm`) is authoritative
    for what THIS terminal can draw, so it's used when available; otherwise the
    macOS CoreText system cascade is used as a (broader) fallback. Verdicts are
    cached per mode so rebuilds don't re-probe; the wezterm cache also carries a
    signature of the version + font fallback and self-invalidates when either
    changes (see _wezterm_probe_signature)."""
    if no_filter:
        return (lambda cps: None), "disabled"

    if shutil.which("wezterm"):
        probe, mode = _wezterm_probe, "wezterm"
        signature = _wezterm_probe_signature()
    elif platform.system() == "Darwin" and shutil.which("swift"):
        probe, mode = _swift_probe, "coretext"
        signature = None
    else:
        return (lambda cps: None), "unavailable"

    os.makedirs(CACHE_DIR, exist_ok=True)
    cache_path = os.path.join(CACHE_DIR, f"render-cache-{mode}.json")
    cache = {}
    if not refresh_render and os.path.exists(cache_path):
        try:
            with open(cache_path) as fh:
                blob = json.load(fh)
            # New format: {"signature": str|null, "verdicts": {hex: 0/1}}.
            # Reuse verdicts only when the signature still matches (or we can't
            # compute one); a drift means the fallback/version changed, so we
            # drop the cache and re-probe. A legacy flat cache has no "verdicts"
            # key and is silently discarded (re-probed once).
            if isinstance(blob, dict) and "verdicts" in blob:
                if signature is None or blob.get("signature") == signature:
                    cache = {int(k, 16): bool(v)
                             for k, v in blob["verdicts"].items()}
                else:
                    log("  font fallback/version changed since last probe; "
                        "re-probing")
        except (OSError, ValueError):
            cache = {}

    def fn(cps):
        todo = [cp for cp in cps if cp not in cache]
        if todo:
            log(f"  probing {len(todo):,} codepoints via {mode}...")
            probed = probe(todo)
            if probed is None:
                warn("render probe failed; keeping all codepoints")
                return None
            for cp in todo:
                cache[cp] = cp in probed
            try:
                with open(cache_path, "w") as fh:
                    json.dump({"signature": signature,
                               "verdicts": {format(k, "X"): (1 if v else 0)
                                            for k, v in cache.items()}}, fh)
            except OSError:
                pass
        return {cp for cp in cps if cache.get(cp)}

    return fn, mode


# Parse a single-codepoint cluster line from `wezterm ls-fonts --text`. Two
# renderable shapes exist:
#   * font-resolved:  `... \u{1e900} ... glyph=<name> ...` (tofu when .notdef)
#   * built-in glyph: `... \u{1fb00} ... drawn by wezterm because
#                      custom_block_glyphs=true: Sextant(1)` (no `glyph=`)
# Clusters with more than one \u{} (combining sequences) are skipped -- those
# categories are dropped by DROP_CATEGORIES anyway.
# `glyph=` is followed by the glyph name, then NUL padding -- stop at NUL too.
_WEZTERM_LINE = re.compile(r"glyph=([^\x00\s]+)")
_WEZTERM_CP = re.compile(r"\\u\{([0-9a-fA-F]+)\}")
_WEZTERM_NATIVE = "drawn by wezterm"


def _wezterm_probe(cps):
    """Return the subset of cps THIS terminal can actually render: those WezTerm
    paints with its built-in block/box/braille renderer (reported as "drawn by
    wezterm ...") plus those the configured font fallback resolves to a real
    glyph (not `.notdef`). Probed at the runtime custom_block_glyphs setting, so
    the verdict matches what ends up on screen -- no separate force-keep list.
    Batched to stay under WezTerm's ls-fonts glyph-atlas limit; the tiny
    `font_size` override only packs more glyphs per batch."""
    renderable = set()
    # Work queue of chunks; a chunk that overflows the glyph atlas is split in
    # half and retried, so any mix of glyph sizes eventually fits.
    queue = [cps[i:i + 2000] for i in range(0, len(cps), 2000)][::-1]
    while queue:
        chunk = queue.pop()
        if not chunk:
            continue
        text = " ".join(chr(cp) for cp in chunk)
        try:
            proc = subprocess.run(
                # font_size=6 packs more glyphs per atlas (perf only). We do NOT
                # override custom_block_glyphs, so the probe sees exactly what
                # this terminal draws at runtime: built-in glyphs report "drawn
                # by wezterm ...", the rest go through the font fallback.
                ["wezterm", "--config", "font_size=6",
                 "ls-fonts", "--text", text],
                capture_output=True, text=True, timeout=120,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            warn(f"wezterm probe failed ({exc})")
            return None
        if proc.returncode != 0:
            if "Texture Size exceeded" in proc.stderr and len(chunk) > 1:
                mid = len(chunk) // 2
                queue.append(chunk[mid:])
                queue.append(chunk[:mid])
                continue
            sys.stderr.write(proc.stderr)
            return None
        for line in proc.stdout.splitlines():
            cphexes = _WEZTERM_CP.findall(line)
            if len(cphexes) != 1:
                continue  # multi-codepoint cluster: ambiguous, skip
            cp = int(cphexes[0], 16)
            if _WEZTERM_NATIVE in line:
                renderable.add(cp)  # WezTerm's built-in renderer draws it
                continue
            m = _WEZTERM_LINE.search(line)
            if m and m.group(1) != ".notdef":
                renderable.add(cp)  # font fallback has a real glyph
    return renderable


def _swift_probe(cps):
    fd, swift_path = tempfile.mkstemp(suffix=".swift")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(SWIFT_PROBE)
        proc = subprocess.run(
            ["swift", swift_path],
            input="\n".join(format(cp, "X") for cp in cps),
            capture_output=True, text=True, timeout=600,
        )
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            return None
        return {int(ln.strip(), 16) for ln in proc.stdout.splitlines() if ln.strip()}
    finally:
        try:
            os.unlink(swift_path)
        except OSError:
            pass


# --- schema (single flat table) -------------------------------------------

DDL = """
CREATE TABLE symbols (
  symbol           TEXT PRIMARY KEY,
  code_point       INTEGER NOT NULL,
  display_width    INTEGER NOT NULL DEFAULT 1,
  name             TEXT NOT NULL DEFAULT '',
  description      TEXT NOT NULL DEFAULT '',
  shortcode        TEXT NOT NULL DEFAULT '', -- single primary, by source priority
  extra_shortcodes TEXT NOT NULL DEFAULT '', -- other platforms' shortcodes (search)
  source_keys      TEXT NOT NULL DEFAULT '', -- icon-font glyph keys: cod-/fa-/iec-...
  keywords         TEXT NOT NULL DEFAULT '', -- upstream terms/categories (search)
  tags             TEXT NOT NULL DEFAULT '', -- collection facet (e.g. "emoji gitmoji")
  last_used        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_symbols_recency ON symbols(last_used DESC, name ASC);
CREATE INDEX idx_symbols_shortcode ON symbols(shortcode);
"""

# Drop everything a previous (normalized) build may have created.
DROP = """
DROP TABLE IF EXISTS picker_index;
DROP TABLE IF EXISTS keywords;
DROP TABLE IF EXISTS shortcodes;
DROP TABLE IF EXISTS symbol_tags;
DROP TABLE IF EXISTS tags;
DROP TABLE IF EXISTS symbol_sources;
DROP TABLE IF EXISTS sources;
DROP TABLE IF EXISTS render_exclusions;
DROP TABLE IF EXISTS meta;
DROP TABLE IF EXISTS symbols;
"""


# --- merge + write --------------------------------------------------------

def pick_by_priority(contribs, priority, getter):
    """First non-empty value following `priority` source order, else any."""
    by_src = {}
    for c in contribs:
        val = getter(c)
        if val and c.source not in by_src:
            by_src[c.source] = val
    for src in priority:
        if by_src.get(src):
            return by_src[src]
    return next(iter(by_src.values()), None)


def primary_shortcode(contribs):
    scs = [(p, code, pr) for c in contribs for (p, code, pr) in c.shortcodes if code]
    for plat in SHORTCODE_PRIORITY:
        cands = [(code, pr) for (p, code, pr) in scs if p == plat]
        if cands:
            cands.sort(key=lambda x: 0 if x[1] else 1)  # is_primary first
            return cands[0][0]
    return ""


def display_name(contribs, symbol):
    official = pick_by_priority(contribs, NAME_PRIORITY, lambda c: c.official_name)
    if official:
        return official
    by_src = {}
    for c in contribs:
        if c.source_key and c.source not in by_src:
            by_src[c.source] = c.source_key
    for src in SOURCE_KEY_PRIORITY:
        if by_src.get(src):
            return by_src[src]
    return symbol


def build_db(db_path, contributions_by_source, measure=True, remeasure=False):
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    # Preserve recency across rebuilds (keyed by the stable symbol string).
    # Supports migrating from the older normalized schema (last_selected_at).
    old_recency = {}
    if cur.execute("SELECT name FROM sqlite_master WHERE type='table' "
                   "AND name='symbols'").fetchone():
        cols = [r[1] for r in cur.execute("PRAGMA table_info(symbols)")]
        col = ("last_used" if "last_used" in cols
               else "last_selected_at" if "last_selected_at" in cols else None)
        if col:
            for sym, ts in cur.execute(f"SELECT symbol, {col} FROM symbols"):
                if ts:
                    old_recency[sym] = ts

    cur.executescript(DROP)
    cur.executescript(DDL)

    # group all contributions by canonical key
    grouped = {}
    for contribs in contributions_by_source.values():
        for c in contribs:
            grouped.setdefault(c.code_seq, []).append(c)

    log(f"merging {sum(len(v) for v in contributions_by_source.values()):,} "
        f"contributions into {len(grouped):,} canonical symbols")

    rows = []
    dropped_cat = 0
    for code_seq, contribs in grouped.items():
        code_point = contribs[0].code_point
        # Drop symbols whose base codepoint is in a non-drawing category
        # (invisible controls/format/separators, standalone combining marks).
        if unicodedata.category(chr(code_point)) in DROP_CATEGORIES:
            dropped_cat += 1
            continue
        symbol = max((c.symbol for c in contribs), key=len)
        name = display_name(contribs, symbol)
        # Rich-only description: prose from a RICH_DESC_SOURCES source, else "".
        description = ""
        for src in RICH_DESC_SOURCES:
            hit = next((c.description for c in contribs
                        if c.source == src and c.description), "")
            if hit:
                description = hit
                break
        width = render_width(symbol, code_point)
        shortcode = primary_shortcode(contribs)
        all_shortcodes = dict.fromkeys(
            code for c in contribs for (_, code, _) in c.shortcodes if code)
        extra_shortcodes = " ".join(c for c in all_shortcodes if c != shortcode)
        # `@`-anchored glyph keys: the meaningful icon-font keys only (the raw
        # `u-<hex>` and emoji keys are excluded -- see ICON_KEY_SOURCES).
        source_keys = " ".join(dict.fromkeys(
            c.source_key for c in contribs
            if c.source in ICON_KEY_SOURCES and c.source_key))
        tags = " ".join(dict.fromkeys(t for c in contribs for t in c.tags))
        # Everything else: upstream terms/categories PLUS the non-rich source
        # descriptions (gemoji CLDR names, FA labels) folded in as search tokens,
        # minus anything already surfaced as a shortcode, glyph key, or tag.
        kw_tokens = [k for c in contribs for k in c.keywords if k]
        kw_tokens += [w for c in contribs if c.source not in RICH_DESC_SOURCES
                      for w in c.description.split()]
        seen = {shortcode, *all_shortcodes, *source_keys.split(), *tags.split()}
        keywords = " ".join(dict.fromkeys(
            k for k in kw_tokens if k and k not in seen))
        rows.append((symbol, code_point, width, name, description, shortcode,
                     extra_shortcodes, source_keys, keywords, tags,
                     old_recency.get(symbol, 0)))

    if dropped_cat:
        log(f"dropped {dropped_cat:,} non-drawing symbols "
            f"(categories: {', '.join(sorted(DROP_CATEGORIES))})")

    # Ground-truth widths from the terminal for the uncertain set, and prune
    # multi-codepoint emoji that don't ligate into a single 1-2 cell glyph
    # (e.g. ZWJ sequences the terminal can't render, which advance 4 cells).
    if measure:
        uncertain = [r[0] for r in rows if needs_measure(r[0], r[1])]
        widths = measure_widths(uncertain, remeasure)
        if widths:
            kept, dropped_broken = [], 0
            for r in rows:
                symbol, code_point = r[0], r[1]
                w = widths.get(symbol)
                if w is None:
                    kept.append(r)
                    continue
                non_vs = [c for c in symbol if not _is_vs(ord(c))]
                if w <= 0 or (len(non_vs) > 1 and w != 2):
                    dropped_broken += 1
                    continue
                kept.append((symbol, code_point, w) + tuple(r[3:]))
            rows = kept
            if dropped_broken:
                log(f"dropped {dropped_broken:,} emoji that don't render as a "
                    f"single 1-2 cell glyph (broken ligatures / tofu)")

    cur.executemany(
        "INSERT OR IGNORE INTO symbols(symbol, code_point, display_width, name, "
        "description, shortcode, extra_shortcodes, source_keys, keywords, tags, "
        "last_used) VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)

    conn.commit()
    conn.close()


# --- main -----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Build the terminal-symbols SQLite DB.")
    ap.add_argument("--db", default=DEFAULT_DB, help=f"output DB (default: {DEFAULT_DB})")
    ap.add_argument("--glyphs-json", default=DEFAULT_GLYPHS_JSON,
                    help="path to the font build's glyphs.json")
    ap.add_argument("--custom-meta", default=DEFAULT_CUSTOM_META,
                    help="authoritative overlay for custom-svg glyph metadata")
    ap.add_argument("--offline", action="store_true",
                    help="use cached upstream copies only (no network)")
    ap.add_argument("--refresh", action="store_true",
                    help="force re-fetch of upstream sources")
    ap.add_argument("--no-render-filter", action="store_true",
                    help="keep all codepoints (skip CoreText probe)")
    ap.add_argument("--refresh-render", action="store_true",
                    help="re-probe renderability (ignore the render cache)")
    ap.add_argument("--no-measure", action="store_true",
                    help="skip terminal DSR width measurement (keep heuristic "
                         "widths; don't prune broken-ligature emoji)")
    ap.add_argument("--remeasure", action="store_true",
                    help="re-measure widths via DSR (ignore the width cache)")
    ap.add_argument("--sources", default="all",
                    help="comma list: glyphs,unicode,gemoji,iamcal,gitmoji (default: all)")
    args = ap.parse_args()

    selected = ({"glyphs", "unicode", "gemoji", "iamcal", "gitmoji"}
                if args.sources == "all"
                else {s.strip() for s in args.sources.split(",") if s.strip()})

    log("loading emoji property tables for display widths")
    load_emoji_data(args.offline, args.refresh)

    contributions = {}

    if "glyphs" in selected:
        if not os.path.exists(args.glyphs_json):
            die(f"glyphs.json not found at {args.glyphs_json} "
                "(build the font first, or pass --glyphs-json / drop 'glyphs')")
        log(f"ingesting glyphs.json: {args.glyphs_json}")
        custom_meta = load_custom_meta(args.custom_meta)
        if custom_meta:
            log(f"  custom overlay: {len(custom_meta)} icons from {args.custom_meta}")
        rows = ingest_glyphs_json(args.glyphs_json, custom_meta)
        for c in rows:
            contributions.setdefault(c.source, []).append(c)
        log(f"  {len(rows):,} rows from glyphs.json")

    if "unicode" in selected:
        render_fn, render_mode = make_renderable_fn(
            args.no_render_filter, args.refresh_render)
        log(f"ingesting Unicode via unicodedata {unicodedata.unidata_version} "
            f"(render filter: {render_mode})")
        rows = ingest_unicode(render_fn)
        contributions.setdefault("unicode-stdlib", []).extend(rows)
        log(f"  {len(rows):,} renderable Unicode rows")

    for key, ingest in (("gemoji", ingest_gemoji),
                        ("iamcal", ingest_iamcal),
                        ("gitmoji", ingest_gitmoji)):
        if key not in selected:
            continue
        log(f"ingesting {key}: {UPSTREAM[key]}")
        data = fetch_json(key, UPSTREAM[key], args.offline, args.refresh)
        rows = data["gitmojis"] if key == "gitmoji" else data
        contribs = ingest(rows)
        contributions.setdefault(key, []).extend(contribs)
        log(f"  {len(contribs):,} rows from {key}")

    if not any(contributions.values()):
        die("no contributions ingested; nothing to build")

    log(f"writing database: {args.db}")
    build_db(args.db, contributions,
             measure=not args.no_measure, remeasure=args.remeasure)

    conn = sqlite3.connect(args.db)
    n = conn.execute("SELECT COUNT(*) FROM symbols").fetchone()[0]
    sc = conn.execute("SELECT COUNT(*) FROM symbols WHERE shortcode <> ''").fetchone()[0]
    conn.close()
    log(f"done: {n:,} symbols ({sc:,} with a shortcode)")


if __name__ == "__main__":
    main()
