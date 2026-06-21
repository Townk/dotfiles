"""Drop codepoints in the colour-emoji ranges from a font's cmap (step 7).

We touch the cmap subtables only -- glyf and other tables are left alone.
Removing the codepoint->glyph mapping is enough for terminal font lookup:
ghostty/wezterm walk font cmaps in order, so a missing entry here means the
next font in the chain (Apple Color Emoji etc.) gets asked.

Idempotent: a second pass removes nothing (already-stripped codepoints are not
present). Explicit donor codepoints (imported in step 6b) are preserved.
"""
import re

from .ranges import EMOJI_KEEP_RANGES, EMOJI_STRIP_RANGES, in_ranges


def load_keep_codepoints(path):
    """Explicit donor codepoints (U+XXXX tokens) to preserve from stripping."""
    if not path:
        return set()
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return set()
    keep = set()
    for match in re.finditer(r"U\+([0-9A-Fa-f]{4,6})\b", text):
        keep.add(int(match.group(1), 16))
    return keep


def in_strip_range(cp, explicit_keep):
    if cp in explicit_keep:
        return False
    if in_ranges(cp, EMOJI_KEEP_RANGES):
        return False
    return in_ranges(cp, EMOJI_STRIP_RANGES)


def strip_font(font, explicit_keep):
    """Remove colour-emoji codepoints from every cmap subtable of an open
    TTFont. Returns (removed_count, removed_codepoints_set). No file IO."""
    removed = 0
    removed_cps = set()
    for table in font["cmap"].tables:
        # `table.cmap` is {codepoint: glyph_name}; mutating while iterating is
        # unsafe, so collect victims first, delete second.
        victims = [cp for cp in table.cmap if in_strip_range(cp, explicit_keep)]
        for cp in victims:
            del table.cmap[cp]
        removed += len(victims)
        removed_cps.update(victims)
    return removed, removed_cps
