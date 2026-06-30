--------------------------------------------------------------------------------
-- Vim Mode Indicator Component
--------------------------------------------------------------------------------
-- Displays current Vim mode with integrated search count display.
--
-- Features:
--   - Mode indicator (●) with color matching the mode
--   - Search count display (N/M) when searching (integrated into left section)
--   - Pre-generated highlights for performance (no runtime highlight creation)
--
-- Optimization:
--   Removed recompute=1 from searchcount() to avoid expensive buffer scans on
--   every statusline redraw. Search count updates when you press n/N naturally.
--------------------------------------------------------------------------------

local M = require("lualine.component"):extend()

-- Pull a color from a highlight group so mode colors track the active colorscheme
-- (which is generated from .chezmoidata/theme.yaml). One Dark literals are the
-- fallback only when a group is unset.
local function extract(group, attr)
  local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
  if hl[attr] then
    return string.format("#%06x", hl[attr])
  end
  return nil
end

local default_options = {
  symbols = {
    bar = "▎",
    circle = "●",
  },
}

function M:init(options)
  M.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", options or {}, default_options)

  -- Mode colors follow the colorscheme (same highlight-group mapping the
  -- doom-modeline theme uses), so the indicator changes with theme.yaml.
  self.options.mode_colors = self.options.mode_colors
    or {
      normal = extract("Function", "fg") or "#61afef",
      insert = extract("String", "fg") or "#98c379",
      visual = extract("DiagnosticWarn", "fg") or "#e5c07b",
      replace = extract("DiagnosticError", "fg") or "#e06c75",
      command = extract("Keyword", "fg") or "#c678dd",
      terminal = extract("DiagnosticInfo", "fg") or "#56b6c2",
    }
  -- Inverted swatch foreground = the editor background (was a hardcoded value).
  self.inverted_fg = extract("Normal", "bg") or "#282c34"

  -- 1. Mode Map
  self.mode_map = {
    ["n"] = "normal",
    ["no"] = "normal",
    ["nov"] = "normal",
    ["noV"] = "normal",
    ["no\22"] = "normal",
    ["niI"] = "normal",
    ["niR"] = "normal",
    ["niV"] = "normal",
    ["i"] = "insert",
    ["ic"] = "insert",
    ["ix"] = "insert",
    ["v"] = "visual",
    ["V"] = "visual",
    ["\22"] = "visual",
    ["s"] = "visual",
    ["S"] = "visual",
    ["\19"] = "visual",
    ["R"] = "replace",
    ["Rc"] = "replace",
    ["Rv"] = "replace",
    ["Rx"] = "replace",
    ["c"] = "command",
    ["cv"] = "command",
    ["ce"] = "command",
    ["r"] = "replace",
    ["rm"] = "replace",
    ["r?"] = "replace",
    ["!"] = "command",
    ["t"] = "terminal",
  }

  -- 2. Pre-generate Highlights (The Fix)
  -- We store them in a table to look them up by mode name later
  self.highlights = {}
  for mode_name, color_hex in pairs(self.options.mode_colors) do
    self.highlights[mode_name] = {
      standard = self:create_hl({ fg = color_hex }, "mode_" .. mode_name),
      inverted = self:create_hl({ fg = self.inverted_fg, bg = color_hex }, "mode_inv_" .. mode_name),
    }
  end
end

function M:update_status()
  local mode_code = vim.api.nvim_get_mode().mode
  local mode_key = self.mode_map[mode_code] or "normal"

  -- Lookup the pre-generated highlight groups
  local active_hl = self.highlights[mode_key]

  local left_part = ""
  -- Handle Search Logic
  if vim.v.hlsearch ~= 0 and mode_code ~= "c" then
    -- OPTIMIZATION: Removed { recompute = 1 } to avoid expensive buffer scan on every redraw.
    -- The search count will update when n/N is pressed or search changes naturally.
    local ok, search = pcall(vim.fn.searchcount, { maxcount = 999, timeout = 100 })
    local current = ok and tonumber(search.current) or 0
    local total = ok and tonumber(search.total) or 0
    if total > 0 then
      -- Use the pre-generated inverted highlight
      left_part = string.format(
        "%s %d/%d %s ",
        self:format_hl(active_hl.inverted),
        current,
        total,
        self:format_hl(active_hl.standard)
      )
    else
      left_part = self:format_hl(active_hl.standard) .. self.options.symbols.bar
    end
  else
    left_part = self:format_hl(active_hl.standard) .. self.options.symbols.bar
  end

  return left_part .. self.options.symbols.circle
end

return M
