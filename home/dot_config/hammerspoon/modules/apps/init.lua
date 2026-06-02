--- apps/init.lua
--- Third-party app launchers: PixelSnap, ColorSlurp, Shottr.
--- Each function activates the app via AppleScript or URL scheme.
---
--- Usage:
---   local apps = require("apps")
---   apps.pixelSnapFindDimensions()
---   apps.shottrCaptureArea()

local cb = require("apps.clipboard")

local M = {}

--- Activate PixelSnap 2 and trigger the "Find Dimensions" menu action.
--- If already running, launch it again immediately (toggles dimensions on).
--- If not running, wait until it's fully launched, then launch it again.
function M.pixelSnapFindDimensions()
	local app = hs.application.find("PixelSnap 2")
	if app then
		hs.application.launchOrFocus("PixelSnap 2")
	else
		hs.application.launchOrFocus("PixelSnap 2")
		hs.timer.waitUntil(
			function() return hs.application.find("PixelSnap 2") ~= nil end,
			function() hs.application.launchOrFocus("PixelSnap 2") end,
			0.2
		)
	end
end

--- Open the ColorSlurp color picker magnifier via URL scheme.
function M.colorSlurpPickColor()
	hs.urlevent.openURL("colorslurp://x-callback-url/show-magnifier")
end

--- Capture the full screen with Shottr via URL scheme.
function M.cleanshotCaptureScreen()
	hs.urlevent.openURL("cleanshot://capture-fullscreen")
end

--- Capture a selected area with Shottr via URL scheme.
function M.cleanshotCaptureArea()
	hs.urlevent.openURL("cleanshot://capture-area")
end

--- Capture a scrolling screenshot with Shottr via URL scheme.
function M.cleanshotCaptureScrolling()
	hs.urlevent.openURL("cleanshot://scrolling-capture")
end

--- Capture text via OCR with Shottr via URL scheme.
function M.cleanshotCaptureOCR()
	hs.urlevent.openURL("cleanshot://capture-text")
end

function M.raycastSearchSVG()
  hs.urlevent.openURL("raycast://extensions/1weiho/svgl/index")
end

function M.raycastSearchUnicode()
  hs.urlevent.openURL("raycast://extensions/mmazzarolo/unicode-symbols/index")
end

function M.raycastSearchEmoji()
  hs.urlevent.openURL("raycast://extensions/raycast/emoji-symbols/search-emoji-symbols")
end

function M.raycastSearchGitMoji()
  hs.urlevent.openURL("raycast://extensions/ricoberger/gitmoji/gitmoji")
end

function M.raycastSearchMaterialIcon()
  hs.urlevent.openURL("raycast://extensions/creasty/material-icons/index")
end

function M.raycastViewMyIp()
  hs.urlevent.openURL("raycast://extensions/koinzhang/ip-geolocation/my-ip-geolocation")
end

function M.raycastViewSystemInfo()
  hs.urlevent.openURL("raycast://extensions/Visual-Studio-Coder/system-information/index")
end

function M.raycastSystemMonitor()
  hs.urlevent.openURL("raycast://extensions/hossammourad/raycast-system-monitor/system-monitor")
end

function M.raycastQRCodeFromSelection()
  cb.copySelection()
  hs.timer.doAfter(0.2, function()
    hs.urlevent.openURL("raycast://extensions/Melvynx/qrcode-generator/clipboard")
  end)
end

return M
