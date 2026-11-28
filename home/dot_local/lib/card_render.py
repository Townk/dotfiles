"""card_render — shared card renderer for the Python terminal viewers.

Single home for the rounded-card drawing code that sqlite-view and
disk-image-view used to carry as private copies: the palette binding (CTP),
the ANSI SGR helpers, the Style design tokens, the ANSI-aware width / truncate
/ wrap helpers, human_bytes, and CardRenderer itself. ics-view imports only
the pieces it shares byte-for-byte (CTP, the SGR helpers, _ANSI_RE and the
Style tokens); its own CardRenderer has diverged and stays in that script.

Imported the same way as theme_palette: the viewer puts the lib dir
(``$THEME_PYLIB_DIR``, default ``~/.local/lib``) on sys.path — after setting
``sys.dont_write_bytecode`` — and imports this module, which in turn imports
theme_palette from that same directory. The palette is read at import, so a
theme override is picked up on the next invocation.

Pure standard library; no third-party dependencies. Deployed verbatim by
chezmoi to ~/.local/lib/card_render.py.

Public API:
    CTP                      palette class (CTP.LAVENDER -> (r, g, b)).
    _fg _bg _bold _dim _reset   ANSI SGR helpers.
    Style                    colour + box-drawing tokens; viewers subclass it
                             to add their own ICON_* glyphs.
    visual_width, truncate_visual, wrap_ansi   ANSI-aware text helpers.
    human_bytes              byte count -> "1.5 KiB" ("?" for None).
    CardRenderer             card rows and borders; viewers subclass it and set
                             ``style_class`` to their Style.
"""

from __future__ import annotations

import re

from theme_palette import palette_type

# Catppuccin Mocha truecolor palette, built from the shared theme_palette source.
CTP = palette_type()


def _fg(r: int, g: int, b: int) -> str:
    return f"\033[38;2;{r};{g};{b}m"


def _bg(r: int, g: int, b: int) -> str:
    return f"\033[48;2;{r};{g};{b}m"


def _bold() -> str:
    return "\033[1m"


def _dim() -> str:
    return "\033[2m"


def _reset() -> str:
    return "\033[0m"


class Style:
    """Design tokens every card shares. Viewers subclass it to add ICON_* glyphs."""

    primary = _fg(*CTP.LAVENDER)
    secondary = _fg(*CTP.BLUE)
    accent = _fg(*CTP.MAUVE)
    success = _fg(*CTP.GREEN)
    warning = _fg(*CTP.YELLOW)
    danger = _fg(*CTP.RED)
    info = _fg(*CTP.SKY)
    muted = _fg(*CTP.OVERLAY1)
    subtle = _fg(*CTP.SUBTEXT0)
    text = _fg(*CTP.TEXT)
    bg_accent = _bg(*CTP.SURFACE0)

    # The one icon the renderer itself draws (CardRenderer.error_card).
    ICON_WARN = ""

    PILL_LEFT = ""
    PILL_RIGHT = ""
    CORNER_TL = "╭"
    CORNER_TR = "╮"
    CORNER_BL = "╰"
    CORNER_BR = "╯"
    HORIZ = "─"
    VERT = "│"
    T_LEFT = "├"
    T_RIGHT = "┤"
    MIDDOT = "·"


_ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def visual_width(text: str) -> int:
    return len(_ANSI_RE.sub("", text))


def truncate_visual(text: str, width: int, ellipsis: str = "...") -> str:
    plain = _ANSI_RE.sub("", text)
    if len(plain) <= width:
        return text
    leading_ansi = ""
    m = re.match(r"(\033\[[0-9;]*m)+", text)
    if m:
        leading_ansi = m.group(0)
    return leading_ansi + plain[: max(0, width - len(ellipsis))] + ellipsis + _reset()


def wrap_ansi(content: str, width: int) -> list[str]:
    """Word-wrap `content` to `width` visible columns while preserving ANSI SGR.

    Mirrors sqlite-view's wrap_plain word semantics (split on whitespace,
    single-space joins, hard-break overlong words) but keeps color: inline
    codes are retained, the style active at each line's start is re-opened, and
    every emitted line ends reset. wrap_plain cannot do this -- it strips the
    escapes, so a wrapped row would render colorless.
    """
    if width <= 0:
        return [""]

    active = ""

    def apply(code: str) -> None:
        nonlocal active
        active = "" if code in ("\033[0m", "\033[m") else active + code

    # Tokenise into words, recording the SGR state active at each word's start.
    tokens: list[tuple[str, int, str]] = []  # (text_with_sgr, visible_width, style_before)
    cur_text, cur_w, cur_before, in_word = "", 0, "", False
    i, n = 0, len(content)
    while i < n:
        m = _ANSI_RE.match(content, i)
        if m:
            if in_word:
                cur_text += m.group(0)
            apply(m.group(0))
            i = m.end()
            continue
        ch = content[i]
        i += 1
        if ch == " ":  # break only on ASCII space; NBSP keeps a pill intact
            if in_word:
                tokens.append((cur_text, cur_w, cur_before))
                cur_text, cur_w, in_word = "", 0, False
        else:
            if not in_word:
                in_word, cur_before, cur_text, cur_w = True, active, "", 0
            cur_text += ch
            cur_w += 1
    if in_word:
        tokens.append((cur_text, cur_w, cur_before))

    if not tokens:
        return []

    # Greedily pack words into lines. Each word re-emits the SGR state active at
    # its start (`before`), so it is styled correctly wherever it lands, not just
    # when it opens a line. The powerline pill caps depend on this: their colour
    # is set by an SGR that sits on the whitespace just before the glyph, which
    # would otherwise be lost (colourless caps) or replaced by the leftover pill
    # background (inverted caps).
    lines: list[str] = []
    line, line_w = "", 0

    def flush() -> None:
        nonlocal line, line_w
        lines.append(line + _reset())
        line, line_w = "", 0

    for text, word_w, before in tokens:
        if word_w > width:  # overlong word: flush, then hard-break its glyphs
            if line_w > 0:
                flush()
            plain = _ANSI_RE.sub("", text)
            for j in range(0, len(plain), width):
                lines.append(before + plain[j : j + width] + _reset())
            continue
        sep = 1 if line_w > 0 else 0
        if line_w + sep + word_w > width:
            flush()
            sep = 0
        if sep:
            line += " "
            line_w += 1
        line += before + text
        line_w += word_w
    if line:
        flush()
    return lines


def human_bytes(size: int | float | None) -> str:
    if size is None:
        return "?"
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{size} B"


class CardRenderer:
    # The Style the card is drawn with. A viewer points this at its own Style
    # subclass so `renderer.s` also carries that viewer's ICON_* glyphs.
    style_class: type[Style] = Style

    def __init__(self, width: int):
        self.w = max(44, width)
        self.s = self.style_class()
        self._reset = _reset()

    def _top_border(self, title: str = "") -> str:
        if title:
            title = " " + truncate_visual(title, self.w - 4) + " "
            fill = max(0, self.w - 2 - visual_width(title))
            return (
                self.s.primary
                + self.s.CORNER_TL
                + title
                + self.s.primary
                + self.s.HORIZ * fill
                + self.s.CORNER_TR
                + self._reset
            )
        return self.s.primary + self.s.CORNER_TL + self.s.HORIZ * (self.w - 2) + self.s.CORNER_TR + self._reset

    def _mid_border(self, label: str = "") -> str:
        if not label:
            return self.s.primary + self.s.T_LEFT + self.s.HORIZ * (self.w - 2) + self.s.T_RIGHT + self._reset
        label = truncate_visual(label.strip(), self.w - 8)
        labeled = f"{self.s.HORIZ} {label} "
        fill = max(0, self.w - 2 - visual_width(labeled))
        return (
            self.s.primary
            + self.s.T_LEFT
            + labeled
            + self.s.HORIZ * fill
            + self.s.T_RIGHT
            + self._reset
        )

    def _section_divider(self, label: str) -> list[str]:
        inner_w = self.w - 2
        label = truncate_visual(label.strip(), max(1, inner_w - 5))
        label_w = visual_width(label)
        title_w = label_w + 2
        divider = _fg(*CTP.OVERLAY1)
        title = _fg(*CTP.BASE) + _bg(*CTP.OVERLAY1) + f" {label} " + self._reset

        top_rule = "▁" * max(0, inner_w - 4)
        bottom_rule = "▔" * min(max(1, title_w), inner_w - 2)

        top = (
            self.s.primary + self.s.VERT + self._reset
            + "  " + divider + top_rule + self._reset
            + "  " + self.s.primary + self.s.VERT + self._reset
        )
        middle = (
            self.s.primary + self.s.VERT + self._reset
            + "  " + title + " " * max(0, inner_w - 2 - title_w)
            + self.s.primary + self.s.VERT + self._reset
        )
        bottom = (
            self.s.primary + self.s.VERT + self._reset
            + "  " + divider + bottom_rule + self._reset
            + " " * max(0, inner_w - 2 - visual_width(bottom_rule))
            + self.s.primary + self.s.VERT + self._reset
        )
        return [top, middle, bottom]

    def _bottom_border(self) -> str:
        return self.s.primary + self.s.CORNER_BL + self.s.HORIZ * (self.w - 2) + self.s.CORNER_BR + self._reset

    def _blank_row(self) -> str:
        return self.s.primary + self.s.VERT + " " * (self.w - 2) + self.s.VERT + self._reset

    def _row(self, content: str, prefix: str = "", indent: int = 3, right_indent: int | None = None, blank_between: bool = False) -> str:
        right_pad = right_indent if right_indent is not None else indent
        margin = " " * indent
        inner_w = self.w - 2 - indent - right_pad
        if prefix:
            prefix_w = visual_width(prefix)
            margin += prefix + " "
            inner_w -= prefix_w + 1

        plain = _ANSI_RE.sub("", content)
        if len(plain) <= inner_w:
            return (
                self.s.primary + self.s.VERT + self._reset
                + margin + content + " " * (inner_w - len(plain)) + " " * right_pad
                + self.s.primary + self.s.VERT + self._reset
            )

        lines = wrap_ansi(content, inner_w)
        out = []
        continuation_indent = indent + (visual_width(prefix) + 1 if prefix else 0)
        for i, line in enumerate(lines):
            pre = margin if i == 0 else " " * continuation_indent
            out.append(
                self.s.primary + self.s.VERT + self._reset
                + pre + line + " " * (inner_w - visual_width(line)) + " " * right_pad
                + self.s.primary + self.s.VERT + self._reset
            )
        # When asked (used for the pill row), separate wrapped lines with a blank
        # card row so multi-line pills breathe instead of stacking tightly.
        joiner = "\n" + self._blank_row() + "\n" if blank_between else "\n"
        return joiner.join(out)

    def _pill(self, text: str, rgb: tuple[int, int, int]) -> str:
        r, g, b = rgb
        br, bg, bb = CTP.BASE
        # Pad and space the label with non-breaking spaces so wrap_ansi treats
        # the whole pill as one unbreakable word: a pill that would not fit on
        # the current line moves to the next line intact, never splitting.
        body = " " + text.replace(" ", " ") + " "
        left = f"\033[38;2;{r};{g};{b};49m{self.s.PILL_LEFT}\033[0m"
        middle = f"\033[38;2;{br};{bg};{bb};48;2;{r};{g};{b}m{body}\033[0m"
        right = f"\033[38;2;{r};{g};{b};49m{self.s.PILL_RIGHT}\033[0m"
        return left + middle + right

    def error_card(self, label: str, message: str) -> str:
        """A whole card reporting `message`, titled with the viewer's `label`."""
        s = self.s
        return "\n".join(
            [
                self._top_border(f"{s.ICON_WARN} {label}"),
                self._blank_row(),
                self._row(f"{s.danger}{message}{_reset()}", prefix=f"{s.danger}{s.ICON_WARN}{_reset()}"),
                self._blank_row(),
                self._bottom_border(),
            ]
        )
