"""Print a glyph-count diff of the built Symbols TTFs vs the upstream-shipped
ones, with per-collection probe coverage (step 8). Diagnostic stdout only."""
import os

from fontTools.ttLib import TTFont

PROBES = [
    ("Seti-UI + Custom",       0xE5FA),
    ("Devicons",               0xE700),
    ("Font Awesome (curated)", 0xF015),
    ("Material Design Icons",  0xF0001),
    ("Octicons",               0xF400),
    ("Weather Icons",          0xE300),
    ("Font Logos",             0xF300),
    ("Codicons",               0xEA60),
    ("Heavy Angle Brackets",   0x276C),
    ("Progress Indicators",    0xEE00),
]


def _cmap(f):
    return set((TTFont(f).getBestCmap() or {}).keys())


def _name(f, i):
    t = TTFont(f)["name"]
    rec = t.getName(i, 3, 1, 0x409) or t.getName(i, 1, 0, 0)
    return str(rec) if rec else "?"


def main(argv):
    built_dir, fa_merged, shipped_dir = argv[0], argv[1], argv[2]

    fa_pts = _cmap(fa_merged) if os.path.exists(fa_merged) else set()

    def report(label, path):
        pts = _cmap(path)
        print("=== %s: %s (%s bytes) ===" % (label, os.path.basename(path), f"{os.path.getsize(path):,}"))
        print("  family : %s" % _name(path, 1))
        print("  cmap   : %s codepoints" % f"{len(pts):,}")
        for col, cp in PROBES:
            print("    [%s] %s" % ("x" if cp in pts else " ", col))
        if fa_pts:
            inter = len(fa_pts & pts)
            print("  FA glyphs from merged OTF present: %s / %s" % (f"{inter:,}", f"{len(fa_pts):,}"))
        print()

    for f in sorted(os.listdir(built_dir)):
        if f.endswith(".ttf") and f.startswith("Symbols"):
            report("BUILT", os.path.join(built_dir, f))

    if os.path.isdir(shipped_dir):
        for f in sorted(os.listdir(shipped_dir)):
            if f.endswith(".ttf") and f.startswith("Symbols"):
                report("SHIPPED (in repo)", os.path.join(shipped_dir, f))
