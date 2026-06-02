--- osd/init.lua
--- Reusable macOS-style on-screen display widget for transient notifications.
---
--- Designed for lightweight feedback that doesn't warrant a full system
--- notification — volume/brightness changes, mode toggles, status messages, etc.
---
--- Usage:
---   local osd = require("osd")
---
---   -- Progress bar with a single icon:
---   osd.show(osd.icons.volume, 75)
---
---   -- Progress bar with icon chosen by level:
---   osd.show({iconLow, iconMid, iconHigh}, 75)  -- picks iconHigh
---
---   -- Structured icon table (up/down/off variants):
---   osd.show({ up = imgUp, down = imgDown, off = imgOff }, 50, "down")
---
---   -- Text label instead of progress bar:
---   osd.show(icon, "Dark Mode")
---
---   -- Text-only (no icon):
---   osd.show(nil, "Configuration Reloaded")
---
--- The OSD appears centered horizontally at 3/4 screen height on the
--- screen containing the currently focused window, auto-dismisses after
--- a brief delay, and updates in-place if called again before dismissal.

local images = require("images")

local M = {}

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

--- Seconds before fade-out begins after `show()`.
--- @type number
M.dismissDelay = 2.0

--- Duration of the fade-out animation in seconds.
--- @type number
M.fadeDuration = 0.3

--- Number of discrete alpha steps during fade-out.
--- @type integer
M.fadeSteps = 15

---------------------------------------------------------------------------
-- Layout constants
---------------------------------------------------------------------------

local OSD_WIDTH    = 210
local OSD_HEIGHT   = 130
local CORNER_RADIUS = 16
local ICON_SIZE    = 68
local ICON_BAR_GAP = 8
local PADDING_H    = 20
local BAR_SEGMENTS = 16
local BAR_GAP      = 3
local BAR_HEIGHT   = 28
local BAR_RADIUS   = 2.5
local BORDER_W     = 1.5

---------------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------------

local BG_COLOR     = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.70 }
local BORDER_COLOR = { white = 1, alpha = 0.25 }
local BAR_ON       = { white = 1.0, alpha = 0.95 }
local BAR_OFF      = { white = 1.0, alpha = 0.15 }

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------

--- @type hs.canvas|nil
local canvas = nil

--- @type hs.timer|nil
local dismissTimer = nil

--- @type hs.timer|nil
local fadeTimer = nil

--- @type boolean  True while a fade-out animation is running.
local fading = false

--- @type hs.sound|nil  Lazily loaded volume-tick sound.
local tickSound = nil

--- @type boolean  Whether we already attempted to load the tick sound.
local tickSoundLoaded = false

---------------------------------------------------------------------------
-- Volume tick sound (lazy)
---------------------------------------------------------------------------

--- Load the tick sound on first use.
--- @return hs.sound|nil
local function getTickSound()
	if tickSoundLoaded then
		return tickSound
	end
	tickSoundLoaded = true
	tickSound = hs.sound.getByFile(
		"/System/Library/LoginPlugins/BezelServices.loginPlugin"
			.. "/Contents/Resources/volume.aiff"
	) or hs.sound.getByName("Tink")
	return tickSound
end

--- Play the macOS volume-change tick sound.
--- @param level number|nil  Playback volume 0.0–1.0 (default 1.0)
function M.playTick(level)
	local snd = getTickSound()
	if not snd then return end
	snd:stop()
	snd:volume(level or 1.0)
	snd:play()
end

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

--- Cancel all pending timers and reset the fading flag.
local function cancelTimers()
	if dismissTimer then
		dismissTimer:stop()
		dismissTimer = nil
	end
	if fadeTimer then
		fadeTimer:stop()
		fadeTimer = nil
	end
	fading = false
end

--- Resolve a single icon from the various accepted formats.
--- @param iconOrIcons OsdIconSpec|nil
--- @param percent     number          Clamped 0–100
--- @param direction   OsdDirection|nil
--- @return hs.image|nil
local function resolveIcon(iconOrIcons, percent, direction)
	if type(iconOrIcons) ~= "table" then
    if type(iconOrIcons) == "string" then
      return images.getIcon(iconOrIcons)
    end
		return iconOrIcons --[[@as hs.image|nil]]
	end

	--- @type table
	local tbl = iconOrIcons
  local icon = nil

	-- Structured table: { up, down, off, static }
	if tbl.static or tbl.up or tbl.down or tbl.off then
		if percent <= 0 and tbl.off then
      icon = tbl.off
		elseif tbl.static then
			icon = tbl.static
		elseif direction == "down" and tbl.down then
			icon = tbl.down
		else
			icon = tbl.up or tbl.down
		end
  else
    -- Plain list: pick icon by percentage (evenly divided buckets).
    -- percent=0 maps to index 1, percent=100 maps to index n.
    local n = #tbl
    if n == 0 then return nil end
    local idx = math.max(1, math.ceil(percent / 100 * n))
    icon = tbl[idx]
	end
  if type(icon) == "string" then
    return images.getIcon(icon)
  end
  return icon
end

--- Build the ordered list of canvas element tables for the current OSD state.
--- @param icon    hs.image|nil
--- @param percent number
--- @param text    string|nil
--- @return table[]
local function buildElements(icon, percent, text)
	local elements = {}

	-- Background with rounded rect and subtle border
	local bw2 = BORDER_W / 2
	elements[#elements + 1] = {
		type = "rectangle",
		action = "strokeAndFill",
		frame = { x = bw2, y = bw2, w = OSD_WIDTH - BORDER_W, h = OSD_HEIGHT - BORDER_W },
		fillColor = BG_COLOR,
		strokeColor = BORDER_COLOR,
		strokeWidth = BORDER_W,
		roundedRectRadii = { xRadius = CORNER_RADIUS, yRadius = CORNER_RADIUS },
	}

	-- Vertically center the icon + bar group
	local contentH = ICON_SIZE + ICON_BAR_GAP + BAR_HEIGHT
	local topY = (OSD_HEIGHT - contentH) / 2

	-- Icon (centered above bar)
	if icon then
		elements[#elements + 1] = {
			type = "image",
			image = icon,
			frame = {
				x = (OSD_WIDTH - ICON_SIZE) / 2,
				y = topY,
				w = ICON_SIZE,
				h = ICON_SIZE,
			},
			imageScaling = "shrinkToFit",
			imageAlignment = "center",
		}
	end

	-- Bottom area: text label or segmented progress bar
	local barY = topY + ICON_SIZE + ICON_BAR_GAP

	if text then
		elements[#elements + 1] = {
			type = "text",
			frame = { x = PADDING_H, y = barY, w = OSD_WIDTH - 2 * PADDING_H, h = BAR_HEIGHT },
			text = hs.styledtext.new(text, {
				font = { name = ".AppleSystemUIFont", size = 14 },
				color = BAR_ON,
				paragraphStyle = { alignment = "center" },
			}),
		}
	else
		local barAreaW = OSD_WIDTH - 2 * PADDING_H
		local segW = (barAreaW - (BAR_SEGMENTS - 1) * BAR_GAP) / BAR_SEGMENTS

		for i = 1, BAR_SEGMENTS do
			local threshold = (i - 1) / BAR_SEGMENTS * 100
			elements[#elements + 1] = {
				type = "rectangle",
				action = "fill",
				frame = {
					x = PADDING_H + (i - 1) * (segW + BAR_GAP),
					y = barY,
					w = segW,
					h = BAR_HEIGHT,
				},
				fillColor = (percent > threshold) and BAR_ON or BAR_OFF,
				roundedRectRadii = { xRadius = BAR_RADIUS, yRadius = BAR_RADIUS },
			}
		end
	end

	return elements
end

--- Get the screen that should display the OSD.
--- Uses the screen containing the currently focused window, falling back
--- to the primary screen if no window is focused.
--- @return hs.screen
local function targetScreen()
	local win = hs.window.focusedWindow()
	if win then
		return win:screen() or hs.screen.primaryScreen()
	end
	return hs.screen.primaryScreen()
end

---------------------------------------------------------------------------
-- Fade-out animation
---------------------------------------------------------------------------

--- Fade the OSD out over `M.fadeDuration` seconds, then hide it.
--- @private
function M._fadeOut()
	if not canvas then return end

	fading = true
	local step = 0
	local interval = M.fadeDuration / M.fadeSteps

	fadeTimer = hs.timer.doEvery(interval, function()
		-- Guard: if show() was called during the fade, it will have
		-- cancelled our timer and reset `fading`. If we still fire
		-- due to a queued run-loop event, bail out immediately.
		if not fading then return end

		step = step + 1
		if step >= M.fadeSteps then
			canvas:hide()
			canvas:alpha(1)
			cancelTimers()
		else
			canvas:alpha(1 - step / M.fadeSteps)
		end
	end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Show or update the OSD with the given icon(s) and a value.
---
--- If the OSD is already visible it updates in-place and resets the
--- dismiss timer. The OSD appears on the screen containing the currently
--- focused window.
---
--- @param iconOrIcons OsdIconSpec|nil   Icon specification (see types.d.lua)
--- @param percentOrText number|string   Percentage 0–100, or text to display
--- @param direction OsdDirection|nil    Hint for structured icon tables
function M.show(iconOrIcons, percentOrText, direction)
	--- @type number
	local percent
	--- @type string|nil
	local text

	if type(percentOrText) == "string" then
		percent = 0
		text = percentOrText
	else
		percent = math.max(0, math.min(100, (percentOrText or 0) --[[@as number]]))
		text = nil
	end

	local icon = resolveIcon(iconOrIcons, percent, direction)

	-- Cancel any pending dismiss/fade before touching the canvas.
	cancelTimers()

	-- Position: centered horizontally, 3/4 down the target screen.
	local screen = targetScreen()
	local frame = screen:fullFrame()
	local x = frame.x + (frame.w - OSD_WIDTH) / 2
	local y = frame.y + frame.h * 0.75 - OSD_HEIGHT / 2

	if not canvas then
		canvas = hs.canvas.new({ x = x, y = y, w = OSD_WIDTH, h = OSD_HEIGHT })
		if not canvas then return end
		canvas:behavior( ---@diagnostic disable-line: undefined-field
			hs.canvas.windowBehaviors.canJoinAllSpaces
				+ hs.canvas.windowBehaviors.stationary
		)
		canvas:level(hs.canvas.windowLevels.overlay) ---@diagnostic disable-line: undefined-field
	else
		canvas:topLeft({ x = x, y = y })
		canvas:size({ w = OSD_WIDTH, h = OSD_HEIGHT })
	end

	-- Build and apply elements one-by-one (avoids table.unpack stack limit).
	local elements = buildElements(icon, percent, text)
	-- Clear existing elements, then insert new ones.
	while canvas:elementCount() > 0 do
		canvas:removeElement(1)
	end
	for _, elem in ipairs(elements) do
		canvas:insertElement(elem)
	end

	canvas:alpha(1)
	canvas:show()

	-- Schedule auto-dismiss.
	dismissTimer = hs.timer.doAfter(M.dismissDelay, function()
		dismissTimer = nil
		M._fadeOut()
	end)
end

--- Immediately hide the OSD without animation.
function M.hide()
	cancelTimers()
	if canvas then
		canvas:hide()
		canvas:alpha(1)
	end
end

--- Release all resources. Call before `hs.reload()`.
function M.cleanup()
	M.hide()
	if canvas then
		canvas:delete()
		canvas = nil
	end
	if tickSound then
		tickSound:stop()
		tickSound = nil
	end
	tickSoundLoaded = false
end

return M
