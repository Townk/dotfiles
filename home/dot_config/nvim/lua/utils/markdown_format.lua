--------------------------------------------------------------------------------
-- Markdown-aware `formatexpr`
--------------------------------------------------------------------------------
-- Vim's built-in formatter only applies `formatlistpat` indent to the FIRST
-- continuation line of a wrapped list item; lines 3+ collapse back to column
-- 0. This module re-wraps each list item in the formatted range so EVERY
-- continuation line stays aligned under the text column following the marker.
--
-- Scope: we only own list items (bullets `-`/`*`/`+` and numbered `N.`/`N)`).
-- For plain paragraphs, blockquotes, and any range that doesn't start with a
-- list marker, we return 1 so vim falls back to its internal formatter
-- (which handles those cases fine via `formatlistpat` + `comments=n:>`).
--
-- Wire-up (see after/ftplugin/markdown.lua):
--   vim.bo.formatexpr = "v:lua.require'utils.markdown_format'.format()"
--
-- Vim calls 'formatexpr' for `gq{motion}` and insert-mode auto-wrap (`t`/`c`
-- in 'formatoptions'); `gw` deliberately bypasses it, so the ftplugin also
-- remaps `gw` to `gq` in markdown buffers.
--------------------------------------------------------------------------------

local M = {}

-- Bullet (`-`/`*`/`+`) or numbered (`1.` / `1)`) marker at line start.
-- Returns `indent, marker` so the caller can reconstruct the first line and
-- compute the continuation column (= #indent + #marker).
local function match_list(line)
  local indent, marker = line:match("^(%s*)([%-%*%+]%s+)")
  if marker then
    return indent, marker
  end
  return line:match("^(%s*)(%d+[%.%)]%s+)")
end

-- Greedy word-wrap. Words longer than `max_width` are placed on their own
-- line (matches vim's internal behaviour for unbreakable tokens).
local function wrap_words(content, max_width)
  local out, cur = {}, ""
  for word in content:gmatch("%S+") do
    if #cur == 0 then
      cur = word
    elseif #cur + 1 + #word <= max_width then
      cur = cur .. " " .. word
    else
      out[#out + 1] = cur
      cur = word
    end
  end
  if #cur > 0 then
    out[#out + 1] = cur
  end
  return out
end

function M.format()
  local lnum = vim.v.lnum
  local count = vim.v.count > 0 and vim.v.count or 1

  -- Insert-mode auto-wrap sets v:char. Rewriting the buffer with
  -- nvim_buf_set_lines mid-keystroke would desync the cursor from what the
  -- user is typing — let the internal formatter handle that path. The
  -- ftplugin's `comments` fix is enough for the insert-mode common case.
  if vim.v.char ~= "" then
    return 1
  end

  local tw = vim.bo.textwidth
  if tw <= 0 then
    return 1
  end

  local lines = vim.fn.getline(lnum, lnum + count - 1)
  if type(lines) == "string" then
    lines = { lines }
  end

  -- Defer to internal formatter unless this range is purely list items.
  -- Two early-outs cover everything that isn't a list:
  --   - first line isn't a list marker → plain paragraph or blockquote
  --   - any blank line in the range → multiple paragraphs; let vim split
  if not match_list(lines[1]) then
    return 1
  end
  for _, l in ipairs(lines) do
    if l:match("^%s*$") then
      return 1
    end
  end

  -- Walk list items: a new item starts on any line matching a marker;
  -- everything between markers is continuation of the prior item. This
  -- correctly handles consecutive items at the same depth, nested items
  -- (different indent), and mixed bullet/numbered chains.
  local out = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local indent, marker = match_list(line)
    if not marker then
      -- Defensive: a non-list line in the middle of a "list paragraph"
      -- means something unusual (e.g. indented code). Bail rather than
      -- corrupt the buffer.
      return 1
    end

    -- Collect this item's continuation lines (up to the next marker).
    local item = { line }
    local j = i + 1
    while j <= #lines and not match_list(lines[j]) do
      item[#item + 1] = lines[j]
      j = j + 1
    end

    -- Wrap-width budget: continuation lines sit at column
    -- (#indent + #marker), and the first line gets the marker that fills
    -- exactly that width — so a single `tw - #cont` budget works for both.
    local cont = indent .. string.rep(" ", #marker)
    local max_width = math.max(tw - #cont, 10)

    -- Stitch back into one logical line (drop continuation indent we're
    -- about to redo), collapse whitespace, then re-wrap.
    local content = line:sub(#indent + #marker + 1)
    for k = 2, #item do
      content = content .. " " .. item[k]:gsub("^%s+", "")
    end
    content = content:gsub("%s+", " ")
    local wrapped = wrap_words(content, max_width)

    out[#out + 1] = indent .. marker .. (wrapped[1] or "")
    for k = 2, #wrapped do
      out[#out + 1] = cont .. wrapped[k]
    end

    i = j
  end

  vim.api.nvim_buf_set_lines(0, lnum - 1, lnum - 1 + count, false, out)
  return 0
end

return M
