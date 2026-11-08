"""Bambu Studio's command-line slicer, headless: flattened presets, an assemble list (plates, objects, filaments,
per-object settings) sliced into one project .3mf, and what the slicer said about each plate.

Generic (no project names here); scripts/slice.py drives it. Facts it relies on (Bambu Studio 02.08.02.61, found
2026-11-04; see docs/build/printing.md):
- the CLI reads preset JSON as is: it ignores `inherits`, so every preset is flattened here first;
- every filament must be mapped to the printer's one nozzle (filament_map, filament_nozzle_map,
  nozzle_volume_type, as the GUI saves them), or the CLI segfaults exporting a plate that doesn't use filament 1;
- the bed type goes in the process JSON (the default Cool Plate refuses PETG, code -61);
- --outputdir must be absolute and the cwd, --export-3mf a bare file name; it writes result.json there;
- it never needs the GUI, but a crash shows the same macOS dialog: refuse to run while the GUI is open.
"""
import json
import math
import re
import subprocess
import zipfile
from functools import lru_cache
from pathlib import Path
from xml.etree import ElementTree as ET

APP = Path("/Applications/BambuStudio.app")
CLI = APP / "Contents/MacOS/BambuStudio"
SYSTEM = APP / "Contents/Resources/profiles/BBL"
USER = Path.home() / "Library/Application Support/BambuStudio/user"
SUPPORT_FEATURES = ("Support", "Support interface", "Support transition", "Support ironing")
ERRORS = {-13: "output path", -21: "arrange failed (a plate's parts don't fit)", -51: "validation", -52: "partly outside the plate",
          -61: "filament not allowed on this bed", -62: "filaments of mixed temperatures", -100: "slicing",
          -101: "path conflict", -102: "path outside the plate", -103: "first layer", -104: "unprintable"}


# ---------- presets ----------
@lru_cache(maxsize=None)
def _system(kind):
    """name -> path of every system preset of a kind (machine, process, filament)."""
    out = {}
    for p in sorted((SYSTEM / kind).rglob("*.json")):
        try:
            out.setdefault(json.loads(p.read_text())["name"], p)
        except (ValueError, KeyError):
            continue
    return out


def find_preset(kind, name):
    """A preset by name: the user's own (any account folder) first, then the system's."""
    for d in sorted(USER.glob("*")) if USER.exists() else []:
        p = d / kind / f"{name}.json"
        if p.exists():
            return p
    if name in _system(kind):
        return _system(kind)[name]
    raise FileNotFoundError(f"no {kind} preset named {name!r}")


def _merge(parent, child, pv, cv):
    """One option, child over parent: per-variant vectors merged by variant name, "nil" keeps the parent's."""
    if not isinstance(child, list) or not isinstance(parent, list):
        return child
    if pv and cv and len(cv) > 1 and len(child) == len(cv) and len(parent) == len(pv):
        out = list(parent)
        for variant, v in zip(cv, child):
            if variant in pv and v != "nil":
                out[pv.index(variant)] = v
        return out
    if "nil" in child:
        return [p if c == "nil" else c for c, p in zip(child, parent + [parent[-1]] * len(child))]
    return child


def flatten(kind, name, variants=None):
    """A preset with its whole `inherits` chain resolved. `variants`: the printer's extruder variants (a
    system filament leaf stores per-variant vectors but inherits a one-entry variant list)."""
    data = json.loads(find_preset(kind, name).read_text())
    parent = flatten(kind, data["inherits"], variants) if data.get("inherits") else {}
    # `include`: presets merged in after the parent, before this one's own keys. The H2S's G-code (start, end,
    # filament change, layer change) lives there: without it the CLI writes a generic printer's start G-code
    # that never loads a filament nor heats it (found 2026-11-04)
    for inc in data.get("include", []):
        parent.update({k: v for k, v in json.loads(find_preset(kind, inc).read_text()).items()
                       if k not in ("name", "instantiation", "inherits", "include")})
    if not parent:
        return dict(data)
    pv = parent.get("filament_extruder_variant") or parent.get("print_extruder_variant")
    cv = data.get("filament_extruder_variant") or data.get("print_extruder_variant")
    out = dict(parent)
    for k, v in data.items():
        if k in ("filament_extruder_variant", "print_extruder_variant") and pv:
            continue
        out[k] = _merge(parent.get(k), v, pv, cv) if k in parent else v
    out["name"] = data["name"]
    if parent.get("filament_id"):
        out.setdefault("filament_id", parent["filament_id"])
    if (kind == "filament" and variants and len(out.get("filament_extruder_variant", [])) != len(variants)
            and any(isinstance(v, list) and len(v) == len(variants) for v in data.values())):
        out["filament_extruder_variant"] = list(variants)
        out["filament_self_index"] = ["1"] * len(variants)
    return out


def write_profiles(out, printer, process, filaments, bed="Textured PEI Plate"):
    """Flattened machine.json, process.json and filament_<n>.json in `out`. `filaments`: [(preset, colour)] or
    [(preset, colour, {key: value} over the preset)]. `bed`: the project's bed type (a plate can set its own:
    the assemble list's plate_params curr_bed_type)."""
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    machine = flatten("machine", printer)
    proc = flatten("process", process)
    n = len(filaments)
    proc.update({"curr_bed_type": bed,
                 "filament_map_mode": "Manual", "filament_map": ["1"] * n,          # one nozzle: see above
                 "filament_nozzle_map": ["0"] * n, "nozzle_volume_type": ["Standard"]})
    for d in (machine, proc):
        d.pop("include", None)
    (out / "machine.json").write_text(json.dumps(machine, indent=1))
    (out / "process.json").write_text(json.dumps(proc, indent=1))
    fils = []
    for i, (preset, colour, *over) in enumerate(filaments, 1):
        f = flatten("filament", preset, machine.get("printer_extruder_variant"))
        for k, v in (over[0] if over else {}).items():         # a vector option keeps its length (per variant)
            f[k] = [str(v)] * len(f[k]) if isinstance(f.get(k), list) else str(v)
        if not f.get("filament_id") or not f.get("filament_density"):
            raise ValueError(f"filament {preset!r}: no filament_id or density after flattening")
        f.pop("include", None)
        f["filament_settings_id"] = [f["name"]]
        f["filament_colour"] = f["default_filament_colour"] = [colour]
        p = out / f"filament_{i}.json"
        p.write_text(json.dumps(f, indent=1))
        fils.append(p)
    return out / "machine.json", out / "process.json", fils


# ---------- slicing ----------
def gui_running():
    """The Bambu Studio app's own process, if it is open (the CLI is the same binary, with arguments)."""
    ps = subprocess.run(["ps", "-axo", "command"], capture_output=True, text=True).stdout.splitlines()
    return any(l.strip() == str(CLI) for l in ps)


def _run(workdir, args, timeout):
    if gui_running():
        raise RuntimeError("Bambu Studio is open: quit it first (a CLI crash would show its crash dialog)")
    workdir = Path(workdir).resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    (workdir / "result.json").unlink(missing_ok=True)
    cmd = [str(CLI), "--debug", "2", "--slice", "0", "--outputdir", str(workdir), *args]
    with open(workdir / "cli.log", "w") as log:
        rc = subprocess.call(cmd, cwd=workdir, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    res = workdir / "result.json"
    if not res.exists():
        return {"return_code": rc, "error_string": f"no result.json (exit {rc}, a crash?): see {workdir / 'cli.log'}"}
    return json.loads(res.read_text())


def slice_project(workdir, name, machine, process, filaments, assemble, timeout=1800):
    """Slice every plate of an assemble list into workdir/name (a project .3mf: models, settings, plates, G-code).
    Returns result.json as a dict (return_code 0 = success); the CLI's log is workdir/cli.log."""
    return _run(workdir, ["--export-3mf", name, "--load-settings", f"{machine};{process}",
                          "--load-filaments", ";".join(map(str, filaments)), "--load-assemble-list", str(assemble)], timeout)


def sliced_only(project, workdir, name, timeout=1800):
    """The project re-sliced as G-code only (--min-save, a flag: no value), so it opens ready to send. The
    CLI won't take --min-save with an assemble list, so it reads the finished project (an absolute path)."""
    return _run(workdir, ["--min-save", "--export-3mf", name, str(Path(project).resolve())], timeout)


# ---------- what the slicer said ----------
def _support_grams(gcode, density, diameter=1.75):
    """Grams of support per filament (1-based): the extrusion inside '; FEATURE: Support*' blocks (M83, relative E)."""
    area = math.pi * (diameter / 2) ** 2
    feature, tool, mm = None, 0, {}
    for line in gcode.splitlines():
        if line.startswith("; FEATURE:"):
            feature = line[10:].strip()
        elif re.fullmatch(r"T\d{1,2}", line.strip()):
            tool = int(line.strip()[1:])
        elif feature in SUPPORT_FEATURES and line.startswith(("G1", "G2", "G3")):
            m = re.search(r"\bE(-?[\d.]+)", line)
            if m and float(m.group(1)) > 0:
                mm[tool] = mm.get(tool, 0.0) + float(m.group(1))
    return {t + 1: round(v * area / 1000 * (density[t] if t < len(density) else 1.25), 1) for t, v in mm.items()}


def summarize(project, result=None):
    """Per plate of a sliced project: name, objects, minutes, grams per filament, support grams, warnings."""
    z = zipfile.ZipFile(project)
    names = set(z.namelist())
    cfg = json.loads(z.read("Metadata/project_settings.config"))
    density = [float(x) for x in cfg.get("filament_density", [])]
    plate_names = {}
    if "Metadata/model_settings.config" in names:
        for pl in ET.fromstring(z.read("Metadata/model_settings.config")).iter("plate"):
            md = {m.get("key"): m.get("value") for m in pl.findall("metadata")}
            plate_names[md.get("plater_id")] = md.get("plater_name", "")
    warn = {p["id"]: p.get("warning_message", "") for p in (result or {}).get("sliced_plates", [])}
    plates = []
    for pl in ET.fromstring(z.read("Metadata/slice_info.config")).iter("plate"):
        md = {m.get("key"): m.get("value") for m in pl.findall("metadata")}
        i = int(md["index"])
        g = f"Metadata/plate_{i}.gcode"
        plates.append({
            "plate": i, "name": plate_names.get(str(i), ""),
            "objects": [o.get("name") for o in pl.findall("object")],
            "minutes": round(int(md.get("prediction", 0)) / 60),
            "grams": {int(f.get("id")): float(f.get("used_g")) for f in pl.findall("filament")},
            "support_g": _support_grams(z.read(g).decode("utf-8", "replace"), density) if g in names else {},
            "outside": md.get("outside") == "true",
            "warnings": [w.get("msg") for w in pl.findall("warning")] + ([warn[i]] if warn.get(i) else []),
            "sliced": g in names,
        })
    return plates


def thumbnails(project, out_dir):
    """The plates' preview images (Metadata/plate_N.png) saved as out_dir/plate_N.png."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    z = zipfile.ZipFile(project)
    saved = []
    for n in z.namelist():
        if re.fullmatch(r"Metadata/plate_\d+\.png", n):
            (out_dir / Path(n).name).write_bytes(z.read(n))
            saved.append(out_dir / Path(n).name)
    return sorted(saved)
