--------------------------------------------------------------------------------
-- universal.lua — type-preserving clipboard provider for SSH NeoVim.
--------------------------------------------------------------------------------
-- Talks the Phase 5 clipboard-bridge framing protocol over the reverse SSH
-- tunnel (the clipboard-bridge launchd service on the Mac, reached at loopback
-- TCP 127.0.0.1:2490 — the RemoteForward endpoint; see ~/.ssh/config.d/
-- clipboard.config). The bridge serves a length-prefixed binary protocol
-- instead of bare pbpaste, so we carry the register TYPE across machines, not
-- just the text:
--
--   paste()  → G (get text) + R (get-regtype)  → {lines, regtype}
--   copy()   → T (set text + regtype)            when bridge-up
--
-- This is what finally makes a visual-BLOCK yank (regtype "b") keep its shape
-- across an SSH boundary: the laptop records the regtype when nvim copies, and
-- hands it back on the next paste. The prior provider read only text and
-- inferred the type, so block-ness was lost on the round-trip and yanky.nvim
-- rejected it with E5108 "provider returned invalid data".
--
-- Bridge-down (iPad/Blink — no reverse tunnel, OSC 52 has no read): copy()
-- falls back to write-only OSC 52 (text rides up through Zellij/WezTerm to the
-- host clipboard) and paste() serves the per-process {text, regtype} cache, so
-- yank-then-put stays type-correct in-session and never queries the terminal
-- (Zellij refuses OSC 52 reads — the hang this bridge exists to avoid). Empty
-- cache + bridge-down falls back to the unnamed register.
--
-- SSH-only: options.lua gates setup() on SSH_CONNECTION/SSH_CLIENT/SSH_TTY, so
-- local NeoVim keeps LazyVim's default pbcopy/pbpaste.
local M = {}

local function ssh()
  return not not (vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT or vim.env.SSH_TTY)
end

local function cache_path()
  local cache = vim.env.XDG_CACHE_HOME or ((vim.env.HOME or "") .. "/.cache")
  return cache .. "/nvim-clipboard/last"
end

-- The reverse-forwarded peer clipboard is a loopback TCP port (see
-- ~/.ssh/config.d/clipboard.config): a forwarded unix socket goes stale on an
-- unclean disconnect and macOS ssh won't clear it; a port frees itself.
local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 2490

--------------------------------------------------------------------------------
-- Regtype normalization. NeoVim's g:clipboard copy() gets one of "v" charwise,
-- "V" linewise, or "b" blockwise (verified empirically on 0.12 — it passes the
-- plain "b", NOT the getregtype() CTRL-V[+width] form); the protocol (and
-- setreg(), which paste()'s return feeds) speak "v"/"l"/"b". Normalize on the
-- way in so the cache and the T op store a clean single byte. Accept the CTRL-V
-- form too, defensively, in case a future NeoVim changes the contract.
--------------------------------------------------------------------------------
local function norm_regtype(rt)
  if not rt or rt == "" then return "v" end
  local c = rt:sub(1, 1)
  if c == "V" or c == "l" then return "l" end
  if c == "b" or c == "\22" then return "b" end -- "b" (what NeoVim passes) or CTRL-V (0x16)
  return "v"
end

local function infer_regtype(text)
  return text:sub(-1) == "\n" and "l" or "v"
end

-- Mirror vim.fn.systemlist: drop a single trailing newline, then split.
local function to_lines(text)
  if text:sub(-1) == "\n" then text = text:sub(1, -2) end
  return vim.split(text, "\n", { plain = true })
end

--------------------------------------------------------------------------------
-- Binary framing. LuaJIT (NeoVim) has no string.pack, so pack/unpack a 4-byte
-- big-endian length by hand with plain arithmetic (no bit module needed).
--------------------------------------------------------------------------------
local function pack_be32(n)
  return string.char(
    math.floor(n / 0x1000000) % 256,
    math.floor(n / 0x10000) % 256,
    math.floor(n / 0x100) % 256,
    n % 256
  )
end

local function unpack_be32(s, off)
  local a, b, c, d = s:byte(off, off + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Send one framed request <opcode><BE32 len><payload> to the bridge and return
-- the response {status_byte, payload}, or nil on any connect/timeout/protocol
-- error (a refused connect = bridge down = clean fallback). Synchronous: drives
-- the libuv loop via vim.wait. A libuv TCP connect (not `nc` + systemlist) keeps
-- the binary length prefix and any embedded newlines/NULs byte-exact.
local function frame_request(host, port, opcode, payload, timeout_ms)
  local uv = vim.uv or vim.loop
  payload = payload or ""
  local req = opcode .. pack_be32(#payload) .. payload
  local tcp = uv.new_tcp()
  local chunks, done, result = {}, false, nil

  local function finish(res)
    if done then return end
    result, done = res, true
    if not tcp:is_closing() then
      pcall(function()
        tcp:read_stop()
      end)
      pcall(function()
        tcp:close()
      end)
    end
  end

  tcp:connect(host, port, function(cerr)
    if cerr then
      finish(nil)
      return
    end
    tcp:read_start(function(rerr, chunk)
      if rerr then
        finish(nil)
        return
      end
      if not chunk then -- EOF before a full frame
        finish(nil)
        return
      end
      chunks[#chunks + 1] = chunk
      local buf = table.concat(chunks)
      if #buf >= 5 then
        local n = unpack_be32(buf, 2)
        if #buf >= 5 + n then
          finish({ buf:sub(1, 1), buf:sub(6, 5 + n) })
        end
      end
    end)
    tcp:write(req)
  end)

  vim.wait(timeout_ms or 1000, function()
    return done
  end, 10)
  finish(nil) -- ensure the handle is closed if we timed out
  return result
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

-- Persist the last copy's regtype + text so bridge-down paste() restores shape.
local function write_cache(lines, regtype)
  local path = cache_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local text = table.concat(lines, "\n")
  local f = io.open(path, "w")
  if f then
    f:write(regtype .. "\n" .. text)
    f:close()
  end
end

-- SSH copy. Always cache locally. Bridge-up → push text+regtype to the host
-- clipboard with the T op (carries the register type across the tunnel).
-- Bridge-down or push failure → write-only OSC 52 (text only).
function M.copy(reg)
  local osc52 = require("vim.ui.clipboard.osc52").copy(reg)
  return function(lines, regtype)
    local rt = norm_regtype(regtype)
    write_cache(lines, rt)
    local text = table.concat(lines, "\n")
    local resp = frame_request(BRIDGE_HOST, BRIDGE_PORT, "T", rt .. text, 1000)
    if resp and resp[1] == "O" then
      return -- pushed to the host clipboard with its type; done
    end
    osc52(lines) -- bridge-down or push failed: OSC 52 (text only)
  end
end

-- SSH paste. Bridge-up → G (text) + R (regtype) over the tunnel; the regtype is
-- authoritative (block preserved across machines). Bridge-down → cached
-- {text, regtype}; empty cache → unnamed register (old no-hang behavior).
function M.paste()
  return function()
    local cached_rt, cached_text = read_cache()
    local g = frame_request(BRIDGE_HOST, BRIDGE_PORT, "G", "", 1000)
    if g and g[1] == "O" then
      local text = g[2]
      local regtype
      local r = frame_request(BRIDGE_HOST, BRIDGE_PORT, "R", "", 1000)
      if r and r[1] == "O" and #r[2] >= 1 then
        local rt = r[2]:sub(1, 1)
        if rt == "v" or rt == "l" or rt == "b" then
          regtype = rt
        end
      end
      return { to_lines(text), regtype or cached_rt or infer_regtype(text) }
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
