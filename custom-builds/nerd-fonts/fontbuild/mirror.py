"""Alias every Private Use icon at a second, mirror codepoint (step 7a).

Why: an app that bundles its own, older Symbols Nerd Font and prefers it for
its UI text (Rex does, for tab titles and the key-hint overlay) draws every
icon that copy has from that copy — upstream artwork, not the icons this build
sized and extended. Such an app still falls back to the installed fonts for a
codepoint its bundled copy lacks. So each icon is ALSO reachable at a mirror
codepoint no upstream Nerd Font uses; a label written with mirror codepoints is
drawn from this build.

cmap-only: a mirror entry points at the SAME glyph as its source, so nothing is
duplicated, later steps that reshape a glyph (icon scale) reach both codepoints,
and the file grows by the cmap rows alone. The rule lives in ranges.py
(MIRROR_RANGES); whoever writes mirror codepoints must use the same rule — see
ui_glyphs in home/dot_config/rex/init.lua.tmpl.

Idempotent: an existing mirror entry is left alone, so re-running adds nothing.
"""
from .ranges import MIRROR_RANGES, mirror_cp

# cmap subtable formats that can hold a codepoint above U+FFFF.
_WIDE_FORMATS = (12, 13)


def mirror_font(font):
    """Add the mirror aliases to every full-repertoire cmap subtable of an open
    TTFont. Returns the number of aliases added. No file IO."""
    wide = [t for t in font["cmap"].tables if t.format in _WIDE_FORMATS]
    if not wide:
        raise SystemExit("mirror: font has no format-12 cmap subtable; cannot "
                         "hold Plane-16 mirror codepoints")
    best = font.getBestCmap() or {}
    clash = [cp for cp in best if any(lo + off <= cp <= hi + off
                                      for lo, hi, off in MIRROR_RANGES)
             and best.get(_source_of(cp)) != best[cp]]
    if clash:
        raise SystemExit(
            "mirror: %d codepoint(s) already occupy the mirror block with a "
            "different glyph (first U+%X) — MIRROR_RANGES collides with "
            "another Plane-16 allocation" % (len(clash), min(clash)))
    added = set()
    for table in wide:
        for cp, gname in list(table.cmap.items()):
            target = mirror_cp(cp)
            if target is None or target in table.cmap:
                continue
            table.cmap[target] = gname
            added.add(target)
    return len(added)


def _source_of(cp):
    for lo, hi, off in MIRROR_RANGES:
        if lo + off <= cp <= hi + off:
            return cp - off
    return None


def main(argv):
    """mirror <ttf>... — add the aliases to already-built fonts in place."""
    import os

    from fontTools.ttLib import TTFont

    for path in argv:
        font = TTFont(path)
        n = mirror_font(font)
        font.save(path)
        print("  %s: mirrored %d icon codepoint(s)" % (os.path.basename(path), n))
    return 0
