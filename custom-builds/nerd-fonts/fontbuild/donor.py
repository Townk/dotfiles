"""Copy a small Unicode allowlist from OFL donor fonts into the built fonts
(step 6b).

Uses fontTools instead of FontForge so the donor step copies only glyph
outlines, metrics, and cmap entries. That avoids FontForge's expensive GPOS
validation path while keeping the generated font tiny and simple.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

from fontTools.misc.transform import Identity, Transform
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTCollection, TTFont

from .ranges import LEGACY_HI, LEGACY_LO

DEFAULT_DIRS = [
    "~/Library/Fonts",
    "/Library/Fonts",
    "/System/Library/Fonts",
    "/System/Library/Fonts/Supplemental",
    "/opt/homebrew/share/fonts",
    "/usr/local/share/fonts",
    "~/.local/share/fonts",
    "/usr/share/fonts",
]

KNOWN_PATHS = {
    "Iosevka": [
        "~/Library/Fonts/Iosevka.ttc",
        "/Library/Fonts/Iosevka.ttc",
        "/opt/homebrew/share/fonts/Iosevka.ttc",
        "/usr/local/share/fonts/Iosevka.ttc",
    ],
    "Noto Sans Symbols 2": [
        "~/Library/Fonts/NotoSansSymbols2-Regular.ttf",
        "/Library/Fonts/NotoSansSymbols2-Regular.ttf",
        "/opt/homebrew/share/fonts/NotoSansSymbols2-Regular.ttf",
        "/usr/local/share/fonts/NotoSansSymbols2-Regular.ttf",
    ],
    "Noto Sans Math": [
        "~/Library/Fonts/NotoSansMath-Regular.ttf",
        "/Library/Fonts/NotoSansMath-Regular.ttf",
        "/opt/homebrew/share/fonts/NotoSansMath-Regular.ttf",
        "/usr/local/share/fonts/NotoSansMath-Regular.ttf",
    ],
    "Noto Music": [
        "~/Library/Fonts/NotoMusic-Regular.ttf",
        "/Library/Fonts/NotoMusic-Regular.ttf",
        "/opt/homebrew/share/fonts/NotoMusic-Regular.ttf",
        "/usr/local/share/fonts/NotoMusic-Regular.ttf",
    ],
    "STIX Two Math": [
        "/System/Library/Fonts/Supplemental/STIXTwoMath.otf",
        "~/Library/Fonts/STIXTwoMath-Regular.otf",
        "/Library/Fonts/STIXTwoMath-Regular.otf",
        "/opt/homebrew/share/fonts/STIXTwoMath-Regular.otf",
        "/usr/local/share/fonts/STIXTwoMath-Regular.otf",
    ],
}


def expand(path: str) -> str:
    return os.path.abspath(os.path.expanduser(path))


def load_codepoints(path: str) -> list[int]:
    cps: list[int] = []
    seen: set[int] = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0]
            for match in re.finditer(r"(?:U\+)?([0-9A-Fa-f]{4,6})\b", line):
                cp = int(match.group(1), 16)
                if cp in (0xFE0E, 0xFE0F) or cp in seen:
                    continue
                seen.add(cp)
                cps.append(cp)
    return cps


def name_records(font: TTFont, name_id: int) -> list[str]:
    out: list[str] = []
    for rec in font["name"].names:
        if rec.nameID != name_id:
            continue
        try:
            value = rec.toUnicode().strip()
        except Exception:
            continue
        if value and value not in out:
            out.append(value)
    return out


def family_matches(font: TTFont, family: str, path: str) -> bool:
    wanted = family.casefold()
    for name_id in (1, 4, 6):
        for name in name_records(font, name_id):
            folded = name.casefold()
            if folded == wanted or folded.startswith(wanted + " "):
                return True
    basename = os.path.basename(path).casefold().replace("-", "").replace("_", "")
    return wanted.replace(" ", "") in basename


def font_cmap(font: TTFont) -> dict[int, str]:
    best = font.getBestCmap() or {}
    out = {int(cp): name for cp, name in best.items()}
    for table in font["cmap"].tables:
        if not table.isUnicode():
            continue
        for cp, name in table.cmap.items():
            out.setdefault(int(cp), name)
    return out


def open_font_faces(path: str) -> list[TTFont]:
    suffix = Path(path).suffix.lower()
    if suffix in {".ttc", ".otc"}:
        return list(TTCollection(path).fonts)
    return [TTFont(path)]


def candidate_paths(family: str, explicit_paths: list[str]) -> list[str]:
    paths: list[str] = []
    paths.extend(expand(path) for path in explicit_paths)
    paths.extend(expand(path) for path in KNOWN_PATHS.get(family, []))

    suffixes = (".ttf", ".otf", ".ttc", ".otc")
    for root in DEFAULT_DIRS:
        root = expand(root)
        if not os.path.isdir(root):
            continue
        try:
            entries = os.listdir(root)
        except OSError:
            continue
        for entry in entries:
            if entry.lower().endswith(suffixes):
                paths.append(os.path.join(root, entry))

    out: list[str] = []
    seen: set[str] = set()
    for path in paths:
        if path in seen or not os.path.exists(path):
            continue
        seen.add(path)
        out.append(path)
    return out


def open_donor(family: str, needed: set[int], explicit_paths: list[str]):
    for path in candidate_paths(family, explicit_paths):
        try:
            faces = open_font_faces(path)
        except Exception:
            continue
        for font in faces:
            if not family_matches(font, family, path):
                continue
            cmap = font_cmap(font)
            if any(cp in cmap for cp in needed):
                return path, font, cmap
    return None, None, {}


def cmap_accepts_cp(table, cp: int) -> bool:
    if not table.isUnicode():
        return False
    if table.format in {0, 6}:
        return cp <= 0xFF
    if table.format == 4:
        return cp <= 0xFFFF
    return True


def unique_glyph_name(order: set[str], cp: int) -> str:
    base = "u%04X" % cp if cp <= 0xFFFF else "u%06X" % cp
    name = base
    i = 1
    while name in order:
        i += 1
        name = f"{base}.{i}"
    return name


def draw_donor_glyph(donor: TTFont, donor_gname: str, transform, max_err: float):
    donor_set = donor.getGlyphSet()
    rec = DecomposingRecordingPen(donor_set)
    donor_set[donor_gname].draw(rec)

    tt_pen = TTGlyphPen(None)
    cu2qu_pen = Cu2QuPen(tt_pen, max_err=max_err)
    rec.replay(TransformPen(cu2qu_pen, transform))
    return tt_pen.glyph()


def glyphset_bounds(font: TTFont, gname: str):
    """(xMin,yMin,xMax,yMax) of a glyph's outline (any outline format), or None."""
    try:
        gs = font.getGlyphSet()
        pen = BoundsPen(gs)
        gs[gname].draw(pen)
        return pen.bounds
    except Exception:
        return None


def target_cell(font: TTFont):
    """The monospace cell rect (x0,y0,x1,y1) from the font's FULL BLOCK U+2588:
    x 0..advance, y blockYMin..blockYMax. None if U+2588 is absent."""
    gname = (font.getBestCmap() or {}).get(0x2588)
    if not gname:
        return None
    bb = glyphset_bounds(font, gname)
    if not bb:
        return None
    adv = font["hmtx"].metrics.get(gname, (0, 0))[0]
    if adv <= 0:
        return None
    return (0.0, float(bb[1]), float(adv), float(bb[3]))


def donor_block_cell(donor: TTFont, donor_cmap: dict[int, str]):
    """The donor's design cell for the legacy-computing block, from the union of
    its U+1FB00-1FBFF glyphs: x 0..max(xMax), y min(yMin)..max(yMax). None if
    empty."""
    xmax = ymin = ymax = None
    for cp in range(LEGACY_LO, LEGACY_HI + 1):
        gname = donor_cmap.get(cp)
        if not gname:
            continue
        bb = glyphset_bounds(donor, gname)
        if not bb:
            continue
        xmax = bb[2] if xmax is None else max(xmax, bb[2])
        ymin = bb[1] if ymin is None else min(ymin, bb[1])
        ymax = bb[3] if ymax is None else max(ymax, bb[3])
    if xmax is None or xmax <= 0 or ymax <= ymin:
        return None
    return (0.0, float(ymin), float(xmax), float(ymax))


def import_one(dest: TTFont, donor: TTFont, donor_cmap: dict[int, str], cp: int,
               cell=None) -> str:
    if "glyf" not in dest:
        raise SystemExit("destination font is not TrueType/glyf-based")

    donor_gname = donor_cmap[cp]
    dest_upm = dest["head"].unitsPerEm
    donor_upm = donor["head"].unitsPerEm

    order = dest.getGlyphOrder()
    order_set = set(order)
    new_name = unique_glyph_name(order_set, cp)
    order.append(new_name)
    dest.setGlyphOrder(order)

    if cell is not None:
        # Cell-normalize: affine-map the donor's block cell onto the target cell
        # so the glyph tiles, and override the advance to the target cell width.
        (dx0, dy0, dx1, dy1), (tx0, ty0, tx1, ty1) = cell
        sx = (tx1 - tx0) / (dx1 - dx0)
        sy = (ty1 - ty0) / (dy1 - dy0)
        xform = Transform(sx, 0, 0, sy, tx0 - dx0 * sx, ty0 - dy0 * sy)
        glyph = draw_donor_glyph(donor, donor_gname, xform, max(1.0, sx, sy))
        dest["glyf"][new_name] = glyph
        glyph.recalcBounds(dest["glyf"])
        dest["hmtx"].metrics[new_name] = (int(round(tx1 - tx0)),
                                          int(getattr(glyph, "xMin", 0)))
    else:
        scale = dest_upm / donor_upm
        glyph = draw_donor_glyph(donor, donor_gname, Identity.scale(scale),
                                 max(1.0, scale))
        dest["glyf"][new_name] = glyph
        advance, lsb = donor["hmtx"].metrics.get(donor_gname, (donor_upm, 0))
        dest["hmtx"].metrics[new_name] = (int(round(advance * scale)),
                                          int(round(lsb * scale)))

    mapped = False
    for table in dest["cmap"].tables:
        if cmap_accepts_cp(table, cp):
            table.cmap[cp] = new_name
            mapped = True
    # A cp the dest cmap can't encode (e.g. an SMP donor when dest has only a
    # format-4 subtable) would be an unreachable glyph counted as imported.
    # Nerd Fonts TTFs carry a format-12 subtable, so this is a boundary guard.
    if not mapped:
        raise SystemExit(
            "no cmap subtable can map U+%04X (dest lacks a format-12 cmap?)" % cp)

    dest["maxp"].numGlyphs = len(order)
    return new_name


def resolve_donors(cps, families, explicit_paths):
    """Open each donor family once and assign codepoints by family priority.
    Returns (donors, unresolved) where donors = [(family, path, font, cmap,
    covered)]. Shared across all destination fonts so each donor is opened once.
    """
    donors = []
    unresolved = set(cps)
    for family in families:
        path, font, cmap = open_donor(family, unresolved, explicit_paths)
        if not font:
            print("  donor missing or unused: %s" % family)
            continue
        covered = sorted(cp for cp in unresolved if cp in cmap)
        donors.append((family, path, font, cmap, covered))
        unresolved.difference_update(covered)
        print("  donor: %-20s %3d glyph(s)  %s" % (family, len(covered), path))
        if not unresolved:
            break
    return donors, unresolved


def import_into(dest, donors, cell_normalize_legacy):
    """Import the resolved donor glyphs into an open destination TTFont. When
    cell_normalize_legacy is true (embedded mono text font), legacy-computing
    block glyphs are remapped onto the dest cell so they tile. Returns
    (imported, already, norm). No file IO."""
    present = set(dest.getBestCmap() or {})
    tcell = target_cell(dest) if cell_normalize_legacy else None
    norm = imported = already = 0
    for _family, _path, donor, cmap, covered in donors:
        dcell = donor_block_cell(donor, cmap) if tcell is not None else None
        for cp in covered:
            if cp in present:
                already += 1
                continue
            cell = None
            if tcell is not None and dcell is not None and LEGACY_LO <= cp <= LEGACY_HI:
                cell = (dcell, tcell)
                norm += 1
            import_one(dest, donor, cmap, cp, cell=cell)
            present.add(cp)
            imported += 1
    return imported, already, norm
