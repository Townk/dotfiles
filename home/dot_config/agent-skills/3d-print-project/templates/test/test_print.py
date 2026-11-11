"""Every printable part prints as it is exported: closed, on the bed, in one piece, without support (but where
it is allowed below). The slicer's own view of the same parts is test/test_slice.py."""
import re
from pathlib import Path

import numpy as np
import pytest
import trimesh

from scripts.export import BED, export_part
from scripts.print_parts import COMPANIONS, PRINT_PARTS, STATUSES, base, hosts, print_status

HOSTS = sorted(n for n in PRINT_PARTS if n not in COMPANIONS)   # a companion (the badge's letters) sits on its part
# parts printed on support on purpose (by base name), and why. The slicer checks the support they get
# (test/test_slice.py) and that nothing else gets any.
# parts printed on support on purpose (by base name) -> why. The slicer checks they get it and nothing else does
# (test/test_slice.py).
SUPPORTED = {}
# parts the box checks below can't clear but the slicer prints without a warning (test/test_slice.py) -> why
SLICER_JUDGED = {}
# coupons printed and passed as they are, kept for the record
COUPONS_AS_PRINTED = set()


@pytest.fixture(scope="session")
def stl_dir(tmp_path_factory):
    """Every part exported once for the whole session (they take seconds; every check reads them)."""
    from concurrent.futures import ThreadPoolExecutor
    out = tmp_path_factory.mktemp("stl")
    with ThreadPoolExecutor() as pool:
        list(pool.map(lambda n: export_part(n, out), PRINT_PARTS))
    return out


def _mesh(stl_dir, name):
    from scripts.print_parts import group, stl_name
    return trimesh.load_mesh(Path(stl_dir) / group(name) / f"{stl_name(name)}.stl")


@pytest.mark.parametrize("name", sorted(PRINT_PARTS))
def test_part_is_printable(name, stl_dir):
    mesh = _mesh(stl_dir, name)
    assert mesh.is_watertight, f"{name} is not a closed solid"
    assert mesh.is_volume, f"{name} is not a valid volume"
    lo, hi = mesh.bounds
    if name not in COMPANIONS:   # a companion is placed on its part, not on the bed
        assert abs(lo[2]) < 0.01, f"{name} does not sit on the bed (min z = {lo[2]:.3f})"
    ext = hi - lo
    flat_fits = (ext[0] <= BED[0] and ext[1] <= BED[1]) or (ext[0] <= BED[1] and ext[1] <= BED[0])
    assert flat_fits and ext[2] <= BED[2], f"{name} is {ext.round(1)} mm, larger than the bed"


@pytest.mark.parametrize("name", HOSTS)
def test_part_prints_as_one_piece(name, stl_dir):
    mesh = _mesh(stl_dir, name)
    mesh.merge_vertices()
    from scripts.print_parts import PIECES
    assert len(mesh.split(only_watertight=False)) == PIECES.get(name, 1), f"{name} has loose pieces"


def _face_groups(mesh, idx):
    """The faces `idx`, grouped into connected regions (sharing a vertex): [[face index]]."""
    parent = {int(i): int(i) for i in idx}

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    seen = {}
    for i in idx:
        for v in mesh.faces[i]:
            v = int(v)
            if v in seen:
                parent[root(int(i))] = root(seen[v])
            else:
                seen[v] = int(i)
    groups = {}
    for i in idx:
        groups.setdefault(root(int(i)), []).append(int(i))
    return list(groups.values())


def _ceilings(mesh):
    mesh.merge_vertices()
    idx = np.where((mesh.face_normals[:, 2] < -0.99) & (mesh.triangles_center[:, 2] > 0.05))[0]
    return [mesh.triangles[g].reshape(-1, 3) for g in _face_groups(mesh, idx)]


UNSUPPORTED = [n for n in HOSTS if base(n) not in SUPPORTED]
BOX_CHECKED = [n for n in UNSUPPORTED if base(n) not in SLICER_JUDGED and n not in COUPONS_AS_PRINTED]


@pytest.mark.parametrize("name", BOX_CHECKED)
def test_part_prints_without_support(name, stl_dir):
    # every flat ceiling is a short bridge (<= 20 mm across, <= 50 mm long) or a hairline facet
    bad = []
    for t in _ceilings(_mesh(stl_dir, name)):
        d = sorted((t.max(0) - t.min(0))[:2])
        if d[0] > 1 and (d[0] > 20 or d[1] > 50):
            bad.append([round(v, 1) for v in d])
    assert not bad, f"{name}: flat overhangs needing support {bad}"


def _inside(mesh, pts):
    """Point-in-solid by the generalised winding number (no spatial index needed)."""
    tri = mesh.triangles[None, :, :, :] - np.asarray(pts, float)[:, None, None, :]
    a, b, c = tri[..., 0, :], tri[..., 1, :], tri[..., 2, :]
    la, lb, lc = (np.linalg.norm(v, axis=-1) for v in (a, b, c))
    num = np.einsum("pti,pti->pt", a, np.cross(b, c))
    den = la * lb * lc + np.einsum("pti,pti->pt", a, b) * lc + np.einsum("pti,pti->pt", b, c) * la + np.einsum("pti,pti->pt", c, a) * lb
    return np.abs(np.arctan2(num, den).sum(axis=1) / (2 * np.pi)) > 0.5


@pytest.mark.parametrize("name", BOX_CHECKED)
def test_ceilings_are_anchored_at_two_opposite_edges(name, stl_dir):
    # a flat ceiling wider than 2 mm is a bridge: material below it just past
    # both ends of one of its spans; one-sided, it is an overhang that needs support
    mesh = _mesh(stl_dir, name)
    bad = []
    for t in _ceilings(mesh):
        lo, hi = t.min(0), t.max(0)
        if min(hi[:2] - lo[:2]) <= 2:   # a hole's top facet, a 2 mm span: bridged without thinking
            continue
        z, (xm, ym) = lo[2] - 0.4, (lo[:2] + hi[:2]) / 2
        probes = [[lo[0] - 0.4, ym, z], [hi[0] + 0.4, ym, z], [xm, lo[1] - 0.4, z], [xm, hi[1] + 0.4, z]]
        i = _inside(mesh, probes)
        if not ((i[0] and i[1]) or (i[2] and i[3])):
            bad.append([lo.round(1).tolist(), hi.round(1).tolist()])
    assert not bad, f"{name}: ceilings anchored on one side only (overhangs) {bad}"


@pytest.mark.slow
@pytest.mark.parametrize("name", UNSUPPORTED)
def test_no_island_starts_in_mid_air(name, stl_dir):
    # sliced every 0.2 mm, each region must rest on what lies within 1 mm below it (a slicer's "floating
    # region"); 1 mm (five layers), so a few badly reconstructed sections can't fake an island
    import warnings
    from shapely.ops import unary_union
    warnings.filterwarnings("ignore", category=DeprecationWarning)
    mesh = _mesh(stl_dir, name)
    layers, bad = [], []
    for z in np.arange(0.1, mesh.bounds[1][2], 0.2):
        sec = mesh.section(plane_origin=[0, 0, z], plane_normal=[0, 0, 1])
        polys = [] if sec is None else sec.to_planar(to_2D=np.eye(4), check=False)[0].polygons_full
        if len(layers) >= 5:
            below = unary_union([p for layer in layers[-5:] for p in layer]).buffer(0.45)
            bad += [(round(float(z), 1), round(p.area, 1)) for p in polys if p.area > 0.5 and p.intersection(below).area < 0.05 * p.area]
        layers.append(list(polys))
    assert not bad, f"{name}: regions starting in mid-air (height, mm2) {bad}"


@pytest.mark.parametrize("name", [n for n in HOSTS if base(n) not in COUPONS_AS_PRINTED])
def test_a_part_with_little_hold_on_the_bed_gets_a_brim(name, stl_dir):
    # a part that touches the bed with a thin rim round a wide footprint (its shrinkage peels the rim) or stands
    # tall on a small foot (the nozzle rocks it) prints with a brim (SLICER brim_type): kids-charger's dock, a
    # 3 mm rim under 144 mm of PETG, lifted an hour in and fell over without one
    from scripts.print_parts import SLICER
    mesh = _mesh(stl_dir, name)
    lo, hi = mesh.bounds
    on_bed = (mesh.face_normals[:, 2] < -0.99) & (mesh.triangles_center[:, 2] < lo[2] + 0.01)
    contact = mesh.area_faces[on_bed].sum()
    ext = hi - lo
    rim = contact / (ext[0] * ext[1]) < 0.1
    post = ext[2] / np.sqrt(contact) > 6
    own = SLICER.get(base(name), {})
    if rim or post:
        assert own.get("brim_type", "auto_brim") not in ("auto_brim", "no_brim"), (
            f"{name}: {contact:.0f} mm2 on the bed under {ext.round(0)} mm, and no brim")
    if rim:
        # ... fused to it: with the slicer's 0.1 gap the brim stayed on the plate and the dock's rim warped up off
        # it, late in the print (2026-11-06, references/photos/2026-11-06-shell-final-print-bad/)
        assert own.get("brim_object_gap") == "0", f"{name}: its brim isn't fused to its rim (brim_object_gap 0)"


@pytest.mark.parametrize("name", [n for n in HOSTS if base(n) not in COUPONS_AS_PRINTED])
def test_a_big_part_stands_on_a_foot(name, stl_dir):
    # a part over 150 mm a side stands on more than a rim: on average 4 mm of bed contact along its outline (a
    # PETG box on a 1.6 mm strip warped up off its brim, kids-charger 2026-11-06)
    mesh = _mesh(stl_dir, name)
    lo, hi = mesh.bounds
    ext = hi - lo
    if min(ext[:2]) < 150:
        return
    on_bed = (mesh.face_normals[:, 2] < -0.99) & (mesh.triangles_center[:, 2] < lo[2] + 0.01)
    width = mesh.area_faces[on_bed].sum() / (2 * (ext[0] + ext[1]))
    assert width >= 4, f"{name} stands on {width:.1f} mm of its outline on average"


def test_print_orientations_never_reflect_a_part():
    # a print module may only move and rotate its part: a mirror() would print its mirror image. The part's
    # own design may mirror (a left part from a right one).
    root = Path(__file__).resolve().parents[1]
    bad = []
    files = sorted((root / "parts").rglob("*.scad"))
    if not PRINT_PARTS:
        pytest.skip("no parts yet")
    assert files, "no part files scanned: the parts moved?"
    for f in files:
        for m in re.finditer(r"^module (\w+_print\w*)\(.*?(?=^(?:module|function|//) |\Z)", f.read_text(), re.S | re.M):
            if "mirror" in m.group(0):
                bad.append(f"{f.name}: {m.group(1)}")
    assert not bad, f"print modules that mirror their part: {bad}"


def test_every_part_has_a_print_status():
    status = print_status()
    assert set(hosts()) == set(status)
    assert all(s["status"] in STATUSES for s in status.values())
    # what a status needs (the rack's rule): a reason for reprint, hold and unknown; a date for printed
    for n, s in status.items():
        need = {"reprint": "why", "hold": "why", "unknown": "why", "printed": "date"}.get(s["status"])
        assert need is None or s.get(need), f"{n}: {s['status']} without its {need}"

# Variants (a left and a right part): add a twin test, each part matching its mirror twin in volume and size, with
# a NOT_MIRRORED table of what differs on purpose (kids-charger test/test_print.py).
