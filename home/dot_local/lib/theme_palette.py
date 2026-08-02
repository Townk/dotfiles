"""theme_palette — shared palette loader for the Python terminal viewers.

Single source for the Catppuccin-Mocha-derived truecolor palette that
ics-view / disk-image-view / sqlite-view (and any future copy) render with.
It resolves the palette JSON in the SAME order as theme::json_path in
theme-common.zsh, so a viewer launched WITHOUT $THEME_PALETTE_JSON inherited
(a GUI open, an env-scrubbed subprocess) still reads the effective, possibly
SSH-tinted cache copy instead of the untinted config copy — the Python side of
the split-palette fix the shell readers already carry.

Pure standard library (json, os); no third-party dependencies. Deployed
verbatim by chezmoi to ~/.local/lib/theme_palette.py.

Public API:
    load_palette() -> dict   {NAME_UPPER: (r, g, b)} for the resolved palette.
    palette_type() -> type   the class the viewers bind as CTP (CTP.LAVENDER).
    palette_json_path() -> str  the resolved JSON path (resolution order only).
"""

from __future__ import annotations

import json
import os

# Built-in Catppuccin Mocha values. Used when no palette JSON is readable, and
# as the default for any key a resolved palette omits.
_PALETTE_FALLBACK = {
    "base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b",
    "surface0": "#313244", "surface1": "#45475a", "surface2": "#585b70",
    "overlay0": "#6c7086", "overlay1": "#7f849c", "overlay2": "#9399b2",
    "text": "#cdd6f4", "subtext1": "#bac2de", "subtext0": "#a6adc8",
    "lavender": "#b4befe", "blue": "#89b4fa", "sapphire": "#74c7ec",
    "sky": "#89dceb", "teal": "#94e2d5", "green": "#a6e3a1",
    "yellow": "#f9e2af", "peach": "#fab387", "maroon": "#eba0ac",
    "red": "#f38ba8", "mauve": "#cba6f7", "pink": "#f5c2e7",
    "flamingo": "#f2cdcd", "rosewater": "#f5e0dc", "white": "#ffffff",
}


def palette_json_path() -> str:
    """Resolve the palette JSON path, mirroring theme::json_path's order:

      1. $THEME_PALETTE_JSON — the sole override (the shell exports it pointing
         at the effective/SSH-tinted cache copy).
      2. else ${XDG_CACHE_HOME:-~/.cache}/theme/chezmoi-system.json if readable
         — theme-apply writes the override-tinted palette there.
      3. else ${XDG_CONFIG_HOME:-~/.config}/theme/chezmoi-system.json.

    ``~`` is expanded. The config tier is unconditional, so this never fails.
    """
    override = os.environ.get("THEME_PALETTE_JSON")
    if override:
        return os.path.expanduser(override)

    cache_home = os.environ.get("XDG_CACHE_HOME") or "~/.cache"
    cache = os.path.expanduser(os.path.join(cache_home, "theme", "chezmoi-system.json"))
    if os.access(cache, os.R_OK):
        return cache

    config_home = os.environ.get("XDG_CONFIG_HOME") or "~/.config"
    return os.path.expanduser(os.path.join(config_home, "theme", "chezmoi-system.json"))


def load_palette() -> dict:
    """Return ``{NAME_UPPER: (r, g, b)}`` for the resolved palette.

    Every built-in key is present; the resolved JSON's ``palette`` object
    overrides matching keys. A missing, unreadable, or invalid JSON file is
    tolerated — the built-in Catppuccin Mocha values are returned instead of
    raising (the same fallback the viewers' private _load_palette had).
    """
    pal = dict(_PALETTE_FALLBACK)
    try:
        with open(palette_json_path(), encoding="utf-8") as _fh:
            pal.update(json.load(_fh).get("palette", {}))
    except (OSError, ValueError):
        pass

    def _rgb(value: str) -> tuple:
        value = value.lstrip("#")
        return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))

    return {name.upper(): _rgb(hexval) for name, hexval in pal.items()}


def palette_type() -> type:
    """Return the class the viewers bind as ``CTP``.

    Equivalent to ``type("CTP", (), load_palette())``: each palette name
    becomes a class attribute holding its ``(r, g, b)`` triple, so callers
    read ``CTP.LAVENDER``, ``CTP.BASE``, etc.
    """
    return type("CTP", (), load_palette())
