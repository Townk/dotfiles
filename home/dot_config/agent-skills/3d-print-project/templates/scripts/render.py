"""Render an OpenSCAD model with even lighting: a key light from behind the camera, soft fill
from above, on a muted blue background (the black details show).

uv run --with pyrender --with trimesh --with numpy --with pillow python scripts/render/render.py \
    model.scad out.png [--rx 70 --rz -30 | --camera tx,ty,tz,rx,ry,rz,dist] [--target x,y,z --dist d]
    [-D name=value ...] [--size 1400x1100] [--ortho]

OpenSCAD exports the model as coloured 3MF; this lights and draws it. Camera angles follow
OpenSCAD's gimbal: rx = 0 looks straight down, rx = 90 looks level from the front (-Y); rz turns
the view about Z. Without a target and distance the view frames the whole model.
"""
import argparse
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

import numpy as np
import pyrender
import trimesh
from PIL import Image


def load_3mf(path):
    """[(rgba, trimesh)] per colour, from OpenSCAD's coloured 3MF export."""
    with zipfile.ZipFile(path) as z:
        xml = z.read(next(n for n in z.namelist() if n.endswith(".model"))).decode()
    colours = [tuple(int(c[i:i + 2], 16) / 255 for i in (0, 2, 4, 6)) for c in re.findall(r'displaycolor="#([0-9A-Fa-f]{8})"', xml)]
    v = np.array(re.findall(r'<vertex x="([-\d.e]+)" y="([-\d.e]+)" z="([-\d.e]+)"', xml), float)
    tri = re.findall(r'<triangle v1="(\d+)" v2="(\d+)" v3="(\d+)"(?: pid="\d+" p1="(\d+)")?', xml)
    f = np.array([t[:3] for t in tri], int)
    p = np.array([int(t[3]) if t[3] else len(colours) - 1 for t in tri])
    return [(colours[k], trimesh.Trimesh(v, f[p == k], process=False)) for k in np.unique(p)]


def look_at(eye, target, up=(0, 0, 1)):
    f = np.asarray(target, float) - eye
    f /= np.linalg.norm(f)
    s = np.cross(f, up)
    if np.linalg.norm(s) < 1e-6:
        s = np.cross(f, (0, 1, 0))
    s /= np.linalg.norm(s)
    u = np.cross(s, f)
    m = np.eye(4)
    m[:3, 0], m[:3, 1], m[:3, 2], m[:3, 3] = s, u, -f, eye
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scad"), ap.add_argument("out")
    ap.add_argument("--rx", type=float, default=70), ap.add_argument("--rz", type=float, default=-30)
    ap.add_argument("--target"), ap.add_argument("--dist", type=float)
    ap.add_argument("-D", action="append", default=[])
    ap.add_argument("--size", default="1400x1100")
    ap.add_argument("--ortho", action="store_true")
    ap.add_argument("--camera", help="OpenSCAD gimbal camera: tx,ty,tz,rx,ry,rz,dist (dist 0: frame the model)")
    a = ap.parse_args()
    if a.camera:
        tx, ty, tz, a.rx, _, a.rz, dist = map(float, a.camera.split(","))
        if dist > 0:
            a.target, a.dist = f"{tx},{ty},{tz}", dist
    w, h = map(int, a.size.split("x"))
    with tempfile.TemporaryDirectory() as d:
        model = Path(d) / "m.3mf"
        cmd = ["openscad", "--backend=manifold", "-o", str(model)] + sum([["-D", x] for x in a.D], []) + [a.scad]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(r.stdout + r.stderr)
        parts = load_3mf(model)
    lo = np.min([m.bounds[0] for _, m in parts], axis=0)
    hi = np.max([m.bounds[1] for _, m in parts], axis=0)
    target = np.array(list(map(float, a.target.split(",")))) if a.target else (lo + hi) / 2
    rx, rz = np.radians(a.rx), np.radians(a.rz)
    view = np.array([np.sin(rz) * np.sin(rx), -np.cos(rz) * np.sin(rx), np.cos(rx)])   # from the target toward the eye
    fov = np.radians(30)
    dist = a.dist or np.linalg.norm(hi - lo) / 2 / np.sin(fov / 2) * 1.02
    eye = target + view * dist
    scene = pyrender.Scene(ambient_light=[0.3, 0.3, 0.3], bg_color=[0.35, 0.42, 0.50, 1.0])
    for rgba, m in parts:
        lin = [c ** 2.2 for c in rgba[:3]] + [rgba[3]]                                     # sRGB → linear
        mat = pyrender.MetallicRoughnessMaterial(baseColorFactor=lin, metallicFactor=0.0, roughnessFactor=0.75)
        scene.add(pyrender.Mesh.from_trimesh(m, material=mat, smooth=False))
    pose = look_at(eye, target)
    half = dist * np.tan(fov / 2)                                                     # the same framing as the perspective view
    cam = (pyrender.OrthographicCamera(xmag=half * w / h, ymag=half, znear=0.1, zfar=dist + 2 * np.linalg.norm(hi - lo))   # pyrender's default far plane is 100 mm
           if a.ortho else pyrender.PerspectiveCamera(yfov=fov, aspectRatio=w / h))
    scene.add(cam, pose=pose)
    scene.add(pyrender.DirectionalLight(intensity=2.0), pose=pose)                                   # key: behind the camera
    scene.add(pyrender.DirectionalLight(intensity=0.7), pose=look_at(target + np.array([0.3, -0.2, 1]) * dist, target))   # soft fill from above
    colour, _ = pyrender.OffscreenRenderer(w, h).render(scene)
    Image.fromarray(colour).save(a.out)
    print(a.out)


if __name__ == "__main__":
    main()
