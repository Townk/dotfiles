# Run inside FontForge: merge Brands/Regular/Solid into one OTF.
# Solid wins overlaps, then Regular, then Brands.
#
# This script is executed by FontForge's bundled Python interpreter
# (`fontforge -lang=py -script`), which has the `fontforge` C-extension but NOT
# fontTools. It is therefore standalone and must NOT import the rest of the
# `fontbuild` package.
import os, sys
import subprocess
import tempfile
import fontforge

PRIORITY = ["Solid", "Regular", "Brands"]

def find_fa_files(srcdir):
    found = {}
    for name in os.listdir(srcdir):
        lower = name.lower()
        if not (lower.endswith(".otf") or lower.endswith(".ttf")):
            continue
        full = os.path.join(srcdir, name)
        if "brands" in lower:
            found["Brands"] = full
        elif "solid" in lower:
            found["Solid"] = full
        elif "regular" in lower:
            found["Regular"] = full
    return found

def load_free_icon_cps(icons_json):
    """Map {codepoint: icon-name} for every FREE Font Awesome icon."""
    if not icons_json or not os.path.exists(icons_json):
        return {}
    try:
        import json
        with open(icons_json) as fh:
            data = json.load(fh)
    except Exception:
        return {}
    out = {}
    for name, info in data.items():
        if not isinstance(info, dict) or not info.get("free"):
            continue
        u = info.get("unicode")
        if not isinstance(u, str):
            continue
        try:
            out[int(u, 16)] = name
        except ValueError:
            pass
    return out


def curated_occupancy(ttf_path):
    """Codepoints already claimed by the curated Nerd Fonts layout, read
    from the upstream-shipped Symbols-Only TTF. A free FA icon whose
    native codepoint is in here would be skipped by the patcher's
    careful mode, so we relocate it instead."""
    occ = set()
    if not ttf_path or not os.path.exists(ttf_path):
        return occ
    try:
        f = fontforge.open(ttf_path)
    except Exception:
        return occ
    for g in f.glyphs():
        if g.unicode is not None and g.unicode >= 0:
            occ.add(g.unicode)
    f.close()
    return occ


def load_custom_meta(path):
    """Flat {icon-name: info} from custom-icons/metadata.json (or {} if
    absent/invalid). Accepts an "icons" wrapper and ignores header keys
    starting with _ or $."""
    if not path or not os.path.exists(path):
        return {}
    try:
        import json
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if isinstance(data, dict) and isinstance(data.get("icons"), dict):
        data = data["icons"]
    if not isinstance(data, dict):
        return {}
    return {
        name: info for name, info in data.items()
        if isinstance(info, dict) and not name.startswith(("_", "$"))
    }


def normalize_svg(src_path, usvg_bin):
    """Return a path to a cleaned-up copy of src_path for FontForge to import.

    Runs the SVG through `usvg` (the resvg project's SVG simplifier), which
    resolves CSS `<style>` fills, converts basic shapes to paths, bakes/
    flattens references, and resolves clips/masks into a minimal, well-defined
    SVG. FontForge's own SVG importer is unreliable on those features, so this
    makes the import faithful regardless of where the source SVG came from.

    usvg does NOT crop the canvas, and it doesn't need to: the downstream
    bounding-box normalization (here and in step 7b) trims to the real drawing
    extent from the imported contours. Returns a temp path the caller must
    delete; falls back to src_path (and prints a note) if usvg is unavailable
    or fails."""
    if not usvg_bin:
        return src_path, False
    try:
        fd, tmp = tempfile.mkstemp(suffix=".svg", prefix="usvg_")
        os.close(fd)
        subprocess.run([usvg_bin, src_path, tmp],
                       check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        return tmp, True
    except Exception as exc:
        sys.stderr.write("  usvg failed for %s (%s); importing raw\n"
                         % (os.path.basename(src_path), exc))
        return src_path, False


def import_custom_svgs(dest, custom_dir, start_cp, meta, used, usvg_bin=""):
    """Import every *.svg under custom_dir into a Plane-16 PUA glyph and
    return {icon-name: codepoint}.

    Codepoint assignment is STABLE so a downstream TUI can hard-code one:
      * An icon with a "code" pin in metadata.json (a hex string) always
        lands at exactly that codepoint.
      * Everything else is auto-assigned from start_cp, skipping any
        codepoint already taken (FA natives, relocated FA, pinned customs,
        and earlier auto customs). `used` is the live occupancy set and is
        mutated in place. Pins are reserved BEFORE any auto-assignment so an
        unpinned icon can never squat on a pinned slot.

    Each SVG is first run through usvg (see normalize_svg) so the import is
    faithful regardless of source quirks (CSS fills, shapes, clips, transforms).

    The icon name is the filename without extension (cursor-ai.svg ->
    usr-cursor-ai in glyphs.json). Each outline is normalised to roughly the box
    the FA icons occupy in this combined OTF (em-tall, on the FA descent),
    aspect preserved, centred, advance = one em, so the patcher treats it like
    every other FA glyph. Final sizing is set uniformly for all icons in step
    7b (normalized to the curated md/oct box), so this placement only needs to
    be sane, not exact."""
    out = {}
    try:
        names = sorted(n for n in os.listdir(custom_dir)
                       if n.lower().endswith(".svg"))
    except OSError:
        return out
    EM = float(dest.em)          # FA combined OTF unitsPerEm (verified 512 today)
    # FontForge reports descent as a positive value; the icon box sits in
    # [descent_em - EM, ascent], i.e. DESC = ascent - em (negative).
    DESC = float(dest.ascent - dest.em)   # FA icon box is DESC .. DESC + EM

    # Pass 1: reserve every valid pin so auto-assignment can't grab it.
    pinned = {}
    for fn in names:
        name = os.path.splitext(fn)[0]
        info = meta.get(name)
        pin = info.get("code") if isinstance(info, dict) else None
        if pin is None:
            continue
        try:
            cp = int(str(pin), 16)
        except ValueError:
            sys.stderr.write("  custom pin for %s is not hex (%r); auto-assigning\n"
                             % (name, pin))
            continue
        if cp in used:
            sys.stderr.write("  custom pin U+%X for %s already in use; auto-assigning\n"
                             % (cp, name))
            continue
        pinned[name] = cp
        used.add(cp)

    nxt = [start_cp]

    def alloc():
        while nxt[0] in used:
            nxt[0] += 1
        cp = nxt[0]
        used.add(cp)
        nxt[0] += 1
        return cp

    def abandon(cp):
        # Import failed or produced nothing: drop the empty glyph so it isn't
        # shipped as an invisible blank PUA slot. (alloc() only moves forward, so
        # the discarded codepoint isn't reused; `used` is rebuilt by the caller
        # anyway -- the discard just keeps this set tidy.)
        try:
            dest.removeGlyph(dest[cp])
        except Exception:
            pass
        used.discard(cp)

    # Pass 2: import each icon at its pinned or freshly-allocated codepoint.
    for fn in names:
        name = os.path.splitext(fn)[0]
        path = os.path.join(custom_dir, fn)
        was_pinned = name in pinned
        cp = pinned[name] if was_pinned else alloc()
        g = dest.createChar(cp, "customsvg_%05x" % cp)
        g.clear()
        norm_path, is_tmp = normalize_svg(path, usvg_bin)
        try:
            g.importOutlines(norm_path)
        except Exception as exc:
            sys.stderr.write("  custom SVG import failed for %s: %s\n" % (fn, exc))
            abandon(cp)
            continue
        finally:
            if is_tmp:
                try:
                    os.unlink(norm_path)
                except OSError:
                    pass
        bb = g.boundingBox()
        if not bb or (bb[2] - bb[0]) <= 0 or (bb[3] - bb[1]) <= 0:
            sys.stderr.write("  custom SVG produced an empty glyph: %s\n" % fn)
            abandon(cp)
            continue
        xmin, ymin, xmax, ymax = bb
        scale = EM / max(xmax - xmin, ymax - ymin)
        g.transform((scale, 0, 0, scale, 0, 0))
        xmin, ymin, xmax, ymax = g.boundingBox()
        w = xmax - xmin
        h = ymax - ymin
        dx = -xmin + (EM - w) / 2.0       # centre in the 0..EM cell
        dy = DESC - ymin + (EM - h) / 2.0  # centre in the DESC..DESC+EM box
        g.transform((1, 0, 0, 1, dx, dy))
        g.width = int(round(EM))
        g.removeOverlap()
        g.correctDirection()
        out[name] = cp
        print("  custom: %-20s -> U+%X  (%s%s)"
              % (name, cp, fn, ", pinned" if was_pinned else ""))
    return out


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(
            "usage: <srcdir> <output_otf> "
            "[icons_json] [curated_ttf] [fa_map_out] [reserved_start_hex] "
            "[custom_svg_dir] [custom_start_hex] [custom_meta_json] [usvg_bin]\n")
        return 2
    srcdir, outpath = argv[1], argv[2]
    icons_json       = argv[3] if len(argv) > 3 else ""
    curated_ttf      = argv[4] if len(argv) > 4 else ""
    fa_map_out       = argv[5] if len(argv) > 5 else ""
    reserved_start   = int(argv[6], 16) if len(argv) > 6 and argv[6] else 0
    custom_dir       = argv[7] if len(argv) > 7 else ""
    custom_start     = int(argv[8], 16) if len(argv) > 8 and argv[8] else 0
    custom_meta_file = argv[9] if len(argv) > 9 else ""
    usvg_bin         = argv[10] if len(argv) > 10 else ""
    files = find_fa_files(srcdir)
    for label in PRIORITY:
        if label not in files:
            sys.stderr.write("missing FA '%s' OTF in %s\n" % (label, srcdir)); return 3

    print("Merging Font Awesome OTFs from %s" % srcdir)
    for label in PRIORITY:
        print("  %-8s -> %s" % (label, files[label]))

    dest = fontforge.open(files[PRIORITY[0]])
    dest.encoding = "UnicodeFull"
    dest.fontname  = "FontAwesomeCombined-Regular"
    dest.familyname = "Font Awesome Combined"
    dest.fullname  = "Font Awesome Combined"
    dest.copyright = "Fonticons, Inc."

    seen = set(g.unicode for g in dest.glyphs() if g.unicode >= 0)
    print("  baseline (%s): %d codepoints" % (PRIORITY[0], len(seen)))

    for label in PRIORITY[1:]:
        src = fontforge.open(files[label])
        src.encoding = "UnicodeFull"
        added = 0
        for glyph in src.glyphs():
            cp = glyph.unicode
            if cp < 0 or cp in seen:
                continue
            src.selection.select(glyph.encoding)
            src.copy()
            dest.selection.select(("unicode",), cp)
            dest.paste()
            try: dest[cp].glyphname = glyph.glyphname
            except Exception: pass
            seen.add(cp); added += 1
        src.close()
        print("  merged %s: +%d glyphs (total: %d)" % (label, added, len(seen)))

    # -- Relocate colliding free icons so they survive the patcher --
    # The patcher's `--custom` careful mode only fills EMPTY codepoints,
    # so any free FA icon whose native codepoint is already owned by a
    # curated Nerd Fonts collection (Powerline, Devicons, Seti, ...) gets
    # dropped. We give those icons a *copy* at a fresh Plane-16 Private
    # Use codepoint (the original stays put and is harmlessly skipped at
    # patch time). The patcher then imports and scales the copy through
    # the exact same path as every other custom glyph, so all free icons
    # end up present and visually consistent. The native->relocated map
    # is written out for the JSON step so each icon keeps its `fa-<name>`.
    relocations = {}
    fa_cps = []
    if icons_json and reserved_start:
        free_cps = load_free_icon_cps(icons_json)
        occ = curated_occupancy(curated_ttf)
        present = set(g.unicode for g in dest.glyphs() if g.unicode is not None and g.unicode >= 0)
        for cp in sorted(free_cps):
            if cp not in present:
                continue
            # Relocate any free icon that would otherwise land on top of a real
            # glyph when this merged FA is patched onto a font:
            #   * cp in occ  -> collides with a curated Nerd Fonts glyph.
            #   * non-PUA cp -> Font Awesome 7 places some free icons at ASCII /
            #     text positions (fa-0..9 at U+0030.., fa-a..z at U+0041.., plus
            #     fa-equals/plus/at/asterisk/... at their ASCII codepoints).
            #     Harmless in the Symbols-Only font (no text there), but when
            #     patched onto JetBrains Mono they would clobber its real '=',
            #     digits and A-Z, and the icon-sizing step (7b) would then
            #     mis-scale those text glyphs. Relocate them to Plane-16 too.
            #   * terminal_reserved -> terminals such as WezTerm intercept
            #     U+F5D0..U+F5FB as built-in git-branch sprites before font
            #     fallback, so FA icons there render as branch lines.
            is_pua = (0xE000 <= cp <= 0xF8FF) or (0xF0000 <= cp <= 0xFFFFD) \
                or (0x100000 <= cp <= 0x10FFFD)
            terminal_reserved = 0xF5D0 <= cp <= 0xF5FB
            if cp in occ or not is_pua or terminal_reserved:
                # Deterministic, update-stable slot: native + reserved_start.
                # Colliding free natives sit in the BMP PUA (0xE000..0xF8FF) ->
                # 0x10E000..0x10F8FF; the non-PUA (ASCII) ones land in
                # 0x100021..0x10005A. Both are well inside Plane-16 and clear of
                # the custom block above. The slot is a pure function of the
                # icon's own native codepoint, so it stays stable across updates.
                new_cp = reserved_start + cp
                if new_cp > 0x10FFFD:
                    # No safe Plane-16 slot. This icon is in the relocation
                    # branch because its native slot is taken by a curated glyph
                    # (or is a text/terminal-reserved codepoint), so the original
                    # cannot survive there either -- drop it entirely rather than
                    # keep a native cp that now resolves to the wrong glyph (which
                    # the icon-sizing step would then mis-scale).
                    sys.stderr.write(
                        "  drop free FA U+%X: native+0x%X overflows Plane-16\n"
                        % (cp, reserved_start))
                    continue
                dest.selection.select(("unicode",), cp)
                dest.copy()
                dest.selection.select(("unicode",), new_cp)
                dest.paste()
                try:
                    dest[new_cp].glyphname = "farelo_%05x" % new_cp
                except Exception:
                    pass
                if not is_pua or terminal_reserved:
                    # The original sits at a TEXT or terminal-reserved codepoint,
                    # so remove it: unlike
                    # a curated collision (where the patcher's careful mode skips
                    # the original because the curated glyph occupies that slot),
                    # the Symbols-Only font has nothing there, so a leftover
                    # original would be added as a stray icon and claim a
                    # codepoint that terminal renderers may reserve. Drop it.
                    try:
                        dest.removeGlyph(dest[cp])
                    except Exception:
                        pass
                relocations["%04x" % cp] = "%04x" % new_cp
                fa_cps.append(new_cp)
            else:
                fa_cps.append(cp)
        print("  relocated %d free FA icons off curated/text codepoints (stable: native+U+%X) (%d kept at native)"
              % (len(relocations), reserved_start, len(fa_cps) - len(relocations)))

    # -- Import local custom SVG icons (Plane-16 PUA) --
    # Each SVG is normalized with usvg first, then imported and (in step 7b)
    # sized to the curated md/oct box like every other icon. Codepoints are
    # pinnable via metadata.json so a TUI can hard-code them.
    customs = {}
    if custom_dir and custom_start and os.path.isdir(custom_dir):
        used = set(g.unicode for g in dest.glyphs()
                   if g.unicode is not None and g.unicode >= 0)
        meta = load_custom_meta(custom_meta_file)
        customs = import_custom_svgs(dest, custom_dir, custom_start, meta, used, usvg_bin)
        for c in customs.values():
            fa_cps.append(c)
        print("  imported %d custom SVG icon(s)" % len(customs))

    if fa_map_out:
        import json
        with open(fa_map_out, "w") as fh:
            json.dump({
                "relocations": relocations,
                "reserved_start": ("%04x" % reserved_start) if reserved_start else None,
                "custom": {name: "%04x" % c for name, c in customs.items()},
                "fa_cps": ["%04x" % c for c in sorted(fa_cps)],
            }, fh)
        print("  wrote FA codepoint map: %s (%d icons, %d custom)"
              % (fa_map_out, len(fa_cps), len(customs)))

    print("Writing %s" % outpath)
    dest.generate(outpath, flags=("opentype", "no-FFTM-table"))
    dest.close()
    return 0

sys.exit(main(sys.argv))
