--------------------------------------------------------------------------------
-- Path Utilities Module
--------------------------------------------------------------------------------
-- Shared utility functions for path manipulation and truncation.
--
-- WHY Centralized:
-- Path truncation logic was duplicated between lualine's dynamic-fqn component
-- and the Snacks yank_path action. Centralizing ensures consistency and makes
-- the codebase easier to maintain.
--------------------------------------------------------------------------------

local M = {}

---Calculate the character length of a path segment (excluding slashes)
---@param segment string The path segment (e.g., "usr/local/bin")
---@return number length The total length of all parts plus separators
function M.calc_segment_len(segment)
  local len, count = 0, 0
  for part in segment:gmatch("([^/]+)") do
    len = len + #part
    count = count + 1
  end
  return len + count
end

---Abbreviate a path segment by shortening parts from right to left
---Parts starting with "." keep at least 2 characters (for dotfiles)
---@param segment string The path segment to abbreviate
---@param target_len number Target length for the segment
---@return string abbreviated The abbreviated segment
---@return boolean changed Whether any abbreviation occurred
function M.abbreviate_segment(segment, target_len)
  if segment == "" or #segment <= target_len then
    return segment, false
  end

  local parts = {}
  for part in segment:gmatch("([^/]+)") do
    parts[#parts + 1] = part
  end

  local current_len = M.calc_segment_len(segment)
  local changed = false

  while current_len > target_len do
    local abbreviated = false
    for i = #parts, 1, -1 do
      local min_len = parts[i]:sub(1, 1) == "." and 2 or 1
      if #parts[i] > min_len then
        parts[i] = parts[i]:sub(1, -2)
        current_len = current_len - 1
        abbreviated = true
        changed = true
        break
      end
    end
    if not abbreviated then
      break
    end
  end

  if #parts == 0 then
    return "", changed
  end

  return table.concat(parts, "/") .. "/", changed
end

---Add ellipsis character to abbreviated path parts
---Parts that have been shortened get "…" appended (if they're still > min length)
---@param abbreviated string The abbreviated path segment
---@param original string The original path segment
---@return string result Path segment with ellipsis markers
function M.add_ellipsis_to_segment(abbreviated, original)
  if abbreviated == "" or abbreviated == original then
    return abbreviated
  end

  local abbr_parts = {}
  for part in abbreviated:gmatch("([^/]+)") do
    abbr_parts[#abbr_parts + 1] = part
  end

  local orig_parts = {}
  for part in original:gmatch("([^/]+)") do
    orig_parts[#orig_parts + 1] = part
  end

  for i, part in ipairs(abbr_parts) do
    local threshold = part:sub(1, 1) == "." and 2 or 1
    if orig_parts[i] and #part < #orig_parts[i] and #part > threshold then
      abbr_parts[i] = part .. "…"
    end
  end

  return table.concat(abbr_parts, "/") .. "/"
end

---Truncate a full path for display purposes
---Preserves the leading "/" for absolute paths
---Converts home directory to "~" if requested
---Abbreviates from left to right, keeping the most significant parts
---@param path string The full path to truncate
---@param max_len number Maximum length for the result
---@param convert_home boolean Whether to convert /home/user to ~
---@return string truncated The truncated path suitable for display
function M.truncate_path(path, max_len, convert_home)
  if #path <= max_len then
    return path
  end

  local is_absolute = path:sub(1, 1) == "/"

  if convert_home then
    local home = vim.env.HOME or ""
    if path:sub(1, #home) == home then
      path = "~" .. path:sub(#home + 1)
      is_absolute = false
    end

    if #path <= max_len then
      return path
    end
  end

  -- Parse into parts, preserving original for comparison
  local parts = {}
  local original_parts = {}
  for part in path:gmatch("([^/]+)") do
    table.insert(parts, part)
    table.insert(original_parts, part)
  end

  -- Abbreviate from left to right (least significant to most)
  local result = path
  local changed = false
  while #result > max_len do
    local abbreviated = false
    for i = 1, #parts - 1 do
      local min_len = parts[i]:sub(1, 1) == "." and 2 or 1
      if #parts[i] > min_len then
        parts[i] = parts[i]:sub(1, -2)
        abbreviated = true
        changed = true
        break
      end
    end
    if not abbreviated then
      break
    end
    result = table.concat(parts, "/")
  end

  -- Add ellipsis to truncated parts
  if changed then
    local parts_with_ellipsis = {}
    for i, part in ipairs(parts) do
      if i < #parts and original_parts[i] and #part < #original_parts[i] then
        table.insert(parts_with_ellipsis, part .. "…")
      else
        table.insert(parts_with_ellipsis, part)
      end
    end
    result = table.concat(parts_with_ellipsis, "/")
  end

  -- Restore leading slash for absolute paths
  if is_absolute then
    result = "/" .. result
  end

  return result
end

return M
