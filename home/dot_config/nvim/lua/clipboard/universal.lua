--------------------------------------------------------------------------------
-- universal.lua — type-preserving clipboard provider for SSH NeoVim.
--------------------------------------------------------------------------------
-- Evolves the options.lua OSC 52-write / tunnel-read bridge: stop throwing
-- the register type away on paste.
--
-- The prior provider copied via write-only OSC 52 (yanks ride up through
-- Zellij/WezTerm to the host clipboard) and pasted by reading the host
-- clipboard back through the reverse SSH tunnel (the clipboard-bridge
-- launchd service on the Mac, served at
-- $HOME/.local/state/runtime/chezmoi-system/clipboard-bridge.sock). But its
-- paste() returned a hardcoded regtype "v", so a visual-BLOCK yank
-- (regtype "b") lost its shape on the round-trip and yanky.nvim rejected
-- the corrupted result with E5108 "provider returned invalid data".
--
-- This module keeps the same transport and SSH gating, and adds a tiny
-- per-process cache of the last copy's {lines, regtype}. paste() pairs the
-- tunnel text with the cached regtype (bridge-up) or serves the cached
-- {text, regtype} directly (bridge-down — the iPad/Blink path, where there
-- is no tunnel and OSC 52 has no read), so block yank-then-put round-trips
-- type-correctly and never errors. Empty cache + bridge-down falls back to
-- the unnamed register, preserving the old no-hang behavior.
--
-- Cross-machine block (regtype recorded on the laptop and fetched over the
-- reverse channel) is a later phase; here the cached regtype is the
-- in-session currency, which is correct for the common yank-then-put flow.
--
-- SSH-only: options.lua gates setup() on SSH_CONNECTION/SSH_CLIENT/SSH_TTY,
-- so local NeoVim keeps LazyVim's default pbcopy/pbpaste. The socket path
-- and the nc -U read protocol are unchanged — a type-preserving evolution,
-- not a new transport.
local M = {}

local function ssh()
  return not not (vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT or vim.env.SSH_TTY)
end

local function cache_path()
  local cache = vim.env.XDG_CACHE_HOME or ((vim.env.HOME or "") .. "/.cache")
  return cache .. "/nvim-clipboard/last"
end

local function sock_path()
  return (vim.env.HOME or "") .. "/.local/state/runtime/chezmoi-system/clipboard-bridge.sock"
end

-- Read the cached {regtype, text}. Returns nil if absent or malformed.
local function read_cache()
  local f = io.open(cache_path(), "r")
  if not f then return nil end
  local blob = f:read("*a")
  f:close()
  local nl = blob:find("\n", 1, true)
  if not nl then return nil end
  local regtype = blob:sub(1, nl - 1)
  local text = blob:sub(nl + 1)
  if regtype ~= "v" and regtype ~= "l" and regtype ~= "b" then return nil end
  return regtype, text
end

-- Persist the last copy's regtype + text so paste() can restore the shape.
local function write_cache(lines, regtype)
  local path = cache_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local text = table.concat(lines, "\n")
  local f = io.open(path, "w")
  if f then
    f:write((regtype or "v") .. "\n" .. text)
    f:close()
  end
end

local function infer_regtype(text)
  return text:sub(-1) == "\n" and "l" or "v"
end

-- SSH copy: write-only OSC 52 (reuses the bundled module so yanks ride up
-- through Zellij/WezTerm to the host clipboard, unchanged) + cache the
-- regtype for a later type-correct paste.
function M.copy(reg)
  local osc52 = require("vim.ui.clipboard.osc52").copy(reg)
  return function(lines, regtype)
    write_cache(lines, regtype)
    osc52(lines)
  end
end

-- SSH paste: read the host clipboard back through the reverse tunnel
-- (bridge-up) and pair it with the cached regtype; bridge-down (iPad/Blink)
-- serves the cached {text, regtype} so paste is type-correct and never
-- queries the terminal (Zellij refuses OSC 52 reads — the hang this bridge
-- exists to avoid). Empty cache + bridge-down falls back to the unnamed
-- register, matching the prior behavior.
function M.paste()
  return function()
    local uv = vim.uv or vim.loop
    local sock = sock_path()
    local cached_rt, cached_text = read_cache()
    if vim.fn.executable("nc") == 1 and uv.fs_stat(sock) then
      local out = vim.fn.systemlist({ "nc", "-U", "-w", "1", sock })
      if vim.v.shell_error == 0 then
        local text = table.concat(out, "\n")
        return { out, cached_rt or infer_regtype(text) }
      end
    end
    if cached_text then
      return { vim.split(cached_text, "\n", { plain = true }), cached_rt or "v" }
    end
    return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
  end
end

function M.setup()
  if not ssh() then return end
  vim.opt.clipboard = "unnamedplus"
  vim.g.clipboard = {
    name = "universal-ssh",
    copy = { ["+"] = M.copy("+"), ["*"] = M.copy("*") },
    paste = { ["+"] = M.paste(), ["*"] = M.paste() },
  }
end

return M
