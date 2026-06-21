"""Emit a glyphs.json index describing every codepoint in the built font (step 9).

Sources merged into the JSON:
  * Curated Nerd-Fonts glyph names from <repo>/glyphnames.json, keyed with an
    `nf-` prefix (nf-fa-house, nf-md-account_check, nf-cod-zap) so upstream
    `fa-*` curated names cannot collide with FA 7 native additions.
  * Font Awesome 7 native additions from <fa>/metadata/icons.json (keyed
    `fa-<icon-name>`). Pulls FA's label / search.terms / aliases / styles.
    Icons relocated off a colliding curated codepoint are followed to their
    Plane-16 slot via fa-map.json and tagged with `relocated_from`.
  * Local custom SVG icons, keyed `usr-<filename>`.
  * Anything else in the font's cmap that stdlib `unicodedata` names, `u-<hex>`.
"""

from __future__ import annotations

import json
import os
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

from fontTools.ttLib import TTFont


NF_COLLECTION_NAMES = {
    "fa":      "font-awesome",
    "fae":     "font-awesome-extension",
    "md":      "material-design",
    "mdi":     "material-design-legacy",
    "oct":     "octicons",
    "cod":     "codicons",
    "dev":     "devicons",
    "iec":     "iec-power",
    "linux":   "font-logos",
    "pl":      "powerline",
    "ple":     "powerline-extra",
    "pom":     "pomicons",
    "seti":    "seti-ui+custom",
    "weather": "weather-icons",
    "custom":  "seti-ui+custom",
    "indent":  "indent",
}


def _load_json(path):
    if not path:
        return None
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _safe_unicode_name(cp):
    try:
        return unicodedata.name(chr(cp))
    except (ValueError, OSError):
        return None


def _enrich_with_fa(entry, fa_info):
    if isinstance(fa_info.get("label"), str):
        entry["label"] = fa_info["label"]
    styles = fa_info.get("styles")
    if isinstance(styles, list) and styles:
        entry["styles"] = list(styles)
    search = fa_info.get("search")
    if isinstance(search, dict):
        terms = search.get("terms")
        if isinstance(terms, list) and terms:
            entry["terms"] = [str(t) for t in terms]
    aliases = fa_info.get("aliases")
    if isinstance(aliases, dict) and isinstance(aliases.get("names"), list):
        entry["aliases"] = list(aliases["names"])
    elif isinstance(aliases, list):
        entry["aliases"] = list(aliases)


def _pick_canonical_ttf(built_dir):
    preferred = os.path.join(built_dir, "SymbolsNerdFont-Regular.ttf")
    if os.path.isfile(preferred):
        return preferred
    for entry in sorted(os.listdir(built_dir)):
        if entry.endswith(".ttf") and entry.startswith("Symbols"):
            return os.path.join(built_dir, entry)
    raise SystemExit("no TTFs found under " + built_dir)


def _load_custom_meta(path):
    """Sidecar metadata for the local custom SVG icons (custom-icons/
    metadata.json). Keyed by icon name (filename minus .svg). Accepts either a
    flat map or one wrapped under an "icons" key, and ignores header keys
    beginning with "_" or "$"."""
    data = _load_json(path)
    if isinstance(data, dict) and isinstance(data.get("icons"), dict):
        data = data["icons"]
    if not isinstance(data, dict):
        return {}
    return {
        name: info for name, info in data.items()
        if isinstance(info, dict) and not name.startswith(("_", "$"))
    }


def main(argv):
    args = argv
    (
        built_dir,
        repo_dir,
        fa_metadata_file,
        fa_version,
        nf_ref,
        nf_commit,
        output_path,
        fa_map_file,
    ) = args[:8]
    custom_meta_file = args[8] if len(args) > 8 else ""

    ttf_path = _pick_canonical_ttf(built_dir)
    font = TTFont(ttf_path)
    cmap = font.getBestCmap()
    font_codepoints = set(cmap.keys())

    # native-hex -> relocated-hex for free FA icons the merge step had to move
    # off a colliding curated codepoint (see _fontforge_merge.py).
    fa_map = _load_json(fa_map_file) or {}
    relocations = fa_map.get("relocations", {}) if isinstance(fa_map, dict) else {}
    # name -> Plane-16 hex codepoint for local custom SVG icons.
    customs = fa_map.get("custom", {}) if isinstance(fa_map, dict) else {}
    # name -> {label, terms, aliases, comment, ...} sidecar (optional).
    custom_meta = _load_custom_meta(custom_meta_file)

    nf_glyphs_raw = _load_json(os.path.join(repo_dir, "glyphnames.json")) or {}
    nf_glyphs = {
        name: info for name, info in nf_glyphs_raw.items()
        if name != "METADATA" and isinstance(info, dict) and "code" in info
    }

    fa_icons_raw = _load_json(fa_metadata_file) or {}
    fa_icons = {
        name: info for name, info in fa_icons_raw.items()
        if isinstance(info, dict) and isinstance(info.get("unicode"), str)
    }

    glyphs = {}
    by_source = {
        "nerd-fonts-curated": 0,
        "font-awesome-7": 0,
        "custom-svg": 0,
        "unicode-only": 0,
    }
    used = set()

    for nf_name, info in nf_glyphs.items():
        try:
            cp = int(info["code"], 16)
        except (TypeError, ValueError):
            continue
        if cp not in font_codepoints:
            continue
        entry = {
            "code": format(cp, "04x"),
            "char": chr(cp),
            "source": "nerd-fonts-curated",
        }
        parts = nf_name.split("-", 1)
        if len(parts) >= 2:
            entry["collection"] = NF_COLLECTION_NAMES.get(parts[0], parts[0])
        # Cross-reference FA metadata for curated fa-* entries so curated FA
        # icons inherit FA's natural-language tags too.
        if len(parts) == 2 and parts[0] == "fa":
            fa_lookup = parts[1].replace("_", "-")
            fa_info = fa_icons.get(fa_lookup)
            if fa_info:
                _enrich_with_fa(entry, fa_info)
        unicode_name = _safe_unicode_name(cp)
        if unicode_name:
            entry["unicode_name"] = unicode_name
        glyphs["nf-" + nf_name] = entry
        used.add(cp)
        by_source["nerd-fonts-curated"] += 1

    for fa_name, fa_info in fa_icons.items():
        try:
            native = int(fa_info["unicode"], 16)
        except (TypeError, ValueError):
            continue
        # If this icon was relocated off a colliding curated codepoint, follow
        # it to its Plane-16 landing slot; otherwise it sits at its native FA
        # codepoint.
        relocated_hex = relocations.get(format(native, "04x"))
        cp = int(relocated_hex, 16) if relocated_hex else native
        if cp not in font_codepoints or cp in used:
            continue
        entry = {
            "code": format(cp, "04x"),
            "char": chr(cp),
            "source": "font-awesome-7",
            "collection": "font-awesome",
        }
        if relocated_hex:
            entry["relocated_from"] = format(native, "04x")
        _enrich_with_fa(entry, fa_info)
        unicode_name = _safe_unicode_name(cp)
        if unicode_name:
            entry["unicode_name"] = unicode_name
        glyphs["fa-" + fa_name] = entry
        used.add(cp)
        by_source["font-awesome-7"] += 1

    # Local custom SVG icons, keyed `usr-<filename>`. Per-icon metadata comes
    # from custom-icons/metadata.json when present, otherwise falls back to
    # hints derived from the file name.
    for custom_name, custom_hex in customs.items():
        try:
            cp = int(custom_hex, 16)
        except (TypeError, ValueError):
            continue
        if cp not in font_codepoints or cp in used:
            continue
        meta = custom_meta.get(custom_name, {})
        keywords = meta.get("keywords")
        if not isinstance(keywords, list) or not keywords:
            keywords = meta.get("terms")  # accept the older field name
        if not isinstance(keywords, list) or not keywords:
            keywords = [t for t in custom_name.replace("_", "-").split("-") if t]
        else:
            keywords = [str(t) for t in keywords]
        entry = {
            "code": format(cp, "04x"),
            "char": chr(cp),
            "source": "custom-svg",
            "collection": "custom",
            "keywords": keywords,
        }
        shortcode = meta.get("shortcode")
        if isinstance(shortcode, str) and shortcode:
            entry["shortcode"] = shortcode
        aliases = meta.get("aliases")
        if isinstance(aliases, list) and aliases:
            entry["aliases"] = [str(a) for a in aliases]
        description = meta.get("description") or meta.get("comment") or meta.get("notes")
        if isinstance(description, str) and description:
            entry["description"] = description
        glyphs["usr-" + custom_name] = entry
        used.add(cp)
        by_source["custom-svg"] += 1

    for cp in sorted(font_codepoints - used):
        name = _safe_unicode_name(cp)
        if not name:
            continue
        glyphs["u-{:04x}".format(cp)] = {
            "code": format(cp, "04x"),
            "char": chr(cp),
            "source": "unicode-only",
            "unicode_name": name,
        }
        by_source["unicode-only"] += 1

    out = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "font_family": "Symbols Nerd Font",
        "font_files": sorted(
            os.path.abspath(os.path.join(built_dir, f))
            for f in os.listdir(built_dir)
            if f.endswith(".ttf") and f.startswith("Symbols")
        ),
        "sources": {
            "nerd_fonts_ref": nf_ref or None,
            "nerd_fonts_commit": nf_commit or None,
            "font_awesome_version": fa_version or None,
            "font_awesome_metadata_file": fa_metadata_file or None,
        },
        "stats": {
            "total_codepoints_in_font": len(font_codepoints),
            "total_named_entries": len(glyphs),
            "by_source": by_source,
        },
        "glyphs": glyphs,
    }

    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")

    print(
        "glyphs.json: {total:,} entries "
        "(curated={c:,}, fa7={f:,}, custom={x:,}, unicode-only={u:,}) -> {p}".format(
            total=len(glyphs),
            c=by_source["nerd-fonts-curated"],
            f=by_source["font-awesome-7"],
            x=by_source["custom-svg"],
            u=by_source["unicode-only"],
            p=output_path,
        )
    )
