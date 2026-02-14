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

		if data.key == "SOUND_UP" then
			controls.outputVolumeUp()
			return true
		elseif data.key == "SOUND_DOWN" then
			controls.outputVolumeDown()
			return true
		elseif data.key == "MUTE" then
			controls.toggleMute()
			return true
		elseif data.key == "BRIGHTNESS_UP" then
			controls.brightnessUp()
			return true
		elseif data.key == "BRIGHTNESS_DOWN" then
			controls.brightnessDown()
			return true
		end

		return false
	end)
	mediaKeyTap:start()

	-- Config file watcher
	configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.config/hammerspoon/", reloadConfig):start()
end

return M
