"""Every printable part: name -> (scad file, call that lays it on the bed, -D defines), and how each prints.

The one file a project fills in: scripts/export.py, scripts/slice.py and the tests read everything from here.
"""
from pathlib import Path

PROJECT = "PROJECT"                      # the print project's name: stl/print/<PROJECT>.3mf

PRINT_PARTS = {
    # "widget": ("parts/widget/widget.scad", "widget_print();", {}),
    # "coupon_fit": ("parts/coupons/coupons.scad", "coupon_fit_print();", {}),
    # a variant of one part (a side, a size) is the same call with -D defines: {"side": "left"}
}

GROUPS = ("coupons",)                    # the stl/ folders, in print order; group() maps a part to one

# A companion (an inlay, the letters of a label) prints with its part as one object of two filaments; it exports as
# <part>.<colour>.stl beside it and follows its part's print status. companion name -> (its part, its colour key)
COMPANIONS = {}
QTY = {}                                 # how many of a part to print (default 1)
PIECES = {}                              # parts printed as several loose pieces, and how many (default 1)

# the filament of each part: (type, colour key). Default PLA in the body colour; list the exceptions.
PETG = set()                             # heat (> 50 °C), creep under load, outdoors: else PLA
COLOUR = {}                              # part -> colour key, when not "white"

# what to set up in the slicer beyond the profile, shown in stl/QUEUE.md (scripts/slice.py applies SLICER)
NOTES = {}

# ---------- the slicer (scripts/slice.py, scripts/bambu.py) ----------
PRINTER = "Bambu Lab H2S 0.4 nozzle"
PROCESS = "0.20mm Standard @BBL H2S"
# the plate each filament type prints on (ask the user which plates they have); scripts/slice.py sets it per plate,
# so a plate holds filaments of one plate type. PETG on Textured PEI (70 °C): kids-charger's dock warped on a
# smooth SuperTack at 60 (2026-11-06). The plate sets the bed temperature (the filament's <plate>_temp).
BED_TYPES = {"PLA": "Supertack Plate", "PETG": "Textured PEI Plate"}
BED_TYPE = BED_TYPES["PLA"]               # the project's own
# filament settings over the user's presets, by type (Bambu Studio's keys). PETG cools gently: a big PETG box
# warps with the part fan at 20-50% (kids-charger's dock, 2026-11-06)
FILAMENT_OVERRIDES = {"PETG": {"fan_min_speed": "10", "fan_max_speed": "20", "overhang_fan_speed": "40"}}
# filament type -> the user's calibrated preset (Bambu Studio, user presets; a system preset name works too)
FILAMENT_PRESETS = {"PLA": "Bambu PLA Matte Flow Rate Calibrated", "PETG": "Bambu PETG Matte Flow Rate Calibrated"}
# colour key -> the model's colour (params/common.scad; test/test_slice.py checks they agree)
COLOURS = {"white": "#e9e9e6", "black": "#1c1c1e"}
# The coupons print from a project of their own (stl/print/<project>-coupons.3mf), drafted: they are thrown away
# once read, so they spend as little material and time as they can without changing what they test. Their outer
# wall (what sets a fit across the bed) is the final print's; layers, infill and skins are lean. A coupon that tests
# what layers change (a snap's catch height, a fit along Z, strength) gives its final settings back in SLICER,
# which wins over these.
COUPON_PROCESS = "0.24mm Standard @BBL H2S"
COUPON_SLICER = {"sparse_infill_pattern": "lightning", "sparse_infill_density": "10%",
                 "top_shell_layers": "3", "bottom_shell_layers": "2"}
# per-object settings beyond the process (Bambu Studio's keys), by part name. The usual ones:
#   supports: {"enable_support": "1", "support_type": "tree(auto)", "support_on_build_plate_only": "1"}
#   a brim:   {"brim_type": "outer_only"}  (a thin rim round a wide box: "outer_and_inner", "brim_width": "10", "brim_object_gap": "0")
SLICER = {}

# a part's print status (scripts/print_status.toml): to-print, reprint (why), printing, printed (date), hold (why),
# unknown (why); optional: next (its place in the queue)
STATUSES = ("to-print", "reprint", "printing", "printed", "hold", "unknown")
STATUS_FILE = Path(__file__).with_name("print_status.toml")


def base(name):
    """A part's name without its variant prefix, for the tables above (override for variants)."""
    return name


def group(name):
    """The stl/ folder a part exports to: its folder under parts/ (parts/<group>/<file>.scad)."""
    host = COMPANIONS[name][0] if name in COMPANIONS else name
    return PRINT_PARTS[host][0].split("/")[1]


def material(name):
    """(filament type, colour key)."""
    if name in COMPANIONS:
        host, colour = COMPANIONS[name]
        return material(host)[0], colour
    return ("PETG" if base(name) in PETG else "PLA"), COLOUR.get(base(name), "white")


def note(name):
    return NOTES.get(base(name), "")


def stl_name(name):
    """The STL's file name, without .stl: a companion is <its part>.<colour>."""
    return f"{COMPANIONS[name][0]}.{COMPANIONS[name][1]}" if name in COMPANIONS else name


def hosts():
    """The parts that carry a print status: every printable part but the companions (they follow their part)."""
    return [n for n in PRINT_PARTS if n not in COMPANIONS]


def companion(host):
    return next((c for c, (h, _) in COMPANIONS.items() if h == host), None)


def print_status():
    import tomllib
    return tomllib.loads(STATUS_FILE.read_text())
