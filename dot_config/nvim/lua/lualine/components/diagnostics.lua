--------------------------------------------------------------------------------
-- LSP Diagnostics Counter Component
--------------------------------------------------------------------------------
-- Displays count of LSP diagnostics by severity (errors, warnings, info, hints).
--
-- Performance Optimization:
--   Uses vim.diagnostic.count() instead of vim.diagnostic.get() to avoid
--   allocating full diagnostic objects. This significantly reduces overhead
--   since we only need counts, not the full diagnostic data.
--------------------------------------------------------------------------------

local M = require("lualine.component"):extend()

local default_options = {
  symbols = {
    error = " ",
    warn = " ",
    info = " ",
    hint = " ",
    ok = "✓ ",
  },
}

local hl_groups = {
  [vim.diagnostic.severity.ERROR] = "DiagnosticError",
  [vim.diagnostic.severity.WARN] = "DiagnosticWarn",
  [vim.diagnostic.severity.INFO] = "DiagnosticInfo",
  [vim.diagnostic.severity.HINT] = "DiagnosticHint",
}
local ok_hl = "DiagnosticOk"

function M:init(options)
  M.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", options or {}, default_options)
end

function M:update_status()
  local bufnr = vim.api.nvim_get_current_buf()

  -- Optimization: Use count() instead of get() to avoid allocating full diagnostic objects
  -- This returns a table { [severity] = count, ... } or nil/empty
  local counts = vim.diagnostic.count(bufnr)
  local total = 0

  if counts then
    for _, count in pairs(counts) do
      total = total + count
    end
  end

  if total == 0 then
    if vim.diagnostic.is_enabled and vim.diagnostic.is_enabled({ bufnr = bufnr }) then
      return "%#" .. ok_hl .. "#" .. self.options.symbols.ok
    end
    return ""
  end

  local result = {}
  local symbols = self.options.symbols

  -- Check severities in order: Error(1), Warn(2), Info(3), Hint(4)
  local severities = {
    vim.diagnostic.severity.ERROR,
    vim.diagnostic.severity.WARN,
    vim.diagnostic.severity.INFO,
    vim.diagnostic.severity.HINT,
  }

  -- Map for symbol keys matching options
  local severity_keys = {
    [vim.diagnostic.severity.ERROR] = "error",
    [vim.diagnostic.severity.WARN] = "warn",
    [vim.diagnostic.severity.INFO] = "info",
    [vim.diagnostic.severity.HINT] = "hint",
  }

  for _, sev in ipairs(severities) do
    local c = counts[sev] or 0
    if c > 0 then
      local hl = hl_groups[sev]
      local sym = symbols[severity_keys[sev]]
      table.insert(result, "%#" .. hl .. "#" .. sym .. c .. " ")
    end
  end

  return table.concat(result, " ")
end

return M
