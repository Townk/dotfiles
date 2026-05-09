--------------------------------------------------------------------------------
-- Treesitter Status Indicator
--------------------------------------------------------------------------------
-- Shows whether treesitter highlighting is active for the current buffer.
--
-- Colors:
--   - Green/bold: Treesitter highlighting is active
--   - Gray: AST available but highlighting not enabled
--
-- Optimization: Checks ts_highlighter.active table directly instead of calling
-- get_parser(), which is faster since we only need active status, not the parser.
--------------------------------------------------------------------------------

local M = require("lualine.component"):extend()
local ts_highlighter = require("vim.treesitter.highlighter")

local default_options = {
  symbol = "󰙅",
  status_color = {
    ast_available = "#5c6370",
    highlight_enabled = "#98c379",
  },
}

function M:init(options)
  M.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", options or {}, default_options)
  self.hl_active = self:create_hl({ fg = self.options.status_color.highlight_enabled, bold = true }, "ts_active")
  self.hl_inactive = self:create_hl({ fg = self.options.status_color.ast_available }, "ts_inactive")
end

function M:update_status()
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- Optimization: Check highlighter active table directly instead of calling get_parser
  local is_hl_active = ts_highlighter.active[bufnr] ~= nil

  local hl = is_hl_active and self.hl_active or self.hl_inactive
  return self:format_hl(hl) .. self.options.symbol
end

return M
