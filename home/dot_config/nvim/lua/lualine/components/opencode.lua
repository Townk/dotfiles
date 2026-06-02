--------------------------------------------------------------------------------
-- OpenCode AI Assistant Status Indicator
--------------------------------------------------------------------------------
-- Displays OpenCode connection status with color-coded icons.
--
-- Status Colors:
--   - Idle (green): Connected and ready
--   - Responding (blue): AI is processing a request
--   - Requesting Permission (yellow): Waiting for user approval
--   - Error (red): Connection or processing error
--   - Disconnected (gray): Not connected to OpenCode server
--
-- Pre-computes status_map for O(1) lookup instead of if-else chains.
--------------------------------------------------------------------------------

local M = require("lualine.component"):extend()
local opencode_status_ok, opencode_status = pcall(require, "opencode.status")

local default_options = {
  icons = {
    idle = "󰚩",
    responding = "󱜙",
    requesting_permission = "󱚟",
    error = "󱚡",
    disconnected = "󱚧",
  },
  status_color = {
    idle = "#98c379",
    responding = "#61afef",
    requesting_permission = "#e5c07b",
    error = "#e06c75",
    disconnected = "#5c6370",
  },
}

function M:init(options)
  M.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", options or {}, default_options)
  self:create_highlight_groups()
  -- Pre-compute highlight lookup table to avoid if-else chains in update_status
  self.status_map = {
    idle = { hl = self.hl.idle, icon = self.options.icons.idle },
    responding = { hl = self.hl.responding, icon = self.options.icons.responding },
    requesting_permission = { hl = self.hl.requesting_permission, icon = self.options.icons.requesting_permission },
    error = { hl = self.hl.error, icon = self.options.icons.error },
    disconnected = { hl = self.hl.disconnected, icon = self.options.icons.disconnected },
  }
end

function M:create_highlight_groups()
  local c = self.options.status_color
  self.hl = {
    idle = self:create_hl({ fg = c.idle }, "opencode_idle"),
    responding = self:create_hl({ fg = c.responding }, "opencode_responding"),
    requesting_permission = self:create_hl({ fg = c.requesting_permission }, "opencode_permission"),
    error = self:create_hl({ fg = c.error }, "opencode_error"),
    disconnected = self:create_hl({ fg = c.disconnected }, "opencode_disconnected"),
  }
end

function M:update_status()
  if not opencode_status_ok then
    return ""
  end

  local status = opencode_status.status
  local config = self.status_map[status] or self.status_map.disconnected
  
  return self:format_hl(config.hl) .. config.icon
end

return M
