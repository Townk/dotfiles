"""fontbuild — fontTools post-patch steps for the Symbols Nerd Font build.

Importable modules (donor import, emoji strip, icon scaling, cell bleed,
glyphs.json index, verification, Blink emoji split) plus an in-memory
`pipeline` that threads a single TTFont through the per-font mutation steps,
so each output font is parsed and serialized once instead of per step.

Run as `python -m fontbuild <subcommand>` from the build's fonttools venv.
The FontForge merge step lives in `_fontforge_merge.py`, which is executed by
FontForge's own interpreter and intentionally does NOT import this package.
"""
