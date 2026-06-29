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


def _compact_runs(cps):
    """Collapse a sorted codepoint list into 'U+XXXX' / 'U+XXXX..U+YYYY' runs."""
    runs = []
    for cp in sorted(cps):
        if runs and cp == runs[-1][1] + 1:
            runs[-1][1] = cp
        else:
            runs.append([cp, cp])
    return ["U+%04X" % a if a == b else "U+%04X..U+%04X" % (a, b)
            for a, b in runs]


def warn_unresolved_donors(families, donors, unresolved):
    """Make a wholesale donor miss IMPOSSIBLE to overlook.

    Donor codepoints with no covering font are dropped silently — they simply
    never enter the built cmap, so the only trace used to be one easily-missed
    line in a multi-thousand-line build log. That is exactly how an entire
    category (e.g. the 856-glyph Iosevka-only set: Symbols for Legacy Computing
    Supplement incl. every SEPARATED BLOCK SEXTANT, plus Latin/Cyrillic
    extensions) shipped blank into the Blink/JBM font. Print a loud, counted,
    range-compressed banner that names the donor families which contributed
    nothing (install those to fix), so the gap is obvious at a glance. Set
    DONOR_STRICT=1 to turn the gap into a hard build failure instead.
    """
    resolved_families = {d[0] for d in donors}
    missing_families = [f for f in families if f not in resolved_families]
    runs = _compact_runs(unresolved)
    bar = "  " + "!" * 70
    print(bar)
    print("  WARNING: %d donor glyph(s) had NO covering font and will be MISSING"
          % len(unresolved))
    print("           from the built fonts (blank cells in Blink/terminals).")
    if missing_families:
        print("  Unprovisioned donor families (install to fix): %s"
              % ", ".join(missing_families))
    shown = ", ".join(runs[:40])
    if len(runs) > 40:
        shown += ", ... (+%d more ranges)" % (len(runs) - 40)
    print("  Affected codepoints: %s" % shown)
    print(bar)
    if os.environ.get("DONOR_STRICT") == "1":
        raise SystemExit(
            "DONOR_STRICT=1: %d donor glyph(s) unresolved; aborting build."
            % len(unresolved))


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
                warn_unresolved_donors(families, donors, unresolved)

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
