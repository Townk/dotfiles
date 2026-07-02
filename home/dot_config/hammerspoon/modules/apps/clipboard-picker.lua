--- apps/clipboard-picker.lua
--- Cmd+Shift+V clipboard picker — a custom hs.webview UI matching the
--- WhichKey overlay's visual identity (rounded corners, translucent bordered
--- panel — see Assets/html/which-key-overlay.css), extended with a split
--- list/preview/metadata layout, rich HTML/RTF/image preview, and the
--- terminal picker's keybindings.
---
--- Replaces the Phase-4 hs.chooser-based picker: hs.chooser cannot do split
--- panes, custom border/corner-radius styling, or bind arbitrary in-overlay
--- keys (Ctrl-D delete, Ctrl-P pin, Alt-Enter insert-without-dismiss), so
--- this is a full hs.webview + HTML/CSS/JS UI, the same technique the
--- WhichKey overlay (modules/keybindings/overlay.lua) already uses for its
--- visual identity — but interactive (allowTextEntry(true), a real focused
--- window) where WhichKey is a read-only HUD.
---
--- Architecture: the initial list load embeds only cheap fields (id,
--- preview, kind, pinned, source_app, len, group, age, words) as JSON in the
--- page; filtering + selection happen entirely client-side in JS (no
--- per-keystroke round trip). Rich preview content (potentially MB-sized
--- blobs) is fetched from Lua on selection change only, via the
--- hs.webview.usercontent message bridge — the same one-way mechanism
--- WhichKey uses for its size-report callback, extended here to carry
--- preview/delete/pin/accept/dismiss messages from JS to Lua.
---
--- API:
---   local picker = require("apps.clipboard-picker")
---   picker.show()     -- open (or refresh + focus, if already open)
---   picker.hide()      -- dismiss
---   picker.toggle()
---   picker.cleanup()   -- delete the webview (register with lifecycle)

local M = {}

local sqlite3 = require("hs.sqlite3")
local history = require("apps.clipboard-history")

local ASSETS_DIR = hs.configdir .. "/Assets/html"

--------------------------------------------------------------------------------
-- Template loading (mirrors modules/keybindings/template.lua's approach)
--------------------------------------------------------------------------------

local htmlTemplateRaw, cssTemplateRaw

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function ensure_templates()
  if not cssTemplateRaw then
    cssTemplateRaw = read_file(ASSETS_DIR .. "/clipboard-picker.css")
    assert(cssTemplateRaw, "clipboard-picker: CSS template not found")
  end
  if not htmlTemplateRaw then
    htmlTemplateRaw = read_file(ASSETS_DIR .. "/clipboard-picker.html")
    assert(htmlTemplateRaw, "clipboard-picker: HTML template not found")
  end
end

-- Substitute %%KEY%% placeholders. Function-based gsub replacement values are
-- inserted verbatim (not re-interpreted as %n capture references), so no
-- extra escaping is needed here — same technique as template.lua.
local function substitute(tmpl, subs)
  return (tmpl:gsub("%%%%([%w_]+)%%%%", function(key)
    local val = subs[key]
    if val ~= nil then return tostring(val) end
    hs.printf("clipboard-picker: unresolved placeholder %%%%%s%%%%", key)
    return ""
  end))
end

--------------------------------------------------------------------------------
-- Row projection: date-bucket grouping, word count, display labels
--------------------------------------------------------------------------------

local KIND_LABELS = {
  text = "Plain Text", rtf = "Rich Text", html = "HTML",
  image = "Image", files = "Files", mixed = "Mixed",
}

local function age_string(ts, now)
  local diff = math.max(0, now - ts)
  if diff < 60 then return math.floor(diff) .. "s ago"
  elseif diff < 3600 then return math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then return math.floor(diff / 3600) .. "h ago"
  else return math.floor(diff / 86400) .. "d ago" end
end

-- Today / Yesterday / <weekday> (this week) / <Mon DD> (older). Computed from
-- calendar-day difference at local noon (DST-safe), not raw second deltas.
local function group_label(ts, now)
  -- last_ts is a SQLite REAL (fractional seconds from hs.timer.secondsSinceEpoch);
  -- os.date/os.time require an integer, hence the floor.
  ts = math.floor(ts)
  now = math.floor(now)
  local function midday(t)
    local d = os.date("*t", t)
    return os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
  end
  local diffDays = math.floor((midday(now) - midday(ts)) / 86400 + 0.5)
  if diffDays <= 0 then return "Today"
  elseif diffDays == 1 then return "Yesterday"
  elseif diffDays < 7 then return os.date("%A", ts)
  else return os.date("%b %d", ts) end
end

local function count_words(text)
  if not text or text == "" then return 0 end
  local n = 0
  for _ in text:gmatch("%S+") do n = n + 1 end
  return n
end

-- Top N clips (local + remote-own; laptop-ref rows can't be rich-restored
-- here — same origin filter as the Phase-4 chooser and the terminal picker).
local function query_items()
  local db = sqlite3.open(history._db_path())
  if not db then return {} end
  local s = assert(db:prepare([[
    SELECT id, text_preview, text_plain, type_kind, source_app, len, pinned, last_ts
    FROM clips
    WHERE origin IN ('local','remote-own')
    ORDER BY pinned DESC, last_ts DESC
    LIMIT 500;
  ]]))
  local items = {}
  local now = os.time()
  while s:step() == sqlite3.ROW do
    local kind = s:get_value(3) or "text"
    local plain = s:get_value(2)
    local last_ts = s:get_value(7) or now
    items[#items + 1] = {
      id        = s:get_value(0),
      preview   = s:get_value(1) or ("[" .. kind .. "]"),
      kind      = kind,
      kindLabel = KIND_LABELS[kind] or kind,
      app       = s:get_value(4) or "?",
      len       = s:get_value(5) or 0,
      words     = count_words(plain),
      pinned    = (s:get_value(6) or 0) == 1,
      group     = group_label(last_ts, now),
      age       = age_string(last_ts, now),
    }
  end
  s:finalize()
  db:close()
  return items
end

--------------------------------------------------------------------------------
-- Rich preview generation (fetched from Lua on selection change only)
--------------------------------------------------------------------------------

local IMAGE_UTIS = { "public.png", "public.jpeg", "public.tiff", "com.compuserve.gif" }
local IMAGE_MIME = {
  ["public.png"] = "image/png", ["public.jpeg"] = "image/jpeg",
  ["public.tiff"] = "image/tiff", ["com.compuserve.gif"] = "image/gif",
}

-- First matching (blob, uti) pair for the given clip id across candidate UTIs.
local function fetch_blob(db, id, utis)
  for _, uti in ipairs(utis) do
    local s = db:prepare("SELECT blob FROM clip_types WHERE clip_id=? AND uti=?;")
    if s then
      s:bind(1, id); s:bind(2, uti)
      local blob
      if s:step() == sqlite3.ROW then blob = s:get_value(0) end
      s:finalize()
      if blob then return blob, uti end
    end
  end
  return nil, nil
end

local function fetch_text_plain(db, id)
  local s = db:prepare("SELECT text_plain FROM clips WHERE id=?;")
  local text
  if s then
    s:bind(1, id)
    if s:step() == sqlite3.ROW then text = s:get_value(0) end
    s:finalize()
  end
  return text
end

-- Build the preview payload {kind="text"|"html"|"image", ...} for a clip id.
-- rtf/rtfd is converted to HTML natively via hs.styledtext (no shell-out).
-- Falls back to text_plain when a rich payload is missing or unconvertible.
local function fetch_preview(id, kind)
  local db = sqlite3.open(history._db_path())
  if not db then return { kind = "text", text = "" } end

  local result
  if kind == "html" then
    local blob = fetch_blob(db, id, { "public.html" })
    if blob then result = { kind = "html", html = blob } end
  elseif kind == "rtf" then
    local blob, uti = fetch_blob(db, id, {
      "public.rtf", "NeXT RTFD pasteboard type", "Apple RTFD pasteboard type",
    })
    if blob then
      local rtfType = (uti == "public.rtf") and "rtf" or "rtfd"
      local ok, st = pcall(hs.styledtext.getStyledTextFromData, blob, rtfType)
      if ok and st then
        local ok2, htmlOut = pcall(function() return st:convert("html") end)
        if ok2 and htmlOut then result = { kind = "html", html = htmlOut } end
      end
    end
  elseif kind == "image" then
    local blob, uti = fetch_blob(db, id, IMAGE_UTIS)
    if blob then
      local ok, b64 = pcall(hs.base64.encode, blob)
      if ok and b64 then
        result = { kind = "image", dataUri = "data:" .. (IMAGE_MIME[uti] or "image/png") .. ";base64," .. b64 }
      end
    end
  elseif kind == "files" then
    -- Best-effort: public.file-url blobs are typically UTF8 file:// URL
    -- bytes; render as-is (monospace) rather than attempting full NSURL
    -- bookmark-data decoding. Known limitation, not exhaustive.
    local blob = fetch_blob(db, id, { "public.file-url" })
    if blob then result = { kind = "text", text = blob } end
  end

  if not result then
    result = { kind = "text", text = fetch_text_plain(db, id) or "" }
  end

  db:close()
  return result
end

local function delete_item(id)
  local db = sqlite3.open(history._db_path())
  if not db then return end
  local d1 = db:prepare("DELETE FROM clip_types WHERE clip_id=?;")
  if d1 then d1:bind(1, id); d1:step(); d1:finalize() end
  local d2 = db:prepare("DELETE FROM clips WHERE id=?;")
  if d2 then d2:bind(1, id); d2:step(); d2:finalize() end
  db:close()
end

local function toggle_pin(id)
  local db = sqlite3.open(history._db_path())
  if not db then return false end
  local u = db:prepare("UPDATE clips SET pinned = 1 - pinned WHERE id=?;")
  if u then u:bind(1, id); u:step(); u:finalize() end
  local pinned = false
  local s = db:prepare("SELECT pinned FROM clips WHERE id=?;")
  if s then
    s:bind(1, id)
    if s:step() == sqlite3.ROW then pinned = (s:get_value(0) == 1) end
    s:finalize()
  end
  db:close()
  return pinned
end

--------------------------------------------------------------------------------
-- Webview lifecycle
--------------------------------------------------------------------------------

local webview
local ucc
local savedWindow -- the app window focused before the picker opened
local isShown = false

local function build_html(items)
  ensure_templates()
  return substitute(htmlTemplateRaw, {
    CSS = cssTemplateRaw,
    -- hs.json.encode escapes '/' as '\/', which prevents a "</script>"
    -- breakout inside the embedded JSON literal (verified empirically:
    -- encode() on a string containing "</b>" yields "<\/b>", so no literal
    -- "</script" byte sequence can appear even if a clip's preview text
    -- contains that string).
    ITEMS_JSON = hs.json.encode(items),
  })
end

local function handle_message(body)
  if type(body) ~= "table" or not body.action then return end
  local action = body.action

  if action == "preview" then
    local content = fetch_preview(body.id, body.kind)
    if webview then
      webview:evaluateJavaScript("window.__setPreview(" .. hs.json.encode(content) .. ")")
    end
  elseif action == "delete" then
    delete_item(body.id)
  elseif action == "pin" then
    local pinned = toggle_pin(body.id)
    if webview then
      webview:evaluateJavaScript(string.format("window.__setPinned(%d, %s)", body.id, tostring(pinned)))
    end
  elseif action == "accept" then
    history.restore_by_id(body.id)
    if body.dismiss then
      M.hide()
      -- Post the paste just after hide() refocuses the target app.
      hs.timer.doAfter(0.12, function() hs.eventtap.keyStroke({ "cmd" }, "v") end)
    else
      -- Alt+Enter: paste into the target app but keep the picker open. This
      -- necessarily shuffles focus away (to paste into the right app) and
      -- back (to keep accepting keystrokes) — a brief visible flash is
      -- expected/inherent, not a bug; validate the feel in UX review.
      local target = savedWindow
      hs.timer.doAfter(0.02, function()
        if target then target:focus() end
        hs.timer.doAfter(0.1, function()
          hs.eventtap.keyStroke({ "cmd" }, "v")
          hs.timer.doAfter(0.1, function()
            if webview then
              webview:show()
              local hsWin = webview:hswindow()
              if hsWin then hsWin:focus() end
              webview:evaluateJavaScript("window.__focusInput && window.__focusInput()")
            end
          end)
        end)
      end)
    end
  elseif action == "dismiss" then
    M.hide()
  end
end

local function ensure_webview()
  if webview then return end
  ucc = hs.webview.usercontent.new("clipboardPicker")
  ucc:setCallback(function(msg) handle_message(msg.body) end)

  local sf = hs.screen.mainScreen():fullFrame()
  local w, h = 780, 520
  local rect = { x = sf.x + (sf.w - w) / 2, y = sf.y + (sf.h - h) / 2, w = w, h = h }

  webview = hs.webview.new(rect, {}, ucc)
  webview:transparent(true)
  webview:windowStyle({ "borderless" })
  -- modalPanel (not WhichKey's "overlay" + nonactivating): this picker needs
  -- to become a real, focused key window so the search field can accept
  -- keyboard input, unlike the read-only WhichKey HUD.
  webview:level(hs.drawing.windowLevels.modalPanel)
  webview:allowTextEntry(true)
  webview:shadow(true)
  webview:deleteOnClose(false)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.show()
  ensure_webview()
  savedWindow = hs.window.focusedWindow()
  webview:html(build_html(query_items()))
  webview:show()
  webview:bringToFront(true)
  -- Hammerspoon is a background/accessory app: showing a window does NOT by
  -- itself make it the key window or activate the app, so keyboard input
  -- goes nowhere until the user manually clicks it. hswindow():focus() is
  -- the same call hs.window uses to raise+activate a normal app window, and
  -- works on a webview's own window too (verified: hs.window.focusedWindow()
  -- afterward matches this window's id).
  local hsWin = webview:hswindow()
  if hsWin then hsWin:focus() end
  isShown = true
end

function M.hide()
  if webview then webview:hide() end
  isShown = false
  -- Without this, focus stays claimed by the (now hidden) webview's window
  -- and keyboard input goes nowhere until the user manually clicks another
  -- window — explicitly hand focus back to whatever was focused before show().
  if savedWindow then
    savedWindow:focus()
    savedWindow = nil
  end
end

function M.toggle()
  if isShown then M.hide() else M.show() end
end

function M.cleanup()
  if webview then webview:delete(); webview = nil end
  ucc = nil
  isShown = false
end

-- Test/inspection helpers (not used in production paths).
M._query_items = query_items
M._group_label = group_label
M._count_words = count_words
M._fetch_preview = fetch_preview

return M
