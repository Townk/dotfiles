"""Weigh variants of one part with the slicer: each variant (its -D defines and slicer settings over the part's own)
is exported and sliced alone, and the table says its hours, grams, support and warnings. Quit Bambu Studio first.

  uv run python scripts/compare.py <part> '[["label", {"param": value}, {"slicer_key": "value"}], ...]'

Work goes in stl/compare/<part>/<label>/ (the variant's STL and its sliced plate, for scripts/support_map.py)."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts import print_parts  # noqa: E402
from scripts.export import export_part  # noqa: E402
from scripts.slice import slice_alone  # noqa: E402


def compare(part, variants, out=ROOT / "stl" / "compare"):
    """[(label, defines, settings)] -> [{variant, minutes, grams, support_g, warnings}], one slice at a time."""
    file, call, defines = print_parts.PRINT_PARTS[part]
    rows = []
    try:
        for label, d, settings in variants:
            print_parts.PRINT_PARTS[part] = (file, call, {**defines, **d})
            work = Path(out) / part / label
            export_part(part, work / "stl")
            r = slice_alone(part, work / "stl", work / "slice", settings)
            rows.append({"variant": label, **{k: r[k] for k in ("minutes", "grams", "support_g", "warnings")}})
            print(json.dumps(rows[-1]), flush=True)
    finally:
        print_parts.PRINT_PARTS[part] = (file, call, defines)
    return rows


if __name__ == "__main__":
    rows = compare(sys.argv[1], json.loads(sys.argv[2]))
    print("\n| Variant | Time | Grams | Support (g) | Warnings |\n|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['variant']} | {r['minutes'] // 60}h{r['minutes'] % 60:02d} | {sum(r['grams'].values()):.0f} | "
              f"{sum(r['support_g'].values()):.0f} | {'; '.join(r['warnings']) or 'none'} |")
