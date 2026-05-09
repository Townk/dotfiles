--------------------------------------------------------------------------------
-- Dynamic Fully-Qualified Name (File Path) Component
--------------------------------------------------------------------------------
-- This lualine component displays the current file's path with intelligent
-- abbreviation based on available screen space. It shows project-relative paths
-- with visual hierarchy (project root in bold, less significant dirs dimmed).
--
-- Key Features:
--   - Project root detection (looks for .git, package.json, etc.)
--   - Intelligent abbreviation algorithm (abbreviates from left, keeps important parts)
--   - Caching (file paths, project roots, file sizes) for performance
--   - Visual hierarchy through color coding
--   - Modified/readonly indicators
--
-- Algorithm Overview:
--   1. Parse path into segments: pre-root / project-root / less-significant / most-significant / filename
--   2. Calculate available width (statusline width minus other components)
--   3. Abbreviate segments from left to right until path fits
--   4. Add ellipsis (…) to abbreviated segments
--   5. Color-code segments by importance
--
-- WHY This Complexity:
--   Long file paths can dominate the statusline. This component ensures you
--   always see the most important parts (filename, parent dir, project root)
--   while gracefully abbreviating less critical parent directories.
--------------------------------------------------------------------------------

local M = require("lualine.component"):extend()

local default_options = {
  root_markers = {
    ".git",
    "pyproject.toml",
    "package.json",
    "Cargo.toml",
    "go.mod",
    "Makefile",
    ".hg",
    ".svn",
  },
  icons = {
    readonly = "󰌾",
    modified = "󰆓",
  },
  colors = {
    filename = "#ffffff",
    directories = "#85b860",
    important_directories = "#98c379",
    non_project_directories = "#5c6370",
    modified = "#e06c75",
    readonly = "#e5c07b",
  },
  min_filename_len = 3,
  max_statusline_area = 0.5, -- use up to 50% of the status line
}

function M:init(options)
  M.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", options or {}, default_options)
  self.home = vim.env.HOME or ""
  self.home_len = #self.home
  self:create_highlight_groups()

  -- Cache tables
  self.icon_hl_cache = {}
  self.root_cache = {}
  self.fsize_cache = {}
  self.parsed_path_cache = {}

  -- Setup autocmds to invalidate cache
  self:setup_autocmds()
end

function M:setup_autocmds()
  local group = vim.api.nvim_create_augroup("LualineDynamicFqnCache", { clear = true })

  vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter" }, {
    group = group,
    callback = function(args)
      -- Invalidate caches for the specific buffer
      self.fsize_cache[args.buf] = nil
      self.parsed_path_cache[args.buf] = nil
    end,
  })
end

function M:create_highlight_groups()
  local c = self.options.colors
  self.hl = {
    pre_root = self:create_hl({ fg = c.non_project_directories }, "fqn_pre_root"),
    project_root = self:create_hl({ fg = c.important_directories, gui = "bold" }, "fqn_project_root"),
    less_significant = self:create_hl({ fg = c.directories }, "fqn_less_sig"),
    most_significant = self:create_hl({ fg = c.important_directories, gui = "bold" }, "fqn_most_sig"),
    filename = self:create_hl({ fg = c.filename, gui = "bold" }, "fqn_filename"),
    modified = self:create_hl({ fg = c.modified, gui = "bold" }, "fqn_modified"),
    readonly = self:create_hl({ fg = c.readonly }, "fqn_readonly"),
  }
  self.hl_modified_map = {
    pre_root = self.hl.modified,
    project_root = self.hl.modified,
    less_significant = self.hl.modified,
    most_significant = self.hl.modified,
    filename = self.hl.modified,
  }
  self.hl_normal_map = {
    pre_root = self.hl.pre_root,
    project_root = self.hl.project_root,
    less_significant = self.hl.less_significant,
    most_significant = self.hl.most_significant,
    filename = self.hl.filename,
  }
end

function M:get_filetype_icon()
  local ft = vim.bo.filetype
  local cached = self.icon_hl_cache[ft]
  if cached then
    return cached.icon, cached.hl
  end

  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local filename = vim.fn.expand("%:t")
    local extension = vim.fn.expand("%:e")
    local icon, icon_color = devicons.get_icon_color(filename, extension)
    if icon and icon_color then
      local hl = self:create_hl({ fg = icon_color }, "fqn_icon_" .. ft)
      self.icon_hl_cache[ft] = { icon = icon, hl = hl }
      return icon, hl
    end
  end

  self.icon_hl_cache[ft] = { icon = "", hl = nil }
  return "", nil
end

function M:find_project_root(bufnr)
  local cached = self.root_cache[bufnr]
  if cached ~= nil then
    return cached
  end

  local root
  if vim.fs.root then
    root = vim.fs.root(bufnr, self.options.root_markers)
  else
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath ~= "" then
      local dir = vim.fn.fnamemodify(filepath, ":h")
      for _, marker in ipairs(self.options.root_markers) do
        local found = vim.fs.find(marker, { path = dir, upward = true, stop = self.home })
        if #found > 0 then
          root = vim.fn.fnamemodify(found[1], ":h")
          break
        end
      end
    end
  end

  self.root_cache[bufnr] = root or false
  return root
end

function M:parse_path(filepath, bufnr)
  -- Use cache if available
  if self.parsed_path_cache[bufnr] then
    return self.parsed_path_cache[bufnr]
  end

  local project_root = self:find_project_root(bufnr)
  local dir = vim.fn.fnamemodify(filepath, ":h")
  local filename = vim.fn.fnamemodify(filepath, ":t")

  local pre_root, proj_root_name, less_sig, most_sig = "", "", "", ""

  if project_root then
    proj_root_name = vim.fn.fnamemodify(project_root, ":t") .. "/"
    pre_root = vim.fn.fnamemodify(project_root, ":h") .. "/"

    local root_len = #project_root
    if #dir > root_len then
      local relative = dir:sub(root_len + 2)
      if relative ~= "" then
        local last_slash = relative:find("/[^/]*$")
        if last_slash then
          less_sig = relative:sub(1, last_slash)
          most_sig = relative:sub(last_slash + 1) .. "/"
        else
          most_sig = relative .. "/"
        end
      end
    end
  else
    local parent = vim.fn.fnamemodify(dir, ":t")
    local pre_parent = vim.fn.fnamemodify(dir, ":h")
    if parent ~= "" then
      most_sig = parent .. "/"
    end
    if pre_parent ~= "" and pre_parent ~= "." then
      pre_root = pre_parent .. "/"
    end
  end

  local result = {
    pre_root = pre_root,
    project_root = proj_root_name,
    less_significant = less_sig,
    most_significant = most_sig,
    filename = filename,
  }

  self.parsed_path_cache[bufnr] = result
  return result
end

-- Use shared path utilities for common operations
local PathUtils = require("utils.path")

function M:abbreviate_filename(filename, target_len)
  local min_len = self.options.min_filename_len
  if #filename <= target_len or target_len < min_len + 1 then
    return filename
  end

  local dot_pos = filename:find("%.[^%.]+$")
  local name, ext_with_dot
  if dot_pos then
    name = filename:sub(1, dot_pos - 1)
    ext_with_dot = filename:sub(dot_pos)
  else
    name = filename
    ext_with_dot = ""
  end

  local available = target_len - #ext_with_dot - 1
  if available < min_len then
    available = min_len
  end

  if #name <= available then
    return filename
  end

  local left_len = math.ceil(available / 2)
  local right_len = available - left_len

  return name:sub(1, left_len) .. "…" .. name:sub(-right_len) .. ext_with_dot
end

function M:abbreviate_path(parts, available_width)
  local pre = parts.pre_root
  local proj = parts.project_root
  local less = parts.less_significant
  local most = parts.most_significant
  local fname = parts.filename

  if pre:sub(1, self.home_len) == self.home then
    pre = "~" .. pre:sub(self.home_len + 1)
  end

  local total = #pre + #proj + #less + #most + #fname
  if total <= available_width then
    return { pre_root = pre, project_root = proj, less_significant = less, most_significant = most, filename = fname }
  end

  local segments = { "pre", "less", "proj", "most" }
  local values = { pre = pre, less = less, proj = proj, most = most }
  local originals = { pre = pre, less = less, proj = proj, most = most }

  for _, key in ipairs(segments) do
    while total > available_width and values[key] ~= "" do
      local old_len = #values[key]
      local new_val = PathUtils.abbreviate_segment(values[key], math.max(1, old_len - 1))
      if #new_val == old_len then
        break
      end
      total = total - (old_len - #new_val)
      values[key] = new_val
    end
    if total <= available_width then
      break
    end
  end

  if total > available_width then
    total = total - #values.pre - #values.proj - #values.less - #values.most
    values.pre, values.proj, values.less, values.most = "", "", "", ""
    originals.pre, originals.proj, originals.less, originals.most = "", "", "", ""
  end

  if total > available_width then
    fname = self:abbreviate_filename(fname, available_width)
  end

  return {
    pre_root = PathUtils.add_ellipsis_to_segment(values.pre, originals.pre),
    project_root = PathUtils.add_ellipsis_to_segment(values.proj, originals.proj),
    less_significant = PathUtils.add_ellipsis_to_segment(values.less, originals.less),
    most_significant = PathUtils.add_ellipsis_to_segment(values.most, originals.most),
    filename = fname,
  }
end

function M:get_filesize_len(filepath, bufnr)
  if self.fsize_cache[bufnr] then
    return self.fsize_cache[bufnr]
  end

  local size = vim.fn.getfsize(filepath)
  local len = 0
  if size > 0 then
    local suffixes = { "b", "k", "m", "g" }
    local i = 1
    while size > 1024 do
      size = size / 1024
      i = i + 1
    end
    local str = i == 1 and string.format("%d%s", size, suffixes[1]) or string.format("%.1f%s", size, suffixes[i])
    len = #str
  end

  self.fsize_cache[bufnr] = len
  return len
end

function M:update_status()
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    return ""
  end

  local is_modified = vim.bo[bufnr].modified
  local is_readonly = vim.bo[bufnr].readonly or not vim.bo[bufnr].modifiable
  -- Check if file actually exists on disk (not a scratch buffer or new file)
  local file_exists = vim.fn.filereadable(filepath) == 1

  local icon, icon_hl = self:get_filetype_icon()
  local parts

  if file_exists then
    parts = self:parse_path(filepath, bufnr)
    local statusline_width = (vim.o.laststatus == 3) and vim.o.columns or vim.fn.winwidth(0)

    local limit = statusline_width * self.options.max_statusline_area
    -- Removed dynamic mode_len calculation to avoid searchcount
    local mode_len = 10 -- Approximated constant
    local filesize_len = self:get_filesize_len(filepath, bufnr)
    local deduction = mode_len + 2 + filesize_len + 2 + 2
    local available = math.max(10, limit - deduction)

    parts = self:abbreviate_path(parts, available)
  else
    parts = {
      pre_root = "",
      project_root = "",
      less_significant = "",
      most_significant = "",
      filename = vim.fn.fnamemodify(filepath, ":t"),
    }
  end

  local hl = is_modified and self.hl_modified_map or self.hl_normal_map
  local result = {}
  local insert = table.insert

  if icon ~= "" then
    insert(result, icon_hl and (self:format_hl(icon_hl) .. icon .. " ") or (icon .. " "))
  end

  if is_readonly then
    insert(result, self:format_hl(self.hl.readonly) .. self.options.icons.readonly .. " ")
  elseif is_modified then
    insert(result, self:format_hl(self.hl.modified) .. self.options.icons.modified .. " ")
  end

  if parts.pre_root ~= "" then
    insert(result, self:format_hl(hl.pre_root) .. parts.pre_root)
  end
  if parts.project_root ~= "" then
    insert(result, self:format_hl(hl.project_root) .. parts.project_root)
  end
  if parts.less_significant ~= "" then
    insert(result, self:format_hl(hl.less_significant) .. parts.less_significant)
  end
  if parts.most_significant ~= "" then
    insert(result, self:format_hl(hl.most_significant) .. parts.most_significant)
  end
  if parts.filename ~= "" then
    insert(result, self:format_hl(hl.filename) .. parts.filename)
  end

  return table.concat(result)
end

return M
