"""Drive OpenSCAD headless from tests."""
import subprocess
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run_scad(body, workdir, *, includes=(), uses=(), fmt="stl", root=ROOT, out=None, defines=None):
    """Render `body` with params.scad in scope; return the combined log.

    `defines` ({name: value}) are passed as `-D name=value`: they override params in
    the main file and what it `include`s. A `use`d file keeps its own params, so a
    probe that overrides them (side, kid) passes the part in `includes`.

    `includes` / `uses` are paths relative to `root`. Fails the calling test
    if OpenSCAD reports any ERROR or WARNING (assert failures land in the
    .echo file, so that file is read back too).
    """
    root = Path(root)
    src = Path(workdir) / f"probe_{uuid.uuid4().hex}.scad"
    out = Path(out) if out else src.with_suffix("." + fmt)
    head = [f"include <{root / 'params.scad'}>"]
    head += [f"include <{root / p}>" for p in includes]
    head += [f"use <{root / p}>" for p in uses]
    src.write_text("\n".join(head) + "\n" + body + "\n")
    # a crash must fail the test, not pass it with an empty log; macOS 27's dyld now and then kills OpenSCAD at
    # launch (EXC_BREAKPOINT, SIGKILL, before it reads the model), so a death by signal is tried once more
    for attempt in (1, 2):
        proc = subprocess.run(
            ["openscad", "--backend=manifold", *(f"-D{k}={v}" for k, v in (defines or {}).items()), "-o", str(out), str(src)],
            capture_output=True, text=True,
        )
        if proc.returncode >= 0:
            break
    log = proc.stdout + proc.stderr
    code = f"signal {-proc.returncode}" if proc.returncode < 0 else f"exit {proc.returncode}"
    empty = proc.returncode == 1 and "Current top level object is empty" in log   # an answer, not a failure
    assert proc.returncode == 0 or empty, f"OpenSCAD failed ({code}, {attempt} tries) on {src}\n{log[-2000:]}"
    if fmt == "echo" and out.exists():
        log += out.read_text()
    bad = [l for l in log.splitlines() if l.startswith(("ERROR", "WARNING"))]
    assert not bad, "\n".join(bad)
    return log


MIN_OVERLAP_MM3 = 1e-3


def is_empty(body, workdir, **kw):
    """True when the rendered geometry is empty (e.g. an intersection).

    Parts that only touch face-to-face can come back from Manifold as a
    zero-thickness sliver rather than nothing, so anything below
    MIN_OVERLAP_MM3 counts as empty.
    """
    out = Path(workdir) / f"empty_{uuid.uuid4().hex}.stl"
    log = run_scad(body, workdir, out=out, **kw)
    if "Current top level object is empty" in log:
        return True
    import warnings

    import trimesh  # only needed when something rendered

    with warnings.catch_warnings():  # slivers make trimesh divide by ~0
        warnings.simplefilter("ignore", RuntimeWarning)
        return abs(trimesh.load_mesh(out).volume) < MIN_OVERLAP_MM3


def overlap_volume(body, workdir, **kw):
    """Volume (mm³) of the rendered geometry; 0 when empty."""
    out = Path(workdir) / f"vol_{uuid.uuid4().hex}.stl"
    log = run_scad(body, workdir, out=out, **kw)
    if "Current top level object is empty" in log:
        return 0.0
    import warnings

    import trimesh

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return abs(trimesh.load_mesh(out).volume)
