"""Where the slicer put a part's support, in the part's own (STL) coordinates, summed on a grid: what to redesign.

  uv run python scripts/support_map.py stl/compare/<part>/<label>/slice/part.3mf stl/compare/<part>/<label>/stl/<group>/<part>.stl [grid mm]

Prints the grid cells holding the most support extrusion: their X, Y range, share and the heights it spans."""
import collections
import re
import sys
import zipfile

import numpy as np
import trimesh


def support_map(project, stl, grid=20):
    z = zipfile.ZipFile(project)
    mesh = trimesh.load_mesh(stl)
    model = z.read("3D/3dmodel.model").decode()

    def transform(s):
        t = np.array([float(x) for x in s.split()]).reshape(4, 3)
        return t[:3], t[3]
    Ri, ti = transform(re.findall(r'<item [^>]*transform="([^"]+)"', model)[0])
    comp = re.findall(r'<component [^>]*transform="([^"]+)"', model)
    Rc, tc = transform(comp[0]) if comp else (np.eye(3), np.zeros(3))
    obj = next(n for n in z.namelist() if n.startswith("3D/Objects/"))
    v = np.array(re.findall(r'<vertex x="([-\d.e]+)" y="([-\d.e]+)" z="([-\d.e]+)"', z.read(obj).decode()), float)
    back = lambda p: ((p - ti) @ np.linalg.inv(Ri) - tc) @ np.linalg.inv(Rc)
    off = mesh.bounds[0] - back((v @ Rc + tc) @ Ri + ti).min(0)      # the plate's placement back to the STL's
    feat, zc, x, y, pts = None, 0.0, 0.0, 0.0, []
    for line in z.read("Metadata/plate_1.gcode").decode("utf-8", "replace").splitlines():
        if line.startswith("; FEATURE:"):
            feat = line[10:].strip()
        elif line.startswith("; Z_HEIGHT:"):
            zc = float(line.split(":")[1])
        elif line.startswith(("G1", "G2", "G3")):
            m = re.search(r"X([-\d.]+)", line); x = float(m.group(1)) if m else x
            m = re.search(r"Y([-\d.]+)", line); y = float(m.group(1)) if m else y
            m = re.search(r"E([\d.]+)", line)
            if feat and feat.startswith("Support") and m:
                pts.append((x, y, zc, float(m.group(1))))
    if not pts:
        return []
    P = np.array(pts)
    L = back(P[:, :3]) + off
    cells = collections.defaultdict(lambda: [0.0, 1e9, -1e9])
    for (lx, ly, lz), e in zip(L, P[:, 3]):
        c = cells[(int(np.floor(lx / grid)), int(np.floor(ly / grid)))]
        c[0] += e; c[1] = min(c[1], lz); c[2] = max(c[2], lz)
    total = sum(c[0] for c in cells.values())
    return sorted(((k[0] * grid, k[1] * grid, c[0] / total, c[1], c[2]) for k, c in cells.items()), key=lambda r: -r[2])


if __name__ == "__main__":
    grid = float(sys.argv[3]) if len(sys.argv) > 3 else 20
    for x, y, share, z0, z1 in support_map(sys.argv[1], sys.argv[2], grid)[:15]:
        print(f"x {x:6.0f}..{x + grid:<5.0f} y {y:6.0f}..{y + grid:<5.0f} {100 * share:4.1f}%  z {z0:5.1f}..{z1:5.1f}")
