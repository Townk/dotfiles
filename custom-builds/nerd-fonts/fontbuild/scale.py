"""Normalize icon glyph sizing to the curated md/oct box (step 7b).

Measures the curated Material-Design + Octicons glyphs in each font (median
max-dimension and median vertical centre), then scales every Font Awesome glyph
(native + relocated) and every custom SVG icon to icon_fill x that box, aspect
preserved, about its own bbox centre, and moves it onto that centre + icon_dy.
Advance widths are untouched; composite glyphs are decomposed.
"""
import json
import statistics

from fontTools.misc.transform import Identity
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen


def load_targets(fa_map):
    """(targets, custom_cps) from a parsed fa-map.json: every FA-origin glyph
    (native + relocated) plus the custom SVG icons (which get an extra nudge)."""
    targets = [int(h, 16) for h in fa_map.get("fa_cps", [])]
    custom_cps = {int(h, 16) for h in fa_map.get("custom", {}).values()}
    return targets, custom_cps


def load_ref_cps(repo_dir):
    """Curated reference codepoints: Material Design + Octicons. glyphnames.json
    keys are unprefixed (md-account, oct-x); the font carries them as nf-*."""
    glyphnames = json.load(open(repo_dir + "/glyphnames.json"))
    ref_cps = set()
    for _name, _info in glyphnames.items():
        if _name == "METADATA" or not isinstance(_info, dict):
            continue
        if _name.startswith(("md-", "oct-")):
            try:
                ref_cps.add(int(_info["code"], 16))
            except (KeyError, ValueError, TypeError):
                pass
    return ref_cps


def _bbox(glyf, gname):
    g = glyf[gname]
    g.recalcBounds(glyf)
    if g.numberOfContours == 0:
        return None
    return g.xMin, g.yMin, g.xMax, g.yMax


def _measure_ref(glyf, cmap, ref_cps):
    centers, sizes = [], []
    for cp in ref_cps:
        gname = cmap.get(cp)
        if not gname:
            continue
        b = _bbox(glyf, gname)
        if not b:
            continue
        xmin, ymin, xmax, ymax = b
        centers.append((ymin + ymax) / 2.0)
        sizes.append(max(xmax - xmin, ymax - ymin))
    if not sizes:
        raise SystemExit("no md/oct reference glyphs found in font")
    return statistics.median(centers), statistics.median(sizes)


def _transform_one(glyf, glyph_set, gname, factor, target_cy):
    glyph = glyf[gname]
    glyph.recalcBounds(glyf)
    if glyph.numberOfContours == 0:
        return False
    cx = (glyph.xMin + glyph.xMax) / 2.0
    cy = (glyph.yMin + glyph.yMax) / 2.0
    rec = DecomposingRecordingPen(glyph_set)
    glyph.draw(rec, glyf)
    pen = TTGlyphPen(glyph_set)
    # Scale about the bbox centre, then move that centre to target_cy.
    t = (Identity
         .translate(0, target_cy - cy)
         .translate(cx, cy).scale(factor).translate(-cx, -cy))
    rec.replay(TransformPen(pen, t))
    ng = pen.glyph()
    ng.recalcBounds(glyf)
    glyf[gname] = ng
    return True


def scale_font(font, targets, custom_cps, ref_cps,
               icon_fill, icon_dy_em, custom_dy_em):
    """Scale the FA + custom icons of an open TTFont to the curated md/oct box.
    Returns a dict of metrics for logging. No file IO."""
    upm = font["head"].unitsPerEm
    glyf = font["glyf"]
    cmap = font.getBestCmap() or {}
    gs = font.getGlyphSet()

    ref_cy, ref_size = _measure_ref(glyf, cmap, ref_cps)
    target_size = icon_fill * ref_size
    base_cy = ref_cy + icon_dy_em * upm
    custom_offset = custom_dy_em * upm

    n = 0
    tops, bots = [], []
    for cp in targets:
        gname = cmap.get(cp)
        if not gname:
            continue
        b = _bbox(glyf, gname)
        if not b:
            continue
        cur = max(b[2] - b[0], b[3] - b[1])
        if cur <= 0:
            continue
        cy = base_cy + (custom_offset if cp in custom_cps else 0)
        if _transform_one(glyf, gs, gname, target_size / cur, cy):
            n += 1
            g = glyf[gname]
            tops.append(g.yMax)
            bots.append(g.yMin)

    asc = font["hhea"].ascent
    desc = font["hhea"].descent
    bleed = bool(tops) and (max(tops) > asc or min(bots) < desc)
    return {
        "upm": upm, "ref_size": ref_size, "ref_cy": ref_cy, "n": n,
        "target_size": target_size, "icon_dy_em": icon_dy_em,
        "custom_dy_em": custom_dy_em, "tops": tops, "bots": bots,
        "asc": asc, "desc": desc, "bleed": bleed,
    }


def log_scale_result(name, info):
    """Reproduce the original _scale_fa.py stdout for one font."""
    upm = info["upm"]
    print("  %s: md/oct box=%.3fem center=%+.3f -> %d icons @ %.3fem%s%s"
          % (name, info["ref_size"] / upm, info["ref_cy"] / upm, info["n"],
             info["target_size"] / upm,
             (" dy=%+.2fem" % info["icon_dy_em"]) if info["icon_dy_em"] else "",
             (" custom_dy=%+.2fem" % info["custom_dy_em"]) if info["custom_dy_em"] else ""))
    if info["tops"]:
        span = ("  top<=%.3f bot>=%.3f (cell %.3f..%.3f)"
                % (max(info["tops"]) / upm, min(info["bots"]) / upm,
                   info["desc"] / upm, info["asc"] / upm))
        print(("  WARNING: vertical bleed!" + span) if info["bleed"]
              else ("  ok," + span))
