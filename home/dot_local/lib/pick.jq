# pick.jq — shared jq helpers for the fzf picker line emitters
#           (pick-glyph, pick-gitmoji, …).
#
# Off-PATH internal module, included by the picker scripts via:
#     jq -L "$HOME/.local/lib" \
#        --argjson palette "$(cat ~/.config/theme/palette.json)" 'include "pick"; … '
# `include` merges these defs into the program's namespace, so the
# emitter can call `c_glyph`, `paint`, `emit_line`, etc. directly.
#
# Purpose: define the picker "wire contract" and the shared Catppuccin
# palette in ONE place. Each picker still authors its own per-entry
# transform (which fields, what layout, any padding/filtering) — this
# module only removes the duplicated colour literals and the manual
# \x1f / \x1e string assembly so the format can never drift between
# pickers.
#
# Wire contract (one line per pickable entry):
#     <visible>\x1f<tail[0]>\x1e<tail[1]>\x1e…\x1e<tail[-1]>
#
#   * <visible> is the (already-colour-wrapped) display portion fzf
#     shows. The pickers run fzf with `--delimiter=\x1f --with-nth=1`
#     so everything from the first \x1f on is hidden from view but
#     still searchable.
#   * <tail> is plain, uncoloured text split on \x1e. By convention the
#     LAST tail field is the raw character/emoji, so the shell side can
#     read the output payload straight from the tail and ANSI colour
#     from the visible portion can never leak into stdout.

# --- Catppuccin palette from the single source --------------------------------
# Colors come from $palette (= ~/.config/theme/palette.json, generated from
# theme.yaml), injected by the caller via `--argjson palette`, so the picker
# tracks the system theme. Each is a 24-bit truecolor fg SGR built from the
# palette hex; fzf renders them via `--ansi`. _hex2int parses a 2-char hex byte
# (jq has no base-N parse).
def c_reset: "\u001b[0m";
def _hexnib: if . >= 48 and . <= 57 then . - 48 elif . >= 97 and . <= 102 then . - 87 elif . >= 65 and . <= 70 then . - 55 else 0 end;
def _hex2int: explode | map(_hexnib) | reduce .[] as $d (0; . * 16 + $d);
def _fg($hex): ($hex | ltrimstr("#")) as $x | "\u001b[38;2;\($x[0:2]|_hex2int);\($x[2:4]|_hex2int);\($x[4:6]|_hex2int)m";
def c_glyph: _fg($palette.palette.white);    # bright white — the symbol/emoji itself
def c_key:   _fg($palette.palette.blue);     # blue — curated names / :code:
def c_auto:  _fg($palette.palette.mauve);    # mauve — synthetic EMOJI-/UNICODE- names
def c_code:  _fg($palette.palette.overlay1); # overlay1 — (U+XXXX) codepoint
def c_desc:  _fg($palette.palette.subtext0); # subtext0 — description / unicode name

# Wrap the input string in an SGR colour and a reset.
#   "foo" | paint(c_glyph)   →  "\e[…mfoo\e[0m"
def paint($sgr): $sgr + . + c_reset;

# Emit one picker line per the wire contract above. `$visible` is the
# coloured display portion; `$tail` is an array of plain-text fields
# (last element = raw char by convention). Joins the tail with \x1e
# and prefixes the \x1f display delimiter.
def emit_line($visible; $tail):
  $visible + "\u001f" + ($tail | map(tostring) | join("\u001e"));
