# pick.jq — shared jq helpers for the fzf picker line emitters
#           (pick-glyph, pick-gitmoji, …).
#
# Off-PATH internal module, included by the picker scripts via:
#     jq -L "$HOME/.local/lib" 'include "pick"; … '
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

# --- Catppuccin Mocha palette (24-bit truecolor SGR sequences) ---
# fzf reads the assembled lines with `--ansi`, so these render as
# colour rather than literal text in the visible portion only.
def c_reset: "\u001b[0m";
def c_glyph: "\u001b[38;2;255;255;255m";   # bright white #ffffff — the symbol/emoji itself
def c_key:   "\u001b[38;2;137;180;250m";   # blue        #89b4fa — curated names / :code:
def c_auto:  "\u001b[38;2;203;166;247m";   # mauve       #cba6f7 — synthetic EMOJI-/UNICODE- names
def c_code:  "\u001b[38;2;127;132;156m";   # overlay1    #7f849c — (U+XXXX) codepoint
def c_desc:  "\u001b[38;2;166;173;200m";   # subtext0    #a6adc8 — description / unicode name

# Wrap the input string in an SGR colour and a reset.
#   "foo" | paint(c_glyph)   →  "\e[…mfoo\e[0m"
def paint($sgr): $sgr + . + c_reset;

# Emit one picker line per the wire contract above. `$visible` is the
# coloured display portion; `$tail` is an array of plain-text fields
# (last element = raw char by convention). Joins the tail with \x1e
# and prefixes the \x1f display delimiter.
def emit_line($visible; $tail):
  $visible + "\u001f" + ($tail | map(tostring) | join("\u001e"));
