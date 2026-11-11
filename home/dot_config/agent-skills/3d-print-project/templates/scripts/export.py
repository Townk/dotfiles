"""Export printable parts to STL. `uv run python scripts/export.py [part ...]` writes stl/<group>/<part>.stl
(a companion as <its part>.<colour>.stl), each moved onto the bed's centre
(z = 0; a move only), then the print queue: stl/queue/<group>/ (what to print or reprint, with its
companions) and stl/QUEUE.md (that list, with what is on hold and what is unknown), from
scripts/print_status.toml. `scripts/slice.py` turns the queue into the print project. stl/projects/ (your
own slicer projects) is left alone."""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.print_parts import (COMPANIONS, GROUPS, PRINT_PARTS, QTY, companion, group, hosts, material,  # noqa: E402
                                 note, print_status, stl_name)

BED = (340, 320, 340)


def render_part(name, out_dir, move=(0, 0, 0)):
    """OpenSCAD's STL of `name`, in its print orientation, moved by `move` in OpenSCAD: its path. (Moved in
    OpenSCAD, in doubles: moving the STL's float32 vertices afterwards rounds near-coincident ones apart and
    opened the shell, 2026-11-04.)"""
    file, call, defines = PRINT_PARTS[name]
    call = f"translate([{move[0]!r}, {move[1]!r}, {move[2]!r}]) {call}"
    out_dir = Path(out_dir) / group(name)
    out_dir.mkdir(parents=True, exist_ok=True)
    wrapper = out_dir / f"{stl_name(name)}.scad"
    # include, not use: -D defines must reach every piece of the part (a use'd file keeps its own params)
    wrapper.write_text(f"include <{ROOT / 'params.scad'}>\ninclude <{ROOT / file}>\n{call}\n")
    stl = out_dir / f"{stl_name(name)}.stl"
    d = [f"-D{k}={v!r}".replace("'", '"') for k, v in defines.items()]
    proc = subprocess.run(["openscad", "--backend=manifold", *d, "-o", str(stl), str(wrapper)],
                          capture_output=True, text=True)
    log = proc.stdout + proc.stderr
    bad = [l for l in log.splitlines() if l.startswith(("ERROR", "WARNING"))]
    if proc.returncode != 0 or bad:
        raise RuntimeError(f"{name}: {log}")
    wrapper.unlink()
    return stl


def bed_offset(mesh):
    """The move that puts a mesh on the bed: its footprint centred, its bottom at z = 0."""
    lo, hi = mesh.bounds
    return [-(lo[0] + hi[0]) / 2, -(lo[1] + hi[1]) / 2, -lo[2]]


SLIVER_MM3 = 0.01   # the most a dropped sliver may hold (drop_slivers)
SLIVER_MM2 = 0.5    # ... and its area
VOID_MM3 = 5        # the most a filled sealed void may hold


def drop_slivers(mesh):
    """The mesh without Manifold's zero-volume slivers: loose pieces under SLIVER_MM3 and SLIVER_MM2. The shell's hollow pinches where the tower joins the body
    and leaves a few where a hollowed part's skin pinches (kids-charger, 2026-11-04: each < 0.05 mm2). Anything bigger is a real piece: it stays, and test/test_print.py fails on it."""
    pieces = mesh.split(only_watertight=False)
    if len(pieces) == 1:
        return mesh
    # and sealed hairline voids (an inside-out piece under VOID_MM3): filled, as the slicer would. kids-charger's
    # tower left one (0.2 wide, 1.7 mm3) where infill closed a gap that was open to the hollow (2026-11-07)
    keep = [p for p in pieces if (abs(p.volume) >= SLIVER_MM3 or p.area >= SLIVER_MM2) and not -VOID_MM3 < p.volume < 0]
    import trimesh
    return trimesh.util.concatenate(keep) if len(keep) != len(pieces) else mesh


def export_part(name, out_dir):
    """stl/<group>/<stl name>.stl, on the bed. A companion moves with its part (it is placed on it)."""
    import trimesh
    host = COMPANIONS[name][0] if name in COMPANIONS else name
    probe = Path(out_dir) / f"_probe_{name}"
    move = [round(float(v), 3) for v in bed_offset(trimesh.load_mesh(render_part(host, probe)))]
    shutil.rmtree(probe, ignore_errors=True)
    stl = render_part(name, out_dir, move)
    mesh = trimesh.load_mesh(stl)
    clean = drop_slivers(mesh.copy())
    if len(clean.faces) != len(mesh.faces):
        # ASCII, as OpenSCAD writes it: binary STL is float32, and rounding the shell's near-coincident
        # vertices together opened it (13 loose pieces on reload, 2026-11-04)
        clean.export(stl, file_type="stl_ascii")
    return stl


def prune_stale(out_dir):
    """Delete STLs that aren't where export_part would write them now: parts no longer printed, parts
    in another group's folder. Other folders (your own) are left alone."""
    out_dir = Path(out_dir)
    where = {f"{group(n)}/{stl_name(n)}.stl" for n in PRINT_PARTS}
    stale = sorted(p for g in GROUPS for p in (out_dir / g).glob("*.stl") if f"{g}/{p.name}" not in where)
    for p in stale:
        p.unlink()
    return stale


def queue(status=None):
    """The parts to print or reprint, in the order given by `next`, then by group and print order."""
    status = status or print_status()
    order = list(PRINT_PARTS)
    nxt = [n for n in hosts() if status[n]["status"] in ("reprint", "to-print")]
    return sorted(nxt, key=lambda n: (status[n].get("next") is None, status[n].get("next", 0),
                                      GROUPS.index(group(n)), order.index(n)))


def build_queue(out_dir, status=None):
    """stl/queue/<group>/: the STLs of every part to print or reprint, each with its companion; and
    stl/QUEUE.md: what is printing now, what is next, what is on hold and what is unknown."""
    out_dir = Path(out_dir)
    status = status or print_status()
    q = out_dir / "queue"
    shutil.rmtree(q, ignore_errors=True)
    lines = ["# Print queue", "", "Generated by `scripts/export.py` from `scripts/print_status.toml`: don't edit.",
             "The STLs are in `stl/queue/`; `scripts/slice.py` lays them out as one print project with every plate",
             "and setting (`stl/print/`). A `<part>.<colour>.stl` prints with its part, as one object.",
             "Print settings and notes: `docs/build/printing.md`.", ""]

    def row(n):
        kind, colour = material(n)
        c = companion(n)
        colour = f"{kind} {colour}" + (f", with its {material(c)[1]} companion" if c else "")
        s = status[n]
        why = {"reprint": f"reprint: {s.get('why', '')}", "to-print": "new"}.get(s["status"], s.get("why", ""))
        return f"| `{stl_name(n)}` | {group(n)} | {colour} | {QTY.get(n, 1)} | {why} | {note(n)} |"

    head = ["| Part | Group | Filament | Count | Why | Print notes |", "|---|---|---|---|---|---|"]
    by = lambda *keys: [n for n in hosts() if status[n]["status"] in keys]
    nxt = queue(status)
    for title, names in (("Printing now", sorted(by("printing"))), ("Next", nxt),
                         ("On hold", sorted(by("hold"))), ("Unknown: tell me if you have printed these", sorted(by("unknown")))):
        if names:
            lines += [f"## {title} ({len(names)})", "", *head, *map(row, names), ""]
    for n in nxt:
        for part in [n] + ([companion(n)] if companion(n) else []):
            src = out_dir / group(part) / f"{stl_name(part)}.stl"
            dst = q / group(part) / src.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
    (out_dir / "QUEUE.md").write_text("\n".join(lines))


if __name__ == "__main__":
    from concurrent.futures import ThreadPoolExecutor
    out = ROOT / "stl"
    out.mkdir(exist_ok=True)
    for p in prune_stale(out):
        print("removed", p.relative_to(ROOT))
    only = sys.argv[1:]                                        # names to export (default: all)
    names = sorted(n for n in PRINT_PARTS if not only or n in only)
    with ThreadPoolExecutor() as pool:                         # OpenSCAD is single-threaded: one per core
        for stl in pool.map(lambda n: export_part(n, out), names):
            print(stl.relative_to(ROOT))
    build_queue(out)
    print("wrote", (out / "QUEUE.md").relative_to(ROOT))
