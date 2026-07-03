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
local dismissOnBlur = require("system.dismiss-on-blur")

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
  file = "File", directory = "Directory", url = "URL",
}

local function age_string(ts, now)
  local diff = math.max(0, now - ts)
  if diff < 60 then return math.floor(diff) .. "s ago"
  elseif diff < 3600 then return math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then return math.floor(diff / 3600) .. "h ago"
  else return math.floor(diff / 86400) .. "d ago" end
end

-- 1st/2nd/3rd/4th... suffix for a day-of-month number.
local function ordinal_suffix(day)
  local rem100 = day % 100
  if rem100 >= 11 and rem100 <= 13 then return "th" end
  local rem10 = day % 10
  if rem10 == 1 then return "st"
  elseif rem10 == 2 then return "nd"
  elseif rem10 == 3 then return "rd"
  else return "th" end
end

-- "Tuesday, July 4th 2025" -- full weekday + full month + ordinal day + year.
local function full_date_label(ts)
  local d = os.date("*t", ts)
  return os.date("%A, %B ", ts) .. d.day .. ordinal_suffix(d.day) .. os.date(" %Y", ts)
end

-- Pinned / Today / Yesterday / <full date> (everything else). Pinned always
-- wins regardless of date, so pinned items form their own group at the top
-- (the SQL query already sorts pinned DESC, last_ts DESC, so they're
-- already contiguous). Date grouping is computed from calendar-day
-- difference at local noon (DST-safe), not raw second deltas.
local function group_label(ts, now, pinned)
  if pinned then return "Pinned" end
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
  else return full_date_label(ts) end
end

local function count_words(text)
  if not text or text == "" then return 0 end
  local n = 0
  for _ in text:gmatch("%S+") do n = n + 1 end
  return n
end

-- Top N clips. Self-contained model (spec §11): the picker always shows THIS
-- Mac's whole store — no peer union, no origin filter. Every clip it shows, it
-- holds in full, so accepting one is always a local restore. `source_host`
-- drives only the per-row local/remote badge, never visibility.
local function query_items()
  local db = sqlite3.open(history._db_path())
  if not db then return {} end
  local s = assert(db:prepare([[
    SELECT id, text_preview, text_plain, type_kind, source_app, source_bundle_id, len, pinned, last_ts, source_host
    FROM clips
    ORDER BY pinned DESC, last_ts DESC
    LIMIT 500;
  ]]))
  local items = {}
  local now = os.time()
  local my_host = history._my_host()
  while s:step() == sqlite3.ROW do
    local kind = s:get_value(3) or "text"
    local plain = s:get_value(2)
    local last_ts = s:get_value(8) or now
    local pinned = (s:get_value(7) or 0) == 1
    -- Provenance (§11): remote iff copied on a different host. NULL source_host
    -- (legacy rows) reads as local.
    local host = s:get_value(9)
    items[#items + 1] = {
      id        = s:get_value(0),
      preview   = s:get_value(1) or ("[" .. kind .. "]"),
      kind      = kind,
      kindLabel = KIND_LABELS[kind] or kind,
      app       = s:get_value(4) or "?",
      bundleId  = s:get_value(5), -- nil for clips captured before this column existed
      len       = s:get_value(6) or 0,
      words     = count_words(plain),
      pinned    = pinned,
      remote    = (host ~= nil and host ~= "" and host ~= my_host),
      sourceHost = host,
      group     = group_label(last_ts, now, pinned),
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

-- Cache of bundleId -> data-URI icon string (or false for "looked up, no
-- icon found" -- cached too, so a missing/uninstalled app isn't re-queried
-- on every selection change). Lives for the module's lifetime; M.cleanup()
-- only ever runs right before a full hs.reload(), which wipes this (and
-- every other module-level local) anyway, so there's nothing to explicitly
-- clear here.
local iconCache = {}

-- Best-effort bundle ID resolution from an app's display name, for clips
-- captured before source_bundle_id existed (nothing else to go on for
-- those). Mirrors streamdeck/layers.lua's resolveAppBundleID: try the app
-- if it's currently running first (exact, no guessing), else guess the
-- same 4 common install directories it checks. Not reused directly from
-- there since it's a private helper scoped to that module's own streamdeck
-- concerns -- duplicating ~15 lines here beats a cross-module refactor for
-- what's just a fallback path for pre-migration data.
local function guess_bundle_id_from_name(name)
  local running = hs.application.get(name)
  if running then
    local ok, id = pcall(function() return running:bundleID() end)
    if ok and id then return id end
  end
  local paths = {
    "/Applications/" .. name .. ".app",
    "/System/Applications/" .. name .. ".app",
    "/Applications/Utilities/" .. name .. ".app",
    "/System/Applications/Utilities/" .. name .. ".app",
  }
  for _, path in ipairs(paths) do
    local info = hs.application.infoForBundlePath(path)
    if info and info.CFBundleIdentifier then return info.CFBundleIdentifier end
  end
  return nil
end

-- Fetch the app's real icon as a data-URI string (base64 PNG via
-- hs.image:encodeAsURLString(), ready to use directly as an <img src>),
-- cached by bundle id since the same handful of apps repeat across many
-- clips. Falls back to guessing the bundle id from appName when bundleId
-- is nil (pre-migration clips). Returns nil if nothing resolves or no icon
-- is found.
local function fetch_app_icon(bundleId, appName)
  local key = bundleId
  if not key or key == "" then
    if not appName or appName == "" then return nil end
    key = guess_bundle_id_from_name(appName)
    if not key then return nil end
  end
  local cached = iconCache[key]
  if cached ~= nil then
    return cached or nil
  end
  local ok, img = pcall(hs.image.imageFromAppBundle, key)
  local dataUri
  if ok and img then
    local ok2, encoded = pcall(function() return img:encodeAsURLString() end)
    if ok2 and encoded then dataUri = encoded end
  end
  iconCache[key] = dataUri or false
  return dataUri
end

local FILE_PREVIEW_MAX_BYTES = 65536

-- Heuristic "is this a text file" check on a bounded sample: reject NUL
-- bytes (binary formats almost always contain one early) and reject if
-- more than a small fraction of bytes are non-whitespace control
-- characters. Crude but good enough for a quick preview, not a real
-- content-type sniffer.
local function looks_like_text(sample)
  if #sample == 0 or sample:find("\0") then return false end
  local bad = 0
  for i = 1, #sample do
    local b = sample:byte(i)
    if b < 32 and b ~= 9 and b ~= 10 and b ~= 13 then bad = bad + 1 end
  end
  return (bad / #sample) < 0.01
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
        local dataUri = "data:" .. (IMAGE_MIME[uti] or "image/png") .. ";base64," .. b64
        -- hs.image has no raw-bytes constructor; round-tripping the just-built
        -- data URI through imageFromURL (per its own docs: it accepts the
        -- output of encodeAsURLString back as input) is the only way to get
        -- an hs.image object -- and thus :size() -- from in-memory blob bytes.
        local dims
        local okImg, img = pcall(hs.image.imageFromURL, dataUri)
        if okImg and img then dims = img:size() end
        result = { kind = "image", dataUri = dataUri, width = dims and dims.w, height = dims and dims.h }
      end
    end
  elseif kind == "files" then
    -- Best-effort: public.file-url blobs are typically UTF8 file:// URL
    -- bytes; render as-is (monospace) rather than attempting full NSURL
    -- bookmark-data decoding. Known limitation, not exhaustive.
    local blob = fetch_blob(db, id, { "public.file-url" })
    if blob then result = { kind = "text", text = blob } end
  elseif kind == "file" then
    local path = fetch_blob(db, id, { "x-resolved-path" })
    if path then
      -- If the file is an image, show it as one instead of the text quick
      -- view below (imageFromPath sniffs actual content, not just the
      -- extension, so a mislabeled/corrupt file correctly falls through).
      local okImg, img = pcall(hs.image.imageFromPath, path)
      if okImg and img then
        local okEnc, encoded = pcall(function() return img:encodeAsURLString() end)
        if okEnc and encoded then
          local dims = img:size()
          result = { kind = "image", dataUri = encoded, width = dims and dims.w, height = dims and dims.h }
        end
      end
    end
    if path and not result and path:lower():match("%.html?$") then
      -- .html/.htm by extension -- unlike images, there's no equivalent
      -- single-call content sniff available here. Rendered through the
      -- same iframe path as the "html" kind (dark-mode/transparency
      -- detection etc. all apply unchanged).
      local f = io.open(path, "rb")
      if f then
        local content = f:read(FILE_PREVIEW_MAX_BYTES)
        f:close()
        if content and content ~= "" then result = { kind = "html", html = content } end
      end
    end
    if path and not result then
      local f = io.open(path, "rb")
      if f then
        local content = f:read(FILE_PREVIEW_MAX_BYTES)
        local truncated = content and #content == FILE_PREVIEW_MAX_BYTES and f:read(1) ~= nil
        f:close()
        if content and looks_like_text(content) then
          result = { kind = "text", text = truncated and (content .. "…") or content }
        end
      end
      -- Unreadable, binary, empty, or missing: fall back to the path itself.
      if not result then result = { kind = "text", text = path } end
    end
  elseif kind == "directory" then
    local path = fetch_blob(db, id, { "x-resolved-path" })
    if path then result = { kind = "text", text = path } end
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

-- Returns the new pinned state AND the item's current group label (via the
-- same group_label() the initial query uses) -- pinning/unpinning changes
-- which group a clip belongs to (into/out of "Pinned"), and the client
-- has no way to recompute that itself (it only ever sees a pre-formatted
-- group string, never the raw timestamp).
local function toggle_pin(id)
  local db = sqlite3.open(history._db_path())
  if not db then return false, nil end
  local u = db:prepare("UPDATE clips SET pinned = 1 - pinned WHERE id=?;")
  if u then u:bind(1, id); u:step(); u:finalize() end
  local pinned, group = false, nil
  local s = db:prepare("SELECT pinned, last_ts FROM clips WHERE id=?;")
  if s then
    s:bind(1, id)
    if s:step() == sqlite3.ROW then
      pinned = (s:get_value(0) == 1)
      group = group_label(s:get_value(1) or os.time(), os.time(), pinned)
    end
    s:finalize()
  end
  db:close()
  return pinned, group
end

--------------------------------------------------------------------------------
-- Webview lifecycle
--------------------------------------------------------------------------------

-- Unique id this picker registers itself under with the shared
-- dismiss-on-blur module (see modules/system/dismiss-on-blur.lua for the
-- underlying mechanism and escape hatch).
local DISMISS_ON_BLUR_ID = "clipboard-picker"

local webview
local ucc
local savedWindow -- the app window focused before the picker opened
local isShown = false

-- Absolute file:// URL for the icon font, substituted into the CSS's
-- @font-face src. An explicit @font-face load bypasses WebKit's local
-- font-matching-by-name restriction (see the comment in
-- clipboard-picker.css) that can otherwise silently fail to resolve a
-- user-installed font by family name alone inside a webview.
local function icon_font_url()
  return "file://" .. (os.getenv("HOME") or "") .. "/Library/Fonts/SymbolsNerdFontMono-Regular.ttf"
end

local function build_html(items)
  ensure_templates()
  local css = substitute(cssTemplateRaw, { ICON_FONT_URL = icon_font_url() })
  return substitute(htmlTemplateRaw, {
    CSS = css,
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
    content.id = body.id -- lets JS guard against a stale response landing after the selection has moved on
    if webview then
      webview:evaluateJavaScript("window.__setPreview(" .. hs.json.encode(content) .. ")")
    end
  elseif action == "icon" then
    local dataUri = fetch_app_icon(body.bundleId, body.appName)
    if webview then
      webview:evaluateJavaScript(
        "window.__setSourceIcon(" .. hs.json.encode({ id = body.id, dataUri = dataUri }) .. ")")
    end
  elseif action == "delete" then
    delete_item(body.id)
  elseif action == "pin" then
    local pinned, group = toggle_pin(body.id)
    if webview then
      webview:evaluateJavaScript(
        "window.__setPinned(" .. hs.json.encode({ id = body.id, pinned = pinned, group = group }) .. ")")
    end
  elseif action == "copy" then
    -- Ctrl+Y: restore to the clipboard (restore_by_id reinstates the register
    -- type) and dismiss — but do NOT auto-paste, so a block clip can be `p`'d
    -- as a block in nvim instead of being pasted charwise into the focused app.
    history.restore_by_id(body.id)
    M.hide()
  elseif action == "accept" then
    history.restore_by_id(body.id)
    if body.dismiss then
      M.hide()
      -- Post the paste just after hide() refocuses the target app.
      hs.timer.doAfter(0.12, function() hs.eventtap.keyStroke({ "cmd" }, "v") end)
    else
      -- Ctrl+Enter: paste into the target app but keep the picker open. This
      -- necessarily shuffles focus away (to paste into the right app) and
      -- back (to keep accepting keystrokes) — a brief visible flash is
      -- expected/inherent, not a bug; validate the feel in UX review.
      -- dismissOnBlur.suppress guards this deliberate focus shuffle, which
      -- would otherwise get dismissed the moment we focus the target app to
      -- paste.
      dismissOnBlur.suppress(DISMISS_ON_BLUR_ID, true)
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
            dismissOnBlur.suppress(DISMISS_ON_BLUR_ID, false)
          end)
        end)
      end)
    end
  elseif action == "acceptPlain" then
    -- Alt+Enter: paste with RTF/HTML styling stripped, otherwise the same
    -- dismiss-then-paste flow as a plain Enter accept.
    history.restore_plain_by_id(body.id)
    M.hide()
    hs.timer.doAfter(0.12, function() hs.eventtap.keyStroke({ "cmd" }, "v") end)
  elseif action == "dismiss" then
    M.hide()
  end
end

local function ensure_webview()
  if webview then return end
  ucc = hs.webview.usercontent.new("clipboardPicker")
  ucc:setCallback(function(msg) handle_message(msg.body) end)

  local sf = hs.screen.mainScreen():fullFrame()
  local w, h = 780, 570 -- +50px vs. the pre-keybinding-hints-row height
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
  -- Mutual exclusion between our own managed panels (e.g. WhichKey) -- see
  -- modules/system/dismiss-on-blur.lua's dismissOthers.
  dismissOnBlur.dismissOthers(DISMISS_ON_BLUR_ID)
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

  -- Dismiss automatically when focus moves away (click another window,
  -- Cmd+Tab, Raycast or any other launcher-style panel stealing key-window
  -- status, a system dialog, ...) -- see modules/system/dismiss-on-blur.lua.
  dismissOnBlur.arm(DISMISS_ON_BLUR_ID, function(win)
    local ourWin = webview and webview:hswindow()
    return win ~= nil and ourWin ~= nil and win:id() == ourWin:id()
  end, M.hide)
end

function M.hide()
  -- Only reclaim focus for savedWindow if OUR OWN window still has it right
  -- now AND we're not being dismissed because Cmd+Tab was pressed. Two
  -- distinct reasons to skip it:
  --   1. Something else already took focus/key-window status (Raycast,
  --      another app, WhichKey's leader via dismissOnBlur.dismissOthers) --
  --      stealing it back would yank it away from whatever the user just
  --      switched to (confirmed: this is exactly why Raycast dismissed
  --      itself right after opening).
  --   2. The OS switcher is engaging (dismissOnBlur.dismissingViaSwitcher):
  --      it's about to own the ENTIRE focus transition itself once Cmd is
  --      released, to whatever app the user actually selects -- not
  --      necessarily savedWindow. See dismiss-on-blur.lua for why calling
  --      :focus() here is the suspected cause of a reported rapid-cycling
  --      bug in the switcher HUD.
  local hsWin = webview and webview:hswindow()
  local currentlyFocused = hs.window.focusedWindow()
  local weStillHadFocus = hsWin ~= nil and currentlyFocused ~= nil and currentlyFocused:id() == hsWin:id()

  if webview then webview:hide() end
  isShown = false
  dismissOnBlur.disarm(DISMISS_ON_BLUR_ID)

  if savedWindow and weStillHadFocus and not dismissOnBlur.dismissingViaSwitcher then
    savedWindow:focus()
  end
  savedWindow = nil
end

function M.toggle()
  if isShown then M.hide() else M.show() end
end

function M.cleanup()
  if webview then webview:delete(); webview = nil end
  ucc = nil
  dismissOnBlur.disarm(DISMISS_ON_BLUR_ID)
  isShown = false
end

-- Test/inspection helpers (not used in production paths).
M._query_items = query_items
M._group_label = group_label
M._count_words = count_words
M._fetch_preview = fetch_preview
M._fetch_app_icon = fetch_app_icon

return M
