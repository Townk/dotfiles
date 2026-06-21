"""Subcommand dispatch for `python -m fontbuild`.

  pipeline      donor import + emoji strip + icon scale + cell bleed (in-memory)
  scale         re-normalize icon sizing only (used by recalibrate-fa.sh)
  glyphs        emit glyphs.json index
  verify        print built-vs-shipped glyph-count diff
  emoji-split   subset + split Noto OT-SVG into wide/narrow WOFF2 for Blink
"""
import sys

USAGE = ("usage: python -m fontbuild "
         "<pipeline|scale|glyphs|verify|emoji-split> ...\n")


def _run_scale(rest):
    """scale <fa_map> <repo_dir> <icon_fill> <icon_dy> <custom_dy> <ttf>...

    Mirrors the original _scale_fa.py argv so recalibrate-fa.sh changes minimally.
    """
    import json
    import os

    from fontTools.ttLib import TTFont

    from . import scale

    fa_map = json.load(open(rest[0]))
    repo_dir = rest[1]
    icon_fill = float(rest[2])
    icon_dy = float(rest[3])
    custom_dy = float(rest[4])
    paths = rest[5:]

    targets, custom_cps = scale.load_targets(fa_map)
    ref_cps = scale.load_ref_cps(repo_dir)
    for path in paths:
        font = TTFont(path)
        info = scale.scale_font(font, targets, custom_cps, ref_cps,
                                icon_fill, icon_dy, custom_dy)
        font.save(path)
        scale.log_scale_result(os.path.basename(path), info)
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        sys.stderr.write(USAGE)
        return 2
    cmd, rest = argv[0], argv[1:]

    if cmd == "pipeline":
        from . import pipeline
        return pipeline.run(rest)
    if cmd == "scale":
        return _run_scale(rest)
    if cmd == "glyphs":
        from . import glyphs_json
        glyphs_json.main(rest)
        return 0
    if cmd == "verify":
        from . import verify
        verify.main(rest)
        return 0
    if cmd == "emoji-split":
        from . import emoji_noto
        emoji_noto.main(rest)
        return 0

    sys.stderr.write("unknown subcommand: %s\n%s" % (cmd, USAGE))
    return 2
