--- system/actions.lua
--- Discrete system-level actions: macOS Shortcuts, Hammerspoon console,
--- input source cycling, and audio device cycling.

local audio = require("audio")
local osd = require("osd")

local M = {}

-- ============================================================
-- macOS SHORTCUTS
-- ============================================================

--- Restart the computer via the "Restart Computer" Shortcut.
function M.systemRestart()
	hs.execute("shortcuts run 'Restart Computer'")
end

--- Log out the current user via the "Log Out User" Shortcut.
function M.systemLogOut()
	hs.execute("shortcuts run 'Log Out User'")
end

-- ============================================================
-- HAMMERSPOON CONSOLE
-- ============================================================

--- Toggle the Hammerspoon console window.
function M.hammerspoonConsole()
	hs.toggleConsole()
end

-- ============================================================
-- KEYBOARD INPUT SOURCE
-- ============================================================

--- Cycle through available keyboard input sources and show OSD feedback.
function M.cycleInputSources()
	local layouts = hs.keycodes.layouts()
	if layouts == nil or #layouts == 0 then
    osd.show("keyboard-off", "No input sources available")
		return
	end

	local currentLayout = hs.keycodes.currentLayout()
	local currentIndex = 1

	for i, layout in ipairs(layouts) do
		if layout == currentLayout then
			currentIndex = i
			break
		end
	end

	local nextIndex = currentIndex % #layouts + 1
	local nextLayout = layouts[nextIndex]

	hs.keycodes.setLayout(nextLayout)
  osd.show("keyboard", nextLayout)
end

-- ============================================================
-- AUDIO DEVICE CYCLING
-- ============================================================

--- Cycle to the next audio output device and show OSD feedback.
function M.cycleOutputDevice()
	local nextDev = audio.outputs:cycleDevice()
	if nextDev then
		osd.show("volume-up", nextDev:name())
		osd.playTick()
	end
end

--- Cycle to the next audio input device and show OSD feedback.
function M.cycleInputDevice()
	local nextDev = audio.inputs:cycleDevice()
	if nextDev then
		osd.show("mic", nextDev:name())
	end
end

return M
