---
name: 3d-print-project
description: Runs a 3D-printed design project in OpenSCAD, from idea to a print-ready Bambu Studio project. Use when the user wants to design something to 3D print, start or scaffold a new print project, move an existing model onto the project pattern, change a printed part, report a print or a coupon result, or get the .3mf to print.
---

# 3D print project

A project is a parametric OpenSCAD model, a pytest suite that proves every part fits and prints, and a print
queue that ends in one Bambu Studio project (`stl/print/<project>.3mf`): every part, printed or not, every plate, filament and setting
already set, so the user opens it and prints. The user prints on a Bambu Lab H2S and reviews visually.

The user's standing goal for every part: **the best quality and strength, the least material, the fastest print,
in balance.** They pull apart; weigh each choice that moves them (a hollow, an infill, walls, layer height, an
orientation, a plate's colours) with the slicer's numbers (`scripts/compare.py`), say which you chose and what the
others would cost, and keep the visible faces at quality.

The pattern lives in `~/Projects/3D/` (mac-mini-rack set it; organizer, edc-case, kids-charger follow it).
The templates are in `~/.config/agent-skills/3d-print-project/templates/` (absolute path: only this file is
linked into each harness). When a sibling project has a newer version of a template, prefer it and update the
template.

## Branches

### A new project

1. **Brief.** Ask what it holds or does, where it lives (the environment: a shelf, a drawer, a rack), what must
   not happen (the anti-goals), the build plate it prints on (`BED_TYPE`), and the material if it isn't obvious (PLA Matte by default; PETG Matte for heat
   over ~50 °C, creep under load, outdoors; no TPU). Ask for caliper measurements of every bought object, and for
   any reference model (STL, 3MF, maker drawing) to put in `references/`. Done when every object the design
   touches has a measured or explicitly estimated size.
2. **Concepts.** Two or three throwaway layouts rendered to `renders/review/YYYY-MM-DD-concept/`. Done when the
   user picks one.
3. **Spec** in `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`: Status (who approved what, when, on which
   renders), Why, Goals, Non-goals, Anti-goals, the measured environment, the design, the coupons, what is still
   to measure, How the user will judge it (the hand test), What the model checks, History. Mark your own
   choices *(my call)*; quote the user's decisions with dates. Carry every binding requirement from earlier specs.
4. **Scaffold**: `git init`; copy the templates (`dot_gitignore` becomes `.gitignore`); fill `PROJECT`,
   `pyproject.toml`, `params.scad`'s frame; `uv lock`. Write `AGENTS.md` and `README.md` modelled on the newest
   sibling's. Done when `bash scripts/test.sh` passes on the empty project.
5. **Coupons first**: small prints cut from the real part's modules that settle each unknown fit (three values
   each, marked on the coupon). Parts that depend on them are `hold`. Hand them over as their own print project:
   `scripts/slice.py` writes `stl/print/<project>-coupons.3mf` (and `PRINT-coupons.md`) for the queued coupons
   (`--coupons all`: every one), drafted leaner and faster than the final print (`COUPON_PROCESS`,
   `COUPON_SLICER`: 0.24 mm layers, 10% lightning infill, thin skins), the outer wall untouched. Done when the
   coupons' project slices with no warnings and you have given the user its path and `PRINT-coupons.md`.
6. **The model**, test first (below). Then export, slice, hand over the print project and the assembly guide.

### Moving an existing project onto the pattern

1. Commit the project as it stands (a baseline), and export every part from the old scripts into the
   scratchpad: the conversion must not change geometry.
2. `git mv` into the layout: `parts/<group>/<entry>.scad` with `*_print()` modules, `assembly.scad` for
   viewing, the templates' scripts and tests, `docs/design/`, `docs/build/`, `docs/superpowers/` for the old
   brief and notes. The user's own slicer projects go to `stl/projects/`, untouched.
3. Compare every new export with the baseline (volume, extents). Done when they all match, or each difference is
   explained.
4. Run the suite, then the slicer. Expect real findings: an old project was never checked this way. Fix the
   model, or record an allowance with its reason; never loosen a check to pass.

### Changing the model

Test first: write the test, watch it fail for the right reason, then change the model. Then:

```bash
bash scripts/test.sh                 # without the slow tests; --all (the slicer too) before a merge
uv run python scripts/export.py      # stl/<group>/, stl/queue/, stl/QUEUE.md
uv run python scripts/slice.py       # stl/print/<project>.3mf (every part) and PRINT.md; the queue: <project>-queue.3mf;
                                     # queued coupons: <project>-coupons.3mf
```

**Before anything runs the slicer** (`slice.py`, `test.sh --all`, a comparison), ask the user to quit Bambu Studio
and wait for their yes: the CLI is the same binary, and its crash shows the user the app's crash dialog. Never
hand slicer runs to a background agent, and run one slicer at a time.

A change to a printed part sets it to `reprint` with the reason, in the same commit. A design change worth
asking about comes with a render. Done when the suite passes `--all`, the print project is rebuilt, and
`PRINT.md` shows no slicer warning.

### The assembly guide

An IKEA-style picture book per variant, that anyone can build the product from without knowing the design (the
user, 2026-11-08): `scripts/guide/build.py` writes `renders/guide/<variant>/index.html`. Copy the templates'
`scripts/guide/build.py` and `test/test_guide.py`; write the project's own:

- `scripts/guide/guide.scad`: every piece as `piece(id, p)`, pulled out by `p` along its way in; the hardware
  (inserts, screws, springs) modelled at each hole, with a line back to it; the points the close-ups look at as
  `FOCUS` (echoed); a `flip` (the product turned over for the steps from below), cut-away close-ups (`crop`: the
  model cut to a box round the point, so no wall hides it) and sections. kids-charger's is the reference.
- `scripts/guide/steps.py`: `STATIONS` (a guide per variant), `WORDS` (what changes between them), `TITLE`, `INTRO`
  (the tools), `ACCENT`, `FINISHED`, and `STEPS`, each its pieces (label, count, thumbnail id, part or hardware name, a part
  named where it first appears only), its pictures and a few plain words. **3 kinds of piece a step at most; a
  screw or an insert from 2 angles or more** (an overview and close-ups). Order the steps by what the assembly
  needs, not by part: the piece a screw goes into before the screw; what blocks a cable after the cable.
  **Every piece has a code** (the user, 2026-11-09: off the plate, the clips looked alike): printed pieces a
  number, bought ones a letter, in the order the steps bring them; the page opens with every piece, its code,
  count, size and how to tell it from the ones like it (`TELL`), and each step says "Pieces 4, 5 and D".
  `THUMB_PART` codes a piece a step brings back by its picture; `SAME` gives pieces that print the same one code.
  Engrave each printed piece's number in a hidden face (0.6 deep, `coded()` in its `*_print()`; a 6 and a 9 with a
  dot), from a params table the guide reads: a code printed on a piece never changes when the steps do.
  **Draw pieces in the order the hands put them in.** When one piece holds another down (a keeper over a clip, a
  lid over a part), show the held piece going in alone first (`later`: pieces not drawn yet in a view), then that
  piece in place (`placed`) with the holder above it and its screws above the holder: an explode stacked out of
  order reads as the wrong assembly (kids-charger's clips once floated over their keepers: the user, 2026-11-09).

`test/test_guide.py` checks those rules, that every printed part is in it as often as it prints, that the hardware
is `docs/build/`'s table, and that every piece and close-up the steps name exists. Then look at every picture (a
contact sheet: `magick montage`): a close-up whose camera sits in a wall or behind one renders blank or as a wall;
cut it (`top`: just above the floor it looks into) or turn it. Rebuild the guide with the design.

### The user reports a print

Record it in `scripts/print_status.toml` (`printed` with the date; `reprint` / `hold` with why). A coupon's
verdict goes in `params/` and in `docs/measurements.md` (from Still to measure to Measured, the verdict in words:
"0.1 goes in with effort, out only with a mallet"), then release what waited on it (`hold` -> `to-print`) and
rebuild the queue and the print project. Photos go in `references/photos/YYYY-MM-DD-topic/`.

## The rules

**Model**
- Every dimension lives in `params/` (one file per concern, included by `params.scad`); parts never hard-code a
  value another part or a test needs. Estimates are marked `MEASURE`.
- Parts are modelled in place, in one world frame documented in `params.scad`; moving states (a hinge angle, a
  dial) are transforms of it, so tests probe any state.
- A part's entry file is what others `use`; its pieces are `include`d by it. A `use`d file keeps its own params:
  a probe or a variant that overrides them (`-D side=...`) includes the part.
- Print orientations are `*_print()` modules that only turn a part: never `mirror(` (it prints the mirror image).
  A left/right variant is a param of the design, with text and bought hardware never mirrored.
- Bought objects are data: one size per object drives its pocket and its ghost. Anything shaped to one cable plug
  or device case goes in a small swappable part; the big part gets an opening sized by an envelope param, with an
  `assert` for when a new item exceeds it.
- Pieces of a union overlap, never just touch (touching leaves an STL that isn't closed).

**Printing**
- Every part in `scripts/print_parts.py` passes `test/test_print.py`: closed, on the bed, one piece, no support
  but where `SUPPORTED` says why, every ceiling a bridge anchored at both ends, no region starting in mid-air.
- The slicer has the last word. `test/test_slice.py` slices the whole product and reads each plate's G-code: its
  filaments loaded at their temperatures, no warnings, support only where allowed. A part the box checks can't
  clear but the slicer prints cleanly goes in `SLICER_JUDGED` with why.
- The project is the build's output: every part, whatever its print status (kids-charger dropped a dock that was
  printing, and the user asked for it back, 2026-11-07). What is still to print is `<project>-queue.3mf` beside it.
- Slicer settings are data in `scripts/print_parts.py` (printer, process, the user's calibrated filament presets,
  colours, per-part settings), never set by hand in the project.
- Coupons are drafted, the product is not: a coupon is read once and thrown away, so it gets the least material and
  time that still tells the truth. Keep what it measures as printed: the outer wall always (a fit across the bed);
  for a coupon that tests what layers change (a height, a snap's catch, strength) give its final settings back in
  `SLICER`, which wins over `COUPON_SLICER`. A plate holds one filament; multi-filament
  objects (a part and its companion) share their own plates.

**Fit, measurements, strength**
- Coupons first; a part waiting on a coupon or a measurement is `hold` with what it waits for.
- `docs/measurements.md` and `params/` stay equal (`test/test_measurements.py`). Sources, best first: calipers,
  a reference model (section it), a maker drawing, a photo (±3 mm, replace before a pocket is final). Say which
  face a radius belongs to.
- Every part a mechanism's force goes through gets a strength check (weakest section, a design load from
  `params/`, its flex; mac-mini-rack `test/strength.py`). Prefer a sound redesign to a patch.

**Renders, docs, git**
- Every image made to evaluate a design goes in `renders/review/YYYY-MM-DD-topic/`, finals in `renders/final/`:
  never the scratchpad or `/tmp`. White with black accents (or the project's colours) on #596B80.
- `docs/design/` is the design now, `docs/build/` how to print and assemble; `test/test_layout.py` checks every
  link and every path they name. Write tersely: plain declarative sentences, reasons after a colon, dates on
  decisions.
- The assembly guide is built output, like the print project: rebuilt when a part, a screw or a step changes.
- Conventional commits scoped by part (`feat(tray): …`), a `## Changes Description` body, the suite's result.
  `stl/`, `renders/`, `references/`, `.superpowers/` are not in git.

## Lessons (each cost a failed print or a wasted session)

- **Walk the assembly, not just the fit.** Move each part along its real insertion path in steps, and trace each
  cable from plug to plug (its largest plug, angled heads included) through every opening, from where the hands
  are. The kids-charger Pencil dock failed three test prints on "how does the cable get in" while every
  final-pose check passed. Write the motion as a test, with a WRONG case that must block. Test every cable, not
  only the one that failed before: kids-charger's Switch cable way was closed in the printed dock (built from the
  fit-test body, which left its channel out) and only the user's eye caught it (`test/test_routes.py` now follows
  every cable's plug from its clip to the tray). Check what is printed, not the part a coupon was cut from.
- **Measure the reference model.** When the user supplies an STL or 3MF, section it (trimesh) and compare the cut
  against it before export. A slot cut from one remembered radius on the wrong face didn't fit.
- **Coupons test only the unknown.** A full-height test took 2 h; the interface alone took 20 min. A pocket coupon
  4 mm deep can pass where the full tray is tight: design so the object drops in freely and something else holds it.
- **A check that passes silently proves nothing.** A crashed OpenSCAD once passed every echo probe (the template
  `test/scad.py` fails on a crash); a probe that is empty because it is misplaced passes too. Watch each new
  test fail on the old model.
- **The slicer finds what the checks miss.** The user once found a hanging slope in the slicer that every check
  passed; kids-charger's arm passed them all and the slicer called it floating. Slice before handing over.
- **Never move an exported STL in Python.** Binary STL is float32: translating a mesh rounds near-coincident
  vertices together and opens it. Move parts in OpenSCAD (`scripts/export.py` does).
- **Weigh a change with the slicer, not by guessing.** Slice the part's variants alone (`scripts/compare.py`) and
  compare hours, grams and support; find where the slicer puts support (`scripts/support_map.py`) before
  redesigning. kids-charger's dock went from 34h46 and 347 g of support to about 24 h and 139 g by limiting its
  hollow to a 40° roof over the tray (the rest infill); a guessed fix for the arm missed the real overhang.
- **Lightning infill is for short parts.** Its branches rise free from the floor to the surfaces they hold; in a
  solid PETG bin 49 tall they stood ~40 tall, the nozzle knocked them over and the pocket floors printed in mid-air
  (alex-gridfinity's ratchets bin, 2026-11-13: plate cancelled). The slicer calls it clean. Over ~15 mm use a
  self-supporting infill (adaptive cubic, gyroid); `test/test_print.py` checks.
- **Ribs don't buy back support in Bambu's tree(auto).** Walls under a floor still leave the floor between them
  supported (kids-charger's tray ribs: +44 min, +50 g, -6 g of support; `bridge_no_support` changed nothing).
  What removes support is material that rises to the ceiling at 40-45° (a roof), or a shape with no ceiling.
- **A big PETG box warps: give it a wide foot, a warm bed, a gentle fan and a fused brim.** kids-charger's dock
  stands on its rim alone (a 1.6 mm strip at the bed, under the floating base line's set-in, under a
  260 × 190 × 144 box). With no brim its back lifted an hour in and fell over; with a brim 0.1 off it, on the
  SuperTack at 60 °C and the fan at 20-50%, the brim stayed on the plate and the rim warped up off it late in the
  print (2026-11-06). Now: PETG on Textured PEI at 70 (`BED_TYPES`, set per plate), its fan at 10-20%
  (`FILAMENT_OVERRIDES`), the brim fused (`brim_object_gap` 0), door and lid closed. `test/test_print.py` asks
  for a brim on any part whose bed contact is under 10% of its footprint or that stands over 6 times taller than
  its contact is wide, fused for the rims. Design big parts to stand on more than a rim (`test/test_print.py`:
  over 150 mm a side, 4 mm of bed contact along the outline on average): keep the bed face full, or hide a foot
  inside a set-in base line (the rim thickened inward, a 45° chamfer back to the skin), kept out of whatever lies
  against the walls inside. The dock's foot (`dock_foot`, 2026-11-07): 1,800 to 3,850 mm² for 9 g and 8 min.
- **Tall supports in PETG are blocks, not trees.** kids-charger's dock stood its floors on tree trunks 3 mm thick
  at 30-45 mm; three fell an hour in, before what they held printed (2026-11-07). Blocks (`normal(auto)`,
  `support_style` default) were the fastest and sturdiest of six setups (+133 g, -2 h); thick organic trees the
  middle ground. `test/test_slice.py` measures the support's pieces in the G-code: a median over 100 mm² at
  20, 30 and 40 mm.
- **Block supports from the plate beat organic trees on a big PETG box.** kids-charger's dock: the trees' feet let
  go and printed strings (2026-11-07); normal block supports from the build plate only came out sturdier and peeled
  cleaner (2026-11-09).
- **What stands free between openings needs more than the skin.** The wall between two vent slots is a strip held
  only above and below; at 1.6 (the hollow's skin) one per row broke mid-print, a missing tooth (kids-charger,
  2026-11-09). Thicken the wall behind an opening row inside (45° above and below), and check it in a test.
- **A pocket in an upright face has a ceiling.** A flat one 2.5 deep printed as strings; slope it 45° up into the face
  and shape the part that goes in to match (a glued badge: its back edge chamfered).
- **Screw a box's every corner.** A corner with no screw within ~100 mm opens when the box is handled or loaded
  (kids-charger's tower, on a shelf): a boss in each corner, even inside a mechanism's room, with its swing tested.
- **A part printed on its side has no base line on its bed face.** A plinth set-in or a channel's flat end facing
  the bed becomes a ledge in mid-air; end channels on a 45° plane they share.
- **The person reviews by eye.** Renders inside the project, project-relative paths in the reply; a design
  question comes with a picture.

## Bambu Studio's CLI

`scripts/bambu.py` drives it headless (its docstring lists the facts it relies on). The ones that bite:

- It ignores `inherits` and `include` in presets: every preset is flattened first, `include` too (the printer's
  own start G-code lives there; without it the G-code loads no filament and never heats).
- Every filament must be mapped to the single nozzle (`filament_map`, `filament_nozzle_map`,
  `nozzle_volume_type`), or it segfaults on a plate that doesn't use filament 1.
- It runs beside the open app but a crash shows the app's crash dialog: the scripts refuse to run while Bambu
  Studio is open. Ask the user to quit it.
- Plates come from an assemble list (a plate's own bed type: `plate_params` `{"curr_bed_type": ...}`); parts don't spill to new plates (bin-pack first). `--min-save` is a bare
  flag and can't combine with an assemble list: the G-code-only copy is made from the finished project.
- A full project opens unsliced in the app (Slice all, then print); the `.gcode.3mf` opens ready to send
  (from Bambu Studio's source, 02.08: confirm it in the app the first time).
