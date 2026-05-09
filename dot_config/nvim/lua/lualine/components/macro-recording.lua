--------------------------------------------------------------------------------
-- Macro Recording Indicator
--------------------------------------------------------------------------------
-- Displays the register being recorded to when recording a macro.
--
-- Shows: "@a" (if recording to register 'a'), or nothing if not recording.
--
-- WHY: Easy to forget you're recording a macro and accidentally record unwanted
-- actions. This visual indicator prevents that.
--------------------------------------------------------------------------------

local M = require("lualine.component"):extend()

local default_options = {
  symbol = " @",
}

function M:init(options)
  M.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", options or {}, default_options)
end

function M:update_status()
  local recording_reg = vim.fn.reg_recording()
  if recording_reg == "" then
    return ""
  end

  return self.options.symbol .. recording_reg
end

return M
