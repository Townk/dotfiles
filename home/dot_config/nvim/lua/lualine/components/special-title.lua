--------------------------------------------------------------------------------
-- Special Buffer Title Component
--------------------------------------------------------------------------------
-- Provides custom title rendering for special buffer types in lualine.
-- Replaces the default filename display with context-aware titles for
-- plugin buffers (Help, Trouble, Snacks, OpenCode, etc.).
--
-- Architecture:
--   - Preset System: Built-in detectors and renderers for common plugins
--   - Priority-based: Higher priority presets are checked first
--   - Extensible: Users can add custom cases via options
--   - Cached: Results are cached per buffer for performance
--   - Mutual Exclusion: Works with dynamic-fqn via exported condition
--
-- Usage in lualine config:
--   {
--     "special-title",
--     active_presets = { "opencode", "help", "trouble" },
--     custom_cases = {
--       my_plugin = {
--         priority = 250,
--         detect = function(bufnr) return vim.bo[bufnr].filetype == "myplugin" end,
--         render = function(bufnr, icons, opts) return "My Plugin" end,
--       },
--     },
--   }
--
-- Mutual Exclusion with dynamic-fqn:
--   Use the exported condition function to hide dynamic-fqn when special title exists:
--   {
--     "dynamic-fqn",
--     cond = function()
--       local SpecialTitle = require("lualine.components.special-title")
--       return not SpecialTitle.has_special_title()
--     end,
--   }
--
-- Built-in Presets:
--   - opencode (200): OpenCode terminal with version
--   - snacks_explorer (150): File explorer with truncated project root
--   - snacks_picker (140): Snacks picker with dynamic title
--   - trouble (130): Trouble diagnostics window with mode
--   - help (100): Help pages with formatted subject
--   - quickfix (90): Quickfix/Location list
--   - terminal (10): Terminal buffers with shell name
--
-- Preset Structure:
--   {
--     priority = 100,  -- Higher = checked first
--     detect = function(bufnr) -> boolean,
--     render = function(bufnr, icons, options) -> string,
--   }
--------------------------------------------------------------------------------

local PathUtils = require("utils.path")

local M = require("lualine.component"):extend()

M._has_special_title_cache = {}
M._opencode_version_cache = nil

M.presets = {}

M.presets.help = {
  priority = 100,
  detect = function(bufnr)
    return vim.bo[bufnr].buftype == "help" or vim.bo[bufnr].filetype == "help"
  end,
  render = function(bufnr, icons)
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local filename = vim.fn.fnamemodify(filepath, ":t")
    local subject = filename:gsub("%.txt$", ""):gsub("^@", "")
    subject = subject:gsub("-", " ")
    subject = subject:gsub("(%w)(%w*)", function(first, rest)
      return first:upper() .. rest:lower()
    end)
    return icons.help .. " Help: " .. subject
  end,
}

M.presets.terminal = {
  priority = 10,
  detect = function(bufnr)
    return vim.bo[bufnr].buftype == "terminal"
  end,
  render = function(bufnr, icons)
    local shell = vim.fn.fnamemodify(vim.o.shell, ":t")
    return icons.terminal .. " " .. shell
  end,
}

M.presets.quickfix = {
  priority = 90,
  detect = function(bufnr)
    return vim.bo[bufnr].buftype == "quickfix"
  end,
  render = function(bufnr, icons)
    local winid = vim.fn.win_getid()
    local wininfo = vim.fn.getwininfo(winid)[1]
    if wininfo and wininfo.loclist == 1 then
      return icons.location .. " Location List"
    else
      return icons.quickfix .. " Quickfix List"
    end
  end,
}

M.presets.opencode = {
  priority = 200,
  detect = function(bufnr)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    return bufname:match("opencode") or vim.b[bufnr].opencode
  end,
  render = function(bufnr, icons)
    if not M._opencode_version_cache then
      M._opencode_version_cache = "v0.0.0"
      local handle = io.popen("opencode --version 2>/dev/null")
      if handle then
        local result = handle:read("*a")
        handle:close()
        if result and result ~= "" then
          M._opencode_version_cache = result:gsub("^%s*", ""):gsub("%s*$", "")
        end
      end
    end
    return icons.opencode .. " OpenCode " .. M._opencode_version_cache
  end,
}

M.presets.snacks_picker = {
  priority = 140,
  detect = function(bufnr)
    local ft = vim.bo[bufnr].filetype
    if ft ~= "snacks_picker_list" and ft ~= "snacks_picker_input" then
      return false
    end
    local ok, picker = pcall(function()
      return require("snacks.picker").current
    end)
    if ok and picker and picker.opts then
      return not (picker.opts.source == "files" and picker.opts.layout == "sidebar")
    end
    return true
  end,
  render = function(bufnr, icons, options)
    local ok, title = pcall(function()
      return require("snacks.picker").get()[1].title
    end)

    if ok and title ~= "" then
      return icons.picker .. " " .. title
    end
    return icons.picker .. " Picker"
  end,
}

M.presets.snacks_explorer = {
  priority = 150,
  detect = function(bufnr)
    if M.presets.snacks_picker.detect(bufnr) then
      local ok, picker_source = pcall(function()
        return require("snacks.picker").get()[1].init_opts.source
      end)
      return ok and picker_source == "explorer"
    end
    return false
  end,
  render = function(bufnr, icons, options)
    local cwd = vim.fn.getcwd()
    local display_cwd = PathUtils.truncate_path(cwd, options.max_cwd_len, true)
    return icons.explorer .. " " .. display_cwd
  end,
}

M.presets.trouble = {
  priority = 130,
  detect = function(bufnr)
    return vim.bo[bufnr].filetype:match("^trouble")
  end,
  render = function(bufnr, icons)
    local ft = vim.bo[bufnr].filetype
    local mode = ft:match("^trouble_(.+)$") or "Workspace"
    mode = mode:gsub("^%l", string.upper)
    return icons.trouble .. " Trouble: " .. mode
  end,
}

local default_options = {
  icons = {
    help = "󰋖",
    explorer = "󰙅",
    picker = "󰍉",
    opencode = "󰧑",
    terminal = "󰆍",
    quickfix = "󰁨",
    location = "󰁨",
    trouble = "󰙨",
  },
  max_cwd_len = 30,
  active_presets = {
    "opencode",
    "snacks_explorer",
    "snacks_picker",
    "trouble",
    "help",
    "quickfix",
    "terminal",
  },
  custom_cases = {},
}

function M:init(options)
  M.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", options or {}, default_options)

  self.special_cases = {}

  for _, preset_name in ipairs(self.options.active_presets) do
    local preset = M.presets[preset_name]
    if preset then
      table.insert(self.special_cases, {
        name = preset_name,
        priority = preset.priority,
        detect = preset.detect,
        render = preset.render,
      })
    end
  end

  for name, case in pairs(self.options.custom_cases or {}) do
    table.insert(self.special_cases, {
      name = name,
      priority = case.priority or 0,
      detect = case.detect,
      render = case.render,
    })
  end

  table.sort(self.special_cases, function(a, b)
    return a.priority > b.priority
  end)

  self:setup_autocmds()
end

function M:setup_autocmds()
  local group = vim.api.nvim_create_augroup("LualineSpecialTitleCache", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufLeave" }, {
    group = group,
    callback = function(args)
      M._has_special_title_cache[args.buf] = nil
    end,
  })
end

function M.get_special_title(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local cached = M._has_special_title_cache[bufnr]
  if cached ~= nil then
    -- cached can be a title string, false (no special title), or nil (uncached)
    -- Return nil when cached is false to indicate no special title
    return cached ~= false and cached or nil
  end

  local lualine = require("lualine")
  local config = lualine.get_config()

  local special_case_list = {}
  if config and config.sections then
    for _, section in pairs(config.sections) do
      if type(section) == "table" then
        for _, component in ipairs(section) do
          if type(component) == "table" and component[1] == "special-title" then
            local opts = vim.tbl_deep_extend("keep", component, default_options)
            for _, preset_name in ipairs(opts.active_presets or {}) do
              local preset = M.presets[preset_name]
              if preset then
                table.insert(special_case_list, {
                  priority = preset.priority,
                  detect = preset.detect,
                  render = function(b)
                    return preset.render(b, opts.icons, opts)
                  end,
                })
              end
            end
            for _, case in pairs(opts.custom_cases or {}) do
              table.insert(special_case_list, {
                priority = case.priority or 0,
                detect = case.detect,
                render = function(b)
                  return case.render(b, opts.icons, opts)
                end,
              })
            end
            break
          end
        end
      end
    end
  end

  table.sort(special_case_list, function(a, b)
    return a.priority > b.priority
  end)

  for _, case in ipairs(special_case_list) do
    if case.detect(bufnr) then
      local title = case.render(bufnr)
      M._has_special_title_cache[bufnr] = title
      return title
    end
  end

  M._has_special_title_cache[bufnr] = false
  return nil
end

function M.has_special_title()
  return M.get_special_title() ~= nil
end

function M:update_status()
  local bufnr = vim.api.nvim_get_current_buf()

  for _, case in ipairs(self.special_cases) do
    if case.detect(bufnr) then
      local title = case.render(bufnr, self.options.icons, self.options)
      M._has_special_title_cache[bufnr] = title
      return title
    end
  end

  M._has_special_title_cache[bufnr] = false
  return nil
end

return M
