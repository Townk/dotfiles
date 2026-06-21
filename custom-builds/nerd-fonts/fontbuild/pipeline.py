"""In-memory per-font pipeline (steps 6b -> 7 -> 7b -> 7c).

For each built font: donor import -> emoji strip -> stash a pristine pre-scale
copy -> icon scale -> cell bleed (JetBrains Mono only). The font is parsed once
and serialized twice (the pre-scale stash + the final output) instead of the
per-step load/save round-trips the original separate steps performed. Donors are
resolved once and shared across all output fonts.
"""
import argparse
import json
import os

from fontTools.ttLib import TTFont

from . import donor, scale, strip_emoji
from .bleed import bleed_font


def run(argv):
    ap = argparse.ArgumentParser(prog="fontbuild pipeline")
    ap.add_argument("--fa-map", required=True)
    ap.add_argument("--repo-dir", required=True)
    ap.add_argument("--donor-glyphs", default="")
    ap.add_argument("--donor-families", default="")
    ap.add_argument("--donor-paths", default="")
    ap.add_argument("--icon-fill", type=float, required=True)
    ap.add_argument("--icon-dy", type=float, default=0.0)
    ap.add_argument("--custom-dy", type=float, default=0.0)
    ap.add_argument("--prescale-dir", required=True)
    ap.add_argument("fonts", nargs="+")
    args = ap.parse_args(argv)

    # --- resolve donors ONCE (shared across all destination fonts) ---
    donors = []
    explicit_keep = set()
    if args.donor_glyphs and os.path.isfile(args.donor_glyphs):
        cps = donor.load_codepoints(args.donor_glyphs)
        families = [f.strip() for f in args.donor_families.split(",") if f.strip()]
        explicit_paths = [p for p in args.donor_paths.split(os.pathsep) if p]
        # Protect every imported donor codepoint from the emoji strip. Reuse the
        # parsed import set rather than re-parsing the file with a stricter regex,
        # so the keep set is a strict superset of what was imported (a bare-hex
        # entry in an emoji range can't be imported and then stripped away).
        explicit_keep = set(cps)
        if not cps:
            print("  no donor codepoints listed")
        elif not families:
            print("  no donor font families configured")
        else:
            donors, unresolved = donor.resolve_donors(cps, families, explicit_paths)
            if unresolved:
                print("  unresolved donor glyph(s): " +
                      ", ".join("U+%04X" % cp for cp in sorted(unresolved)))

    # --- shared scale inputs ---
    fa_map = json.load(open(args.fa_map))
    targets, custom_cps = scale.load_targets(fa_map)
    ref_cps = scale.load_ref_cps(args.repo_dir)

    if explicit_keep:
        print("  preserving %d explicit donor codepoint(s)" % len(explicit_keep))

    os.makedirs(args.prescale_dir, exist_ok=True)
    total_stripped = 0
    for path in args.fonts:
        base = os.path.basename(path)
        is_jbm = base.startswith("JetBrains")
        font = TTFont(path)

        # 6b: donor import (in-memory). Cell-normalize legacy block only for the
        # embedded mono text font (JBM).
        if donors:
            imported, already, norm = donor.import_into(font, donors, is_jbm)
            print("  %s: donor imported %d, skipped %d present%s" %
                  (base, imported, already,
                   (" (%d legacy cell-normalized)" % norm) if norm else ""))

        # 7: emoji strip (in-memory). The Blink CSS derives its emoji
        # unicode-range from the Noto subset's own cmap (step 10), so no sidecar
        # of stripped codepoints is needed here.
        removed, _removed_cps = strip_emoji.strip_font(font, explicit_keep)
        total_stripped += removed
        print("  %s: stripped %d emoji codepoints" % (base, removed))

        # 7b: stash pristine (pre-scale) copy, then normalize icon sizing.
        font.save(os.path.join(args.prescale_dir, base))
        info = scale.scale_font(font, targets, custom_cps, ref_cps,
                                args.icon_fill, args.icon_dy, args.custom_dy)
        scale.log_scale_result(base, info)

        # 7c: bleed block + legacy-computing glyphs (JBM only).
        if is_jbm:
            res = bleed_font(font)
            if res is None:
                print("  no U+2588 full block; skipping bleed")
            else:
                print("  bled %d block/legacy glyphs (cell %d..%d, overshoot "
                      "+%d/-%d -> %d..%d)"
                      % (res["changed"], res["cell_bot"], res["cell_top"],
                         res["over_top"], res["over_bot"],
                         res["bot_to"], res["top_to"]))

        font.save(path)

    print("  total emoji codepoints stripped: %d" % total_stripped)
    return 0
