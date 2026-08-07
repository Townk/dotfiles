--------------------------------------------------------------------------------
-- universal.lua — type-preserving clipboard provider for NeoVim, on RECOB.
--------------------------------------------------------------------------------
-- STAGED, NOT INSTALLED. This file replaces
-- `home/dot_config/nvim/lua/clipboard/universal.lua` in Phase 8's cutover
-- change (docs/recob-implementation-plan.md), together with the shims and the
-- build hook. It lives here until then because applying a RECOB-speaking
-- provider onto a machine whose bridge still speaks the old protocol would
-- break the human's clipboard in the interval — the exact failure §13's
-- "one apply per machine" ordering exists to avoid.
--
-- It is the second implementation of the wire, and deliberately so
-- (docs/recob-protocol-spec.md §8): a rule only one implementation obeys is a
-- rule that has not been tested. What changed from the opcode version:
--
--   paste()  G + R  ->  one `clip.get` exchange (text, regtype, ts, host)
--   copy()   O + T  ->  one `clip.set` carrying its own provenance
--   persist  P      ->  `store.persist.text` on the TRUSTED socket
--   peer host H     ->  `host.identity`, and only when one is still needed
--
-- The origin file, its TTL, its hash keying and the suppress flag are gone:
-- the daemon writes the pasteboard and the row in one operation, so there is
-- no window for a note left in a file to describe (§6.2).
--
-- Three rules from §8 that are easy to lose in a rewrite:
--   * The credential never crosses the wire. The banner carries a nonce; the
--     hello answers SHA256(token .. ":c:" .. nonce) and issues its own.
--   * The server must prove itself before this client sends anything carrying
--     user data or parses any response — an unverified peer's `caps` is a
--     claim, not a fact.
--   * OSC 52 is a fallback for an ABSENT bridge, never for a refusing or slow
--     one. The only admitted signal is ECONNREFUSED; everything else fails
--     loudly, because anything an attacker can slow down would otherwise
--     become a downgrade (§5.2).
-- lua-language-server sees this file outside the nvim runtime path, because it
-- lives here until Phase 8 installs it over the provider; `vim` is a global
-- the runtime supplies. Narrow suppression rather than a blanket one.
---@diagnostic disable: undefined-global
local M = {}

local uv = vim.uv or vim.loop

local WIRE_MAGIC = "RECOB"
local WIRE_VERSION = 1
local PROTO = 1

local function ssh()
  return not not (vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT or vim.env.SSH_TTY)
end

local function state_home()
  return vim.env.XDG_STATE_HOME or ((vim.env.HOME or "") .. "/.local/state")
end

local function cache_path()
  local cache = vim.env.XDG_CACHE_HOME or ((vim.env.HOME or "") .. "/.cache")
  return cache .. "/nvim-clipboard/last"
end

-- Loopback TCP for the peer (a forwarded unix socket goes stale on an unclean
-- disconnect and macOS ssh will not clear it); this machine's own bridge is
-- the trusted unix socket, whose uid boundary is its credential.
local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 2490
local TRUSTED_SOCKET = vim.env.CLIPBOARD_BRIDGE_LOCAL_SOCKET
  or ((vim.env.HOME or "") .. "/.local/state/cb.sock")

local PREAMBLE_TIMEOUT_MS = tonumber(vim.env.RECOB_HELLO_TIMEOUT_MS) or 500
local EXCHANGE_TIMEOUT_MS = 2000

--------------------------------------------------------------------------------
-- Framing. LuaJIT has no string.pack, so the 4-byte big-endian length is
-- assembled with plain arithmetic — the same approach the opcode version used,
-- against a different frame shape.
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
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- §4.3: <1-byte name length><name><BE32 value length><value>, repeated.
local function encode_fields(fields)
  local parts = {}
  for _, pair in ipairs(fields) do
    local name, value = pair[1], pair[2] or ""
    parts[#parts + 1] = string.char(#name) .. name .. pack_be32(#value) .. value
  end
  return table.concat(parts)
end

local function decode_fields(body)
  local fields, pos = {}, 1
  while pos <= #body do
    local name_len = body:byte(pos)
    if not name_len or pos + name_len + 4 > #body then return fields end
    local name = body:sub(pos + 1, pos + name_len)
    local value_len = unpack_be32(body, pos + name_len + 1)
    if not value_len then return fields end
    local start = pos + name_len + 5
    fields[name] = body:sub(start, start + value_len - 1)
    pos = start + value_len
  end
  return fields
end

local function encode_frame(kind, fields)
  local body = encode_fields(fields)
  return kind .. pack_be32(#body) .. body
end

--------------------------------------------------------------------------------
-- One connection, driven synchronously through the libuv loop with vim.wait.
--------------------------------------------------------------------------------
local Conn = {}
Conn.__index = Conn

-- connect(target) -> conn, err
--   err.absent is true ONLY for a refused connect: the single observation §5.2
--   admits as "no bridge here". Every other failure leaves it false, and the
--   caller must not fall back.
local function connect(target)
  local handle = target.socket and uv.new_pipe(false) or uv.new_tcp()
  local self = setmetatable({
    handle = handle,
    buffer = "",
    closed = false,
    err = nil,
    absent = false,
  }, Conn)

  local connected = false
  local function on_connect(cerr)
    if cerr then
      -- libuv spells a refused connect ECONNREFUSED on both platforms.
      self.absent = tostring(cerr):match("ECONNREFUSED") ~= nil
      self.err = tostring(cerr)
      self:close()
      return
    end
    connected = true
    handle:read_start(function(rerr, chunk)
      if rerr then
        self.err = tostring(rerr)
        self:close()
      elseif chunk then
        self.buffer = self.buffer .. chunk
      else
        self:close()
      end
    end)
  end

  if target.socket then
    handle:connect(target.socket, on_connect)
  else
    handle:connect(target.host, target.port, on_connect)
  end
  vim.wait(EXCHANGE_TIMEOUT_MS, function() return connected or self.closed end, 5)
  if not connected then
    if not self.err then self.err = "connect timed out" end
    self:close()
    return nil, self
  end
  return self, nil
end

function Conn:close()
  if self.closed then return end
  self.closed = true
  pcall(function() self.handle:read_stop() end)
  pcall(function() self.handle:close() end)
end

function Conn:write(bytes)
  if self.closed then return false end
  self.handle:write(bytes)
  return true
end

-- Waits until the buffer holds at least `n` bytes, then consumes them.
function Conn:take(n, timeout_ms)
  vim.wait(timeout_ms or EXCHANGE_TIMEOUT_MS, function()
    return #self.buffer >= n or self.closed
  end, 5)
  if #self.buffer < n then return nil end
  local taken = self.buffer:sub(1, n)
  self.buffer = self.buffer:sub(n + 1)
  return taken
end

-- One frame: <kind><BE32 len><body>. Returns kind, fields.
function Conn:frame(timeout_ms)
  local head = self:take(5, timeout_ms)
  if not head then return nil end
  local len = unpack_be32(head, 2)
  local body = ""
  if len > 0 then
    body = self:take(len, timeout_ms)
    if not body then return nil end
  end
  return head:sub(1, 1), decode_fields(body)
end

--------------------------------------------------------------------------------
-- Credentials (§9.2). The token never crosses the wire; only digests do.
--------------------------------------------------------------------------------

-- Every pushed token this machine holds, validated the way §9.2 requires:
-- exactly 64 lowercase hex on a single line, nothing trailing, and no group or
-- other permission bits. A file failing any check is treated as absent.
local function held_tokens()
  local dir = state_home() .. "/clipboard/tunnel-tokens"
  local entries = vim.fn.readdir(dir)
  if vim.v.shell_error ~= 0 or type(entries) ~= "table" then return {} end
  table.sort(entries)
  local tokens = {}
  for _, name in ipairs(entries) do
    local path = dir .. "/" .. name
    local stat = uv.fs_stat(path)
    if stat and stat.type == "file" and (stat.mode % 64) == 0 then
      local fd = io.open(path, "r")
      if fd then
        local blob = fd:read("*a")
        fd:close()
        local line, rest = blob:match("^([^\n]*)\n?(.*)$")
        if rest == "" and line and #line == 64 and line:match("^[0-9a-f]+$") then
          tokens[#tokens + 1] = line
        end
      end
    end
  end
  return tokens
end

--------------------------------------------------------------------------------
-- A session: preamble, hello, and — on the public endpoint — the server's
-- proof, verified before anything else it said is believed (§8 rule 6).
--------------------------------------------------------------------------------
local Session = {}
Session.__index = Session

-- open(target) -> session, err
--   err.absent distinguishes "nothing is bound" from every other failure.
local function open(target)
  local conn, failed = connect(target)
  if not conn then return nil, failed end

  conn:write(WIRE_MAGIC .. string.char(WIRE_VERSION))

  local preamble = conn:take(6, PREAMBLE_TIMEOUT_MS)
  if not preamble or preamble:sub(1, 5) ~= WIRE_MAGIC then
    conn:close()
    -- A connect that completed and then said nothing recognizable is a
    -- reachable-but-not-RECOB endpoint (§7.3), never an absent bridge.
    return nil, { absent = false, err = "not a RECOB endpoint" }
  end
  if preamble:byte(6) ~= WIRE_VERSION then
    conn:close()
    return nil, { absent = false, err = "wire version " .. preamble:byte(6) }
  end

  local kind, banner = conn:frame()
  if kind ~= "H" then
    conn:close()
    return nil, { absent = false, err = "no banner" }
  end

  local hello = {
    { "proto", tostring(PROTO) },
    { "impl", "nvim" },
  }
  local cnonce, tokens
  if target.public then
    tokens = held_tokens()
    if #tokens == 0 then
      conn:close()
      return nil, {
        absent = false,
        err = "no pushed credential for this endpoint -- reconnect so ssh-prepare-connection can push one",
      }
    end
    if not banner.nonce or #banner.nonce == 0 then
      conn:close()
      return nil, { absent = false, err = "banner carried no challenge" }
    end
    -- 32 bytes from the same CSPRNG the daemon uses. vim.fn.sha256 handles
    -- embedded NULs byte-exactly (verified against shasum), which matters:
    -- roughly one nonce in eight contains one.
    local raw = io.open("/dev/urandom", "rb")
    if not raw then
      conn:close()
      return nil, { absent = false, err = "no randomness" }
    end
    cnonce = raw:read(32)
    raw:close()
    local digests = {}
    for i = 1, math.min(#tokens, 8) do
      digests[i] = vim.fn.sha256(tokens[i] .. ":c:" .. banner.nonce)
    end
    hello[#hello + 1] = { "auth", table.concat(digests, "\0") }
    hello[#hello + 1] = { "cnonce", cnonce }
  end
  conn:write(encode_frame("H", hello))

  local caps_kind, caps = conn:frame()
  if caps_kind == "E" then
    conn:close()
    return nil, { absent = false, err = (caps.code or "error") .. ": " .. (caps.message or "") }
  end
  if caps_kind ~= "C" then
    conn:close()
    return nil, { absent = false, err = "no capabilities frame" }
  end
  if target.public then
    -- §9.2 step 3: the endpoint answers the challenge THIS client chose, with
    -- a proof derived from a token this client actually holds. Until it has,
    -- nothing it sent may drive a decision.
    local proven = false
    for i = 1, math.min(#tokens, 8) do
      if caps.proof == vim.fn.sha256(tokens[i] .. ":s:" .. cnonce) then
        proven = true
      end
    end
    if not proven then
      conn:close()
      return nil, { absent = false, err = "the endpoint did not prove itself" }
    end
  end

  return setmetatable({ conn = conn, caps = caps.caps or "" }, Session), nil
end

function Session:close()
  self.conn:close()
end

-- One exchange. Returns fields on `R`, or nil plus an error table whose `code`
-- is the contract (§8 rule 3 — no client branches on message text).
function Session:exchange(fields)
  if not self.conn:write(encode_frame("Q", fields)) then
    return nil, { err = "connection closed" }
  end
  local kind, reply = self.conn:frame()
  if kind == "R" then return reply, nil end
  if kind == "E" then
    return nil, { code = reply.code, message = reply.message }
  end
  return nil, { err = "unexpected frame " .. tostring(kind) }
end

local function trusted_session()
  return open({ socket = TRUSTED_SOCKET })
end

local function peer_session()
  return open({ host = BRIDGE_HOST, port = BRIDGE_PORT, public = true })
end

--------------------------------------------------------------------------------
-- Regtype normalization (unchanged): NeoVim hands copy() "v", "V" or "b"; the
-- wire and setreg() speak "v"/"l"/"b".
--------------------------------------------------------------------------------
local function norm_regtype(rt)
  if not rt or rt == "" then return "v" end
  local c = rt:sub(1, 1)
  if c == "V" or c == "l" then return "l" end
  if c == "b" or c == "\22" then return "b" end
  return "v"
end

local function infer_regtype(text)
  return text:sub(-1) == "\n" and "l" or "v"
end

local function to_lines(text)
  if text:sub(-1) == "\n" then text = text:sub(1, -2) end
  return vim.split(text, "\n", { plain = true })
end

local function sys(cmd)
  if vim.fn.executable(cmd[1]) == 0 then return "" end
  return (vim.fn.system(cmd) or ""):gsub("%s+$", "")
end

-- This machine's stable identity, self-name first — the same precedence the
-- daemon and the shims use, so every writer agrees on what this machine is
-- called.
local MY_HOST
local function my_host()
  if MY_HOST then return MY_HOST end
  local fd = io.open(state_home() .. "/clipboard/self-name", "r")
  if fd then
    local blob = fd:read("*a")
    fd:close()
    local line, rest = blob:match("^([^\n]*)\n?(.*)$")
    if rest == "" and line and line:match("^[A-Za-z0-9][A-Za-z0-9.%-]*$") then
      MY_HOST = line
    end
  end
  if not MY_HOST then
    local out = sys({ "scutil", "--get", "LocalHostName" })
    if out == "" then out = sys({ "hostname", "-s" }) end
    if out ~= "" then MY_HOST = out end
  end
  return MY_HOST
end

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

local function write_cache(lines, regtype)
  local path = cache_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = io.open(path, "w")
  if f then
    f:write(regtype .. "\n" .. table.concat(lines, "\n"))
    f:close()
  end
end

local function warn(message)
  vim.notify("clipboard: " .. message, vim.log.levels.WARN)
end

-- The local history row for a copy that originated here. Best-effort and
-- never blocking the copy: it is this machine's own history, and the
-- clipboard the caller asked for is already set.
local function persist_local(host, text, regtype)
  if not host then return end
  local session = trusted_session()
  if not session then return end
  session:exchange({
    { "op", "store.persist.text" },
    { "host", host },
    { "kind", "text" },
    { "app", "" },
    { "regtype", regtype },
    { "text", text },
  })
  session:close()
end

--------------------------------------------------------------------------------
-- copy. One exchange carries the text, its register type and its provenance.
--------------------------------------------------------------------------------
function M.copy(reg)
  local osc52 = require("vim.ui.clipboard.osc52").copy(reg)
  return function(lines, regtype)
    local rt = norm_regtype(regtype)
    write_cache(lines, rt)
    local text = table.concat(lines, "\n")

    if not ssh() then
      -- Local: the trusted socket sets this machine's own clipboard, and the
      -- daemon writes the row in the same operation.
      local session, failed = trusted_session()
      if not session then
        warn("bridge unavailable (" .. (failed and failed.err or "unknown") .. ")")
        return
      end
      local _, err = session:exchange({
        { "op", "clip.set" },
        { "text", text },
        { "regtype", rt },
      })
      session:close()
      if err then warn(err.code or err.err or "copy failed") end
      return
    end

    local host = my_host()
    local session, failed = peer_session()
    if not session then
      if failed and failed.absent then
        -- Nothing is bound: the one state that permits the less trusted path.
        osc52(lines)
      else
        -- Reachable but unsatisfied. Failing loudly here is what keeps
        -- authentication a control rather than a suggestion (§5.2).
        warn("copy failed -- " .. (failed and failed.err or "bridge error"))
      end
      return
    end
    local fields = {
      { "op", "clip.set" },
      { "text", text },
      { "regtype", rt },
    }
    if host then fields[#fields + 1] = { "origin_host", host } end
    local _, err = session:exchange(fields)
    session:close()
    if err then
      warn("copy failed -- " .. (err.code or err.err or "bridge error"))
      return
    end
    persist_local(host, text, rt)
  end
end

--------------------------------------------------------------------------------
-- paste. One `clip.get` returns the text and its register type together — the
-- G+R pair, and the second connection it cost, are gone (§6.2).
--------------------------------------------------------------------------------
function M.paste()
  return function()
    local cached_rt, cached_text = read_cache()
    local session, failed = (ssh() and peer_session or trusted_session)()

    if session then
      local reply, err = session:exchange({ { "op", "clip.get" } })
      if not err and reply then
        local text = reply.text or ""
        local rt = reply.regtype
        if rt ~= "v" and rt ~= "l" and rt ~= "b" then
          rt = cached_rt or infer_regtype(text)
        end
        -- Self-contained clips: over the tunnel this text is the peer's, so a
        -- full copy is recorded here and survives the peer going offline. The
        -- daemon captures local copies itself.
        if ssh() then
          persist_local(reply.host, text, rt)
        end
        session:close()
        return { to_lines(text), rt }
      end
      session:close()
      if err then warn("paste failed -- " .. (err.code or err.err or "bridge error")) end
    elseif failed and not failed.absent then
      warn("paste failed -- " .. failed.err)
    end

    -- Local state only: the per-process cache, then the unnamed register.
    -- Nothing here is a less trusted transport, so nothing is disclosed.
    if cached_text then
      return { vim.split(cached_text, "\n", { plain = true }), cached_rt or "v" }
    end
    return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
  end
end

function M.setup()
  local is_ssh = ssh()
  BRIDGE_PORT = tonumber(vim.env.CLIPBOARD_BRIDGE_PORT) or 2490
  vim.opt.clipboard = "unnamedplus"
  vim.g.clipboard = {
    name = is_ssh and "universal-ssh" or "universal-local",
    copy = { ["+"] = M.copy("+"), ["*"] = M.copy("*") },
    paste = { ["+"] = M.paste(), ["*"] = M.paste() },
  }
end

-- Test seams: the pure codec halves, so a spec can drive the framing without
-- a live bridge.
M._encode_frame = encode_frame
M._decode_fields = decode_fields
M._pack_be32 = pack_be32

return M
