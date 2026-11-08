"""The assembly guide: `uv run python scripts/guide/build.py [left|right ...]` draws every step of
scripts/guide/steps.py from scripts/guide/guide.scad and writes renders/guide/<side>/index.html, an IKEA-style sheet
per station: each step's pieces with their counts and pictures, then its pictures (screws and inserts from 2 angles or
more), then a few plain words. Opens in a browser, offline; prints one step per page."""
import html
import json
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.guide.steps import ACCENT, FINISHED, INTRO, STATIONS, STEPS, TITLE, WORDS  # noqa: E402

SCAD = ROOT / "scripts/guide/guide.scad"
RENDER = ["uv", "run", "-q", "--with", "pyrender", "--with", "trimesh", "--with", "numpy", "--with", "pillow",
          "python", str(ROOT / "scripts/render.py")]


def focus(side):
    """{name: [x, y, z]} and hand, from guide.scad's FOCUS."""
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "f.echo"
        subprocess.run(["openscad", "-o", str(out), "--export-format", "echo", "-D", "echo_focus=true",
                        "-D", f'side="{side}"', str(SCAD)], check=True, capture_output=True)
        log = out.read_text()
    m = re.search(r"ECHO: FOCUS = (.*), HAND = (-?\d+)", log)
    return dict(json.loads(m.group(1))), int(m.group(2))


def scenes():
    """Each step's (scene, new): the dock's pieces so far unless the step names its own scene."""
    built, out = ["dock"], []
    for s in STEPS:
        scene = s.get("scene")
        out.append(((scene or built) + [n for n in s["new"] if n not in (scene or built)], s["new"]))
        if scene is None:
            built = built + [n for n in s["new"] if n not in built]
    return out, built


def camera(v, pts, hand):
    """render.py's arguments for a view."""
    rz = v.get("rz", -30)
    if rz in ("tower", "post"):
        rz = -90 * hand if rz == "tower" else 90 * hand
    args = []
    if "at" in v:
        x, y, z = pts[v["at"]]
        if v.get("flip"):
            y, z = -y, -z
        args += ["--target", f"{x},{y},{z}", "--dist", str(round(v["r"] * 4.2))]
    args += ["--rx", str(v.get("rx", 60)), "--rz", str(rz)]
    if v.get("ortho"):
        args.append("--ortho")
    return args


def defines(side, scene, new, v=None, pts=None, pull=1):
    d = {"side": f'"{side}"', "kid": f'"{STATIONS[side]}"', "show": json.dumps(scene), "new": json.dumps(new),
         "pull": str(pull), "flip": "true" if v and v.get("flip") else "false"}
    if v and "at" in v and "section" not in v:
        c, r, top = pts[v["at"]], v["r"], v.get("top")
        lo, hi = [x - r for x in c], [x + r for x in c]
        if top is not None:                     # cut toward the eye: above the point, or below it when flipped
            if v.get("flip"):
                lo[2] = c[2] - top
            else:
                hi[2] = c[2] + top
        d |= {"crop": "true", "crop_lo": json.dumps(lo), "crop_hi": json.dumps(hi)}
    if v and "section" in v:
        d |= {"view": '"section"', "section_x": str(pts[v["section"]][0] + v["t"] / 2), "section_t": str(v["t"])}
    return [a for k, val in d.items() for a in ("-D", f"{k}={val}")]


def jobs(side):
    """[(out png, render.py args)] for every picture of the side's guide."""
    pts, hand = focus(side)
    out = ROOT / "renders/guide" / side
    todo = []
    sc, built = scenes()
    for i, (s, (scene, new)) in enumerate(zip(STEPS, sc), 1):
        for j, v in enumerate(s["views"], 1):
            fresh = [n for n in new if n not in v.get("placed", ())]
            todo.append((out / f"step{i:02d}-{j}.png", camera(v, pts, hand) + defines(side, scene, fresh, v, pts)
                         + ["--size", "1200x900"]))
    thumbs = {p[2] for s in STEPS for p in s["pieces"] if p[2]}
    for t in sorted(thumbs):
        todo.append((out / f"piece-{t}.png", ["--rx", "55", "--rz", "-30", "--size", "400x320"] + defines(side, [t], [], pull=0)))
    todo.append((out / "finished.png", camera(FINISHED["view"], pts, hand) + defines(side, built + [FINISHED["scene"]], [], pull=0)
                 + ["--size", "1600x1200"]))
    return todo


def render(job):
    png, args = job
    r = subprocess.run(RENDER + [str(SCAD), str(png)] + args, capture_output=True, text=True, cwd=ROOT)
    if r.returncode or not png.exists():
        raise RuntimeError(f"{png.name}: {r.stderr[-800:]}")
    return png


def page(side):
    w = {**WORDS[side], "kid": STATIONS[side]}
    fill = lambda t: html.escape(t.format(**w))
    hw_total = {}
    for s in STEPS:
        for label, n, thumb, name in s["pieces"]:
            if thumb and thumb.startswith("one_"):
                hw_total[(label, thumb)] = hw_total.get((label, thumb), 0) + n
    steps = []
    for i, s in enumerate(STEPS, 1):
        pieces = "".join(
            f'<div class="pc">{f'<img src="piece-{t}.png" alt="">' if t else '<div class="noimg"></div>'}'
            f'<span class="n">{n}×</span><span class="l">{html.escape(label)}</span></div>' for label, n, t, _ in s["pieces"])
        figs = "".join(f'<img src="step{i:02d}-{j}.png" alt="Step {i}, view {j}" loading="lazy">' for j in range(1, len(s["views"]) + 1))
        words = "".join(f"<li>{fill(t)}</li>" for t in s["text"])
        steps.append(f'''<section class="step" id="s{i}">
  <div class="head"><span class="num">{i}</span><h2>{fill(s["title"])}</h2></div>
  <div class="pieces">{pieces}</div>
  <div class="views v{min(len(s["views"]), 3)}">{figs}</div>
  <ol class="words">{words}</ol>
</section>''')
    bag = "".join(f'<div class="pc"><img src="piece-{t}.png" alt=""><span class="n">{n}×</span><span class="l">{html.escape(l)}</span></div>'
                  for (l, t), n in sorted(hw_total.items()))
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{fill(TITLE)}</title>
<style>
:root {{ --paper: #ffffff; --ink: #1c1c1f; --muted: #66646d; --rule: #e2e0e6; --accent: {ACCENT[side]}; --chip: #f4f3f6; color-scheme: light; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --paper: #18181b; --ink: #ececf0; --muted: #a3a1ab; --rule: #34333a; --chip: #232328; color-scheme: dark; }} }}
:root[data-theme="dark"] {{ --paper: #18181b; --ink: #ececf0; --muted: #a3a1ab; --rule: #34333a; --chip: #232328; color-scheme: dark; }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; background: var(--paper); color: var(--ink); font: 17px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }}
.wrap {{ max-width: 1100px; margin: 0 auto; padding: 32px 16px 64px; display: grid; gap: 48px; }}
h1 {{ font-size: clamp(30px, 5vw, 44px); margin: 0; line-height: 1.1; }}
.lede {{ color: var(--muted); margin: 8px 0 0; max-width: 65ch; }}
.pieces, .bag {{ display: flex; flex-wrap: wrap; gap: 12px; }}
.pc {{ display: grid; grid-template-columns: auto 1fr; grid-template-rows: auto auto; column-gap: 8px; align-items: end; background: var(--chip); border-radius: 10px; padding: 8px 12px 8px 8px; max-width: 260px; }}
.pc img, .pc .noimg {{ grid-row: span 2; width: 96px; height: 77px; object-fit: contain; border-radius: 6px; background: #596b80; }}
.pc .noimg {{ background: transparent; width: 0; }}
.pc .n {{ font-size: 26px; font-weight: 800; line-height: 1; }}
.pc .l {{ font-size: 14px; color: var(--muted); line-height: 1.25; }}
.step {{ display: grid; gap: 16px; border-top: 3px solid var(--ink); padding-top: 16px; break-inside: avoid; }}
.head {{ display: flex; align-items: center; gap: 16px; }}
.num {{ font-size: 56px; font-weight: 800; line-height: 1; color: var(--accent); min-width: 1.2em; }}
h2 {{ margin: 0; font-size: 24px; }}
.views {{ display: grid; gap: 8px; grid-template-columns: 1fr; }}
@media (min-width: 720px) {{ .views.v2 {{ grid-template-columns: 1fr 1fr; }} .views.v3 {{ grid-template-columns: 1fr 1fr 1fr; }} }}
.views img {{ width: 100%; height: auto; display: block; border-radius: 8px; }}
.words {{ margin: 0; padding-left: 22px; display: grid; gap: 6px; max-width: 75ch; }}
.done img {{ width: 100%; border-radius: 10px; }}
nav {{ display: flex; flex-wrap: wrap; gap: 6px; }}
nav a {{ color: var(--ink); text-decoration: none; border: 1px solid var(--rule); border-radius: 999px; padding: 2px 10px; font-size: 14px; }}
@media print {{ .step {{ break-before: page; }} nav {{ display: none; }} }}
</style></head>
<body><div class="wrap">
<header>
  <h1>{fill(TITLE)}</h1>
  <p class="lede">{len(STEPS)} steps. {fill(INTRO)} Each step shows its pieces first, then where they go: a piece drawn away from the rest moves along the line into its place.</p>
</header>
<section><h2>Hardware for the whole station</h2><div class="bag">{bag}</div></section>
<nav>{"".join(f'<a href="#s{i}">{i}</a>' for i in range(1, len(STEPS) + 1))}</nav>
{"".join(steps)}
<section class="step done"><div class="head"><span class="num">✓</span><h2>Done</h2></div><img src="finished.png" alt="Finished"></section>
</div></body></html>
'''


def build(side):
    out = ROOT / "renders/guide" / side
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.png"):
        old.unlink()
    with ThreadPoolExecutor(8) as pool:
        list(pool.map(render, jobs(side)))
    (out / "index.html").write_text(page(side))
    return out / "index.html"


if __name__ == "__main__":
    for side in sys.argv[1:] or list(STATIONS):
        print("wrote", build(side).relative_to(ROOT))
