"""The print projects: `uv run python scripts/slice.py` lays out every part in the print queue (stl/queue/, from
scripts/export.py) on as many plates as it takes, with its filament and settings, and slices them with Bambu
Studio's CLI into stl/print/. The product's parts and the coupons make two projects, the coupons drafted
(COUPON_PROCESS, COUPON_SLICER in scripts/print_parts.py):

  <PROJECT>.3mf             the project: every plate, filament, per-object setting (open it, Slice all, print)
  <PROJECT>.gcode.3mf       the same, sliced only (opens ready to send; nothing left to set)
  PRINT.md                  per plate: its parts, time, grams per filament, support, the slicer's warnings
  plates/plate_N.png        the slicer's preview of each plate
  <PROJECT>-coupons.*, PRINT-coupons.md, plates-coupons/   the same for the coupons in the queue
                            (`--coupons all`: every coupon, queued or not)

A plate holds one filament (no colour changes), but for the objects of several filaments (a part with its
companion), which share their own plates. Quit Bambu Studio first. `--support NAME...` instead slices each part
alone with automatic support on and says how much support it would get (test/test_slice.py)."""
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts import bambu  # noqa: E402
from scripts.export import queue  # noqa: E402
from scripts.print_parts import (BED_TYPE, BED_TYPES, COLOURS, COUPON_PROCESS, COUPON_SLICER, FILAMENT_OVERRIDES,
                                 FILAMENT_PRESETS, PRINTER,  # noqa: E402
                                 PROCESS, PROJECT, QTY, SLICER, base, companion, group, hosts, material, stl_name)
# the two projects: the product's parts, and the coupons (drafted). name, process, settings under each part's own
KINDS = {"product": (PROJECT, PROCESS, {}), "coupons": (f"{PROJECT}-coupons", COUPON_PROCESS, COUPON_SLICER)}


def is_coupon(name):
    return group(name) == "coupons"
BED = (340, 320)      # the plate's usable area (scripts/export.py: BED)
SPACING = 8           # between parts, and round each a brim's room


def _key(part):
    """A filament's key: (type, colour)."""
    return material(part)


def objects(names, stl_root, defaults=None):
    """The objects to print: [{name, parts: [(stl, filament key)], count, settings, footprint}]. `defaults`: settings
    under each part's own (SLICER)."""
    import trimesh
    out = []
    for n in names:
        parts = [n] + ([companion(n)] if companion(n) else [])
        stls = [Path(stl_root) / group(p) / f"{stl_name(p)}.stl" for p in parts]
        ext = trimesh.load_mesh(stls[0]).extents
        out.append({"name": n, "parts": [(s, _key(p)) for s, p in zip(stls, parts)], "count": QTY.get(n, 1),
                    "settings": {**(defaults or {}), **SLICER.get(base(n), {})}, "footprint": (float(ext[0]), float(ext[1]))})
    return out


def pack(items):
    """Shelf-pack footprints (either way round) onto as few plates as it takes: [[item]]. Conservative (boxes):
    the slicer then arranges each plate itself."""
    W, H = BED[0] - SPACING, BED[1] - SPACING
    plates = []
    for it in sorted(items, key=lambda i: -i["footprint"][0] * i["footprint"][1]):
        w, d = (v + SPACING for v in it["footprint"])
        if min(w, d) > min(W, H) or max(w, d) > max(W, H):
            raise ValueError(f"{it['name']} ({w:.0f} x {d:.0f} with spacing) doesn't fit the plate")
        for pl in plates:
            if _place(pl, w, d):
                pl["items"].append(it)
                break
        else:
            pl = {"shelves": [], "items": [it]}
            assert _place(pl, w, d)
            plates.append(pl)
    return [p["items"] for p in plates]


def _place(pl, w, d):
    W, H = BED[0] - SPACING, BED[1] - SPACING
    for ww, dd in ((w, d), (d, w)):
        for sh in pl["shelves"]:
            if dd <= sh["h"] and sh["x"] + ww <= W:
                sh["x"] += ww
                return True
        if sum(s["h"] for s in pl["shelves"]) + dd <= H and ww <= W:
            pl["shelves"].append({"h": dd, "x": ww})
            return True
    return False


def plan(objs):
    """Plates: the objects grouped by their filaments, packed. [{name, objects: {name: count}}] and the
    filament keys in use (their order is the project's filament numbering)."""
    groups = {}
    for o in objs:
        keys = tuple(sorted({k for _, k in o["parts"]}))
        if len(keys) > 1:                                  # every object of several filaments shares plates
            keys = ("multi",)
        groups.setdefault(keys, []).extend([o] * o["count"])
    plates = []
    for keys, items in sorted(groups.items(), key=lambda kv: (kv[0] == ("multi",), kv[0][0][0] != "PETG", str(kv[0]))):
        for i, contents in enumerate(pack(items), 1):
            counts = {}
            for o in contents:
                counts[o["name"]] = counts.get(o["name"], 0) + 1
            label = "multicolour" if keys == ("multi",) else " + ".join(f"{t} {c}" for t, c in keys)
            types = {t for o in contents for _, (t, _c) in o["parts"]}
            if len({BED_TYPES[t] for t in types}) > 1:
                raise ValueError(f"plate {label} {i}: filaments for different plates {sorted(types)}")
            plates.append({"name": f"{label} {i}", "objects": counts, "bed": BED_TYPES[types.pop()]})
    filaments = sorted({k for o in objs for _, k in o["parts"]}, key=lambda k: (k[0] != "PLA", k[1] != "white", k))
    return plates, filaments


def _filaments(keys):
    """write_profiles' filaments: each key's preset, colour and FILAMENT_OVERRIDES."""
    return [(FILAMENT_PRESETS[t], COLOURS[c], FILAMENT_OVERRIDES.get(t, {})) for t, c in keys]


def assemble_list(plates, objs, filaments):
    """Bambu Studio's --load-assemble-list: each plate's objects, their filaments (1-based), copies and settings;
    a part with a companion is one object of two parts (assemble_index)."""
    by = {o["name"]: o for o in objs}
    index = 0
    out = {"plates": []}
    for pl in plates:
        entries = []
        for name, count in pl["objects"].items():
            o = by[name]
            settings = {k: str(v) for k, v in o["settings"].items()}
            if len(o["parts"]) == 1:
                stl, key = o["parts"][0]
                e = {"path": str(stl.resolve()), "count": count, "filaments": [filaments.index(key) + 1]}
                if settings:
                    e["print_params"] = settings
                entries.append(e)
                continue
            for _ in range(count):                              # an assembled object: one per copy
                index += 1
                for stl, key in o["parts"]:
                    entries.append({"path": str(stl.resolve()), "count": 1, "filaments": [filaments.index(key) + 1],
                                    "assemble_index": [index]})
        out["plates"].append({"plate_name": pl["name"], "need_arrange": True, "objects": entries,
                              "plate_params": {"curr_bed_type": pl["bed"]}})
    return out


def build(names, stl_root, out_dir, kind="product"):
    """Slice `names` into out_dir as the `kind` project (KINDS): the project, its sliced-only copy, its PRINT.md
    and summary, the plate previews."""
    name, proc_preset, defaults = KINDS[kind]
    sfx = "" if kind == "product" else f"-{kind}"
    out_dir = Path(out_dir)
    work = out_dir / f"work{sfx}"
    shutil.rmtree(work, ignore_errors=True)
    objs = objects(names, stl_root, defaults)
    plates, filaments = plan(objs)
    machine, process, fils = bambu.write_profiles(
        work / "profiles", PRINTER, proc_preset, _filaments(filaments), BED_TYPE)
    asm = work / "assemble_list.json"
    asm.write_text(json.dumps(assemble_list(plates, objs, filaments), indent=1))
    result = bambu.slice_project(work, f"{name}.3mf", machine, process, fils, asm)
    if result.get("return_code") != 0:
        code = result.get("return_code")
        raise RuntimeError(f"slicing failed: {code} {bambu.ERRORS.get(code, '')} {result.get('error_string')} "
                           f"(see {work / 'cli.log'})")
    sliced = bambu.sliced_only(work / f"{name}.3mf", work / "min", f"{name}.gcode.3mf")
    if sliced.get("return_code") != 0:
        raise RuntimeError(f"the sliced-only copy failed: {sliced.get('error_string')} (see {work / 'min/cli.log'})")
    project = out_dir / f"{name}.3mf"
    shutil.copy2(work / project.name, project)
    shutil.copy2(work / "min" / f"{name}.gcode.3mf", out_dir / f"{name}.gcode.3mf")
    summary = bambu.summarize(project, result)
    shutil.rmtree(out_dir / f"plates{sfx}", ignore_errors=True)
    bambu.thumbnails(project, out_dir / f"plates{sfx}")
    (out_dir / f"summary{sfx}.json").write_text(json.dumps({"filaments": filaments, "plates": summary}, indent=1))
    (out_dir / f"PRINT{sfx}.md").write_text(report(summary, filaments, plates, kind))
    return summary


def report(summary, filaments, plates, kind="product"):
    name, proc_preset, defaults = KINDS[kind]
    names = [f"{i}: {t} Matte {c}" for i, (t, c) in enumerate(filaments, 1)]
    lines = [f"# Print project: `{name}.3mf`", "",
             "Generated by `scripts/slice.py` from the print queue (`stl/QUEUE.md`): don't edit.",
             f"Open `stl/print/{name}.3mf` in Bambu Studio (everything is set: Slice all, then print each plate),",
             f"or `stl/print/{name}.gcode.3mf`, already sliced, to send as it is. Load the AMS with:", "",
             *[f"- {n} ({COLOURS[filaments[i][1]]})" for i, n in enumerate(names)], "",
             f"{PRINTER}, {proc_preset}; plates: " + ", ".join(f"{t} on {b}" for t, b in BED_TYPES.items()) + "." + (
                 f" Drafted (the coupons are read, then thrown away): {', '.join(f'{k} {v}' for k, v in defaults.items())}."
                 if defaults else ""), "",
             "| Plate | On | Parts | Time | Filament (g) | Support (g) | Slicer warnings |", "|---|---|---|---|---|---|---|"]
    tot_min, tot_g = 0, {}
    for s, pl in zip(summary, plates):
        parts = ", ".join(f"`{n}`" + (f" × {c}" if c > 1 else "") for n, c in pl["objects"].items())
        g = ", ".join(f"{i}: {v:.0f}" for i, v in s["grams"].items())
        sup = ", ".join(f"{i}: {v:.0f}" for i, v in s["support_g"].items()) or "none"
        lines.append(f"| {s['plate']} {s['name']} | {pl['bed']} | {parts} | {s['minutes'] // 60}h{s['minutes'] % 60:02d} | {g} | {sup} | "
                     f"{'; '.join(s['warnings']) or 'none'} |")
        tot_min += s["minutes"]
        for i, v in s["grams"].items():
            tot_g[i] = tot_g.get(i, 0) + v
    lines += ["", f"Total: {len(summary)} plates, {tot_min // 60}h{tot_min % 60:02d}, "
              + ", ".join(f"{names[int(i) - 1]} {v:.0f} g" for i, v in sorted(tot_g.items())), ""]
    return "\n".join(lines)


def slice_alone(name, stl_root, work, settings=None):
    """`name` sliced alone on a plate, with its own settings (SLICER) and `settings` over them: its plate's summary
    (minutes, grams, support grams, warnings). For comparing variants of a part."""
    objs = objects([name], stl_root)
    objs[0]["settings"] = {**objs[0]["settings"], **(settings or {})}
    objs[0]["count"] = 1
    plates, filaments = plan(objs)
    work = Path(work)
    machine, process, fils = bambu.write_profiles(
        work / "profiles", PRINTER, PROCESS, _filaments(filaments), BED_TYPE)
    asm = work / "assemble_list.json"
    asm.write_text(json.dumps(assemble_list(plates, objs, filaments), indent=1))
    result = bambu.slice_project(work, "part.3mf", machine, process, fils, asm)
    if result.get("return_code") != 0:
        raise RuntimeError(f"{name}: slicing failed: {result.get('error_string')} (see {work / 'cli.log'})")
    return bambu.summarize(work / "part.3mf", result)[0]


def support_needed(name, stl_root, work):
    """Grams of support the slicer would add to `name` alone with automatic (normal) support on: 0 = none."""
    p = slice_alone(name, stl_root, work, {"enable_support": "1", "support_type": "normal(auto)",
                                           "support_on_build_plate_only": "0"})
    return sum(p["support_g"].values())


if __name__ == "__main__":
    stl = ROOT / "stl"
    if sys.argv[1:2] == ["--support"]:
        for n in sys.argv[2:]:
            print(n, support_needed(n, stl, stl / "print" / "support" / n), "g of support")
        sys.exit()
    every_coupon = sys.argv[1:3] == ["--coupons", "all"]
    names = queue()
    jobs = {"product": [n for n in names if not is_coupon(n)],
            "coupons": [n for n in hosts() if is_coupon(n)] if every_coupon else [n for n in names if is_coupon(n)]}
    if sys.argv[1:2] == ["--coupons"]:
        jobs["product"] = []
    if not any(jobs.values()):
        sys.exit("nothing to print: the queue is empty (scripts/print_status.toml); `--coupons all` slices every coupon")
    (stl / "print").mkdir(parents=True, exist_ok=True)
    for kind, todo in jobs.items():
        if not todo:
            continue
        for p in build(todo, stl, stl / "print", kind):
            print(f"{kind} plate {p['plate']} {p['name']}: {len(p['objects'])} objects, {p['minutes']} min, {p['grams']} g, "
                  f"support {p['support_g'] or 'none'}, warnings {p['warnings'] or 'none'}")
        print("wrote", (stl / "print" / ("PRINT.md" if kind == "product" else f"PRINT-{kind}.md")).relative_to(ROOT))
