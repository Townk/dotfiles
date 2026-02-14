--- streamdeck/config.lua
--- Declarative configuration for Stream Deck+ following the State-Value-Callback
--- schema. All domain logic (audio, controls, actions) lives here. The engine
--- interprets this config generically.

local audio = require("audio")
local controls = require("system.controls")
local actions = require("system.actions")
local colors = require("streamdeck.renderer").colors

-- ============================================================
-- CONSTANTS
-- ============================================================

local BIG_STEP = 10
local SMALL_STEP = 2.5

-- ============================================================
-- HELPERS (migrated from buttons.lua and encoders.lua)
-- ============================================================

local function isMediaPlaying()
	for _, appName in ipairs({ "Spotify", "Music" }) do
		if hs.application.get(appName) then
			local ok, result = hs.osascript.applescript(string.format(
				[[
                tell application "%s"
                    if player state is playing then
                        return "playing"
                    end if
                end tell
            ]],
				appName
			))
			if ok and result == "playing" then
				return true
			end
		end
	end
	return false
end

local function fetchCpuUsage()
	local data = hs.host.cpuUsage()
	if data and data.overall then
		return data.overall.active or 0
	end
	return 0
end

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

local function sendSystemKey(key)
	hs.eventtap.event.newSystemKeyEvent(key, true):post()
	hs.eventtap.event.newSystemKeyEvent(key, false):post()
end

-- ============================================================
-- BUTTONS
-- ============================================================

-- 1: Mic Mute Toggle
local micMuteButton = {
	state = function()
		return audio.inputs:isMuted()
	end,
	icon = function(muted)
		return muted and "\u{1F507}" or "\u{1F399}"
	end,
	label = function(muted)
		return muted and "Muted" or "Mic On"
	end,
	bgColor = function(muted)
		return muted and colors.red or colors.green
	end,
	callback = function()
		controls.toggleMute()
		return true
	end,
}

-- 2: Focus / Do Not Disturb Toggle
local focusButton = {
	state = function()
		return controls.getFocusMode()
	end,
	icon = function(active)
		return active and "\u{1F319}" or "\u{1F514}"
	end,
	label = function(active)
		return active and "Focus On" or "Focus"
	end,
	bgColor = function(active)
		return active and colors.accent or colors.bg
	end,
	callback = function()
		controls.toggleDoNotDisturb()
		return false -- periodic refresh will catch new state
	end,
}

-- 3: Screenshot (selection)
local screenshotButton = {
	state = true,
	icon = "\u{1F4F8}",
	label = "Screenshot",
	bgColor = colors.bgLight,
	callback = function()
		hs.eventtap.keyStroke({ "cmd", "shift" }, "4")
		return false
	end,
}

-- 4: Lock Screen
local lockButton = {
	state = true,
	icon = "\u{1F512}",
	label = "Lock",
	bgColor = colors.bgLight,
	callback = function()
		hs.caffeinate.lockScreen()
		return false
	end,
}

-- 5: Previous Track
local prevTrackButton = {
	state = true,
	icon = "\u{23EE}",
	label = "Prev",
	bgColor = colors.bgLight,
	callback = function()
		sendSystemKey("PREVIOUS")
		return false
	end,
}

-- 6: Play / Pause
local playPauseButton = {
	state = function()
		return isMediaPlaying()
	end,
	icon = function(playing)
		return playing and "\u{23F8}" or "\u{25B6}\u{FE0F}"
	end,
	label = function(playing)
		return playing and "Pause" or "Play"
	end,
	bgColor = function(playing)
		return playing and colors.accent or colors.bgLight
	end,
	callback = function()
		sendSystemKey("PLAY")
		return true
	end,
}

-- 7: Next Track
local nextTrackButton = {
	state = true,
	icon = "\u{23ED}",
	label = "Next",
	bgColor = colors.bgLight,
	callback = function()
		sendSystemKey("NEXT")
		return false
	end,
}

-- 8: Cycle Audio Output Device
local audioOutputButton = {
	state = function()
		local dev = audio.outputs:defaultDevice()
		return dev and dev:name() or "Audio"
	end,
	icon = function(name)
		local isHP = name
			and (name:lower():find("headphone") or name:lower():find("airpod") or name:lower():find("beats"))
		return isHP and "\u{1F3A7}" or "\u{1F50A}"
	end,
	label = function(name)
		local short = name or "Audio"
		if #short > 10 then
			short = short:sub(1, 9) .. "\u{2026}"
		end
		return short
	end,
	bgColor = colors.bgLight,
	callback = function()
		actions.cycleOutputDevice()
		return true
	end,
}

-- ============================================================
-- ENCODERS
-- ============================================================

-- 1: System Volume
local volumeEncoder = {
	state = function()
		return audio.outputs:isMuted()
	end,
	value = function()
		return controls.volume()
	end,
	icon = function(muted)
		return muted and "\u{1F507}" or "\u{1F50A}"
	end,
	label = function(muted)
		return muted and "\u{1F507} MUTED" or "\u{1F50A} Volume"
	end,
	layout = "value_bar",
	status = { min = 0, max = 100 },
	barColor = function(muted)
		return muted and colors.red or colors.blue
	end,
	callbackInc = function(s, v, sec)
		local step = sec and SMALL_STEP or BIG_STEP
		controls.volumeUp(step)
		return math.min((v or 0) + step, 100)
	end,
	callbackDec = function(s, v, sec)
		local step = sec and SMALL_STEP or BIG_STEP
		controls.volumeDown(step)
		return math.max((v or 0) - step, 0)
	end,
	callbackPress = function()
		controls.toggleMute()
		return true
	end,
}

-- 2: Input Volume (Microphone)
local inputVolumeEncoder = {
	state = function()
		return audio.inputs:isMuted()
	end,
	value = function()
		return controls.inputVolume()
	end,
	icon = function(muted)
		return muted and "\u{1F507}" or "\u{1F399}"
	end,
	label = function(muted)
		return muted and "\u{1F507} MUTED" or "\u{1F399} Mic"
	end,
	layout = "value_bar",
	status = { min = 0, max = 100 },
	barColor = function(muted)
		return muted and colors.red or colors.green
	end,
	callbackInc = function(s, v, sec)
		local step = sec and SMALL_STEP or BIG_STEP
		controls.inputVolumeUp(step)
		return math.min((v or 0) + step, 100)
	end,
	callbackDec = function(s, v, sec)
		local step = sec and SMALL_STEP or BIG_STEP
		controls.inputVolumeDown(step)
		return math.max((v or 0) - step, 0)
	end,
	callbackPress = function()
		controls.toggleInputMute()
		return true
	end,
}

-- 3: Display Brightness
local brightnessEncoder = {
	state = true,
	value = function()
		return controls.brightness()
	end,
	icon = function()
		return "\u{2600}"
	end,
	label = function()
		return "\u{2600} Brightness"
	end,
	layout = "value_bar",
	status = { min = 0, max = 100 },
	barColor = colors.orange,
	callbackInc = function(s, v, sec)
		local step = sec and SMALL_STEP or BIG_STEP
		controls.brightnessUp(step)
		return math.min((v or 0) + step, 100)
	end,
	callbackDec = function(s, v, sec)
		local step = sec and SMALL_STEP or BIG_STEP
		controls.brightnessDown(step)
		return math.max((v or 0) - step, 0)
	end,
	callbackPress = function()
		controls.toggleDarkMode()
		return false
	end,
}

-- 4: Clock / CPU (encoder controls keyboard brightness)
local clockCpuEncoder = {
	state = function()
		return os.date("%H:%M")
	end,
	value = function()
		return fetchCpuUsage()
	end,
	icon = function(time)
		return time
	end,
	label = function(_, cpu)
		return string.format("CPU %d%%", math.floor(cpu or 0))
	end,
	layout = "full_canvas",
	status = { min = 0, max = 100 },
	barColor = function(_, cpu)
		cpu = cpu or 0
		return cpu > 80 and colors.red or cpu > 50 and colors.orange or colors.green
	end,
	callbackInc = function(s, v, sec)
		local step = sec and SMALL_STEP or BIG_STEP
		local keyCount = math.max(1, math.floor(step / 10))
		sendSystemKeyWithDelay("ILLUMINATION_UP", keyCount, 0.05)
		return v
	end,
	callbackDec = function(s, v, sec)
		local step = sec and SMALL_STEP or BIG_STEP
		local keyCount = math.max(1, math.floor(step / 10))
		sendSystemKeyWithDelay("ILLUMINATION_DOWN", keyCount, 0.05)
		return v
	end,
	callbackPress = function()
		hs.eventtap.keyStroke({ "ctrl" }, "up")
		return false
	end,
}

-- ============================================================
-- STREAMDECK CONFIG
-- ============================================================

return {
	brightness = 90,
	defaultProfile = "main",
	profiles = {
		{
			id = "main",
			name = "Main",
			pages = {
				{
					id = "home",
					name = "Home",
					onRefresh = function()
						controls.refreshState()
					end,
					inputs = {
						buttons = {
							[1] = micMuteButton,
							[2] = focusButton,
							[3] = screenshotButton,
							[4] = lockButton,
							[5] = prevTrackButton,
							[6] = playPauseButton,
							[7] = nextTrackButton,
							[8] = audioOutputButton,
						},
						encoders = {
							[1] = volumeEncoder,
							[2] = inputVolumeEncoder,
							[3] = brightnessEncoder,
							[4] = clockCpuEncoder,
						},
					},
				},
			},
		},
	},
}
