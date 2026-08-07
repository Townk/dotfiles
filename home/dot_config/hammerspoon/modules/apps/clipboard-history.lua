--- apps/clipboard-history.lua — the READ path, after the daemon took over.
---
--- STAGED, NOT INSTALLED. This file replaces
--- `home/dot_config/hammerspoon/modules/apps/clipboard-history.lua` in Phase 8's
--- cutover change, together with the shims, the provider and the build hook.
--- It cannot land earlier: the moment this module stops capturing, the machine
--- has no clipboard history at all until `recobd` is installed and running.
---
--- WHAT WENT, AND WHY (spec §14.4). The daemon writes the pasteboard and polls
--- `changeCount`, so it knows whether it caused a change; the watcher this
--- module used to run was a second, blind observer of the same events. While
--- both ran, every copy produced two rows or one row and a dedup update —
--- nothing errored, the store just quietly doubled. Absorption is not complete
--- until the old writer stops, and this is the step most likely to be skipped
--- because everything appears to work without it.
---
--- Deleted here, now implemented by the daemon (§14.2): the pasteboard watcher
--- and `capture_now`, the sensitive-UTI refusal, the password-manager
--- deny-list, the loginwindow echo guard, classification, the 5 MB image cap,
--- `type_hash` dedup, retention, `file_authorities`, and the `current-origin` /
--- `current-regtype` sidecar files with their TTLs and hash keying.
---
--- What remains is the read path the pickers use, plus restore — which is now
--- a request to the daemon rather than an in-process pasteboard write, because
--- sole-writer means sole-writer (§14.5). The store is opened READ-ONLY, so a
--- reintroduced write fails loudly here instead of racing the daemon.
---
--- API (unchanged for callers):
---   ch.setup()                   -- open the store read-only
---   ch.cleanup()                 -- close it (registered with lifecycle)
---   ch.restore_by_id(id)         -- full-fidelity restore, via the daemon
---   ch.restore_plain_by_id(id)   -- the degrade-to-text restore (Alt+Enter)

---@diagnostic disable: undefined-global
local M = {}

local sqlite3 = require("hs.sqlite3")

local db -- read-only handle; the pickers' queries run through it

local function data_dir()
  return os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") or "") .. "/.local/share"
end

local function db_path()
  return data_dir() .. "/pick-clipboard/history.db"
end

-- The compiled client, which owns the one implementation of the wire (§8).
-- Restore goes through it rather than through a hand-rolled framing here: a
-- third implementation of the protocol is exactly what the client contract
-- exists to prevent, and a picker action can afford one exec of a static
-- binary.
local function system_clip()
  return os.getenv("SYSTEM_CLIP_BIN") or ((os.getenv("HOME") or "") .. "/.local/bin/system-clip")
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

-- Ask the daemon to restore. Returns true on success; on failure the daemon's
-- own diagnostic reaches the Hammerspoon console, since a silent false here
-- would look identical to an empty clip.
local function restore(id, plain_only)
  if not id then return false end
  local bin = system_clip()
  if not hs.fs.attributes(bin, "mode") then
    hs.printf("clipboard-history: %s is missing -- run chezmoi apply", bin)
    return false
  end
  local cmd = shell_quote(bin) .. " restore " .. shell_quote(id)
  if plain_only then cmd = cmd .. " --plain" end
  local output, ok = hs.execute(cmd .. " 2>&1")
  if not ok then
    hs.printf("clipboard-history: restore failed -- %s", (output or ""):gsub("%s+$", ""))
    return false
  end
  return true
end

--- This machine's stable hostname, as the pickers compare against each row's
--- `source_host` to badge a remote clip. Same precedence every other reader
--- uses: the pushed self-name first, then scutil, then hostname -s.
local MY_HOST
local function my_host()
  if MY_HOST == nil then
    local state = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
    local f = io.open(state .. "/clipboard/self-name", "r")
    if f then
      local blob = f:read("*a")
      f:close()
      local line, rest = blob:match("^([^\n]*)\n?(.*)$")
      if rest == "" and line and line:match("^[A-Za-z0-9][A-Za-z0-9.%-]*$") then
        MY_HOST = line
      end
    end
    if MY_HOST == nil then
      local out = hs.execute("scutil --get LocalHostName 2>/dev/null") or ""
      MY_HOST = (out:gsub("%s+$", ""))
      if MY_HOST == "" then MY_HOST = (hs.host.localizedName() or "") end
    end
  end
  return MY_HOST
end

local PREVIEW_MAX_BYTES = 100

-- Truncate to at most `budget` bytes without splitting a UTF-8 sequence.
local function clip_bytes(s, budget)
  if #s <= budget then return s end
  local cut = budget
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b > 0xBF then break end
    cut = cut - 1
  end
  return s:sub(1, cut)
end

-- One-line snippet for the preview column. Kept here, and still exported,
-- because the picker calls it to re-derive a snippet for rows stored before
-- the flattening existed — a read-path concern, not a capture one.
local function preview_of(text)
  if text == nil then return nil end
  local parts, len = {}, 0
  for line in text:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      parts[#parts + 1] = trimmed
      len = len + #trimmed + 1
      if len > PREVIEW_MAX_BYTES then break end
    end
  end
  local flat = table.concat(parts, " ")
  if #flat > PREVIEW_MAX_BYTES then
    return clip_bytes(flat, PREVIEW_MAX_BYTES) .. "…"
  end
  return flat
end
M._preview_of = preview_of

--- setup — open the store READ-ONLY and start nothing.
---
--- The mode is the assertion: with the daemon as sole writer, any write from
--- this process is a bug, and a read-only handle turns it into an immediate
--- error instead of a row that races the daemon's own. There is no watcher and
--- no schema creation here either — `recobd` owns both, and a Hammerspoon
--- reload must not recreate a store the daemon is serving.
function M.setup()
  if db then return end
  local handle, _, err = sqlite3.open(db_path(), sqlite3.OPEN_READONLY)
  if type(handle) ~= "userdata" then
    -- Before the daemon has ever run there may be no store at all; that is not
    -- an error worth a dialog, but it is worth saying once.
    hs.printf("clipboard-history: cannot open %s read-only (%s)", db_path(), tostring(err))
    return
  end
  db = handle
end

function M.cleanup()
  if db then
    db:close()
    db = nil
  end
end

--------------------------------------------------------------------------------
-- Restore (spec §14.5). Both entry points keep their names and their return
-- contract, so the picker's call sites are unchanged; what moved is who
-- performs the pasteboard write.
--------------------------------------------------------------------------------

--- Restore a clip's full stored representation set by id. The daemon
--- reinstates the row's register type and bumps `last_ts`, and — because it
--- performed the write itself — records no new row for it.
function M.restore_by_id(id)
  return restore(id, false)
end

--- The degrade-to-something-pasteable restore the picker binds to Alt+Enter:
--- a markdown link for file/directory/url/image rows, the plain text
--- otherwise, a derived plain form when there is none, and deliberately no
--- register type reinstated.
function M.restore_plain_by_id(id)
  return restore(id, true)
end

-- Read/inspection helpers the pickers and specs use.
function M._db_path() return db_path() end
function M._my_host() return my_host() end
function M._row_count()
  if not db then return nil end
  local s = db:prepare("SELECT COUNT(*) FROM clips;")
  if not s then return nil end
  local n
  if s:step() == sqlite3.ROW then n = s:get_value(0) end
  s:finalize()
  return n
end

return M
