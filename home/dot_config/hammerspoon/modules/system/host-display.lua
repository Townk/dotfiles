--- host-display — name a machine the way a human knows it (Lua twin of
--- host::display in ~/.local/lib/host.zsh; peer-alias spec H6).
--- Pure Lua (no hs.*) so tests run it under plain `lua`.
---
--- The map ($HOST_ALIASES_FILE, else $XDG_STATE_HOME/hosts/aliases) holds
--- `<key> <alias>` lines learned at SSH login by environment.sh. Values are
--- re-validated on read: a hand-edited line never reaches a toast.
local M = {}

--- The one value rule, ^[A-Za-z0-9._-]{1,64}$ (Lua patterns lack {1,64}).
local function valid(s)
  return type(s) == "string" and #s >= 1 and #s <= 64 and s:match("^[A-Za-z0-9._%-]+$") ~= nil
end

local function nonempty(v)
  if v ~= nil and v ~= "" then return v end
  return nil
end

function M.aliases_path()
  local explicit = nonempty(os.getenv("HOST_ALIASES_FILE"))
  if explicit then return explicit end
  -- Hammerspoon's environment may lack XDG_STATE_HOME: fall back to HOME.
  local state = nonempty(os.getenv("XDG_STATE_HOME")) or ((os.getenv("HOME") or "") .. "/.local/state")
  return state .. "/hosts/aliases"
end

local function first_line(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

--- display(key, self_key) -> the name to show for key.
function M.display(key, self_key)
  if key == nil or key == "" then return key end
  if self_key ~= nil and self_key ~= "" and key == self_key then
    local own = first_line(nonempty(os.getenv("HOST_SELF_ALIAS_FILE")) or ((os.getenv("HOME") or "") .. "/.hostname-alias"))
    if own then
      -- Trim exactly like the ssh sender: drop every CR, then outer whitespace.
      own = own:gsub("\r", ""):match("^%s*(.-)%s*$")
    end
    if valid(own) then return own end
    return key
  end
  local f = io.open(M.aliases_path(), "r")
  if f then
    for line in f:lines() do
      -- Like zsh `IFS=' ' read -r k a`: split on spaces only (not tabs or CR),
      -- the rest of the line is the alias, outer spaces trimmed.
      local k, a = line:match("^ *([^ ]+) *(.-) *$")
      if k == key and valid(a) then
        f:close()
        return a
      end
    end
    f:close()
  end
  return key
end

return M
