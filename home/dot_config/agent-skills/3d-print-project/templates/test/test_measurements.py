"""docs/measurements.md: every row's value is the one in params/ (the page can't drift from the model)."""
import json
import re
from pathlib import Path

from scad import run_scad

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "measurements.md"
ROW = re.compile(r"^\| `(\w+)` \| ([^|]+) \|", re.M)


def _close(a, b):
    if isinstance(a, list):
        return isinstance(b, list) and len(a) == len(b) and all(_close(x, y) for x, y in zip(a, b))
    return abs(a - b) < 0.005


def test_every_measurement_matches_params(tmp_path):
    rows = ROW.findall(DOC.read_text())
    # every estimate in params/ (a `MEASURE` comment) has its row: the tables can't lose one silently
    estimates = {m for f in (ROOT / "params").glob("*.scad")
                 for m in re.findall(r"^\s*(\w+)\s*=.*//\s*MEASURE", f.read_text(), re.M)}
    assert estimates <= {name for name, _ in rows}, f"no row for {sorted(estimates - {n for n, _ in rows})}"
    assert rows, "the tables have no rows"
    log = run_scad("".join(f"echo(R = {name});" for name, _ in rows), tmp_path, fmt="echo")
    values = [json.loads(v) for v in re.findall(r"ECHO: R = (.*)", log)]
    wrong = [f"{name}: doc {doc.strip()}, params {val}" for (name, doc), val in zip(rows, values) if not _close(json.loads(doc), val)]
    assert not wrong, "measurements.md out of date:\n" + "\n".join(wrong)
