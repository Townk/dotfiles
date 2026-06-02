--------------------------------------------------------------------------------
-- LSP Status Indicator Component
--------------------------------------------------------------------------------
-- Shows LSP client status with animated spinner during processing.
--
-- WHY: Provides visual feedback when LSP is working (formatting, organizing
-- imports, etc.) so you know the editor is busy and not frozen.
--
-- Note: vim.lsp.status() is deprecated in NeoVim 0.10+, but kept for
-- compatibility. The component gracefully handles its absence.
--------------------------------------------------------------------------------

local M = require("lualine.component"):extend()

local default_options = {
  symbols = {
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    lsp = "",
  },
  status_color = { processing = "#5c6370", done = "#98c379" },
}

function M:init(options)
  M.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", options or {}, default_options)
  self.spinner_index = 1

  -- Static highlights
  self.groups = {
    processing = self:create_hl({ fg = self.options.status_color.processing }, "lsp_proc"),
    done = self:create_hl({ fg = self.options.status_color.done }, "lsp_done"),
  }
end

function M:update_status()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    return ""
  end
  
  -- Optimization: vim.lsp.status() is deprecated in newer versions (0.10+), 
  -- but we'll keep it for compatibility if user relies on it, or handle nil.
  -- In 0.10+, progress is typically handled via LspProgress event, but status() 
  -- might still work via plugins like lsp-status.nvim or internal shims.
  local progress_message = vim.lsp.status and vim.lsp.status() or ""

  local res = ""
  if #progress_message > 0 then
    local frame = self.options.symbols.spinner[self.spinner_index]
    self.spinner_index = (self.spinner_index % #self.options.symbols.spinner) + 1
    res = self:format_hl(self.groups.processing) .. frame .. " "
  end

  return res .. self:format_hl(self.groups.done) .. self.options.symbols.lsp
end

return M
