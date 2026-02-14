--- streamdeck/helpers.lua
--- Domain helpers extracted from config.lua. Media detection, system key
--- simulation, and other utilities used by Stream Deck presets and config.

local M = {}

--- Check whether Spotify or Music is currently playing.
--- @return boolean
function M.isMediaPlaying()
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

--- Read overall CPU usage percentage.
--- @return number
function M.fetchCpuUsage()
	local data = hs.host.cpuUsage()
	if data and data.overall then
		return data.overall.active or 0
	end
	return 0
end

--- Send a single system key press/release event.
--- @param key string  System key name (e.g. "PLAY", "PREVIOUS", "NEXT")
function M.sendSystemKey(key)
	hs.eventtap.event.newSystemKeyEvent(key, true):post()
	hs.eventtap.event.newSystemKeyEvent(key, false):post()
end

--- Send a system key repeatedly with a delay between presses.
--- @param key string       System key name
--- @param count number     Number of times to press
--- @param delay number?    Delay between presses in seconds (default 0.05)
--- @param callback fun()?  Optional callback when all presses are done
function M.sendSystemKeyWithDelay(key, count, delay, callback)
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

return M
