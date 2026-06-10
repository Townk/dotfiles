--- system/dock.lua
--- Keep Dock visibility aligned with the current display layout.

local M = {}

local watcher = nil
local applyTimer = nil

local builtInScreenNamePatterns = {
	"built%-in",
	"internal",
	"color lcd",
	"liquid retina",
}

local function screenName(screen)
	local ok, name = pcall(function()
		return screen:name()
	end)
	return ok and name or ""
end

local function isBuiltInScreen(screen)
	local name = string.lower(screenName(screen))
	for _, pattern in ipairs(builtInScreenNamePatterns) do
		if name:find(pattern) then
			return true
		end
	end
	return false
end

local function externalScreenPresent()
	local screens = hs.screen.allScreens()
	if #screens > 1 then
		return true
	end
	if #screens == 0 then
		return false
	end
	return not isBuiltInScreen(screens[1])
end

local function readDockAutohide()
	local output, ok = hs.execute("/usr/bin/defaults read com.apple.dock autohide 2>/dev/null")
	if not ok then
		return nil
	end
	output = output:gsub("%s+$", "")
	return output == "1" or output == "true"
end

local function setDockAutohide(enabled)
	local current = readDockAutohide()
	if current == enabled then
		return true
	end

	local value = enabled and "true" or "false"
	local _, ok = hs.execute("/usr/bin/defaults write com.apple.dock autohide -bool " .. value)
	if ok then
		hs.execute("/usr/bin/killall Dock >/dev/null 2>&1 || true")
	end
	return ok == true
end

function M.apply()
	local shouldAutohide = not externalScreenPresent()
	local ok = setDockAutohide(shouldAutohide)
	if not ok then
		hs.printf("dock: failed to set autohide=%s", tostring(shouldAutohide))
	end
end

local function scheduleApply()
	if applyTimer then
		applyTimer:stop()
	end
	applyTimer = hs.timer.doAfter(1, function()
		applyTimer = nil
		M.apply()
	end)
end

function M.setup()
	M.cleanup()
	M.apply()
	watcher = hs.screen.watcher.new(scheduleApply):start()
end

function M.cleanup()
	if applyTimer then
		applyTimer:stop()
		applyTimer = nil
	end
	if watcher then
		watcher:stop()
		watcher = nil
	end
end

return M
