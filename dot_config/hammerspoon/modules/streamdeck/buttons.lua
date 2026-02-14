--- streamdeck/buttons.lua
--- Defines the 8 LCD button actions and state‑aware image updates.
---
--- Layout (Stream Deck+ 4×2):
---   Row 1: Mic Mute | Focus (DnD) | Screenshot | Lock Screen
---   Row 2: Prev Track | Play/Pause | Next Track | Audio Output

local images = require("streamdeck.images")
local audio = require("audio")
local controls = require("system.controls")
local actions = require("system.actions")

local M = {}
M.deck = nil

-- ============================================================
-- STATE
-- ============================================================

local state = {
	isPlaying = false,
}

-- ============================================================
-- HELPERS
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

-- ============================================================
-- BUTTON ACTIONS (one per button, triggered on press)
-- ============================================================

-- 1: Mic Mute Toggle
local function toggleMicMute()
	controls.toggleMute()
	M.updateButton(1)
end

-- 2: Focus / Do Not Disturb Toggle
--    Uses controls.toggleDoNotDisturb() for real state detection + OSD feedback.
local function toggleDnD()
	controls.toggleDoNotDisturb()
	-- Update button after the system has settled (toggle + read takes ~1s)
	hs.timer.doAfter(1.0, function()
		M.updateButton(2)
	end)
end

-- 3: Screenshot (selection)
local function takeScreenshot()
	hs.eventtap.keyStroke({ "cmd", "shift" }, "4")
end

-- 4: Lock Screen
local function lockScreen()
	hs.caffeinate.lockScreen()
end

-- 5: Previous Track
local function prevTrack()
	hs.eventtap.event.newSystemKeyEvent("PREVIOUS", true):post()
	hs.eventtap.event.newSystemKeyEvent("PREVIOUS", false):post()
end

-- 6: Play / Pause
local function playPause()
	hs.eventtap.event.newSystemKeyEvent("PLAY", true):post()
	hs.eventtap.event.newSystemKeyEvent("PLAY", false):post()
	-- Slight delay before checking state so the player can respond
	hs.timer.doAfter(0.3, function()
		state.isPlaying = isMediaPlaying()
		M.updateButton(6)
	end)
end

-- 7: Next Track
local function nextTrack()
	hs.eventtap.event.newSystemKeyEvent("NEXT", true):post()
	hs.eventtap.event.newSystemKeyEvent("NEXT", false):post()
end

-- 8: Cycle Audio Output Device
local function cycleAudioOutput()
	actions.cycleOutputDevice()
	M.updateButton(8)
end

-- ============================================================
-- HANDLER MAP
-- ============================================================

local buttonHandlers = {
	[1] = toggleMicMute,
	[2] = toggleDnD,
	[3] = takeScreenshot,
	[4] = lockScreen,
	[5] = prevTrack,
	[6] = playPause,
	[7] = nextTrack,
	[8] = cycleAudioOutput,
}

-- ============================================================
-- IMAGE UPDATERS
-- ============================================================

local function getButtonImage(btn)
	if btn == 1 then
		return images.micMuteImage(audio.inputs:isMuted())
	elseif btn == 2 then
		local isActive = controls.getFocusMode()
		return images.dndImage(isActive)
	elseif btn == 3 then
		return images.screenshotImage()
	elseif btn == 4 then
		return images.lockImage()
	elseif btn == 5 then
		return images.prevTrackImage()
	elseif btn == 6 then
		return images.playPauseImage(state.isPlaying)
	elseif btn == 7 then
		return images.nextTrackImage()
	elseif btn == 8 then
		local dev = audio.outputs:defaultDevice()
		return images.audioOutputImage(dev and dev:name())
	end
end

function M.updateButton(btn)
	if not M.deck then
		return
	end
	local img = getButtonImage(btn)
	if img then
		M.deck:setButtonImage(btn, img)
	end
end

function M.updateAllButtons()
	state.isPlaying = isMediaPlaying()

	for i = 1, 8 do
		M.updateButton(i)
	end
end

-- ============================================================
-- CALLBACK (registered by streamdeck/init.lua)
-- ============================================================

function M.buttonCallback(device, buttonNumber, pressed)
	if pressed then
		local handler = buttonHandlers[buttonNumber]
		if handler then
			handler()
		end
	end
end

-- ============================================================
-- SETUP
-- ============================================================

function M.setup(deck)
	M.deck = deck
	M.updateAllButtons()
end

return M
