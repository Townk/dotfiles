--- audio/init.lua
--- Audio abstraction layer entry point.
--- Creates SystemInputs and SystemOutputs collections, starts the
--- hs.audiodevice.watcher to react to device changes (plug/unplug,
--- default-device switches), and exposes a cleanup function for teardown.
---
--- Usage:
---   local audio = require("audio")
---   audio.outputs:volume()
---   audio.outputs:toggleMute()
---   audio.inputs:isMuted()
---   audio.outputs:cycleDevice()

local system_devices = require("audio.system_devices")
local SystemInputs = system_devices.SystemInputs
local SystemOutputs = system_devices.SystemOutputs

local M = {}

--- @type SystemInputs|nil
M.inputs = nil
--- @type SystemOutputs|nil
M.outputs = nil

---------------------------------------------------------------------------
-- Watcher lifecycle
---------------------------------------------------------------------------

--- @type AudioWatcherState
local _watcher = {
	running = false,
	userCallback = nil,
}

--- Rebuild inputs and outputs from scratch by re-querying hs.audiodevice.
function M.refresh()
	M.inputs = SystemInputs:new()
	M.outputs = SystemOutputs:new()
end

--- Start watching for system audio device changes.
--- Idempotent: stops any existing watcher before starting a new one.
--- The entire callback body is wrapped in pcall to prevent errors from
--- killing the watcher.
---
--- Handled events:
---   "dev#" — device added/removed → full refresh
---   "dIn " — default input changed → refreshDefault on inputs
---   "dOut" — default output changed → refreshDefault on outputs
--- @param callback? fun(event: string)  Optional user callback invoked after each event
function M.watchDeviceChanges(callback)
	-- Idempotent: stop existing watcher first
	if _watcher.running then
		M.stopWatching()
	end

	_watcher.userCallback = callback

	hs.audiodevice.watcher.setCallback(function(event)
		local ok, err = pcall(function()
			if event == "dev#" then
				M.refresh()
			elseif event == "dIn " then
				if M.inputs then
					M.inputs:refreshDefault()
				end
			elseif event == "dOut" then
				if M.outputs then
					M.outputs:refreshDefault()
				end
			end

			if _watcher.userCallback then
				_watcher.userCallback(event)
			end
		end)

		if not ok then
			print(string.format("[Audio] Watcher error on '%s': %s",
				tostring(event), tostring(err)))
		end
	end)

	hs.audiodevice.watcher.start()
	_watcher.running = true
end

--- Stop the audio device watcher and clear the callback.
function M.stopWatching()
	if _watcher.running then
		hs.audiodevice.watcher.stop()
		hs.audiodevice.watcher.setCallback(nil)
		_watcher.running = false
		_watcher.userCallback = nil
	end
end

--- Full module teardown: stop watcher and release collections.
function M.cleanup()
	M.stopWatching()
	M.inputs = nil
	M.outputs = nil
end

---------------------------------------------------------------------------
-- Initialize on require
---------------------------------------------------------------------------

M.refresh()
M.watchDeviceChanges()

return M
