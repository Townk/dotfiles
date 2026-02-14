--- streamdeck/encoders.lua
--- Handles the 4 rotary encoders, LCD strip dashboard, screen-touch events,
--- and a periodic refresh timer.
---
--- Encoder map:
---   1: System Volume    (turn +/-%, press mute/unmute)
---   2: Input Volume     (turn +/-%, press mic mute/unmute)
---   3: Display Bright.  (turn +/-%, press dark-mode toggle)
---   4: KB Brightness    (turn +/-step, press Mission Control)
---
--- LCD strip sections (one per encoder):
---   1: Volume bar + percentage
---   2: Mic volume bar + percentage
---   3: Brightness bar + percentage
---   4: Clock + CPU %

local images = require("streamdeck.images")
local audio = require("audio")
local controls = require("system.controls")

local M = {}
M.deck = nil

-- ============================================================
-- STATE
-- ============================================================

local encoderState = {
	pressed = {},
	turned = {},
}

local BIG_STEP = 10
local SMALL_STEP = 2.5

local cpuUsage = 0
local updateTimer = nil

local function sendSystemKeyWithDelay(key, count, delay, callback)
	delay = delay or 0.05
	local sent = 0
	local timer
	timer = hs.timer.doEvery(delay, function()
		if sent >= count then
			timer:stop()
			if callback then
				callback()
			end
			return
		end
		hs.eventtap.event.newSystemKeyEvent(key, true):post()
		hs.eventtap.event.newSystemKeyEvent(key, false):post()
		sent = sent + 1
	end)
end

-- ============================================================
-- HELPERS
-- ============================================================

local function clamp(val, lo, hi)
	return math.max(lo, math.min(hi, val))
end

local function fetchCpuUsage()
	local data = hs.host.cpuUsage()
	if data and data.overall then
		return data.overall.active or 0
	end
	return 0
end

-- ============================================================
-- ENCODER ACTIONS
-- ============================================================

-- Encoder 1 - System Volume ---------------------------------

local function volumeTurn(direction, step)
	if direction == "left" then
		controls.volumeDown(step)
	else
		controls.volumeUp(step)
	end
	M.updateStrip(1)
end

local function volumePress()
	controls.toggleMute()
	M.updateStrip(1)
end

-- Encoder 2 - Input Volume ----------------------------------

local function inputVolumeTurn(direction, step)
	if direction == "left" then
		controls.inputVolumeDown(step)
	else
		controls.inputVolumeUp(step)
	end
	M.updateStrip(2)
end

local function inputVolumePress()
	controls.toggleInputMute()
	M.updateStrip(2)
end

-- Encoder 3 - Display Brightness ----------------------------

local function brightnessTurn(direction, step)
	if direction == "left" then
		controls.brightnessDown(step)
	else
		controls.brightnessUp(step)
	end
	M.updateStrip(3)
end

local function brightnessPress()
	controls.toggleDarkMode()
end

-- Encoder 4 - Keyboard Brightness ---------------------------

local function kbBrightnessTurn(direction, step)
	local keyCount = math.floor((step or BIG_STEP) / 10)
	if keyCount < 1 then
		keyCount = 1
	end
	local key = direction == "left" and "ILLUMINATION_DOWN" or "ILLUMINATION_UP"
	sendSystemKeyWithDelay(key, keyCount, 0.05)
end

local function kbBrightnessPress()
	hs.eventtap.keyStroke({ "ctrl" }, "up")
end

-- ============================================================
-- HANDLER MAPS
-- ============================================================

local encoderTurnHandlers = {
	[1] = volumeTurn,
	[2] = inputVolumeTurn,
	[3] = brightnessTurn,
	[4] = kbBrightnessTurn,
}

local encoderPressHandlers = {
	[1] = volumePress,
	[2] = inputVolumePress,
	[3] = brightnessPress,
	[4] = kbBrightnessPress,
}

-- ============================================================
-- LCD STRIP UPDATERS
-- ============================================================

function M.updateStrip(encoder)
	if not M.deck then
		return
	end

	local img
	if encoder == 1 then
		img = images.volumeStrip(controls.volume(), audio.outputs:isMuted())
	elseif encoder == 2 then
		img = images.inputVolumeStrip(controls.inputVolume(), audio.inputs:isMuted())
	elseif encoder == 3 then
		img = images.brightnessStrip(controls.brightness())
	elseif encoder == 4 then
		img = images.clockCpuStrip(os.date("%H:%M"), cpuUsage)
	end

	if img then
		M.deck:setScreenImage(encoder, img)
	end
end

function M.updateAllStrips()
	for i = 1, 4 do
		M.updateStrip(i)
	end
end

-- ============================================================
-- PERIODIC REFRESH (every 2 s)
-- ============================================================

local function refreshState()
	controls.refreshState()
	cpuUsage = fetchCpuUsage()
	M.updateAllStrips()
end

-- ============================================================
-- CALLBACKS (registered by streamdeck/init.lua)
-- ============================================================

function M.encoderCallback(device, encoderNumber, pressed, turnedLeft, turnedRight)
	local isPressed = encoderState.pressed[encoderNumber] or false

	if pressed and not isPressed then
		encoderState.pressed[encoderNumber] = true
		encoderState.turned[encoderNumber] = false
		return
	end

	if isPressed and (turnedLeft or turnedRight) then
		encoderState.turned[encoderNumber] = true
		local direction = turnedLeft and "left" or "right"
		local h = encoderTurnHandlers[encoderNumber]
		if h then
			h(direction, SMALL_STEP)
		end
		return
	end

	if turnedLeft or turnedRight then
		local direction = turnedLeft and "left" or "right"
		local h = encoderTurnHandlers[encoderNumber]
		if h then
			h(direction, BIG_STEP)
		end
		return
	end

	if not pressed and isPressed then
		encoderState.pressed[encoderNumber] = false
		if not encoderState.turned[encoderNumber] then
			local h = encoderPressHandlers[encoderNumber]
			if h then
				h()
			end
		end
		encoderState.turned[encoderNumber] = false
	end
end

function M.screenCallback(device, eventType, x1, y1, x2, y2)
	local stripWidth = 800
	local section = clamp(math.floor(x1 / (stripWidth / 4)) + 1, 1, 4)

	if eventType == "shortPress" then
		local h = encoderPressHandlers[section]
		if h then
			h()
		end
	elseif eventType == "swipe" then
		local direction = x2 > x1 and "right" or "left"
		local h = encoderTurnHandlers[section]
		if h then
			h(direction, BIG_STEP)
		end
	end
end

-- ============================================================
-- SETUP / CLEANUP
-- ============================================================

function M.setup(deck)
	M.deck = deck

	controls.setOnChange(function(setting)
		if setting == "volume" then
			M.updateStrip(1)
		elseif setting == "inputVolume" then
			M.updateStrip(2)
		elseif setting == "brightness" then
			M.updateStrip(3)
		end
	end)

	refreshState()
	if updateTimer then
		updateTimer:stop()
	end
	updateTimer = hs.timer.doEvery(2, refreshState)
end

function M.cleanup()
	if updateTimer then
		updateTimer:stop()
		updateTimer = nil
	end
	controls.setOnChange(nil)
end

return M
