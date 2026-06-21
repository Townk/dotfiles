"""Bleed block-element + legacy-computing glyphs past the cell top/bottom so
they tile without a 1px seam (step 7c, embedded JetBrains Mono only).

The cell box is taken from FULL BLOCK U+2588 (yMin..yMax). The overshoot is
taken from JetBrains Mono's own box-drawing bleed (vertical line U+2502 extends
past the cell by this much), matching the font's existing design exactly. Only
points sitting ON the cell top/bottom edge are moved; interior points are
untouched, so each glyph keeps its fill fraction.
"""
from .ranges import BLEED_RANGES

EPS = 4


def bleed_font(font):
    """Bleed block/legacy glyphs of an open TTFont past the cell edges. Returns
    a dict of metrics for logging, or None if U+2588 is absent. No file IO."""
    cmap = font.getBestCmap() or {}
    glyf = font["glyf"]

    fb = cmap.get(0x2588)
    if not fb:
        return None
    fbg = glyf[fb]
    fbg.recalcBounds(glyf)
    cell_top, cell_bot = fbg.yMax, fbg.yMin

    over_top = over_bot = 100
    vl = cmap.get(0x2502)
    if vl:
        vlg = glyf[vl]
        vlg.recalcBounds(glyf)
        over_top = max(0, vlg.yMax - cell_top)
        over_bot = max(0, cell_bot - vlg.yMin)
    if over_top == 0 and over_bot == 0:
        over_top = over_bot = 100

    top_to, bot_to = cell_top + over_top, cell_bot - over_bot
    changed = 0
    for cp in (c for lo, hi in BLEED_RANGES for c in range(lo, hi + 1)):
        gn = cmap.get(cp)
        if not gn:
            continue
        g = glyf[gn]
        if getattr(g, "numberOfContours", 0) <= 0:
            continue
        coords = g.coordinates
        moved = False
        for i in range(len(coords)):
            x, y = coords[i]
            if abs(y - cell_top) <= EPS:
                coords[i] = (x, top_to)
                moved = True
            elif abs(y - cell_bot) <= EPS:
                coords[i] = (x, bot_to)
                moved = True
        if moved:
            g.recalcBounds(glyf)
            changed += 1
    return {
        "changed": changed, "cell_bot": cell_bot, "cell_top": cell_top,
        "over_top": over_top, "over_bot": over_bot,
        "bot_to": bot_to, "top_to": top_to,
    }
