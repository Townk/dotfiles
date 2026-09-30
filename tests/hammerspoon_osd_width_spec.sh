# OSD toast sizing. Mode B (2026-09-29): "Copied from peer-laptop" rendered as
# "Copied from peer-" — the toast estimated its width at 7.2 pt per character,
# the real 14 pt system-font string came out wider, macOS wrapped it at the
# hyphen, and the one-line-high label hid the second line. The width must come
# from a real measurement, and a label that still overflows must truncate
# visibly ("…"), never wrap out of sight.

Describe 'Hammerspoon OSD toast width'
  osd() {  # osd <lua snippet using M and SCREEN>
    HAMMERSPOON_SPEC_ROOT="$PWD" SNIPPET="$1" lua <<'LUA'
local root = assert(os.getenv("HAMMERSPOON_SPEC_ROOT"))
package.path = root .. "/home/dot_config/hammerspoon/modules/?.lua;"
  .. root .. "/home/dot_config/hammerspoon/modules/?/init.lua;"
  .. package.path
package.preload["images"] = function() return {} end
local M = require("osd")
SCREEN = { x = 0, y = 0, w = 1440, h = 900 }
_G.M = M
assert((loadstring or load)(os.getenv("SNIPPET")))()
LUA
  }

  It 'sizes the toast from the measured text, not the per-character estimate'
    # 22 chars → the estimate alone fits the 210 pt minimum; a real measurement
    # of 200 pt must widen the toast so the label (width - 2*padding) holds it.
    When call osd 'local w = M._osdWidthForText("Copied from peer-laptop", SCREEN, function() return { w = 200, h = 17 } end); print(w >= 200 + 40)'
    The output should equal 'true'
  End

  It 'keeps the minimum width for short measured text'
    When call osd 'print(M._osdWidthForText("ok", SCREEN, function() return { w = 12, h = 17 } end))'
    The output should equal '210'
  End

  It 'never grows past the screen ratio cap'
    When call osd 'print(M._osdWidthForText("x", SCREEN, function() return { w = 5000, h = 17 } end))'
    The output should equal '1080'
  End

  It 'falls back to the estimate when no measurement is available'
    When call osd 'print(M._osdWidthForText(string.rep("a", 40), SCREEN, function() return nil end))'
    The output should equal '328'
  End

  It 'ignores ANSI colour codes when measuring'
    When call osd 'local seen; M._osdWidthForText({ type = "ansiText", value = "\27[1mbold\27[0m" }, SCREEN, function(s) seen = s; return { w = 30, h = 17 } end); print(seen)'
    The output should equal 'bold'
  End

  It 'truncates an overflowing label with an ellipsis instead of wrapping it out of sight'
    When call osd 'print(M._textParagraphStyle().lineBreak)'
    The output should equal 'truncateTail'
  End
End
