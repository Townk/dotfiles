--------------------------------------------------------------------------------
-- Doom-Modeline Custom Lualine Theme
--------------------------------------------------------------------------------
-- This theme creates a doom-emacs-inspired statusline with:
--   - Dynamic color extraction from the active colorscheme
--   - Custom components for file paths, LSP status, diagnostics, etc.
--   - Information-dense layout without clutter
--
-- Architecture:
--   1. extract() - Dynamically pulls colors from current colorscheme
--   2. colors table - Defines semantic color mappings with fallbacks
--   3. conditions - Helper functions for conditional component display
--   4. Custom components - Defined in lua/lualine/components/
--
-- WHY Dynamic Color Extraction:
--   Instead of hardcoding colors, we extract them from highlight groups.
--   This means the statusline adapts automatically when you change colorschemes.
--
-- Component Layout:
--   Left (lualine_a): Mode, filesize, dynamic file path, position, progress
--   Right (lualine_z): Selection, macro, LSP, treesitter, OpenCode, encoding,
--                       filetype, git branch, git diff, diagnostics
--------------------------------------------------------------------------------

-- Extract color from a highlight group dynamically
-- WHY: Allows statusline to adapt to any colorscheme automatically
local function extract(group, attr)
  local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
  if hl[attr] then
    return string.format("#%06x", hl[attr])  -- Convert to hex color string
  end
  return nil
end

local icons = LazyVim.config.icons

local colors = {
  fg = extract("Normal", "fg") or "#abb2bf",
  bg = extract("StatusLine", "bg") or "#282c34",
  fg_dark = extract("Comment", "fg") or "#5c6370",
  git_add = extract("DiagnosticOk", "fg") or extract("DiffAdd", "fg") or "#98c379",
  git_change = extract("DiagnosticWarn", "fg") or "#d19a66",
  git_remove = extract("DiagnosticError", "fg") or "#e06c75",
  diag_ok = extract("DiagnosticOk", "fg") or "#98c379",
  diag_info = extract("DiagnosticInfo", "fg") or "#56b6c2",
  diag_warn = extract("DiagnosticWarn", "fg") or "#d19a66",
  diag_error = extract("DiagnosticError", "fg") or "#e06c75",
  macro_recording = "#e06c75",
  filetype = "#61afef",
  mode_normal = extract("Function", "fg") or "#61afef",
  mode_insert = extract("String", "fg") or "#98c379",
  mode_visual = extract("DiagnosticWarn", "fg") or "#e5c07b",
  mode_replace = extract("DiagnosticError", "fg") or "#e06c75",
  mode_command = extract("Keyword", "fg") or "#c678dd",
  mode_terminal = extract("DiagnosticInfo", "fg") or "#56b6c2",
}

local SpecialTitle = require("lualine.components.special-title")

local conditions = {
  buffer_not_empty = function()
    return vim.fn.empty(vim.fn.expand("%:t")) ~= 1
  end,
  hide_in_width = function()
    return vim.fn.winwidth(0) > 80
  end,
  not_terminal = function()
    return vim.bo.buftype ~= "terminal"
  end,
  not_special_title = function()
    return not SpecialTitle.has_special_title()
  end,
}

local filetype_format = function(ft)
  local parts = {}
  for part in ft:gmatch("[^_%-]+") do
    parts[#parts + 1] = part:sub(1, 1):upper() .. part:sub(2):lower()
  end
  return table.concat(parts, "-")
end

-- Auto-refresh statusline when mode changes or macro recording starts/stops
-- WHY: Ensures vim-mode and macro-recording components update immediately
local lualine_refresh = vim.api.nvim_create_augroup("LuaLineRefreshers", { clear = true })

vim.api.nvim_create_autocmd({ "ModeChanged", "RecordingEnter", "RecordingLeave" }, {
  group = lualine_refresh,
  callback = function()
    vim.schedule(function()
      require("lualine").refresh()
    end)
  end,
})

return {
  options = {
    component_separators = "",
    section_separators = "",
    theme = {
      normal = { c = { fg = colors.fg, bg = colors.bg } },
      inactive = { c = { fg = colors.fg, bg = colors.bg } },
    },
    refresh = {
      statusline = 100,
    },
  },
  sections = {
    lualine_a = {
      {
        "vim-mode",
        padding = { left = 0, right = 2 },
      },
      {
        "filesize",
        color = { fg = colors.fg_dark },
        cond = conditions.not_terminal,
        padding = { left = 0, right = 2 },
      },
      {
        "special-title",
        padding = { left = 0, right = 2 },
      },
      {
        "dynamic-fqn",
        cond = function()
          return conditions.not_terminal() and conditions.not_special_title()
        end,
        padding = { left = 0, right = 2 },
      },
      {
        "location",
        color = { fg = colors.fg_dark },
        cond = function()
          return conditions.buffer_not_empty() and conditions.not_terminal()
        end,
        padding = { left = 0, right = 1 },
      },
      {
        "progress",
        color = { fg = colors.fg_dark },
        cond = function()
          return conditions.buffer_not_empty() and conditions.not_terminal()
        end,
        padding = { left = 0, right = 2 },
      },
    },
    lualine_b = {},
    lualine_c = {},
    lualine_x = {},
    lualine_y = {},
    lualine_z = {
      {
        "selectioncount",
        padding = { left = 1, right = 0 },
      },
      {
        "macro-recording",
        color = { fg = colors.macro_recording, gui = "bold" },
        padding = { left = 2, right = 0 },
      },
      {
        "lsp",
        padding = { left = 2, right = 0 },
      },
      {
        "treesitter",
        padding = { left = 1, right = 0 },
      },
      {
        "opencode",
        padding = { left = 1, right = 0 },
      },
      {
        "fileformat",
        symbols = {
          unix = "LF",
          dos = "CRLF",
          mac = "CR",
        },
        padding = { left = 2, right = 0 },
      },
      {
        "encoding",
        fmt = string.upper,
        padding = { left = 1, right = 0 },
      },
      {
        "filetype",
        icons_enabled = false,
        color = { fg = colors.filetype },
        fmt = filetype_format,
        padding = { left = 2, right = 0 },
      },
      {
        "branch",
        icon = "",
        color = { fg = colors.git_change, gui = "bold" },
        padding = { left = 2, right = 0 },
      },
      {
        "diff",
        symbols = { added = icons.git.added, modified = icons.git.modified, removed = icons.git.removed },
        diff_color = {
          added = { fg = colors.git_add },
          modified = { fg = colors.git_change },
          removed = { fg = colors.git_remove },
        },
        padding = { left = 2, right = 0 },
      },
      {
        "diagnostics",
        symbols = {
          error = icons.diagnostics.Error,
          warn = icons.diagnostics.Warn,
          info = icons.diagnostics.Info,
          hint = icons.diagnostics.Hint,
          ok = "✓ ",
        },
        padding = { left = 2, right = 0 },
      },
    },
  },
}
