--- system/controls.lua
--- Centralized control for system volume, input volume, display brightness,
--- and dark mode. Shows OSD feedback and manages optimistic debounced state.
---
--- Usage:
---   local controls = require("system.controls")
---   controls.volumeUp(10)
---   controls.brightnessDown(5)
---   controls.toggleDarkMode()

local audio = require("audio")
local osd = require("osd")
local OptimisticState = require("system.optimistic_state")

local M = {}

-- ============================================================
-- CONFIGURATION
-- ============================================================

--- Default step size for volume and brightness adjustments.
--- @type number
M.defaultStep = 10

-- ============================================================
-- ICON LOADING (Material SVGs with canvas-drawn fallbacks)
-- ============================================================

--- @type OsdStructuredIcons
local volumeIcons = {
	up = "volume-up",
	down = "volume-down",
	off = "volume-off",
}

--- @type string[]
local brightnessIcons = {}
for i = 1, 7 do
	brightnessIcons[i] = "brightness-" .. i
end

--- @type OsdStructuredIcons
local micIcons = {
	static = "mic",
	off = "mic-off",
}

-- ============================================================
-- STATE
-- ============================================================

--- @type OptimisticState|nil
local outputVolumeState = nil
--- @type OptimisticState|nil
local inputVolumeState = nil
--- @type OptimisticState|nil
local brightnessState = nil
--- @type OptimisticState|nil
local focusState = nil

-- ============================================================
-- CHANGE LISTENER
-- ============================================================

--- @type ControlsOnChange|nil
local onChange = nil

--- Register a callback invoked whenever a control value changes.
--- @param fn ControlsOnChange|nil  Callback, or nil to unregister
function M.setOnChange(fn)
	onChange = fn
end

--- Invoke the onChange callback if registered.
--- @param setting "volume"|"inputVolume"|"brightness"|"focus"
--- @private
local function notifyChange(setting)
	if onChange then
		onChange(setting)
	end
end

-- ============================================================
-- GETTERS
-- ============================================================

--- Get the current output volume (optimistic value from OptimisticState).
--- @return number  Volume percentage (0–100)
function M.outputVolume()
	return outputVolumeState and outputVolumeState:get() or 0
end

--- Get the current input volume (optimistic value from OptimisticState).
--- @return number  Volume percentage (0–100)
function M.inputVolume()
	return inputVolumeState and inputVolumeState:get() or 0
end

--- Get the current display brightness (optimistic value from OptimisticState).
--- @return number  Brightness percentage (0–100)
function M.brightness()
	return brightnessState and brightnessState:get() or 0
end

--- Get the current Focus mode snapshot (optimistic value from OptimisticState).
--- @return FocusMode
function M.focusMode()
	return focusState and focusState:get() or { active = false, name = "" }
end

-- ============================================================
-- VOLUME
-- ============================================================

--- Increase output volume by the given step (default: defaultStep).
--- @param step number|nil  Step size in percentage points
function M.outputVolumeUp(step)
	if not outputVolumeState then return end
	local prev = outputVolumeState:get()
	outputVolumeState:inc(step or M.defaultStep)
	local cur = outputVolumeState:get()
	local muted = audio.outputs:isMuted()
	osd.show(volumeIcons, muted and 0 or cur, "up")
	if cur ~= prev then
		osd.playTick(cur / 100)
	end
end

--- Decrease output volume by the given step (default: defaultStep).
--- @param step number|nil  Step size in percentage points
function M.outputVolumeDown(step)
	if not outputVolumeState then return end
	local prev = outputVolumeState:get()
	outputVolumeState:dec(step or M.defaultStep)
	local cur = outputVolumeState:get()
	local muted = audio.outputs:isMuted()
	osd.show(volumeIcons, muted and 0 or cur, "down")
	if cur ~= prev then
		osd.playTick(cur / 100)
	end
end

--- Toggle output mute and show OSD feedback.
function M.toggleOutputMute()
	audio.outputs:toggleMute()
	local muted = audio.outputs:isMuted()
	if not muted then
		-- Re-read hardware volume as the authoritative value after unmute
		local vol = audio.outputs:volume() or (outputVolumeState and outputVolumeState:get() or 0)
		if outputVolumeState then outputVolumeState:set(vol) end
		osd.show(volumeIcons, vol)
		osd.playTick(vol / 100)
	else
		osd.show(volumeIcons, 0)
	end
	notifyChange("volume")
end

-- ============================================================
-- INPUT VOLUME
-- ============================================================

--- Increase input volume by the given step (default: defaultStep).
--- @param step number|nil  Step size in percentage points
function M.inputVolumeUp(step)
	if not inputVolumeState then return end
	local prev = inputVolumeState:get()
	inputVolumeState:inc(step or M.defaultStep)
	local cur = inputVolumeState:get()
	local muted = audio.inputs:isMuted()
	osd.show(micIcons, muted and 0 or cur, "up")
	if cur ~= prev then
		osd.playTick(cur / 100)
	end
end

--- Decrease input volume by the given step (default: defaultStep).
--- @param step number|nil  Step size in percentage points
function M.inputVolumeDown(step)
	if not inputVolumeState then return end
	local prev = inputVolumeState:get()
	inputVolumeState:dec(step or M.defaultStep)
	local cur = inputVolumeState:get()
	local muted = audio.inputs:isMuted()
	osd.show(micIcons, muted and 0 or cur, "down")
	if cur ~= prev then
		osd.playTick(cur / 100)
	end
end

--- Toggle input mute and show OSD feedback.
function M.toggleInputMute()
	audio.inputs:toggleMute()
	local muted = audio.inputs:isMuted()
	local vol = audio.inputs:volume() or (inputVolumeState and inputVolumeState:get() or 0)
	if inputVolumeState then inputVolumeState:set(vol) end
	osd.show(micIcons, muted and 0 or vol)
	notifyChange("inputVolume")
end

-- ============================================================
-- BRIGHTNESS
-- ============================================================

--- Increase display brightness by the given step (default: defaultStep).
--- Uses OptimisticState for non-blocking optimistic updates.
--- OSD is shown before inc() so the canvas update happens before the
--- observer-triggered encoder re-renders, giving the run loop a chance
--- to paint the OSD frame between ticks.
--- @param step number|nil  Step size in percentage points
function M.brightnessUp(step)
	if brightnessState then
		brightnessState:inc(step or M.defaultStep)
		osd.show(brightnessIcons, brightnessState:get())
	end
end

--- Decrease display brightness by the given step (default: defaultStep).
--- Uses OptimisticState for non-blocking optimistic updates.
--- @param step number|nil  Step size in percentage points
function M.brightnessDown(step)
	if brightnessState then
		brightnessState:dec(step or M.defaultStep)
		osd.show(brightnessIcons, brightnessState:get())
	end
end

-- ============================================================
-- DARK MODE
-- ============================================================

--- Toggle macOS dark mode and show OSD feedback.
function M.toggleDarkMode()
	hs.osascript.applescript([[
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
            end tell
        end tell
    ]])
	local _, isDark = hs.osascript.applescript([[
        tell application "System Events"
            tell appearance preferences
                return dark mode
            end tell
        end tell
    ]])
	osd.show(isDark and "dark-mode" or "light-mode", isDark and "Dark Mode" or "Light Mode")
end

-- ============================================================
-- FOCUS / DO NOT DISTURB
-- ============================================================

--- Directory containing the macOS Focus assertion store.
--- Requires Full Disk Access for the calling process (Hammerspoon has it).
--- @type string
local FOCUS_DB = os.getenv("HOME") .. "/Library/DoNotDisturb/DB"

--- Read and decode a JSON file, returning nil on any failure.
--- @param path string  Absolute path to the JSON file
--- @return table|nil
--- @private
local function readJSON(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*all")
	f:close()
	return hs.json.decode(content)
end

--- Query the current macOS Focus mode from the system assertion store.
--- Checks manual assertions first (picking the most recent), then falls
--- back to time-based scheduled triggers.
--- @return FocusMode
--- @private
local function readFocusMode()
	local assertionsData = readJSON(FOCUS_DB .. "/Assertions.json")
	local configData = readJSON(FOCUS_DB .. "/ModeConfigurations.json")

	if not assertionsData or not configData then
		return { active = false, name = "" }
	end

	local records = assertionsData.data and assertionsData.data[1] and assertionsData.data[1].storeAssertionRecords
	local modes = configData.data and configData.data[1] and configData.data[1].modeConfigurations

	if not modes then
		return { active = false, name = "" }
	end

	-- Case 1: Manual assertion — pick the most recent by start timestamp
	if records and #records > 0 then
		local latest = records[1]
		for i = 2, #records do
			if (records[i].assertionStartDateTimestamp or 0) > (latest.assertionStartDateTimestamp or 0) then
				latest = records[i]
			end
		end
		local modeId = latest.assertionDetails and latest.assertionDetails.assertionDetailsModeIdentifier
		if modeId and modes[modeId] then
			return { active = true, name = modes[modeId].mode.name }
		end
		return { active = true, name = "" }
	end

	-- Case 2: Scheduled time-based triggers
	local date = os.date("*t")
	local now = date.hour * 60 + date.min

	for _, modeObj in pairs(modes) do
		local triggerList = modeObj.triggers and modeObj.triggers.triggers
		if triggerList then
			for _, trigger in ipairs(triggerList) do
				if trigger.enabledSetting == 2 and trigger.timePeriodStartTimeHour then
					local startMin = trigger.timePeriodStartTimeHour * 60 + trigger.timePeriodStartTimeMinute
					local endMin = trigger.timePeriodEndTimeHour * 60 + trigger.timePeriodEndTimeMinute

					local active = (startMin < endMin) and (now >= startMin and now < endMin)
						or (startMin > endMin) and (now >= startMin or now < endMin)

					if active then
						return { active = true, name = modeObj.mode.name }
					end
				end
			end
		end
	end

	return { active = false, name = "" }
end

--- Toggle macOS Do Not Disturb and show OSD feedback.
--- The state is updated optimistically and confirmed after the system settles.
function M.toggleDoNotDisturb()
	if not focusState then return end
	local current = focusState:get()
	focusState:set({ active = not current.active, name = current.name })
end

-- ============================================================
-- ASYNC READ/WRITE CLOSURES
-- ============================================================

--- Volume and input volume use synchronous in-process calls via
--- hs.audiodevice (fast, no shell). The read/write closures call
--- the callback immediately and return nil (no hs.task needed).
--- Brightness uses hs.task for non-blocking m1ddc shell commands.

--- @type OptimisticReadFn
local function readOutputVolume(callback)
	callback(audio.outputs:volume() or 0)
	return nil
end

--- @type OptimisticWriteFn
local function writeOutputVolume(target, callback)
	audio.outputs:setVolume(target)
	callback(true)
	return nil
end

--- @type OptimisticReadFn
local function readInputVolume(callback)
	callback(audio.inputs:volume() or 0)
	return nil
end

--- @type OptimisticWriteFn
local function writeInputVolume(target, callback)
	audio.inputs:setVolume(target)
	callback(true)
	return nil
end

--- Non-blocking brightness reader using hs.task + m1ddc.
--- @type OptimisticReadFn
local function readBrightness(callback)
	local cmd = "/opt/homebrew/bin/m1ddc get luminance 2>/dev/null"
		.. " || /usr/local/bin/m1ddc get luminance 2>/dev/null"
	local task = hs.task.new("/bin/sh", function(exitCode, stdOut, _stdErr)
		if exitCode == 0 and stdOut then
			local b = stdOut:match("(%d+)")
			if b then
				callback(tonumber(b))
				return
			end
		end
		-- Fallback to hs.brightness (fast, in-process, built-in display only)
		callback(hs.brightness.get())
	end, { "-c", cmd })
	task:start()
	return task
end

--- Non-blocking brightness writer using hs.task + m1ddc.
--- @type OptimisticWriteFn
local function writeBrightness(target, callback)
	local cmd = string.format(
		"/opt/homebrew/bin/m1ddc set luminance %d 2>/dev/null"
			.. " || /usr/local/bin/m1ddc set luminance %d 2>/dev/null",
		target,
		target
	)
	local task = hs.task.new("/bin/sh", function(exitCode, _stdOut, _stdErr)
		if exitCode == 0 then
			callback(true)
			return
		end

		local ok, result = pcall(hs.brightness.set, target)
		callback(ok and result ~= false)
	end, { "-c", cmd })
	task:start()
	return task
end

--- @type OptimisticReadFn
local function readFocus(callback)
	callback(readFocusMode())
	return nil
end

--- @type OptimisticWriteFn
local function writeFocus(_, callback)
	hs.execute("/usr/bin/shortcuts run 'Toggle Do Not Disturb'")
	-- Brief delay to let the system update the assertion store before reading back
	hs.timer.doAfter(0.1, function()
		callback(true)
	end)
	return nil
end

-- ============================================================
-- STATE INITIALIZATION & REFRESH
-- ============================================================

--- Read current hardware values and initialize all OptimisticState instances.
--- Called once during lifecycle setup.
function M.initState()
	outputVolumeState = OptimisticState.new({
		initial = audio.outputs:volume() or 50,
		min = 0,
		max = 100,
		read = readOutputVolume,
		write = writeOutputVolume,
		debounce = 0.08,
	})
	outputVolumeState:observe(function(_)
		notifyChange("volume")
	end)

	inputVolumeState = OptimisticState.new({
		initial = audio.inputs:volume() or 50,
		min = 0,
		max = 100,
		read = readInputVolume,
		write = writeInputVolume,
		debounce = 0.08,
	})
	inputVolumeState:observe(function(_)
		notifyChange("inputVolume")
	end)

	-- Brightness: fast built-in read for initial value; async m1ddc read follows
	brightnessState = OptimisticState.new({
		initial = hs.brightness.get() or 50,
		min = 0,
		max = 100,
		read = readBrightness,
		write = writeBrightness,
		debounce = 0.08,
	})
	brightnessState:observe(function(_)
		notifyChange("brightness")
	end)

	focusState = OptimisticState.new({
		initial = readFocusMode(),
		read = readFocus,
		write = writeFocus,
		equals = function(a, b) return a.active == b.active and a.name == b.name end,
	})
	focusState:observe(function(mode)
		--- @cast mode FocusMode
		if mode.active then
			osd.show("notifications-paused", mode.name)
		else
			osd.show("notifications-active", "Focus Off")
		end
		notifyChange("focus")
	end)
end

--- Re-sync optimistic state from hardware for all idle controls.
--- OptimisticState:refresh() only adopts the read value if no writes are pending.
function M.refreshState()
	if outputVolumeState then outputVolumeState:refresh() end
	if inputVolumeState then inputVolumeState:refresh() end
	if brightnessState then brightnessState:refresh() end
	if focusState then focusState:refresh() end
end

-- ============================================================
-- CLEANUP
-- ============================================================

--- Stop all debounce timers, terminate async tasks, and release state.
function M.cleanup()
	if outputVolumeState then outputVolumeState:cleanup(); outputVolumeState = nil end
	if inputVolumeState then inputVolumeState:cleanup(); inputVolumeState = nil end
	if brightnessState then brightnessState:cleanup(); brightnessState = nil end
	if focusState then focusState:cleanup(); focusState = nil end
end

return M
