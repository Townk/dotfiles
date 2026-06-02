--------------------------------------------------------------------------------
-- Unicode Code-Point Utilities Module
--------------------------------------------------------------------------------
-- Shared logic for recognizing textual Unicode code-point escapes and turning
-- them into the glyphs they represent.
--
-- WHY Centralized:
-- Two features consume this: the `<leader>cu` conversion keymaps (which rewrite
-- escapes into glyphs in place) and the inline hint decoration provider (which
-- shows the glyph next to a detected escape). Keeping the patterns in one place
-- guarantees both recognize exactly the same tokens.
--
-- FORMATS:
--   \u{HEX}  variable length   e.g. \u{1F600}
--   U+HEX    variable length   e.g. U+1F600
--   \uHEX    exactly 4 digits  e.g. \u00E9   (JS/Java style; fixed width so
--                                             `\u1F600` is not ambiguous)
--------------------------------------------------------------------------------

local M = {}

-- Tried in order; the braceless `\u` form is last and requires 4 digits, so it
-- never swallows the `\u` of a `\u{...}` token.
M.patterns = {
  "\\u{(%x+)}", -- \u{1F600}
  "U%+(%x+)",   -- U+1F600
  "\\u(%x%x%x%x)", -- \u00E9
}

---Turn a hex string into the glyph for that code point.
---@param hex string Hexadecimal code point (e.g. "1F600")
---@return string glyph The UTF-8 encoded character
function M.glyph(hex)
  return vim.fn.nr2char(tonumber(hex, 16), true)
end

---Decode every recognized escape in `text`, returning the rewritten string.
---@param text string
---@return string decoded
function M.decode(text)
  for _, pattern in ipairs(M.patterns) do
    text = text:gsub(pattern, M.glyph)
  end
  return text
end

---Call `fn` for each escape found in `line`, leftmost first.
---Byte offsets are 0-indexed: `start` is the first byte of the token and
---`stop` is the exclusive end (the byte just past the token), so both map
---directly onto `nvim_buf_set_text`/`nvim_buf_set_extmark` columns.
---@param line string
---@param fn fun(start: integer, stop: integer, hex: string)
function M.each_match(line, fn)
  local from = 1
  while true do
    local best_s, best_e, best_hex
    for _, pattern in ipairs(M.patterns) do
      local s, e, hex = line:find(pattern, from)
      if s and (not best_s or s < best_s) then
        best_s, best_e, best_hex = s, e, hex
      end
    end
    if not best_s then
      return
    end
    fn(best_s - 1, best_e, best_hex)
    from = best_e + 1
  end
end

return M
