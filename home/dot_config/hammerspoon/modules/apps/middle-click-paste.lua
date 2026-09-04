--- apps/middle-click-paste.lua
--- Middle-click pastes the last copied clip into a terminal window.
---
--- Why this exists here and not in the terminals:
---
---   * Ghostty's own middle-click is unusable in both of our setups. With the
---     mux capturing the mouse (the normal setup), Ghostty's mouse-reporting
---     branch runs BEFORE its middle-click block and returns — the click goes
---     to the mux, which has no middle-button binding, and nothing happens.
---     In a bare shell, Ghostty 1.3.x pastes its internal SELECTION clipboard,
---     not the system one, so it replays a stale in-Ghostty selection (or
---     nothing) regardless of what was last copied.
---   * WezTerm's middle-click binding pastes the real system clipboard, but
---     only its plain-text representation — a file clip (pbcopy <path>,
---     Finder copies) or an image clip is a silent no-op.
---
--- Handling it at the OS level fixes both terminals identically.
---
--- The paste source is the recob HISTORY STORE, not the live pasteboard — the
--- same source Cmd+Shift+V (the clipboard picker) reads. That keeps the two
--- gestures agreeing on "the last clip": a middle-click pastes what the picker
--- shows as newest, even when the pasteboard itself was cleared, holds an
--- image, or went stale. The store is opened READ-ONLY (recobd is the sole
--- writer; a write from here would be a bug, and a read-only handle turns it
--- into an immediate error). If the store is unreachable, the handler falls
--- back to the live pasteboard so middle-click never goes dead when the
--- daemon is down.
---
--- What a middle-click does inside a frontmost Ghostty/WezTerm window:
---
---   * newest text/url/html/rtf clip  → synthetic Cmd+V. Both terminals paste
---     through their normal path, so bracketed-paste mode and multi-line
---     safety behavior are unchanged. (The store row is pasted BY first
---     writing it to the pasteboard via the daemon, so Cmd+V has something
---     to paste; see `deliver`.)
---   * newest file/directory clip → the resolved path, shell-quoted, typed
---     via keyStrokes. The only sensible meaning of "paste a file" into a
---     terminal is its path.
---   * no pasteable clip → OSD notice, nothing pasted.
---
--- Costs, accepted deliberately: nothing inside a terminal (mux, nvim) can
--- ever receive a middle click again — no binding there exists to lose. The
--- paste is a synthetic Cmd+V, so Ghostty's `clipboard-paste-protection`
--- dialog may fire on content it flags unsafe, where its selection-paste
--- bypassed it. Middle-clicking a terminal window that is NOT frontmost just
--- focuses it — the event is passed through, otherwise the Cmd+V would land
--- in whatever app had focus before.
---
--- Usage:
---   local middleClick = require("apps.middle-click-paste")
---   middleClick.setup()
---   -- on shutdown:
---   middleClick.cleanup()

local inputPassthrough = require("system.input-passthrough")
local osd = require("osd")

local sqlite3 = require("hs.sqlite3")

local M = {}

local eventTypes = hs.eventtap.event.types
local eventProperties = hs.eventtap.event.properties

--- Bundle IDs of the terminals this module pastes into. Both are terminals
--- whose own middle-click handling is either unreachable (Ghostty under a
--- mux) or text-only (WezTerm), and both paste the system clipboard on Cmd+V.
--- @type table<string, boolean>
local TERMINAL_BUNDLES = {
	["com.mitchellh.ghostty"] = true,
	["com.github.wez.wezterm"] = true,
}

--- Clip kinds whose text_plain is directly pasteable, in one IN() clause.
--- Mirrors the picker's text-bearing set; images and multi-file manifests are
--- excluded (no single text form), file/directory rows resolve to a path.
local TEXT_KINDS = { "text", "url", "html", "rtf" }

local state = {
	tap = nil,
	db = nil,
	debug = false,
}

--- Log a debug message to the Hammerspoon console when state.debug is on.
--- @private
local function log(fmt, ...)
	if state.debug then
		hs.printf("[middleClickPaste] " .. fmt, ...)
	end
end

--- The recob store path, matching apps/clipboard-history.lua's db_path().
--- @private
local function db_path()
	local data = os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") or "") .. "/.local/share"
	return data .. "/pick-clipboard/history.db"
end

--- Open the store READ-ONLY, once. recobd is the sole writer; a read-only
--- handle makes any write from this process an immediate error instead of a
--- row racing the daemon's (same contract as apps/clipboard-history.setup()).
--- Returns nil (and logs once) when the store is absent or unopenable.
--- @private
local function store_db()
	if state.db then
		return state.db
	end
	local handle, _, err = sqlite3.open(db_path(), sqlite3.OPEN_READONLY)
	if type(handle) ~= "userdata" then
		log("cannot open %s read-only (%s)", db_path(), tostring(err))
		return nil
	end
	state.db = handle
	return state.db
end

--- True when the frontmost window belongs to a terminal we paste into.
--- @private
local function terminalFrontmost()
	local app = hs.application.frontmostApplication()
	if not app then
		return false
	end
	local id = app:bundleID()
	return id ~= nil and TERMINAL_BUNDLES[id] == true
end

--- Space-join paths, each POSIX single-quoted so they survive the shell.
--- @private
local function shell_quote_join(paths)
	local quoted = {}
	for _, path in ipairs(paths) do
		quoted[#quoted + 1] = "'" .. path:gsub("'", [['\'']]) .. "'"
	end
	return table.concat(quoted, " ")
end

--- One value from a single-column query, or nil. Finalizes the statement.
--- @private
local function scalar(db, sql, arg)
	local s = db:prepare(sql)
	if not s then
		return nil
	end
	if arg ~= nil then
		s:bind_values(arg)
	end
	local value
	if s:step() == sqlite3.ROW then
		value = s:get_value(0)
	end
	s:finalize()
	return value
end

--- The newest text-pasteable clip from the store.
--- Second return: false for text, true for a file path. Nil + reason when the
--- store holds nothing a terminal could paste.
--- @private
--- @return string|nil text, boolean|string is_file_path_or_reason
local function newest_pasteable(db)
	-- Newest text/url/html/rtf row with non-empty text_plain. These kinds all
	-- carry their readable form in text_plain (html rows keep the source in
	-- clip_types but store the rendered text here).
	local kinds = "'" .. table.concat(TEXT_KINDS, "','") .. "'"
	local row = scalar(
		db,
		"SELECT text_plain FROM clips WHERE type_kind IN ("
			.. kinds
			.. ") AND text_plain IS NOT NULL AND text_plain != '' "
			.. "ORDER BY last_ts DESC LIMIT 1;"
	)
	if type(row) == "string" and row ~= "" then
		return row, false
	end

	-- A file or directory clip: the terminal form is its path. The store keeps
	-- the resolved path in clip_types under the synthetic x-resolved-path UTI.
	local file_id = scalar(
		db,
		"SELECT id FROM clips WHERE type_kind IN ('file','directory') ORDER BY last_ts DESC LIMIT 1;"
	)
	if type(file_id) == "number" then
		local path = scalar(
			db,
			"SELECT blob FROM clip_types WHERE clip_id=? AND uti='x-resolved-path';",
			file_id
		)
		if type(path) == "string" and path ~= "" then
			return shell_quote_join({ path }), true
		end
		return nil, "file clip with no resolvable path"
	end

	return nil, "no text clip in history"
end

--- The pasteboard fallback, used only when the store is unreachable: the
--- current clipboard's plain text, else nil + reason.
--- @private
local function pasteboard_fallback()
	local types = hs.pasteboard.contentTypes() or {}
	local has = {}
	for _, uti in ipairs(types) do
		has[uti] = true
	end
	for _, uti in ipairs({ "public.utf8-plain-text", "public.text", "NSStringPboardType" }) do
		if has[uti] then
			local data = hs.pasteboard.readDataForUTI(nil, uti)
			if data ~= nil and data ~= "" then
				return data, false
			end
		end
	end
	if next(has) == nil then
		return nil, "clipboard is empty"
	end
	return nil, "clipboard has no text (image or other rich content)"
end

--- Resolve what to paste: the store first, the pasteboard as a fallback when
--- the daemon/store is down.
--- @private
--- @return string|nil text, boolean|string is_file_path_or_reason
local function resolve_paste()
	local db = store_db()
	if db then
		local text, flag = newest_pasteable(db)
		if text ~= nil then
			return text, flag
		end
		-- The store was reachable but had nothing pasteable: report its reason
		-- rather than silently second-guessing with the pasteboard.
		return nil, flag
	end
	log("store unreachable; falling back to pasteboard")
	return pasteboard_fallback()
end

--- The tap callback. Consumes middle-clicks inside frontmost terminal
--- windows; passes everything else through untouched.
--- @private
local function onEvent(event)
	-- Only the middle button (down edge is all the tap listens for).
	if event:getProperty(eventProperties.mouseEventButtonNumber) ~= 2 then
		return false
	end

	-- Remote-desktop viewers must keep the original click for the far side.
	if inputPassthrough.isFrontmost() then
		return false
	end

	if not terminalFrontmost() then
		return false
	end

	local text, is_file_path_or_reason = resolve_paste()
	if text == nil then
		local reason = is_file_path_or_reason or "nothing to paste"
		log("nothing pasteable: %s", reason)
		osd.notify("glyph:nf-md-clipboard_off", "Middle-click: " .. reason, "Basso")
		return true -- consume: the terminal's own middle-click would also do nothing
	end

	if is_file_path_or_reason == true then
		-- Paths are typed: a terminal has no Cmd+V meaning for a file clip,
		-- and keyStrokes preserves the shell quoting literally.
		log("typing %d bytes of file paths", #text)
		hs.eventtap.keyStrokes(text)
	else
		-- Put the clip on the pasteboard, then Cmd+V it. The store row is
		-- already the daemon's newest, so this write just re-exposes it to the
		-- terminal's paste path; recobd is sole-writer and absorbs the echo.
		log("pasting %d bytes via Cmd+V", #text)
		hs.pasteboard.setContents(text)
		hs.eventtap.keyStroke({ "cmd" }, "v")
	end
	return true
end

--- Start listening for middle-clicks.
--- @param opts table|nil Options:
---   - debug: boolean  verbose logging to the Hammerspoon console
function M.setup(opts)
	opts = opts or {}
	state.debug = opts.debug == true

	M.cleanup()
	-- Open the store lazily on first middle-click, not here: setup runs at
	-- Hammerspoon load, possibly before recobd has created the DB, and a lazy
	-- open retries on each click rather than giving up for the session.
	state.tap = hs.eventtap.new({ eventTypes.otherMouseDown }, onEvent)
	state.tap:start()
	log("setup: running=%s", tostring(state.tap:isEnabled()))
end

--- Stop the event tap and close the store handle.
function M.cleanup()
	if state.tap then
		state.tap:stop()
		state.tap = nil
	end
	if state.db then
		state.db:close()
		state.db = nil
	end
end

return M
