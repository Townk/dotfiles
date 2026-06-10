--- system/lifecycle.lua
--- Media key interception, config file watcher, reload, and setup/cleanup
--- orchestration for the system module.

local images = require("images")
local controls = require("system.controls")
local osd = require("osd")

local M = {}

-- ============================================================
-- MEDIA KEY INTERCEPTION
-- ============================================================

--- @type hs.eventtap|nil
local mediaKeyTap = nil

local mediaKeyHandlers = {
	SOUND_UP = controls.outputVolumeUp,
	SOUND_DOWN = controls.outputVolumeDown,
	MUTE = controls.toggleOutputMute,
	BRIGHTNESS_UP = controls.brightnessUp,
	BRIGHTNESS_DOWN = controls.brightnessDown,
}

-- ============================================================
-- CONFIG FILE WATCHER
-- ============================================================

--- @type hs.pathwatcher|nil
local configWatcher = nil

--- @type fun()[]
local cleanupFns = {}

--- Run all registered cleanup functions, then clean up lifecycle's own resources.
--- @private
local function runCleanup()
	for _, fn in ipairs(cleanupFns) do
		fn()
	end
	if configWatcher then
		configWatcher:stop()
		configWatcher = nil
	end
	if mediaKeyTap then
		mediaKeyTap:stop()
		mediaKeyTap = nil
	end
	controls.cleanup()
end

--- Pathwatcher callback: reload Hammerspoon when any .lua file changes.
--- @param files string[]  Array of changed file paths
--- @private
local function reloadConfig(files)
	for _, file in pairs(files) do
		if file:sub(-4) == ".lua" then
			runCleanup()
			hs.console.clearConsole()
			hs.settings.set("_configReloaded", true)
			hs.reload()
			return
		end
	end
end

--- Trigger a manual reload (suitable for hotkey binding).
function M.reload()
	runCleanup()
	hs.settings.set("_configReloaded", true)
	hs.reload()
end

-- ============================================================
-- OSD CONVENIENCE
-- ============================================================

--- Show a "Configuration Reloaded" OSD if this launch followed a reload.
function M.showReloaded()
	if hs.settings.get("_configReloaded") then
		hs.settings.set("_configReloaded", false)
		osd.show("refresh", "Configuration Reloaded")
	end
end

-- ============================================================
-- SETUP / CLEANUP
-- ============================================================

--- Register a cleanup function to be called before reload.
--- @param fn fun()  Cleanup function
function M.registerCleanup(fn)
	table.insert(cleanupFns, fn)
end

--- Initialize media key interception, config file watcher, and control state.
function M.setup()
	cleanupFns = {}

	controls.initState()

	-- Media keys
	mediaKeyTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(event)
		local data = event:systemKey()
		if not data or not data.key or not data.down then
			return false
		end

		local handler = mediaKeyHandlers[data.key]
		if not handler then
			return false
		end

		local ok, err = pcall(handler)
		if not ok then
			hs.printf("media key handler failed for %s: %s", tostring(data.key), tostring(err))
			return false
		end

		return true
	end)
	mediaKeyTap:start()

	-- Config file watcher
	configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.config/hammerspoon/", reloadConfig):start()
end

return M
