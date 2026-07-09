--------------------------------------------------------------------------------
-- universal.lua — type-preserving clipboard provider for NeoVim.
--------------------------------------------------------------------------------
-- Talks the clipboard-bridge framing protocol to a loopback TCP port served by
-- the clipboard-bridge launchd service, which speaks a length-prefixed binary
-- protocol instead of bare pbpaste so we carry the register TYPE, not just text:
--
--   paste()  → G (get text) + R (get-regtype)  → {lines, regtype}
--   copy()   → T (set text + regtype)
--
-- Self-contained clips (spec §11): when we paste the PEER's clipboard over the
-- SSH tunnel, we also persist a full local copy into THIS machine's store (H to
-- learn the peer's hostname, then a fire-and-forget P to the LOCAL bridge). So a
-- clip used here survives the origin going offline — next session it's already
-- in the local history, no phone-home. Only over SSH; local pastes are already
-- captured by the Hammerspoon watcher.
--
-- This is what makes a visual-BLOCK yank (regtype "b") keep its shape: the
-- service records the regtype when nvim copies and hands it back on the next
-- paste (a hash check self-invalidates it if anything else changed the
-- clipboard meanwhile). The prior provider read only text and inferred the
-- type, so block-ness was lost.
--
-- TWO modes, one protocol — only the port differs:
--   * SSH   (127.0.0.1:2490) — the RemoteForward endpoint: reads/writes the
--            PEER's clipboard across the reverse tunnel, so a block yanked in
--            remote nvim pastes as a block, cross-machine.
--   * local (127.0.0.1:2489) — this Mac's OWN clipboard-bridge service, so a
--            block copied anywhere (locally, or pushed here from a remote by
--            its T op) pastes as a block in local nvim too.
--
-- Fallbacks when the bridge is unreachable: SSH → write-only OSC 52 copy /
-- per-process cache paste (iPad/Blink, no tunnel, and Zellij refuses OSC 52
-- reads); local → direct pbcopy/pbpaste (same as LazyVim's default, minus the
-- type). Empty cache + no bridge falls back to the unnamed register.
local M = {}

local function ssh()
  return not not (vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT or vim.env.SSH_TTY)
end

local function cache_path()
  local cache = vim.env.XDG_CACHE_HOME or ((vim.env.HOME or "") .. "/.cache")
  return cache .. "/nvim-clipboard/last"
end

-- Loopback TCP (not a unix socket): a forwarded socket goes stale on an unclean
-- disconnect and macOS ssh won't clear it; a port frees itself. BRIDGE_PORT is
-- chosen by setup() per mode (2490 SSH / 2489 local); CLIPBOARD_BRIDGE_PORT
-- overrides it (tests).
local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 2490
-- This machine's OWN bridge, where a used peer clip is materialized (op P) into
-- the local store. Fixed at 2489 regardless of the paste source port; env
-- override for tests.
local LOCAL_PERSIST_PORT = tonumber(vim.env.CLIPBOARD_PERSIST_PORT) or 2489

-- pb* guard executable() for the same reason sys() does (E475 on a missing
-- binary): a restricted PATH without pbcopy/pbpaste must no-op, not throw.
local function pbcopy(text)
  if vim.fn.executable("pbcopy") == 0 then return end
  vim.fn.system({ "pbcopy" }, text)
end
local function pbpaste()
  if vim.fn.executable("pbpaste") == 0 then return {} end
  return vim.fn.systemlist({ "pbpaste" })
end

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

-- Fire-and-forget framed request: connect, write, and close on the first
-- response byte (or a 2s safety timer) — no vim.wait, so the caller (paste())
-- is never blocked. libuv services the callbacks on nvim's main loop. Used for
-- the materialize P op, whose reply we don't need.
local function frame_fire(host, port, opcode, payload)
  local uv = vim.uv or vim.loop
  payload = payload or ""
  local req = opcode .. pack_be32(#payload) .. payload
  local tcp = uv.new_tcp()
  local timer = uv.new_timer()
  local closed = false
  local function shut()
    if closed then return end
    closed = true
    pcall(function() timer:stop(); timer:close() end)
    pcall(function() tcp:read_stop() end)
    pcall(function() tcp:close() end)
  end
  tcp:connect(host, port, function(cerr)
    if cerr then shut(); return end
    -- Any reply (or EOF) means the server has read+processed the request.
    tcp:read_start(function() shut() end)
    tcp:write(req)
  end)
  timer:start(2000, 0, shut) -- safety net if the server never replies
end

-- The peer's hostname (origin of clips read over the SSH tunnel), fetched once
-- via H and cached for the session. Only meaningful in SSH mode. Retries until
-- a non-empty answer, so a transient bridge hiccup doesn't poison the cache.
local PEER_HOST
local function peer_host()
  if PEER_HOST then return PEER_HOST end
  local h = frame_request(BRIDGE_HOST, BRIDGE_PORT, "H", "", 1000)
  if h and h[1] == "O" and h[2] ~= "" then PEER_HOST = h[2] end
  return PEER_HOST
end

-- Run a command and return its trimmed stdout, or "" if the binary isn't on
-- PATH. vim.fn.system() with a list arg RAISES E475 (not empty return) when the
-- executable is missing, so guard with executable() — a dev-shell PATH that
-- lacks /usr/sbin (no scutil) must degrade to the fallback, not throw.
local function sys(cmd)
  if vim.fn.executable(cmd[1]) == 0 then return "" end
  return (vim.fn.system(cmd) or ""):gsub("%s+$", "")
end

-- THIS machine's stable hostname (the copy origin), stamped on the provenance
-- we push out on copy. Cached; scutil LocalHostName, same source the pickers use.
local MY_HOST
local function my_host()
  if MY_HOST then return MY_HOST end
  local out = sys({ "scutil", "--get", "LocalHostName" })
  if out == "" then out = sys({ "hostname", "-s" }) end
  if out ~= "" then MY_HOST = out end
  return MY_HOST
end

-- Materialize a just-pasted peer clip into THIS machine's store (spec §11), so
-- it stays available after the origin machine goes offline. Fire-and-forget P
-- to the local bridge; best-effort (never blocks or errors the paste).
local US, RS = "\31", "\30"
local function materialize(text, regtype)
  if not text or text == "" then return end
  local host = peer_host()
  if not host then return end -- can't attribute origin -> skip (retry next paste)
  local rt = (regtype == "v" or regtype == "l" or regtype == "b") and regtype or ""
  local meta = table.concat({ host, "text", "", rt }, US)
  frame_fire(BRIDGE_HOST, LOCAL_PERSIST_PORT, "P", meta .. RS .. text)
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

-- copy. Always cache locally, then push text+regtype to the bridge with T
-- (records the register type). On an unreachable bridge: SSH → write-only
-- OSC 52 (text rides up through Zellij/WezTerm); local → direct pbcopy.
function M.copy(reg)
  local osc52 = require("vim.ui.clipboard.osc52").copy(reg)
  return function(lines, regtype)
    local rt = norm_regtype(regtype)
    write_cache(lines, rt)
    local text = table.concat(lines, "\n")
    -- §23: over SSH this copy ORIGINATED here. Declare our host to the sit-Mac
    -- (awaited, BEFORE T sets its clipboard, so its watcher tags remote(us) not
    -- local), and record a local row in our own store. Best-effort; never blocks.
    if ssh() then
      local host = my_host()
      if host then
        frame_request(BRIDGE_HOST, BRIDGE_PORT, "O", host .. US .. text, 1000)
        frame_fire(BRIDGE_HOST, LOCAL_PERSIST_PORT, "P",
          table.concat({ host, "text", "", rt }, US) .. RS .. text)
      end
    end
    local resp = frame_request(BRIDGE_HOST, BRIDGE_PORT, "T", rt .. text, 1000)
    if resp and resp[1] == "O" then
      return -- clipboard set with its type via the bridge; done
    end
    if ssh() then
      osc52(lines)
    else
      pbcopy(text)
    end
  end
end

-- paste. Bridge → G (text) + R (regtype); the regtype is authoritative (block
-- preserved). On an unreachable bridge: cached {text, regtype}; then, local
-- only, direct pbpaste (type inferred); SSH empty-cache → unnamed register.
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
      local rt = regtype or cached_rt or infer_regtype(text)
      -- Self-contained (§11): over SSH this text is the PEER's clip, read across
      -- the tunnel — persist a full copy locally so it survives the peer going
      -- offline. Local pastes are already the HS watcher's job; skip those.
      if ssh() then materialize(text, rt) end
      return { to_lines(text), rt }
    end
    if cached_text then
      return { vim.split(cached_text, "\n", { plain = true }), cached_rt or "v" }
    end
    if not ssh() then
      local out = pbpaste()
      return { out, infer_regtype(table.concat(out, "\n")) }
    end
    return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
  end
end

function M.setup()
  local is_ssh = ssh()
  BRIDGE_PORT = tonumber(vim.env.CLIPBOARD_BRIDGE_PORT) or (is_ssh and 2490 or 2489)
  vim.opt.clipboard = "unnamedplus"
  vim.g.clipboard = {
    name = is_ssh and "universal-ssh" or "universal-local",
    copy = { ["+"] = M.copy("+"), ["*"] = M.copy("*") },
    paste = { ["+"] = M.paste(), ["*"] = M.paste() },
  }
end

return M
