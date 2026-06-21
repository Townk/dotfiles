"""Subset Noto OT-SVG to its cmap-reachable emoji and split into two WOFF2 faces
(wide / narrow) for the Blink CSS (step 10). Width comes from hterm's own
wcwidth table (ranges.HTERM_WIDE) so classification matches Blink exactly
(unicodedata's east_asian_width does not). Layout features are dropped so
ZWJ/skin-tone/flag closure can't inflate the SVG-document count past Safari's
~2000 ceiling. Each glyph is embedded once.

Prints four stdout lines (wide-range, narrow-range, wide-woff2, narrow-woff2)
for the bash caller; per-face SVG-document counts go to stderr.
"""
import os
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

from .ranges import HTERM_WIDE


def is_wide(cp):
    for lo, hi in HTERM_WIDE:
        if lo <= cp <= hi:
            return True
    return False


def is_text(cp):
    # Keep JBM's own glyph for these: the whole ASCII/Latin-1 text region
    # (digits, # and * keycap bases, (c)/(r)), plus TM and the zero-width
    # joiner/selectors.
    return cp < 0x2000 or cp in (0x2122, 0x200D, 0xFE0F, 0x20E3)


def compress(xs):
    runs, i = [], 0
    while i < len(xs):
        j = i
        while j + 1 < len(xs) and xs[j + 1] == xs[j] + 1:
            j += 1
        runs.append("U+%X" % xs[i] if i == j else "U+%X-%X" % (xs[i], xs[j]))
        i = j + 1
    return ", ".join(runs)


def subset_to(noto_otf, unicodes, path):
    f = TTFont(noto_otf)
    ss = subset.Subsetter()
    # Drop layout closure so ligature/ZWJ glyphs can't pull extra SVG docs back in.
    ss.options.layout_features = []
    ss.options.layout_scripts = []
    ss.options.notdef_outline = False
    ss.populate(unicodes=unicodes)
    ss.subset(f)
    f.flavor = "woff2"
    f.save(path)
    g = TTFont(path)
    return len(g["SVG "].docList) if "SVG " in g else 0


def main(argv):
    noto_otf = argv[0]
    outdir = argv[1]
    os.makedirs(outdir, exist_ok=True)
    cmap = TTFont(noto_otf).getBestCmap()
    emoji = sorted(c for c in cmap if not is_text(c))
    wide = [c for c in emoji if is_wide(c)]
    narrow = [c for c in emoji if not is_wide(c)]
    wide_path = os.path.join(outdir, "noto-emoji-wide.woff2")
    narrow_path = os.path.join(outdir, "noto-emoji-narrow.woff2")
    wdocs = subset_to(noto_otf, wide, wide_path) if wide else 0
    ndocs = subset_to(noto_otf, narrow, narrow_path) if narrow else 0
    sys.stderr.write("  SVG docs: wide=%d narrow=%d (Safari ceiling ~2000)\n"
                     % (wdocs, ndocs))
    print(compress(wide))
    print(compress(narrow))
    print(wide_path if wide else "")
    print(narrow_path if narrow else "")
