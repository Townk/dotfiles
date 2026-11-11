"""What Bambu Studio's slicer makes of the build (scripts/slice.py, scripts/bambu.py): the whole product sliced
into one project, and each plate's G-code read back. Slow (minutes), and skipped while the Bambu Studio app is
open (the CLI refuses to run beside it)."""
import json
import re
import zipfile
from pathlib import Path

import pytest

from scad import run_scad
from scripts import bambu
from scripts.print_parts import COLOURS, PRINT_PARTS, PROJECT, base, hosts

PRODUCT = [n for n in hosts() if not n.startswith("coupon_")]   # the whole product, every part (not the queue)
needs_slicer = pytest.mark.skipif(not bambu.CLI.exists() or bambu.gui_running(),
                                  reason="needs Bambu Studio installed and its app closed")


def test_slicer_colours_are_the_models(tmp_path):
    # scripts/print_parts.py's COLOURS are the colours params/common.scad renders with (name them alike there)
    names = sorted(COLOURS)
    log = run_scad("echo(C = [" + ", ".join(f"c_{n}" for n in names) + "]);", tmp_path, fmt="echo")
    assert json.loads(re.search(r"ECHO: C = (.*)", log).group(1)) == [COLOURS[n] for n in names]


@pytest.fixture(scope="session")
def project(tmp_path_factory):
    """The whole product sliced into one project (as scripts/slice.py builds stl/print/)."""
    from concurrent.futures import ThreadPoolExecutor
    from scripts.export import export_part
    from scripts.slice import build
    stl = tmp_path_factory.mktemp("stl")
    with ThreadPoolExecutor() as pool:
        list(pool.map(lambda n: export_part(n, stl), PRINT_PARTS))
    out = tmp_path_factory.mktemp("print")
    build(PRODUCT, stl, out)
    return out


def _summary(project):
    return json.loads((project / "summary.json").read_text())


@pytest.mark.slow
@needs_slicer
def test_every_plate_is_sliced(project):
    s = _summary(project)
    assert s["plates"] and all(p["sliced"] and not p["outside"] for p in s["plates"])
    sliced = zipfile.ZipFile(project / f"{PROJECT}.gcode.3mf").namelist()
    assert sum(bool(re.fullmatch(r"Metadata/plate_\d+\.gcode", n)) for n in sliced) == len(s["plates"])


@pytest.mark.slow
@needs_slicer
def test_each_plate_loads_its_own_filaments_hot_enough(project):
    # each plate's G-code loads the filaments its parts are on (M620 S<n>A, 0-based) and heats the nozzle to
    # theirs: a flattened printer without its own start G-code loaded nothing and stayed at 205 (kids-charger, 2026-11-04)
    z = zipfile.ZipFile(project / f"{PROJECT}.3mf")
    s = _summary(project)
    hot = {"PLA": range(190, 231), "PETG": range(230, 261)}           # a nozzle temperature right for each
    bad = []
    for p in s["plates"]:
        g = z.read(f"Metadata/plate_{p['plate']}.gcode").decode("utf-8", "replace")
        used = {int(i) - 1 for i in p["grams"]}
        loaded = {int(m) for m in re.findall(r"^M620 S(\d+)A", g, re.M)}
        heats = {int(t) for t in re.findall(r"^M10[49] S(\d+)", g, re.M)}
        if loaded != used or not all(heats & set(hot[s["filaments"][i][0]]) for i in used):
            bad.append(f"plate {p['plate']} {p['name']}: uses {sorted(used)}, loads {sorted(loaded)}, heats to {sorted(heats)}")
    assert not bad, "\n".join(bad)


@pytest.mark.slow
@needs_slicer
def test_each_plate_prints_on_its_materials_plate_at_its_temperature(project):
    # each plate's bed type is its filament's (BED_TYPES: PETG on Textured PEI at 70, 2026-11-06), and the bed
    # heats to that filament's temperature for it
    from scripts.print_parts import BED_TYPES
    key = {"Textured PEI Plate": "textured_plate_temp", "Supertack Plate": "supertack_plate_temp"}
    z = zipfile.ZipFile(project / f"{PROJECT}.3mf")
    s = _summary(project)
    bad = []
    for p in s["plates"]:
        g = z.read(f"Metadata/plate_{p['plate']}.gcode").decode("utf-8", "replace")
        used = sorted(int(i) - 1 for i in p["grams"])
        want = BED_TYPES[s["filaments"][used[0]][0]]
        bed = re.search(r"^; curr_bed_type = (.+)$", g, re.M).group(1)
        temps = re.search(rf"^; {key[want]}_initial_layer = (.+)$", g, re.M).group(1).split(",")
        heat = {int(t) for t in re.findall(r"^M190 S(\d+)", g, re.M)}
        if bed != want or heat != {max(int(temps[i]) for i in used)}:
            bad.append(f"plate {p['plate']} {p['name']}: {bed}, bed {sorted(heat)} (want {want} at {temps})")
    assert not bad, "\n".join(bad)


@pytest.mark.slow
@needs_slicer
def test_the_petg_cools_gently(project):
    # the dock warped with the part fan at 20-50% (2026-11-06): PETG's fan is FILAMENT_OVERRIDES's, at most 40%
    s = _summary(project)
    z = zipfile.ZipFile(project / f"{PROJECT}.3mf")
    for p in s["plates"]:
        if {s["filaments"][int(i) - 1][0] for i in p["grams"]} == {"PETG"}:
            g = z.read(f"Metadata/plate_{p['plate']}.gcode").decode("utf-8", "replace")
            layers = g[g.index("; Z_HEIGHT:"):g.rindex("; Z_HEIGHT:")]     # the print (not the start G-code's nozzle wipe)
            fans = [float(v) for v in re.findall(r"^M106 S([\d.]+)", layers, re.M)]
            assert fans and max(fans) <= 0.4 * 255 + 1, f"plate {p['plate']}: part fan up to {max(fans) / 2.55:.0f}%"


def _support_pieces(gcode, z, band=0.3, cell=0.25):
    """The support's separate pieces (mm2 each) in the layers within `band` of height z: its extrusion drawn on a
    `cell` grid, one cell grown (a piece's lines join), pieces under 1 mm2 (a stray dab) left out."""
    import numpy as np
    from scipy import ndimage
    feat, zz, x, y, segs = None, 0.0, 0.0, 0.0, []
    for line in gcode.splitlines():
        if line.startswith("; FEATURE:"):
            feat = line[10:].strip()
        elif line.startswith("; Z_HEIGHT:"):
            zz = float(line.split(":")[1])
        elif line.startswith(("G1", "G2", "G3")):
            mx, my, me = (re.search(rf"\b{a}(-?[\d.]+)", line) for a in "XYE")
            nx, ny = float(mx.group(1)) if mx else x, float(my.group(1)) if my else y
            if me and float(me.group(1)) > 0 and feat and feat.startswith("Support") and abs(zz - z) <= band:
                segs.append((x, y, nx, ny))
            x, y = nx, ny
    if not segs:
        return []
    grid = np.zeros((int(600 / cell), int(600 / cell)), bool)
    for x0, y0, x1, y1 in segs:
        k = max(2, int(np.hypot(x1 - x0, y1 - y0) / (cell / 2)))
        grid[(np.linspace(x0, x1, k) / cell).astype(int), (np.linspace(y0, y1, k) / cell).astype(int)] = True
    lab, n = ndimage.label(ndimage.binary_dilation(grid))
    sizes = ndimage.sum(grid | ndimage.binary_dilation(grid), lab, range(1, n + 1)) * cell ** 2
    return [s for s in sizes if s > 1]


@pytest.mark.slow
@needs_slicer
def test_the_support_stands_sturdy(project):
    # tall support stands as blocks, not thin trunks: kids-charger's 3 mm PETG tree trunks fell (2026-11-07)
    import statistics
    z = zipfile.ZipFile(project / f"{PROJECT}.3mf")
    bad = []
    for p in _summary(project)["plates"]:
        if p["support_g"]:
            g = z.read(f"Metadata/plate_{p['plate']}.gcode").decode("utf-8", "replace")
            for h in (20, 30, 40):
                pieces = _support_pieces(g, h)
                if pieces and statistics.median(pieces) < 100:
                    bad.append(f"plate {p['plate']} {p['name']} at {h} mm: {len(pieces)} pieces, median {statistics.median(pieces):.0f} mm2")
    assert not bad, "\n".join(bad)


@pytest.mark.slow
@needs_slicer
def test_the_slicer_has_no_warnings(project):
    # no floating region (the parts test/test_print.py leaves to the slicer, SLICER_JUDGED, are judged here), no
    # part off the plate, nothing it would refuse
    bad = [f"plate {p['plate']} {p['name']}: {w}" for p in _summary(project)["plates"] for w in p["warnings"]]
    assert not bad, "\n".join(bad)


@pytest.mark.slow
@needs_slicer
def test_only_the_parts_allowed_support_get_any(project):
    from test_print import SUPPORTED
    # (the G-code doesn't say which object a support is under: a plate with support must hold a part allowed it)
    bad = [f"plate {p['plate']} {p['name']}: {p['support_g']} g of support" for p in _summary(project)["plates"]
           if p["support_g"] and not any(base(o.rsplit("_", 1)[0]) in SUPPORTED for o in p["objects"])]
    assert not bad, "\n".join(bad)


def test_the_project_holds_every_part_printed_or_not():
    # the project is the build's output, every part in it whatever its status; what is still to print is the
    # queue's project (kids-charger's printing dock had dropped out of it, 2026-11-07)
    from scripts.slice import is_coupon, projects
    product = [n for n in hosts() if not is_coupon(n)]
    if len(product) < 2:
        pytest.skip("fewer than two parts yet")
    status = {n: {"status": "printed"} for n in hosts()} | {product[0]: {"status": "printing"},
                                                            product[-1]: {"status": "to-print"}}
    p = projects(status=status)
    assert p["product"] == product and p["queue"] == [product[-1]] and p["coupons"] == []


def test_the_coupons_are_drafted_leaner_than_the_product():
    # the coupons are thrown away once read: thicker layers, less infill and skin than the final print, the outer
    # wall untouched (what a fit across the bed is)
    from scripts.print_parts import COUPON_PROCESS, COUPON_SLICER, PROCESS
    layer = lambda preset: float(preset.split("mm")[0])
    assert layer(COUPON_PROCESS) > layer(PROCESS)
    assert float(COUPON_SLICER["sparse_infill_density"].rstrip("%")) <= 15
    assert not {k for k in COUPON_SLICER if k.startswith(("outer_wall", "wall_loops", "xy_"))}, "the outer wall is the fit"


@pytest.fixture(scope="session")
def coupon_project(tmp_path_factory):
    """Every coupon sliced into its own project (scripts/slice.py --coupons all)."""
    from concurrent.futures import ThreadPoolExecutor
    from scripts.export import export_part
    from scripts.slice import build, is_coupon
    names = [n for n in hosts() if is_coupon(n)]
    stl = tmp_path_factory.mktemp("stl")
    with ThreadPoolExecutor() as pool:
        list(pool.map(lambda n: export_part(n, stl), names))
    out = tmp_path_factory.mktemp("print")
    build(names, stl, out, "coupons")
    return out


@pytest.mark.slow
@needs_slicer
def test_the_coupons_project_slices_drafted(coupon_project):
    from scripts.print_parts import COUPON_PROCESS
    from scripts.slice import KINDS
    from test_print import COUPONS_AS_PRINTED
    s = json.loads((coupon_project / "summary-coupons.json").read_text())
    assert s["plates"] and all(p["sliced"] and not p["outside"] for p in s["plates"]), s["plates"]
    # no warning but on a coupon printed and passed as it is (check with scripts/compare.py that the warning is
    # its shape, not the draft settings)
    named = lambda w: re.search(r"object (\w+?)_\d+ ", w)
    bad = [w for p in s["plates"] for w in p["warnings"] if not (named(w) and named(w).group(1) in COUPONS_AS_PRINTED)]
    assert not bad, bad
    z = zipfile.ZipFile(coupon_project / f"{KINDS['coupons'][0]}.3mf")
    g = z.read("Metadata/plate_1.gcode").decode("utf-8", "replace")
    assert re.search(r"^; layer_height = (\S+)", g, re.M).group(1) == COUPON_PROCESS.split("mm")[0]
