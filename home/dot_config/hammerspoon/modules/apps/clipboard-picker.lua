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
local osd = require("osd")

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
    -- Rows captured before preview_of() learned to skip leading blank lines
    -- hold an empty text_preview on file and would render as a blank list
    -- row; re-derive the snippet from text_plain for those. Falls through to
    -- the "[kind]" badge when there is no plain text either (a files row
    -- whose bytes were never pulled locally).
    local preview = s:get_value(1)
    if preview == nil or preview:match("^%s*$") then
      preview = history._preview_of(plain)
    end
    if preview == nil or preview == "" then preview = "[" .. kind .. "]" end
    items[#items + 1] = {
      id        = s:get_value(0),
      preview   = preview,
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
      -- Raw recency, alongside the pre-formatted `group`/`age` strings: the
      -- client re-sorts the list itself after a pin toggle, and the ORDER BY
      -- above is not something it can recover from those strings.
      ts        = last_ts,
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

local function fetch_text_preview(db, id)
  local s = db:prepare("SELECT text_preview FROM clips WHERE id=?;")
  local text
  if s then
    s:bind(1, id)
    if s:step() == sqlite3.ROW then text = s:get_value(0) end
    s:finalize()
  end
  return text
end

-- Split an x-file-manifest blob (NUL-joined absolute paths -- see
-- executable_clipboard-bridge-dispatch's clip::persist_files_manifest_row)
-- into a list of paths. Plain string:find (not a pattern) on purpose: a
-- character class containing a literal NUL byte is unreliable across Lua
-- versions, plain-find has no such issue.
local function split_manifest(blob)
  local paths = {}
  if not blob or blob == "" then return paths end
  local pos, n = 1, #blob
  while pos <= n do
    local nul = blob:find("\0", pos, true)
    local seg
    if nul then seg = blob:sub(pos, nul - 1); pos = nul + 1
    else seg = blob:sub(pos); pos = n + 1 end
    if seg ~= "" then paths[#paths + 1] = seg end
  end
  return paths
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

-- Preview built from the x-file-manifest blob alone (NUL-joined absolute
-- paths -- same data the TUI picker shows via text_preview, X3), one path
-- per line. nil when no manifest blob is recorded.
local function manifest_preview(db, id)
  local blob = fetch_blob(db, id, { "x-file-manifest" })
  local paths = split_manifest(blob)
  if #paths == 0 then return nil end
  return { kind = "text", text = table.concat(paths, "\n") }
end

-- Fallback preview chain for the files/file/directory kinds when their
-- primary rich payload (public.file-url / x-resolved-path) is absent --
-- true for a remote manifest row whose bytes were never pulled locally
-- (X2-redo/N: only x-file-manifest is recorded, spec X7). Tries, in order:
-- (1) the manifest's full path list -- unlike public.file-url, which only
-- ever held the first path, this shows ALL of them; (2) clips.text_preview,
-- which for a files/file/directory row is already either the newline-joined
-- paths (X3) or the synthetic "[kind]" badge, so it also covers (3) the
-- badge as a last resort; (4) the badge itself, for the belt-and-suspenders
-- case where text_preview is unexpectedly empty/NULL.
local function file_kind_fallback(db, id, kind)
  local mp = manifest_preview(db, id)
  if mp then return mp end
  local tp = fetch_text_preview(db, id)
  if tp and tp ~= "" then return { kind = "text", text = tp } end
  return { kind = "text", text = "[" .. kind .. "]" }
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
    if blob then
      result = { kind = "text", text = blob }
    else
      -- No public.file-url: a remote manifest row (bytes never pulled) has
      -- neither this nor x-resolved-path -- fall back to the manifest/
      -- text_preview/badge chain instead of leaving the preview blank (X7).
      result = file_kind_fallback(db, id, kind)
    end
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
    if not path then
      -- No x-resolved-path at all (a remote manifest row -- kind refines
      -- to "file" only for a genuine local capture, but be defensive):
      -- fall back to the manifest/text_preview/badge chain rather than a
      -- blank preview (X7).
      result = file_kind_fallback(db, id, kind)
    end
  elseif kind == "directory" then
    local path = fetch_blob(db, id, { "x-resolved-path" })
    if path then
      result = { kind = "text", text = path }
    else
      result = file_kind_fallback(db, id, kind)
    end
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
-- Headless files restore (spec R4) -- delegates to the terminal picker's own
-- rsync-pull-and-localize engine for a files row this in-process restore_by_id
-- cannot faithfully materialize.
--------------------------------------------------------------------------------

-- True for a files/file/directory row that history.restore_by_id cannot
-- faithfully restore in-process: restore_by_id (hs.pasteboard.writeAllData)
-- writes back exactly the UTI->blob rows clip_types has on file, keyed by
-- their LITERAL uti string -- fine for a genuine local capture (real
-- public.file-url/NSFilenamesPboardType blobs alongside the synthetic
-- x-resolved-path, clipboard-history.lua:177,454-460), but for a row whose
-- ONLY rich payload is x-file-manifest (a remote manifest -- the bytes were
-- never pulled) or x-resolved-path with no matching pasteboard-standard UTI
-- (a row the TERMINAL picker localized itself, spec §12: source_host stays
-- the origin host on purpose) it would write nonsense bytes under a literal
-- "x-file-manifest"/"x-resolved-path" UTI -- nothing Finder can paste, a
-- silent false "success". Simplest honest gate (mirrors
-- clip::copy_files_by_id's own case-3/case-4 split in
-- executable_pick-clipboard, kept in the one place that owns the rsync
-- engine): an x-file-manifest blob is present, OR the row's source_host
-- differs from this host.
local function needs_headless_restore(id)
  local db = sqlite3.open(history._db_path())
  if not db then return false end
  local kind, host
  local s = db:prepare("SELECT type_kind, source_host FROM clips WHERE id=?;")
  if s then
    s:bind(1, id)
    if s:step() == sqlite3.ROW then
      kind = s:get_value(0)
      host = s:get_value(1)
    end
    s:finalize()
  end
  local has_manifest = false
  if kind == "files" or kind == "file" or kind == "directory" then
    local m = db:prepare("SELECT 1 FROM clip_types WHERE clip_id=? AND uti='x-file-manifest';")
    if m then
      m:bind(1, id)
      has_manifest = (m:step() == sqlite3.ROW)
      m:finalize()
    end
  end
  db:close()
  if kind ~= "files" and kind ~= "file" and kind ~= "directory" then return false end
  local my_host = history._my_host()
  local is_remote = host ~= nil and host ~= "" and host ~= my_host
  return has_manifest or is_remote
end

-- §6 copy-confirmation toast for rows this picker restores IN-PROCESS
-- (text/image via history.restore_by_id). Files rows never reach this:
-- they go through the headless CLI, whose engine fires the same toast
-- itself (clip::toast_spec in executable_pick-clipboard -- the kind->glyph
-- table below mirrors it; keep the two in sync).
local TOAST_GLYPHS = {
  image = "glyph:nf-md-image",
  file = "glyph:nf-md-file",
  directory = "glyph:nf-md-folder",
  files = "glyph:nf-md-file_multiple",
}

local function copy_toast(id)
  local db = sqlite3.open(history._db_path())
  if not db then return end
  local kind, host
  local s = db:prepare("SELECT type_kind, source_host FROM clips WHERE id=?;")
  if s then
    s:bind(1, id)
    if s:step() == sqlite3.ROW then
      kind = s:get_value(0)
      host = s:get_value(1)
    end
    s:finalize()
  end
  db:close()
  local my_host = history._my_host()
  if host ~= nil and host ~= "" and host ~= my_host then
    osd.notify(TOAST_GLYPHS[kind] or "glyph:nf-md-text_box", "Copied from " .. host, "Frog")
  else
    osd.notify("glyph:fa-clipboard-list", "Clipboard moved to top", "Frog")
  end
end

local PICK_CLIPBOARD_BIN = (os.getenv("HOME") or "") .. "/.local/libexec/pick-clipboard"

-- Single-quote a string for safe embedding in a shell command line: wrap in
-- '...', escaping any embedded ' as '\''  (close quote, escaped quote,
-- reopen quote). Used below for PICK_CLIPBOARD_BIN even though it never
-- contains shell metacharacters in practice -- interpolating ANY string
-- into a command line that a shell will parse deserves the discipline on
-- principle, not just when a byte pattern happens to demand it.
local function shell_quote(str)
  return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- Last non-blank line of a possibly-multiline string, or nil. Used to pull
-- the shim's one-line failure reason out of stderr: clip::restore_fail (W2,
-- executable_pick-clipboard) prints exactly one "pick-clipboard: ..." line
-- per failure, but it's not always the ONLY line on stderr -- a failing
-- rsync can leave its own diagnostics ahead of it -- so the reason is the
-- LAST line, not the first (matching first would surface rsync's noise
-- instead of the shim's actual verdict).
local function last_line(s)
  if not s or s == "" then return nil end
  local last
  for line in s:gmatch("[^\n]+") do last = line end
  return last
end

-- Coerce a clip id received from the webview's JS bridge into an integer,
-- or nil if it can't be one. Load-bearing for the CLI handoff below: the
-- row id is born an integer (query_items, line ~165: `id = s:get_value(0)`
-- straight from sqlite) and travels to JS intact, but every JS number is a
-- double, so when clipboard-picker.html posts it back (`post('copy', { id:
-- it.id })` etc., Assets/html/clipboard-picker.html:411/419/429) the WebKit
-- message bridge delivers it to Lua as a FLOAT -- verified live on this
-- runtime: evaluateJavaScript("({id: 1010})") round-trips as
-- math.type=="float", tostring=="1010.0". The in-process sqlite binds
-- shrug that off (numeric affinity: 1010.0 == 1010), which is why preview/
-- delete/pin all worked -- but stringifying it for pick-clipboard's argv
-- produced "--restore-id 1010.0", which the CLI's all-digits `<->` guard
-- correctly rejects ("--restore-id requires a numeric clip id", the exact
-- failure toast from live validation). math.tointeger accepts an integral
-- float (1010.0 -> 1010) and rejects a fractional one (no silent
-- truncation of garbage); tonumber first also admits a numeric string.
local function clip_id_int(id)
  local n = tonumber(id)
  return n and math.tointeger(n) or nil
end

-- Async headless restore for a gated files row: shells out to the SAME
-- clip::copy_files_by_id logic the terminal picker's Ctrl-Y uses
-- (executable_pick-clipboard --restore-id <id>, spec R4) via hs.task --
-- rsync pulls a remote manifest, which can take a while, so this must never
-- block the UI thread.
--
-- Routed through `/bin/zsh -lc "<cmd>"` rather than invoking
-- PICK_CLIPBOARD_BIN directly as hs.task's launchPath (the argv-form used
-- before, no shell involved at all): Hammerspoon is a background/accessory
-- GUI app, and hs.task's argv-form inherits Hammerspoon's OWN process
-- environment verbatim -- SSH_AUTH_SOCK pointing at Apple's keyless default
-- agent (/var/run/com.apple.launchd.*/Listeners) and a bare
-- /usr/bin:/bin:/usr/sbin:/sbin PATH -- never the real environment any of
-- the user's shells run with (their own SSH agent socket, homebrew PATH,
-- etc.), which only gets assembled by ~/.zshenv & co. The rsync-over-ssh
-- pull inside --restore-id authenticates via SSH_AUTH_SOCK, so headless
-- restores of a REMOTE row silently failed auth from Hammerspoon while the
-- identical `pick-clipboard --restore-id` worked from any login shell --
-- this is the load-bearing reason a login shell is used here, not just a
-- PATH nicety. `-l` (login, no `-i`) sources zshenv/zprofile without
-- pulling in prompt frameworks (p10k, etc) meant for an interactive TTY --
-- the extra startup cost (well under a second) is acceptable, one-time,
-- latency for a paste.
--
-- hs.task.new(launchPath, callbackFn, [streamCallbackFn], [arguments]) ->
-- hs.task; callbackFn receives (exitCode, stdOut, stdErr) on termination
-- (verified against modules/system/controls.lua's own hs.task.new("/bin/sh",
-- cb, { "-c", cmd }) usage, and Hammerspoon's own docs.json for
-- hs.task.new). launchPath MUST be an absolute path (never PATH-searched);
-- "/bin/zsh" satisfies that same as "/bin/sh" did before. onDone(ok), if
-- given, runs after the toast/notification.
local function headless_restore(id, onDone)
  -- Never spawn with garbage: resolve the JS-bridge float (see clip_id_int)
  -- to a real integer first, and if that fails, surface it the same way a
  -- CLI failure would -- full context to the console, persistent notify --
  -- instead of letting the CLI reject a stringified float downstream.
  local intId = clip_id_int(id)
  if not intId then
    print(string.format(
      "clipboard-picker: headless restore got an unresolvable clip id: %s (%s)",
      tostring(id), type(id)))
    hs.notify.new(nil, {
      title = "Clipboard restore failed",
      informativeText = "couldn't resolve the row's clip id",
      withdrawAfter = 0,
    }):send()
    if onDone then onDone(false) end
    return nil
  end
  local cmd = shell_quote(PICK_CLIPBOARD_BIN) .. " --restore-id " .. tostring(intId)
  local cancelled = false
  local task
  task = hs.task.new("/bin/zsh", function(exitCode, stdOut, stdErr)
    -- Fast transfers may finish inside the HUD grace window -- the capsule
    -- (and its progressHide) never happens, so clear the registration here
    -- unconditionally or it leaks into the next transfer.
    osd.progressCancel(nil)
    -- Success is the exit code alone, never output presence: pick-clipboard
    -- can legitimately print nothing on stdout/stderr on a clean success,
    -- and conversely a captured failure reason on stderr must never be
    -- mistaken for "it printed something so it must have worked".
    local ok = (exitCode == 0)
    -- Always printed to the HS console (both branches) -- so the full
    -- stdout+stderr is retrievable after the fact even when the toast was
    -- missed, which live validation showed was easy to do.
    print(string.format(
      "clipboard-picker: headless restore id=%d exit=%s\n-- stdout --\n%s\n-- stderr --\n%s",
      intId, tostring(exitCode), stdOut or "", stdErr or ""))
    if not ok and not cancelled and exitCode ~= 130 then
      -- A transient toast's default ~2s lifetime was unreadably brief for a
      -- failure (live validation). hs.notify is a real Notification Center item;
      -- withdrawAfter=0 disables its own default auto-withdrawal (5s for
      -- the hs.notify.show() shorthand, per hs.notify docs) so it stays
      -- until the user dismisses it -- same durable-until-acknowledged
      -- intent as the terminal picker's own restore-failure hold (W2).
      local reason = last_line(stdErr) or "restore failed"
      -- §4.2a: the NC item below is durable but Focus can swallow it
      -- silently -- live validation watched a failed pull vanish with no
      -- visible message. The OSD toast is the can't-miss immediate signal.
      osd.notify("glyph:nf-md-alert", "Copy failed — " .. reason, "Basso")
      hs.notify.new(nil, {
        title = "Clipboard restore failed",
        informativeText = reason,
        withdrawAfter = 0,
      }):send()
    end
    -- exit 130 / cancelled: §4.4 cancel contract -- the engine already
    -- cleaned up and toasted quietly; a cancel is not a failure.
    if onDone then onDone(ok) end
  end, { "-lc", cmd })
  task:start()
  osd.progressCancel(function()
    -- SIGTERM to the zsh wrapper alone is deferred until the foreground
    -- rsync exits -- kill rsync (the wrapper's direct child) first; rsync
    -- TERM-cleans its own temp file. Then terminate() fires the wrapper's
    -- §4.4 trap.
    cancelled = true
    local pid = task and task:pid()
    if pid then hs.execute("/usr/bin/pkill -TERM -P " .. tostring(pid)) end
    if task then task:terminate() end
  end)
  return task
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

--- Encode a value for embedding inside an HTML <script> element.
---
--- Producing JSON is not the same as embedding it in HTML. hs.json.encode
--- escapes '/' as '\/', so a clip containing "</script>" cannot close the
--- element -- that much the template always relied on, and it is true. But
--- it does NOT escape '<', and the HTML tokenizer gives two other sequences
--- meaning inside script data: '<!--' switches to the escaped state and
--- '<script' to the double-escaped state. Past either one, the element's
--- real '</script>' is consumed as ordinary text rather than closing it, the
--- script element is never terminated, and WebKit never executes it -- with
--- no error event, no console line, nothing. The page then renders its
--- static chrome and stops: empty list, unfocusable filter box, dead Escape
--- (observed in the wild; reproduced from a bare document).
---
--- Escaping every '<' as < is the standard, complete guard. JS parses
--- the escape back to '<', so no displayed text changes.
local function json_for_script(value)
  return (hs.json.encode(value):gsub("<", "\\u003C"))
end

local function build_html(items)
  ensure_templates()
  local css = substitute(cssTemplateRaw, { ICON_FONT_URL = icon_font_url() })
  return substitute(htmlTemplateRaw, {
    CSS = css,
    ITEMS_JSON = json_for_script(items),
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
    -- files/file/directory rows restore_by_id cannot faithfully restore
    -- (spec R4 -- a remote manifest, or a row the terminal picker already
    -- localized itself) go through the headless rsync-pull CLI instead,
    -- same as the terminal picker's own Ctrl-Y; dismiss now regardless (the
    -- pull is async and best-effort from here on), success surfaces via the
    -- engine's own notify toast; failure stays a persistent hs.notify item.
    if needs_headless_restore(body.id) then
      headless_restore(body.id)
    else
      -- Success-gated (§6): a row deleted between render and Ctrl+Y must
      -- not toast over a clipboard that was never touched.
      if history.restore_by_id(body.id) then copy_toast(body.id) end
    end
    M.hide()
  elseif action == "accept" then
    if needs_headless_restore(body.id) then
      -- Enter on a gated files row: the real bytes aren't here yet, so the
      -- normal "restore then paste" order inverts to "dismiss, pull, paste
      -- only once the pull actually lands" -- always dismissing rather than
      -- keeping the Ctrl-Enter flourish's picker-stays-open behavior below,
      -- since holding a modal panel open across a multi-second network pull
      -- would be more disruptive than clarifying.
      M.hide()
      headless_restore(body.id, function(ok)
        if ok then hs.printf("clipboard-picker: synthesized paste [headless-pull] at %s", os.date("%H:%M:%S")); hs.eventtap.keyStroke({ "cmd" }, "v") end
      end)
      return
    end
    history.restore_by_id(body.id)
    if body.dismiss then
      M.hide()
      -- Post the paste just after hide() refocuses the target app.
      hs.timer.doAfter(0.12, function() hs.printf("clipboard-picker: synthesized paste [accept-dismiss] at %s", os.date("%H:%M:%S")); hs.eventtap.keyStroke({ "cmd" }, "v") end)
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
          hs.printf("clipboard-picker: synthesized paste [ctrl-enter] at %s", os.date("%H:%M:%S")); hs.eventtap.keyStroke({ "cmd" }, "v")
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
    hs.timer.doAfter(0.12, function() hs.printf("clipboard-picker: synthesized paste [accept-plain] at %s", os.date("%H:%M:%S")); hs.eventtap.keyStroke({ "cmd" }, "v") end)
  elseif action == "dismiss" then
    M.hide()
  end
end

local PICKER_W, PICKER_H = 780, 570 -- +50px vs. the pre-keybinding-hints-row height

-- Centred frame on the screen the user is actually working on: the screen
-- holding the focused app's window (the only meaningful answer with more
-- than one display attached), falling back to the main screen when nothing
-- is focused. Mirrors modules/osd/init.lua's targetScreen().
--
-- Must be recomputed on every show(), not baked in at creation: the webview
-- is built once and reused for the process's lifetime, so a display
-- connected/disconnected (or the user simply moving to another screen)
-- afterwards would otherwise keep centring the panel on the arrangement
-- that happened to be in place the first time it opened.
local function picker_frame(win)
  win = win or hs.window.focusedWindow()
  local screen = (win and win:screen()) or hs.screen.mainScreen()
  local sf = screen:fullFrame()
  return {
    x = sf.x + (sf.w - PICKER_W) / 2,
    y = sf.y + (sf.h - PICKER_H) / 2,
    w = PICKER_W,
    h = PICKER_H,
  }
end

local function ensure_webview()
  if webview then return end
  ucc = hs.webview.usercontent.new("clipboardPicker")
  ucc:setCallback(function(msg) handle_message(msg.body) end)

  -- javaScriptEnabled is declared EXPLICITLY rather than left to the
  -- default. This page's entire behaviour -- rendering the list, focusing
  -- the filter box, the Escape handler -- lives in inline <script>, and a
  -- machine was found serving the page with content JavaScript refused
  -- while evaluateJavaScript still worked: the signature of WebKit's
  -- allowsContentJavaScript being NO (the modern replacement for this
  -- deprecated flag, which blocks the document's own scripts but not
  -- API-injected ones). The panel then draws its static chrome and nothing
  -- else -- empty list, unfocusable box, dead Escape -- with no error
  -- anywhere Hammerspoon can see. A hard requirement belongs in the
  -- request, not in an assumption about the default.
  webview = hs.webview.new(picker_frame(), { javaScriptEnabled = true }, ucc)
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

--- Diagnostic: report the picker's live state, Lua side and DOM side.
--- Temporary instrument for the blank-panel report — run it while the picker
--- is open: `hs -c 'require("apps.clipboard-picker")._debug()'`, then read
--- the console. Answers, in one shot, whether the data reached the page and
--- whether the page's script ever ran.
function M._debug()
  local hsWin = webview and webview:hswindow()
  local focused = hs.window.focusedWindow()
  hs.printf("PICKER-DEBUG lua: webview=%s isShown=%s winId=%s isKey=%s",
    tostring(webview ~= nil), tostring(isShown),
    tostring(hsWin and hsWin:id()),
    tostring(hsWin ~= nil and focused ~= nil and hsWin:id() == focused:id()))

  local ok, items = pcall(query_items)
  if not ok then
    hs.printf("PICKER-DEBUG lua: query_items THREW: %s", tostring(items))
    return
  end
  local encoded = hs.json.encode(items)
  hs.printf("PICKER-DEBUG lua: rows=%d json=%s templates=%s/%s",
    #items, encoded and tostring(#encoded) or "NIL(encode failed)",
    tostring(htmlTemplateRaw and #htmlTemplateRaw), tostring(cssTemplateRaw and #cssTemplateRaw))

  if not webview then return end
  webview:evaluateJavaScript([[
    JSON.stringify({
      readyState: document.readyState,
      hasQueryBox: !!document.getElementById('query'),
      renderedItems: document.querySelectorAll('.item').length,
      scriptRan: typeof window.__focusInput,
      trapInstalled: (typeof window.onerror === "function"),
      scripts: document.scripts.length,
      htmlLen: document.documentElement.outerHTML.length,
      jsError: window.__lastError || "none"
    })
  ]], function(result, err)
    hs.printf("PICKER-DEBUG dom: %s", tostring(result or err))
  end)
end

--- Diagnostic: does an inline <script> run, and does the page's ORIGIN
--- decide it? Two webviews, same bytes: one loaded the way this picker
--- loads (loadHTMLString, null origin), one from a real file:// URL.
--- Neither is shown. Temporary instrument.
function M._jsprobe()
  local doc = [[<html><body><p id="x">NO-JS</p>]]
    .. [[<script>document.getElementById("x").textContent="JS-RAN";</script></body></html>]]
  local path = "/tmp/hs-jsprobe.html"
  local f = io.open(path, "w")
  if f then f:write(doc); f:close() end

  local a = hs.webview.new({ x = 0, y = 0, w = 10, h = 10 }, { javaScriptEnabled = true })
  a:html(doc)
  local b = hs.webview.new({ x = 0, y = 0, w = 10, h = 10 }, { javaScriptEnabled = true })
  b:url("file://" .. path)

  -- C: a webview configured EXACTLY like the picker's (usercontent
  -- controller, transparency, borderless modal panel, text entry) but
  -- carrying the tiny document. Isolates configuration from content.
  local cucc = hs.webview.usercontent.new("clipboardPickerProbe")
  local c = hs.webview.new({ x = 0, y = 0, w = 10, h = 10 }, { javaScriptEnabled = true }, cucc)
  c:transparent(true)
  c:windowStyle({ "borderless" })
  c:level(hs.drawing.windowLevels.modalPanel)
  c:allowTextEntry(true)
  c:shadow(true)
  c:deleteOnClose(false)
  c:html(doc)

  -- D: a PLAIN webview carrying the picker's real page, built from the real
  -- rows. The other half of the split: if C runs and D does not, the fault
  -- is in what the page contains, not in how the webview is configured.
  local d = hs.webview.new({ x = 0, y = 0, w = 10, h = 10 }, { javaScriptEnabled = true })
  local realOk, realHtml = pcall(function() return build_html(query_items()) end)
  if realOk then d:html(realHtml) end

  -- E: the HTML parser's script-data escape, carried inside a JS string
  -- literal exactly as a clip's preview would carry it. `</script>` is
  -- guarded by hs.json.encode's slash escaping; `<!--` and `<script` are
  -- not, and they switch the tokenizer into a state where the element's
  -- real closing tag is consumed as text instead of ending it.
  local hostile = [[<!--<script>]]
  local e = hs.webview.new({ x = 0, y = 0, w = 10, h = 10 }, { javaScriptEnabled = true })
  e:html([[<html><body><p id="x">NO-JS</p><script>var D = "]]
    .. hostile
    .. [[";document.getElementById("x").textContent="JS-RAN";</script></body></html>]])

  -- F: the same bytes carried through json_for_script, the guard build_html
  -- now applies. E is the fault, F is the fix, in one run.
  local f = hs.webview.new({ x = 0, y = 0, w = 10, h = 10 }, { javaScriptEnabled = true })
  local fdoc = [[<html><body><p id="x">NO-JS</p><script>var D = ]]
    .. json_for_script({ hostile })
    .. "[0];"
    .. [[document.getElementById("x").textContent="JS-RAN:"+D.length;</script></body></html>]]
  f:html(fdoc)

  hs.timer.doAfter(3.0, function()
    local read = [[document.getElementById("x") ? document.getElementById("x").textContent : "NO-DOM"]]
    e:evaluateJavaScript(read, function(r)
      hs.printf("JSPROBE E hostile-raw       = %s", tostring(r)); e:delete()
    end)
    f:evaluateJavaScript(read, function(r)
      hs.printf("JSPROBE F hostile-escaped   = %s", tostring(r)); f:delete()
    end)
    -- For the real page, the same questions _debug asks, plus the two that
    -- instrument could not answer: did the FIRST script element run
    -- (trapInstalled), and did the parser even see both scripts?
    local readReal = [[
      JSON.stringify({
        scriptRan: typeof window.__focusInput,
        trapInstalled: (typeof window.onerror === "function"),
        scripts: document.scripts.length,
        htmlLen: document.documentElement.outerHTML.length,
        jsError: window.__lastError || "none"
      })
    ]]
    a:evaluateJavaScript(read, function(r)
      hs.printf("JSPROBE A plain+html()      = %s", tostring(r)); a:delete()
    end)
    b:evaluateJavaScript(read, function(r)
      hs.printf("JSPROBE B plain+file://     = %s", tostring(r)); b:delete(); os.remove(path)
    end)
    c:evaluateJavaScript(read, function(r)
      hs.printf("JSPROBE C picker-config     = %s", tostring(r)); c:delete()
    end)
    d:evaluateJavaScript(readReal, function(r)
      hs.printf("JSPROBE D real-page (built=%s) = %s", tostring(realOk), tostring(r)); d:delete()
    end)
  end)
end

function M.show()
  -- Mutual exclusion between our own managed panels (e.g. WhichKey) -- see
  -- modules/system/dismiss-on-blur.lua's dismissOthers.
  dismissOnBlur.dismissOthers(DISMISS_ON_BLUR_ID)
  ensure_webview()
  savedWindow = hs.window.focusedWindow()
  webview:frame(picker_frame(savedWindow))
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

  -- TEMPORARY (blank-panel diagnosis): capture the state from INSIDE the
  -- session. Reaching for a terminal to call _debug() by hand blurs the
  -- panel and dismisses it, so the instrument has to fire itself while the
  -- page is still up. Remove with the rest of the instrumentation.
  hs.timer.doAfter(1.5, function() pcall(M._debug) end)

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
M._needs_headless_restore = needs_headless_restore
M._clip_id_int = clip_id_int

return M
