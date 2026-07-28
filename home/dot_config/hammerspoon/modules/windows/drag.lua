--- windows/drag.lua
--- Hold a modifier (Cmd by default) and drag the mouse anywhere inside a
--- window to move that window. A plain Cmd+click (no drag) is delivered
--- to the app normally, so Cmd+click behaviors (e.g. opening URLs in
--- Ghostty) keep working.
---
--- How it works:
---   leftMouseDown with the modifier is buffered, not delivered.
---   On leftMouseDragged: if movement exceeds `threshold`, we engage a
---     window-move and consume the drag/up events.
---   On leftMouseUp with no movement: we synthesize the original click
---     (down+up, original flags) so the application sees it.
---
--- Usage:
---   local drag = require("windows.drag")
---   drag.setup({ mods = { "cmd" }, threshold = 5, passthroughApps = {} })
---   -- on shutdown:
---   drag.cleanup()

local inputPassthrough = require("system.input-passthrough")

local M = {}

--- Default movement threshold, in points, before a click becomes a drag.
--- @type number
local DEFAULT_THRESHOLD = 5

--- Marker placed on events we post ourselves so the callback can ignore
--- its own re-entry.
--- @type integer
local SENTINEL = 0x47585744 -- "GXWD"

local eventTypes = hs.eventtap.event.types
local properties = hs.eventtap.event.properties

--- Internal state machine for one drag gesture.
local state = {
	tap = nil,
	threshold = DEFAULT_THRESHOLD,
	mods = { "cmd" },
	debug = false,
	passthroughApps = {},

	pending = nil,        -- { pos, flags } while we're undecided click vs drag
	window = nil,         -- the window currently being moved, if any
	startWinTopLeft = nil,
	startMousePos = nil,
}

--- Log a debug message to the Hammerspoon console when state.debug is on.
--- @private
local function log(fmt, ...)
	if state.debug then
		hs.printf("[windowDrag] " .. fmt, ...)
	end
end

--- Render a flags table as a short string, e.g. "cmd+shift".
--- @private
local function flagsToString(flags)
	local parts = {}
	for _, m in ipairs({ "cmd", "shift", "alt", "ctrl", "fn", "capslock" }) do
		if flags[m] then parts[#parts + 1] = m end
	end
	if #parts == 0 then return "(none)" end
	return table.concat(parts, "+")
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- True iff `flags` has exactly the modifiers in `required` and no other
--- active modifier (shift/alt/ctrl/cmd). `fn` is ignored intentionally.
--- @param flags    table   Modifier flag table from `event:getFlags()`
--- @param required string[] Required modifier names, e.g. { "cmd" }
--- @return boolean
--- @private
local function modsMatchExactly(flags, required)
	local checkable = { "cmd", "shift", "alt", "ctrl" }
	for _, m in ipairs(checkable) do
		local needed = false
		for _, r in ipairs(required) do
			if r == m then needed = true; break end
		end
		if needed and not flags[m] then return false end
		if not needed and flags[m] then return false end
	end
	return true
end

--- Find the topmost standard window whose frame contains `point`.
--- @param point hs.geometry|table  { x, y } in screen coordinates
--- @return hs.window|nil
--- @private
local function windowAt(point)
	for _, w in ipairs(hs.window.orderedWindows()) do
		if w:isStandard() then
			local f = w:frame()
			if point.x >= f.x and point.x <= f.x + f.w
				and point.y >= f.y and point.y <= f.y + f.h then
				return w
			end
		end
	end
	return nil
end

--- Post a synthetic leftMouseDown + leftMouseUp at `pos` with `flags`, so
--- the application receives the click that we previously suppressed.
--- The events are tagged with SENTINEL so the callback ignores them.
--- @param pos   table  { x, y } in screen coordinates
--- @param flags table  Modifier flag table
--- @private
local function replayClick(pos, flags)
	local down = hs.eventtap.event.newMouseEvent(eventTypes.leftMouseDown, pos)
	down:setFlags(flags)
	down:setProperty(properties.eventSourceUserData, SENTINEL)
	down:post()

	local up = hs.eventtap.event.newMouseEvent(eventTypes.leftMouseUp, pos)
	up:setFlags(flags)
	up:setProperty(properties.eventSourceUserData, SENTINEL)
	up:post()
end

--- Clear the per-gesture state.
--- @private
local function reset()
	state.pending = nil
	state.window = nil
	state.startWinTopLeft = nil
	state.startMousePos = nil
end

-- ---------------------------------------------------------------------------
-- Event tap callback
-- ---------------------------------------------------------------------------

--- Map an event type number to its human-readable name.
--- Computed once at load time so the lookup is cheap.
--- @private
local typeNames = {}
for name, num in pairs(eventTypes) do typeNames[num] = name end

--- Returning `true` suppresses the event; `false` lets it through.
--- @param ev hs.eventtap.event
--- @return boolean suppress
--- @private
local function onEvent(ev)
	-- Ignore events we posted ourselves.
	if ev:getProperty(properties.eventSourceUserData) == SENTINEL then
		return false
	end

	local t = ev:getType()

	if state.debug and state.pending then
		log("event %s (state: pending=%s window=%s)",
			typeNames[t] or tostring(t),
			tostring(state.pending ~= nil),
			tostring(state.window ~= nil))
	end

	if t == eventTypes.leftMouseDown then
		local flags = ev:getFlags()
		local matched = modsMatchExactly(flags, state.mods)
		log("mouseDown flags=%s matched=%s", flagsToString(flags), tostring(matched))
		if matched then
			-- Screen-sharing clients forward this gesture to another machine.
			-- Yield before buffering the down event so the remote Hammerspoon
			-- receives a complete Cmd+drag sequence.
			if inputPassthrough.isFrontmost(state.passthroughApps) then
				log("mouseDown belongs to frontmost input-forwarding app")
				return false
			end
			local pos = ev:location()
			state.pending = { pos = pos, flags = flags }
			state.startMousePos = pos
			return true -- suppress; decision deferred until drag or up
		end
		return false
	end

	-- Both leftMouseDragged and mouseMoved drive the drag logic. macOS
	-- only emits leftMouseDragged when it believes the button is down,
	-- but since we suppress the original mouseDown the system loses that
	-- belief and emits plain mouseMoved instead. So we listen to both.
	if t == eventTypes.leftMouseDragged or t == eventTypes.mouseMoved then
		if state.window then
			-- Already dragging: move the window with the cursor.
			local cur = ev:location()
			state.window:setTopLeft({
				x = state.startWinTopLeft.x + (cur.x - state.startMousePos.x),
				y = state.startWinTopLeft.y + (cur.y - state.startMousePos.y),
			})
			return true
		end
		if state.pending then
			local cur = ev:location()
			local dx = cur.x - state.pending.pos.x
			local dy = cur.y - state.pending.pos.y
			if dx * dx + dy * dy >= state.threshold * state.threshold then
				local win = windowAt(state.pending.pos)
				if win then
					state.window = win
					state.startWinTopLeft = win:topLeft()
					win:focus()
					log("drag engaged on window: %s (%s)",
						win:title() or "?", win:application() and win:application():name() or "?")
				else
					log("drag threshold crossed but no draggable window at (%.0f, %.0f)",
						state.pending.pos.x, state.pending.pos.y)
					replayClick(state.pending.pos, state.pending.flags)
					reset()
				end
			end
			return true
		end
		return false
	end

	if t == eventTypes.leftMouseUp then
		if state.window then
			log("drag released")
			reset()
			return true
		end
		if state.pending then
			log("click without drag — replaying at (%.0f, %.0f) flags=%s",
				state.pending.pos.x, state.pending.pos.y, flagsToString(state.pending.flags))
			local pos = state.pending.pos
			local flags = state.pending.flags
			reset()
			replayClick(pos, flags)
			return true
		end
		return false
	end

	return false
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Start listening for modifier+drag gestures.
--- @param opts table|nil  Options:
---   - mods:      string[] modifiers that must be held (default `{ "cmd" }`)
---   - threshold: number   pixels of movement before a drag engages (default 5)
---   - passthroughApps: table additional bundle IDs or app names to yield to
function M.setup(opts)
	opts = opts or {}
	state.mods = opts.mods or { "cmd" }
	state.threshold = opts.threshold or DEFAULT_THRESHOLD
	state.debug = opts.debug == true
	state.passthroughApps = opts.passthroughApps or {}

	M.cleanup()
	state.tap = hs.eventtap.new({
		eventTypes.leftMouseDown,
		eventTypes.leftMouseDragged,
		eventTypes.leftMouseUp,
		eventTypes.mouseMoved, -- in case macOS routes drags here after we suppress mouseDown
	}, onEvent)
	state.tap:start()
	log("setup: mods=%s threshold=%d running=%s",
		table.concat(state.mods, "+"), state.threshold, tostring(state.tap:isEnabled()))
end

--- Stop the event tap and discard any in-flight gesture state.
function M.cleanup()
	if state.tap then
		state.tap:stop()
		state.tap = nil
	end
	reset()
end

return M
