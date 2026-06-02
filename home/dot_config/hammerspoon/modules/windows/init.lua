--- windows/init.lua
--- Window centering and edge-based resize operations.
--- All resize operations use a fixed pixel step and clamp the result
--- to the current screen bounds.
---
--- Usage:
---   local windows = require("windows")
---   windows.centerFocusedWindow()
---   windows.increaseOutward()

local M = {}

--- Pixel step used for every resize operation.
--- @type number
local STEP = 40

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Return the focused window, its frame, and its screen frame.
--- @return hs.window|nil win   The focused window, or nil if none
--- @return hs.geometry|nil f   The window frame
--- @return hs.geometry|nil s   The screen frame
--- @private
local function windowAndScreen()
	local win = hs.window.focusedWindow()
	if not win then return nil end
	return win, win:frame(), win:screen():frame()
end

--- Clamp a window frame so it stays within the screen bounds.
--- @param f      hs.geometry  Window frame (modified in place)
--- @param screen hs.geometry  Screen frame to clamp against
--- @return hs.geometry  The clamped frame
--- @private
local function clampToScreen(f, screen)
	if f.x < screen.x then f.x = screen.x end
	if f.y < screen.y then f.y = screen.y end
	if f.w > screen.w then f.w = screen.w end
	if f.h > screen.h then f.h = screen.h end
	if f.x + f.w > screen.x + screen.w then f.x = screen.x + screen.w - f.w end
	if f.y + f.h > screen.y + screen.h then f.y = screen.y + screen.h - f.h end
	return f
end

-- ---------------------------------------------------------------------------
-- Center
-- ---------------------------------------------------------------------------

--- Center the focused window on its current screen.
function M.centerFocusedWindow()
	local win = hs.window.focusedWindow()
	if win then
		win:centerOnScreen()
	end
end

-- ---------------------------------------------------------------------------
-- Resize outward / inward (expand or shrink from center)
-- ---------------------------------------------------------------------------

--- Expand the focused window outward by STEP pixels on all four edges.
function M.increaseOutward()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	f.x = f.x - STEP
	f.y = f.y - STEP
	f.w = f.w + STEP * 2
	f.h = f.h + STEP * 2
	win:setFrame(clampToScreen(f, screen))
end

--- Shrink the focused window inward by STEP pixels on all four edges.
function M.decreaseInward()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	if f.w <= STEP * 2 or f.h <= STEP * 2 then return end
	f.x = f.x + STEP
	f.y = f.y + STEP
	f.w = f.w - STEP * 2
	f.h = f.h - STEP * 2
	win:setFrame(clampToScreen(f, screen))
end

-- ---------------------------------------------------------------------------
-- Resize from a single edge
-- ---------------------------------------------------------------------------

--- Grow the focused window upward by STEP pixels (top edge moves up).
function M.increaseSizeAtTop()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	f.y = f.y - STEP
	f.h = f.h + STEP
	win:setFrame(clampToScreen(f, screen))
end

--- Shrink the focused window from the top by STEP pixels (top edge moves down).
function M.decreaseSizeAtTop()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	if f.h <= STEP then return end
	f.y = f.y + STEP
	f.h = f.h - STEP
	win:setFrame(clampToScreen(f, screen))
end

--- Grow the focused window downward by STEP pixels (bottom edge moves down).
function M.increaseSizeAtBottom()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	f.h = f.h + STEP
	win:setFrame(clampToScreen(f, screen))
end

--- Shrink the focused window from the bottom by STEP pixels (bottom edge moves up).
function M.decreaseSizeAtBottom()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	if f.h <= STEP then return end
	f.h = f.h - STEP
	win:setFrame(clampToScreen(f, screen))
end

--- Grow the focused window leftward by STEP pixels (left edge moves left).
function M.increaseSizeAtLeft()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	f.x = f.x - STEP
	f.w = f.w + STEP
	win:setFrame(clampToScreen(f, screen))
end

--- Shrink the focused window from the left by STEP pixels (left edge moves right).
function M.decreaseSizeAtLeft()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	if f.w <= STEP then return end
	f.x = f.x + STEP
	f.w = f.w - STEP
	win:setFrame(clampToScreen(f, screen))
end

--- Grow the focused window rightward by STEP pixels (right edge moves right).
function M.increaseSizeAtRight()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	f.w = f.w + STEP
	win:setFrame(clampToScreen(f, screen))
end

--- Shrink the focused window from the right by STEP pixels (right edge moves left).
function M.decreaseSizeAtRight()
	local win, f, screen = windowAndScreen()
	if not win or not f or not screen then return end
	if f.w <= STEP then return end
	f.w = f.w - STEP
	win:setFrame(clampToScreen(f, screen))
end

return M
