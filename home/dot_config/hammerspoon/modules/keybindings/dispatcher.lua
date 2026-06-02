--- keybindings/dispatcher.lua
--- Eventtap-based keyboard event dispatcher for the keybinding overlay.
--- Swallows ALL keyboard events while active, dispatching matched
--- keys to callbacks for navigation, actions, and scrolling.

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

--- Hardware keycodes for modifier-only keys (swallowed without dispatch).
--- @type table<number, boolean>
local MODIFIER_KEYCODES = {
	[54] = true,
	[55] = true, -- cmd
	[56] = true,
	[60] = true, -- shift
	[58] = true,
	[61] = true, -- alt/option
	[59] = true,
	[62] = true, -- ctrl
	[63] = true, -- fn
}

---------------------------------------------------------------------------
-- Dispatcher class
---------------------------------------------------------------------------

--- @class Dispatcher
local Dispatcher = {}
Dispatcher.__index = Dispatcher

--- Create a new Dispatcher instance.
--- @param callbacks DispatcherCallbacks  Event dispatch callbacks
--- @return Dispatcher
function Dispatcher.new(callbacks)
	local self = setmetatable({
		callbacks = callbacks,
		tap       = nil,
	}, Dispatcher)
	return self
end

---------------------------------------------------------------------------
-- Private methods
---------------------------------------------------------------------------

--- Extract a clean modifier flags table from a raw event flags table.
--- @param flags table  Raw event flags from hs.eventtap
--- @return { cmd: boolean, ctrl: boolean, alt: boolean, shift: boolean }
--- @private
function Dispatcher:_normalizeFlags(flags)
	return {
		cmd   = flags.cmd or false,
		ctrl  = flags.ctrl or false,
		alt   = flags.alt or false,
		shift = flags.shift or false,
	}
end

--- Process a single keyboard event and dispatch to the appropriate callback.
--- @param event hs.eventtap.event
--- @return boolean  true to swallow the event, false to pass through
--- @private
function Dispatcher:_handleKeyEvent(event)
	local keyCode = event:getKeyCode()

	-- Swallow modifier-only key presses
	if MODIFIER_KEYCODES[keyCode] then
		return true
	end

	local keyName = hs.keycodes.map[keyCode]
	if not keyName then
		return true
	end

	local flags = self:_normalizeFlags(event:getFlags() --[[@as table]])

	-- Escape (with optional shift) → close overlay
	if keyName == "escape" and not flags.cmd and not flags.ctrl and not flags.alt then
		self.callbacks.onEscape()
		return true
	end

	-- Delete/Backspace (unmodified) → navigate back
	if
		(keyName == "delete" or keyName == "forwarddelete")
		and not flags.cmd
		and not flags.ctrl
		and not flags.alt
		and not flags.shift
	then
		self.callbacks.onBackspace()
		return true
	end

	-- Ctrl+D / Ctrl+U → scroll
	if flags.ctrl and not flags.cmd and not flags.alt then
		if keyName == "d" then
			self.callbacks.onScrollDown()
			return true
		elseif keyName == "u" then
			self.callbacks.onScrollUp()
			return true
		end
	end

	-- Try to match a binding
	local child = self.callbacks.findChild(keyName, flags)
	if child then
		local swallow = self.callbacks.onMatch(child)
		if swallow == false then
			return false
		end
		return true
	end

	-- No match — notify and swallow
	self.callbacks.onUnmatched(keyName, flags)
	return true
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Start intercepting keyboard events.
function Dispatcher:start()
	if self.tap then
		self.tap:stop()
	end
	self.tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
		local ok, result = pcall(self._handleKeyEvent, self, event)
		if not ok then
			hs.printf("keybindings: dispatcher error: %s", tostring(result))
			return false
		end
		return result
	end)
	self.tap:start()
end

--- Stop intercepting keyboard events (preserves the eventtap for restart).
function Dispatcher:stop()
	if self.tap then
		self.tap:stop()
	end
end

--- Release all resources.
function Dispatcher:cleanup()
	if self.tap then
		self.tap:stop()
		self.tap = nil
	end
end

return Dispatcher
