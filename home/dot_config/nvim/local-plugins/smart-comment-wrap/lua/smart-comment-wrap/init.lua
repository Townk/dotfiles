-- Smart Comment Wrapping for NeoVim
-- Automatically wraps standalone comments at a configurable width while
-- leaving code and trailing comments untouched.
--
-- Features:
--   - Uses Treesitter to detect when cursor is inside a comment
--   - Distinguishes standalone comment blocks from trailing comments
--   - Respects editorconfig for code textwidth
--   - Supports custom `comments_width` in .editorconfig
--   - Global default via vim.g.comments_width
--   - Buffer-local override via vim.b.comments_width
--   - Disabled by default (no wrapping until configured)
--
-- Usage:
--   1. Place this file in your NeoVim config (e.g., lua/smart-comment-wrap.lua)
--   2. Require it from init.lua: require('smart-comment-wrap')
--   3. Enable globally: vim.g.comments_width = 80
--   4. Or per-project: add `comments_width = 80` to your .editorconfig

local M = {}

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

-- Global default for comment width (nil by default, meaning feature is off)
-- Set vim.g.comments_width to enable globally, or use .editorconfig per-project

-- Filetypes where the plugin stays out of the way entirely. Prose filetypes
-- want vim's native text auto-wrap (`t` in formatoptions wrapping at &textwidth),
-- which is what smart-comment-wrap normally strips. Excluded buffers keep their
-- default formatoptions and skip dynamic textwidth switching.
M.config = {
  exclude_filetypes = { 'markdown', 'text', 'rst', 'asciidoc', 'norg' },
}

local function is_excluded(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.tbl_contains(M.config.exclude_filetypes or {}, vim.bo[bufnr].filetype)
end

--------------------------------------------------------------------------------
-- Editorconfig Integration
--------------------------------------------------------------------------------

-- Register a custom editorconfig property handler for `comments_width`
-- This runs after editorconfig processes a buffer, setting vim.b.comments_width
local function setup_editorconfig()
  -- NeoVim's built-in editorconfig (0.9+) exposes properties table
  local ok, editorconfig = pcall(require, 'editorconfig')
  if ok and editorconfig.properties then
    editorconfig.properties.comments_width = function(bufnr, val, opts)
      local width = tonumber(val)
      if width and width > 0 then
        vim.b[bufnr].comments_width = width
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Textwidth Management
--------------------------------------------------------------------------------

-- Stash the code textwidth (from editorconfig or ftplugin) so we can restore it
-- This runs after FileType and editorconfig have done their work
local function save_code_textwidth(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Only save if we haven't already, or if textwidth changed
  local current_tw = vim.bo[bufnr].textwidth
  if current_tw > 0 then
    vim.b[bufnr].code_textwidth = current_tw
  end
end

-- Get the effective comment width for the current buffer
-- Priority: buffer-local > global > nil (disabled)
-- Returns nil if no comment width is configured, meaning the feature is off
local function get_comments_width(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.b[bufnr].comments_width or vim.g.comments_width
end

-- Get the effective code width for the current buffer
-- Falls back to 0 (no wrapping) if nothing was set
local function get_code_textwidth(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.b[bufnr].code_textwidth or 0
end

--------------------------------------------------------------------------------
-- Treesitter Comment Detection
--------------------------------------------------------------------------------

-- Check if a treesitter node type represents a comment
-- Different language grammars use different names
local function is_comment_node(node)
  if not node then return false end
  local node_type = node:type()
  -- Common comment node type patterns across languages
  return node_type:match('comment')
      or node_type == 'line_comment'
      or node_type == 'block_comment'
      or node_type == 'documentation_comment'
      or node_type == 'doc_comment'
end

-- Walk up the tree to find if we're inside a comment
-- Returns the comment node if found, nil otherwise
local function find_comment_node_at_cursor()
  local ok, ts_utils = pcall(require, 'nvim-treesitter.ts_utils')
  -- Wrap node lookup in pcall: get_node()/get_node_at_cursor() raise if the
  -- window has no valid cursor position (e.g. status callers outside insert mode)
  local node
  if not ok then
    local got
    got, node = pcall(vim.treesitter.get_node)
    if not got then return nil end
  else
    local got
    got, node = pcall(ts_utils.get_node_at_cursor)
    if not got then return nil end
  end

  while node do
    if is_comment_node(node) then
      return node
    end
    node = node:parent()
  end
  return nil
end

-- Determine if a comment is standalone (own line) vs trailing (after code)
-- Returns: "standalone", "trailing", or nil if not in a comment
local function get_comment_type()
  local comment_node = find_comment_node_at_cursor()
  if not comment_node then
    return nil
  end

  -- Get the starting position of the comment
  local start_row, start_col = comment_node:start()

  -- Get the text before the comment on the same line
  local line = vim.api.nvim_buf_get_lines(0, start_row, start_row + 1, false)[1]
  if not line then
    return "standalone"
  end

  local text_before = line:sub(1, start_col)

  -- If everything before the comment is whitespace, it's standalone
  if text_before:match('^%s*$') then
    return "standalone"
  else
    return "trailing"
  end
end

--------------------------------------------------------------------------------
-- Fallback Detection (when Treesitter isn't available)
--------------------------------------------------------------------------------

-- Simple regex-based comment detection as fallback
-- Uses the buffer's 'comments' option to understand comment patterns
local function is_in_comment_fallback()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]

  -- Check if the line starts with a comment (after optional whitespace)
  -- This is a simplified check using common patterns
  local comment_patterns = {
    '^%s*//',      -- C++ style
    '^%s*#',       -- Shell/Python style
    '^%s*%-%-',    -- Lua style
    '^%s*;',       -- Assembly/Lisp style
    '^%s*%*',      -- Block comment continuation
    '^%s*/%*',     -- Block comment start
    '^%s*<!%-%-',  -- HTML comment
  }

  for _, pattern in ipairs(comment_patterns) do
    if line:match(pattern) then
      return true, "standalone"
    end
  end

  -- Check for trailing comments (comment after code on same line)
  -- This is tricky without proper parsing, so we use a simple heuristic
  local trailing_patterns = {
    '%s//[^/]',   -- C++ style trailing
    '%s#[^!]',    -- Shell style trailing (not shebang)
    '%s%-%-[^%[]', -- Lua style trailing
  }

  for _, pattern in ipairs(trailing_patterns) do
    local match_start = line:find(pattern)
    if match_start and col >= match_start then
      return true, "trailing"
    end
  end

  return false, nil
end

--------------------------------------------------------------------------------
-- Dynamic Textwidth Adjustment
--------------------------------------------------------------------------------

-- Main function that adjusts textwidth based on cursor context
local function adjust_textwidth_for_context()
  local bufnr = vim.api.nvim_get_current_buf()
  if is_excluded(bufnr) then
    return
  end
  local comments_width = get_comments_width(bufnr)

  -- If no comment width is configured, feature is disabled - do nothing
  if not comments_width then
    return
  end

  -- Try Treesitter first
  local comment_type = get_comment_type()

  -- Fallback to regex if Treesitter didn't find anything
  if not comment_type then
    local in_comment, fallback_type = is_in_comment_fallback()
    if in_comment then
      comment_type = fallback_type
    end
  end

  if comment_type == "standalone" then
    -- Standalone comment: use comment width
    vim.bo[bufnr].textwidth = comments_width
  elseif comment_type == "trailing" then
    -- Trailing comment: disable auto-wrap (don't mess with end-of-line comments)
    vim.bo[bufnr].textwidth = 0
  else
    -- In code: restore the original textwidth
    vim.bo[bufnr].textwidth = get_code_textwidth(bufnr)
  end
end

-- Restore code textwidth when leaving insert mode
local function restore_code_textwidth()
  local bufnr = vim.api.nvim_get_current_buf()
  if is_excluded(bufnr) then
    return
  end
  vim.bo[bufnr].textwidth = get_code_textwidth(bufnr)
end

--------------------------------------------------------------------------------
-- Formatoptions Setup
--------------------------------------------------------------------------------

-- Configure formatoptions for smart comment handling
local function setup_formatoptions()
  -- These will be applied after filetype detection
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('SmartCommentWrapFormatOptions', { clear = true }),
    pattern = '*',
    callback = function()
      if is_excluded() then
        return
      end
      local fo = vim.bo.formatoptions

      -- Remove 't' - don't auto-wrap text (code)
      fo = fo:gsub('t', '')

      -- Add comment-related flags if not present
      if not fo:match('c') then fo = fo .. 'c' end  -- Auto-wrap comments
      if not fo:match('r') then fo = fo .. 'r' end  -- Insert comment leader on Enter
      if not fo:match('o') then fo = fo .. 'o' end  -- Insert comment leader on o/O
      if not fo:match('q') then fo = fo .. 'q' end  -- Allow gq on comments
      if not fo:match('j') then fo = fo .. 'j' end  -- Remove comment leader when joining

      vim.bo.formatoptions = fo
    end,
  })
end

--------------------------------------------------------------------------------
-- Autocommands
--------------------------------------------------------------------------------

local function setup_autocommands()
  local group = vim.api.nvim_create_augroup('SmartCommentWrap', { clear = true })

  -- Save the code textwidth after editorconfig and ftplugin have run
  -- Using BufWinEnter to ensure it runs late enough
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'FileType' }, {
    group = group,
    pattern = '*',
    callback = function(ev)
      -- Defer slightly to let editorconfig finish
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          save_code_textwidth(ev.buf)
        end
      end, 10)
    end,
  })

  -- Adjust textwidth when entering insert mode
  vim.api.nvim_create_autocmd('InsertEnter', {
    group = group,
    pattern = '*',
    callback = adjust_textwidth_for_context,
  })

  -- Adjust textwidth as cursor moves in insert mode
  vim.api.nvim_create_autocmd('CursorMovedI', {
    group = group,
    pattern = '*',
    callback = adjust_textwidth_for_context,
  })

  -- Restore code textwidth when leaving insert mode
  vim.api.nvim_create_autocmd('InsertLeave', {
    group = group,
    pattern = '*',
    callback = restore_code_textwidth,
  })
end

--------------------------------------------------------------------------------
-- Manual Reformat Support (gq)
--------------------------------------------------------------------------------

-- Custom formatexpr that respects comment width for gq operations
-- This is optional but provides consistent behavior with manual reformatting
local function smart_formatexpr()
  local comments_width = get_comments_width()

  -- If no comment width configured, fall back to default formatting
  if not comments_width then
    return 1
  end

  -- Check if we're formatting a comment region
  local start_line = vim.v.lnum
  local end_line = start_line + vim.v.count - 1

  -- Sample the first line to check if it's a comment
  local line = vim.api.nvim_buf_get_lines(0, start_line - 1, start_line, false)[1]
  if not line then
    return 1 -- Fall back to default formatting
  end

  -- Simple check: does the line look like a standalone comment?
  if line:match('^%s*//') or line:match('^%s*#') or line:match('^%s*%-%-') or line:match('^%s*%*') then
    -- Temporarily set textwidth for formatting
    local original_tw = vim.bo.textwidth
    vim.bo.textwidth = comments_width

    -- Use the internal format command
    vim.cmd(string.format('silent! %d,%dnormal! gw', start_line, end_line))

    -- Restore
    vim.bo.textwidth = original_tw
    return 0 -- We handled it
  end

  return 1 -- Fall back to default formatting
end

-- Register the formatexpr (optional, call M.enable_smart_gq() to use)
function M.enable_smart_gq()
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('SmartCommentWrapGQ', { clear = true }),
    pattern = '*',
    callback = function()
      vim.bo.formatexpr = 'v:lua.require("smart-comment-wrap").formatexpr()'
    end,
  })
end

-- Exposed for formatexpr
function M.formatexpr()
  return smart_formatexpr()
end

--------------------------------------------------------------------------------
-- Utility Functions (exposed for user customization)
--------------------------------------------------------------------------------

-- Manually set the comment width for the current buffer
function M.set_buffer_comment_width(width)
  vim.b.comments_width = width
  print(string.format("Buffer comment width set to %d", width))
end

-- Manually set the global comment width
function M.set_global_comment_width(width)
  vim.g.comments_width = width
  print(string.format("Global comment width set to %d", width))
end

-- Get current effective settings (useful for debugging)
function M.get_status()
  local bufnr = vim.api.nvim_get_current_buf()
  return {
    global_comments_width = vim.g.comments_width,
    buffer_comments_width = vim.b[bufnr].comments_width,
    effective_comments_width = get_comments_width(bufnr),
    code_textwidth = get_code_textwidth(bufnr),
    current_textwidth = vim.bo[bufnr].textwidth,
    comment_type = get_comment_type(),
    formatoptions = vim.bo[bufnr].formatoptions,
  }
end

-- Print status (for debugging)
function M.print_status()
  local status = M.get_status()
  print("Smart Comment Wrap Status:")
  print(string.format("  Global comments_width: %s", status.global_comments_width and tostring(status.global_comments_width) or "not set"))
  print(string.format("  Buffer comments_width: %s", status.buffer_comments_width and tostring(status.buffer_comments_width) or "not set"))
  print(string.format("  Effective comments_width: %s", status.effective_comments_width and tostring(status.effective_comments_width) or "off (disabled)"))
  print(string.format("  Code textwidth: %d", status.code_textwidth))
  print(string.format("  Current textwidth: %d", status.current_textwidth))
  print(string.format("  Comment type at cursor: %s", tostring(status.comment_type)))
  print(string.format("  formatoptions: %s", status.formatoptions))
end

--------------------------------------------------------------------------------
-- User Commands
--------------------------------------------------------------------------------

local function setup_commands()
  vim.api.nvim_create_user_command('CommentWidth', function(opts)
    local width = tonumber(opts.args)
    if width then
      M.set_buffer_comment_width(width)
    else
      M.print_status()
    end
  end, {
    nargs = '?',
    desc = 'Set buffer comment width or show current status',
  })

  vim.api.nvim_create_user_command('CommentWidthGlobal', function(opts)
    local width = tonumber(opts.args)
    if width then
      M.set_global_comment_width(width)
    else
      print(string.format("Global comment width: %d", vim.g.comments_width))
    end
  end, {
    nargs = '?',
    desc = 'Set global comment width',
  })
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}

  -- Allow overriding the global default
  if opts.comments_width then
    vim.g.comments_width = opts.comments_width
  end

  -- Allow overriding the prose-filetype exclusion list
  if opts.exclude_filetypes then
    M.config.exclude_filetypes = opts.exclude_filetypes
  end

  -- Set up all components
  setup_editorconfig()
  setup_formatoptions()
  setup_autocommands()
  setup_commands()

  -- Optionally enable smart gq
  if opts.enable_smart_gq then
    M.enable_smart_gq()
  end
end

-- Auto-setup when required (for simple usage)
-- Users can also call M.setup() explicitly for more control
M.setup()

return M
