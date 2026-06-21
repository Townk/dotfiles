"""Shared codepoint ranges and tables for the font build steps.

Single source of truth so the emoji strip (step 7), donor cell-normalization /
bleed (steps 6b/7c), and the Blink emoji split can't drift from one another.
"""

# Terminal cell-fill glyphs: block/box/shade/quadrant glyphs that tile the
# character cell. Unicode 16.0 split these across TWO blocks with identical
# purpose — the older "Symbols for Legacy Computing" (U+1FB00-1FBFF) and the
# newer "Symbols for Legacy Computing Supplement" (U+1CC00-1CEFF, added in
# Unicode 16.0). TUIs draw borders with both (e.g. the zj-hud search/rename
# frames compose their rounded corners from U+1CEA0/1CEA3/1CEA8/1CEAB in the
# Supplement block). Keep the list canonical so every consumer (emoji keep,
# donor cell-normalize, donor cell measure, bleed) handles both blocks
# together — an earlier scalar "Legacy Computing" range silently dropped the
# Supplement block, which is how those 4 corners went missing. Add a future
# terminal-cell block here once and all consumers follow.
TERMINAL_CELL_RANGES = [
    (0x1FB00, 0x1FBFF),   # Symbols for Legacy Computing
    (0x1CC00, 0x1CEFF),   # Symbols for Legacy Computing Supplement (Unicode 16.0)
]


def in_terminal_cell(cp: int) -> bool:
    return any(lo <= cp <= hi for lo, hi in TERMINAL_CELL_RANGES)


# Colour-emoji domain stripped from the built cmaps (step 7). Inclusive pairs.
# Keep in sync with the long comment on `step 7` in build-updated-font.sh.
EMOJI_STRIP_RANGES = [
    (0x2600,  0x27BF),    # Miscellaneous Symbols + Dingbats
    (0x1F300, 0x1FFFF),   # SMP emoji planes
]
# Ranges deliberately preserved even though they fall inside the strip ranges.
# The Supplement block (U+1CC00-1CEFF) sits below U+1F300 so the strip never
# reaches it; list it anyway so the keep set stays in lock-step with the
# terminal-cell model above and stays self-documenting.
EMOJI_KEEP_RANGES = list(TERMINAL_CELL_RANGES)

# Block Elements + terminal-cell glyphs for the cell-bleed step (7c).
# Box Drawing (2500-257F) already bleeds upstream and is the reference, so it is
# intentionally NOT included here.
BLEED_RANGES = [(0x2580, 0x259F)] + TERMINAL_CELL_RANGES

# hterm.wc.unambiguous: width-2 (wide) intervals. Anything not here is width 1.
# Sourced from hterm_all.js (lib.wc.unambiguous) so the Blink emoji split's
# wide/narrow classification matches hterm exactly (east_asian_width does not).
HTERM_WIDE = [
    (4352, 4447), (8986, 8987), (9001, 9002), (9193, 9196), (9200, 9200), (9203, 9203),
    (9725, 9726), (9748, 9749), (9800, 9811), (9855, 9855), (9875, 9875), (9889, 9889),
    (9898, 9899), (9917, 9918), (9924, 9925), (9934, 9934), (9940, 9940), (9962, 9962),
    (9970, 9971), (9973, 9973), (9978, 9978), (9981, 9981), (9989, 9989), (9994, 9995),
    (10024, 10024), (10060, 10060), (10062, 10062), (10067, 10069), (10071, 10071),
    (10133, 10135), (10160, 10160), (10175, 10175), (11035, 11036), (11088, 11088),
    (11093, 11093), (11904, 12255), (12272, 12350), (12352, 12871), (12880, 19903),
    (19968, 42191), (43360, 43391), (44032, 55203), (63744, 64255), (65040, 65049),
    (65072, 65135), (65281, 65376), (65504, 65510), (94176, 94180), (94192, 94193),
    (94208, 101589), (101632, 101640), (110576, 110579), (110581, 110587),
    (110589, 110590), (110592, 110895), (110898, 110898), (110928, 110930),
    (110933, 110933), (110948, 110951), (110960, 111359), (126980, 126980),
    (127183, 127183), (127374, 127374), (127377, 127386), (127488, 127490),
    (127504, 127547), (127552, 127560), (127568, 127569), (127584, 127589),
    (127744, 127776), (127789, 127797), (127799, 127868), (127870, 127891),
    (127904, 127946), (127951, 127955), (127968, 127984), (127988, 127988),
    (127992, 128062), (128064, 128064), (128066, 128252), (128255, 128317),
    (128331, 128334), (128336, 128359), (128378, 128378), (128405, 128406),
    (128420, 128420), (128507, 128591), (128640, 128709), (128716, 128716),
    (128720, 128722), (128725, 128727), (128732, 128735), (128747, 128748),
    (128756, 128764), (128992, 129003), (129008, 129008), (129292, 129338),
    (129340, 129349), (129351, 129535), (129648, 129660), (129664, 129672),
    (129680, 129725), (129727, 129733), (129742, 129755), (129760, 129768),
    (129776, 129784), (131072, 196605), (196608, 262141),
]


def in_ranges(cp, ranges):
    return any(lo <= cp <= hi for lo, hi in ranges)