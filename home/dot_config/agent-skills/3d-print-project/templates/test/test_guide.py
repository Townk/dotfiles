"""The assembly guide (scripts/guide/): an IKEA-style sheet anyone can build the product from (the user, 2026-11-08).
A step adds 3 kinds of piece at most; a screw or an insert is shown from 2 angles or more; every printed part and
every piece of hardware the product takes is in it, as many as the build has. The project's own: steps.py (STEPS,
STATIONS: one guide per variant, WORDS) and guide.scad (piece(id, p), FOCUS); this checks them."""
import re
import subprocess
from pathlib import Path

import pytest

from scripts.guide.build import SCAD, focus, scenes
from scripts.guide.steps import STATIONS, STEPS, WORDS
from scripts.print_parts import QTY, base, hosts

ROOT = Path(__file__).resolve().parents[1]


def test_a_step_adds_three_kinds_of_piece_at_most():
    bad = [s["title"] for s in STEPS if len(s["pieces"]) > 3]
    assert not bad, bad


def test_a_screw_or_insert_is_shown_from_two_angles():
    bad = [s["title"] for s in STEPS if any(w in p[0] for p in s["pieces"] for w in ("screw", "insert")) and len(s["views"]) < 2]
    assert not bad, bad


def test_every_printed_part_is_in_the_guide_as_often_as_it_prints():
    want = {}
    for n in hosts():                                  # a part and its companion print as one (the badge's letters)
        if n.startswith(next(iter(STATIONS)) + "_") or len(STATIONS) == 1:   # one variant's parts (a project's naming)
            want[base(n)] = QTY.get(n, 1)
    got = {}
    for s in STEPS:
        for _, n, _, name in s["pieces"]:
            if name and not any(w in name for w in ("insert", "countersunk", "socket", "spring")) and name != "charger":
                got[name] = got.get(name, 0) + n
    assert got == want


def test_the_hardware_is_the_build_docs():
    # the hardware table in docs/build/ (| What | Qty | ...): its rows of screws, inserts, springs
    rows = re.findall(r"^\| (M\d[^|]+|\d+ × \d+[^|]+) \| (\d+) \|", (ROOT / "docs/build/printing.md").read_text(), re.M)
    want = {k.strip(): int(v) for k, v in rows}
    got = {}
    for s in STEPS:
        for _, n, _, name in s["pieces"]:
            if name in want:
                got[name] = got.get(name, 0) + n
    assert got == want


@pytest.mark.parametrize("side", sorted(STATIONS))
def test_the_guide_model_knows_every_piece_and_close_up(side, tmp_path):
    # every piece id and close-up point the steps name exists in guide.scad (OpenSCAD evaluates the pieces)
    pts, _ = focus(side)
    used = {v[k] for s in STEPS for v in s["views"] for k in ("at", "section") if k in v}
    assert used <= set(pts), used - set(pts)
    sc, built = scenes()
    ids = sorted({i for scene, new in sc for i in scene + new} | {p[2] for s in STEPS for p in s["pieces"] if p[2]} | set(built))
    out = tmp_path / "e.echo"
    r = subprocess.run(["openscad", "-o", str(out), "--export-format", "echo", "-D", f'side="{side}"',
                        "-D", "show=[" + ",".join(f'"{i}"' for i in ids) + "]", str(SCAD)], capture_output=True, text=True)
    log = r.stderr + (out.read_text() if out.exists() else "")
    assert r.returncode == 0 and "ERROR" not in log and "WARNING" not in log, log[-1500:]


def test_the_words_fit_both_stations():
    for side in STATIONS:
        for s in STEPS:
            for t in s["text"] + [s["title"]]:
                t.format(**WORDS[side], kid=STATIONS[side])
