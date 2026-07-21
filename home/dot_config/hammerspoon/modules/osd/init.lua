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

local GLYPH_DB_PATH = os.getenv("HOME") .. "/.local/share/fonts/nerd-font/symbols.db"
local NERD_FONT_NAME = "Symbols Nerd Font Mono"
local NERD_FONT_ICON_SIZE = 40
local SWATCH_SIZE = 44
local SWATCH_RADIUS = 9

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
local TEXT_CHAR_WIDTH = 7.2
local TEXT_MAX_SCREEN_RATIO = 0.75
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

--- @type table<string, hs.sound|false>
local notificationSoundCache = {}

--- @type boolean  Whether we already attempted to load the tick sound.
local tickSoundLoaded = false

--- @type table<string, table|false>
local glyphIconCache = {}

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

local function systemSoundName(soundName)
	return tostring(soundName)
		:gsub("%.aiff$", "")
		:gsub("%.AIF$", "")
		:gsub("%.AIFF$", "")
		:gsub("%.caf$", "")
		:gsub("%.CAF$", "")
end

local function playNotificationSound(soundName)
	if not soundName or soundName == "" then
		return
	end

	local normalizedName = systemSoundName(soundName)
	local cached = notificationSoundCache[normalizedName]
	if cached == false then
		return
	end

	local snd = cached
	if not snd then
		snd = hs.sound.getByName(normalizedName)
			or hs.sound.getByFile("/System/Library/Sounds/" .. normalizedName .. ".aiff")
		if not snd then
			hs.printf("OSD notification sound does not exist: %s", tostring(soundName))
			notificationSoundCache[normalizedName] = false
			return
		end
		notificationSoundCache[normalizedName] = snd
	end

	snd:stop()
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

local function sqlString(value)
	return "'" .. value:gsub("'", "''") .. "'"
end

local function queryGlyphSymbol(symbolName)
	local file = io.open(GLYPH_DB_PATH, "r")
	if not file then
		hs.printf("OSD glyph symbols DB does not exist: %s", GLYPH_DB_PATH)
		return nil
	end
	file:close()

	local sqlite3 = require("hs.sqlite3")
	local db = sqlite3.open(GLYPH_DB_PATH)
	if not db then
		hs.printf("OSD glyph symbols DB does not exist: %s", GLYPH_DB_PATH)
		return nil
	end

	local query = "SELECT symbol FROM symbols WHERE name = " .. sqlString(symbolName) .. " LIMIT 1"
	local symbol = nil
	for row in db:nrows(query) do
		symbol = row.symbol
		break
	end
	db:close()
	return symbol
end

local function resolveGlyphIcon(name)
	local symbolName = name:match("^glyph:(.+)$")
	if not symbolName then
		return nil
	end

	local cached = glyphIconCache[symbolName]
	if cached ~= nil then
		return cached or nil
	end

	local symbol = queryGlyphSymbol(symbolName)
	if not symbol or symbol == "" then
		hs.printf("OSD glyph symbol does not exist: %s", name)
		glyphIconCache[symbolName] = false
		return nil
	end

	local icon = { type = "glyphIcon", char = symbol }
	glyphIconCache[symbolName] = icon
	return icon
end

local function parseHexColor(hex)
	if #hex == 3 then
		hex = hex:gsub(".", "%0%0")
	elseif #hex ~= 6 then
		return nil
	end

	local r = tonumber(hex:sub(1, 2), 16)
	local g = tonumber(hex:sub(3, 4), 16)
	local b = tonumber(hex:sub(5, 6), 16)
	if not r or not g or not b then
		return nil
	end

	return {
		red = r / 255,
		green = g / 255,
		blue = b / 255,
		alpha = 1,
	}
end

local function resolveSwatchIcon(name)
	local hex = name:match("^swatch:#([%x]+)$")
	if not hex then
		return nil
	end

	local color = parseHexColor(hex)
	if not color then
		hs.printf("OSD swatch color is invalid: %s", name)
		return nil
	end

	return { type = "swatchIcon", color = color }
end

local function resolveNamedIcon(name)
	if name:match("^glyph:") then
		return resolveGlyphIcon(name)
	elseif name:match("^swatch:") then
		return resolveSwatchIcon(name)
	end
	return images.getIcon(name)
end

--- Resolve a single icon from the various accepted formats.
--- @param iconOrIcons OsdIconSpec|nil
--- @param percent     number          Clamped 0–100
--- @param direction   OsdDirection|nil
--- @return hs.image|table|nil
local function resolveIcon(iconOrIcons, percent, direction)
	if type(iconOrIcons) ~= "table" then
    if type(iconOrIcons) == "string" then
      return resolveNamedIcon(iconOrIcons)
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
    return resolveNamedIcon(icon)
  end
  return icon
end

--- Build the ordered list of canvas element tables for the current OSD state.
--- @param icon    hs.image|table|nil
--- @param percent number
--- @param text    string|nil
--- @param width   number
--- @return table[]
local function buildElements(icon, percent, text, width)
	local elements = {}

	-- Background with rounded rect and subtle border
	local bw2 = BORDER_W / 2
	elements[#elements + 1] = {
		type = "rectangle",
		action = "strokeAndFill",
		frame = { x = bw2, y = bw2, w = width - BORDER_W, h = OSD_HEIGHT - BORDER_W },
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
		local iconFrame = {
			x = (width - ICON_SIZE) / 2,
			y = topY,
			w = ICON_SIZE,
			h = ICON_SIZE,
		}
		if type(icon) == "table" and icon.type == "glyphIcon" then
			elements[#elements + 1] = {
				type = "text",
				frame = {
					x = iconFrame.x,
					y = iconFrame.y + (ICON_SIZE - NERD_FONT_ICON_SIZE) / 2,
					w = iconFrame.w,
					h = NERD_FONT_ICON_SIZE,
				},
				text = hs.styledtext.new(icon.char, {
					font = { name = NERD_FONT_NAME, size = NERD_FONT_ICON_SIZE },
					color = BAR_ON,
					paragraphStyle = { alignment = "center" },
				}),
			}
		elseif type(icon) == "table" and icon.type == "swatchIcon" then
			local swatchFrame = {
				x = iconFrame.x + (ICON_SIZE - SWATCH_SIZE) / 2,
				y = iconFrame.y + (ICON_SIZE - SWATCH_SIZE) / 2,
				w = SWATCH_SIZE,
				h = SWATCH_SIZE,
			}
			elements[#elements + 1] = {
				type = "rectangle",
				action = "strokeAndFill",
				frame = swatchFrame,
				fillColor = icon.color,
				strokeColor = { white = 1, alpha = 0.65 },
				strokeWidth = 1.5,
				roundedRectRadii = { xRadius = SWATCH_RADIUS, yRadius = SWATCH_RADIUS },
			}
			elements[#elements + 1] = {
				type = "rectangle",
				action = "stroke",
				frame = {
					x = swatchFrame.x + 1.5,
					y = swatchFrame.y + 1.5,
					w = swatchFrame.w - 3,
					h = swatchFrame.h - 3,
				},
				strokeColor = { white = 0, alpha = 0.20 },
				strokeWidth = 1,
				roundedRectRadii = { xRadius = SWATCH_RADIUS - 1.5, yRadius = SWATCH_RADIUS - 1.5 },
			}
		else
			elements[#elements + 1] = {
				type = "image",
				image = icon,
				frame = iconFrame,
				imageScaling = "shrinkToFit",
				imageAlignment = "center",
			}
		end
	end

	-- Bottom area: text label or segmented progress bar
	local barY = topY + ICON_SIZE + ICON_BAR_GAP

	if text then
		local textValue = (type(text) == "table" and text.type == "ansiText")
			and hs.styledtext.ansi(text.value, {
				font = { name = ".AppleSystemUIFont", size = 14 },
				color = BAR_ON,
				paragraphStyle = { alignment = "center" },
			})
			or hs.styledtext.new(text, {
				font = { name = ".AppleSystemUIFont", size = 14 },
				color = BAR_ON,
				paragraphStyle = { alignment = "center" },
			})
		elements[#elements + 1] = {
			type = "text",
			frame = { x = PADDING_H, y = barY, w = width - 2 * PADDING_H, h = BAR_HEIGHT },
			text = textValue,
		}
	else
		local barAreaW = width - 2 * PADDING_H
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

local function osdWidthForText(text, screenFrame)
	if not text then
		return OSD_WIDTH
	end

	local maxWidth = math.floor(screenFrame.w * TEXT_MAX_SCREEN_RATIO)
	local rawText = (type(text) == "table" and text.value) or text
	rawText = rawText:gsub("\27%[[%d;]*m", "")
	local estimated = math.ceil(PADDING_H * 2 + #rawText * TEXT_CHAR_WIDTH)
	return math.max(OSD_WIDTH, math.min(maxWidth, estimated))
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

	if type(percentOrText) == "string" or (type(percentOrText) == "table" and percentOrText.type == "ansiText") then
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
	local width = osdWidthForText(text, frame)
	local x = frame.x + (frame.w - width) / 2
	local y = frame.y + frame.h * 0.75 - OSD_HEIGHT / 2

	if not canvas then
		canvas = hs.canvas.new({ x = x, y = y, w = width, h = OSD_HEIGHT })
		if not canvas then return end
		canvas:behavior( ---@diagnostic disable-line: undefined-field
			hs.canvas.windowBehaviors.canJoinAllSpaces
				+ hs.canvas.windowBehaviors.stationary
		)
		canvas:level(hs.canvas.windowLevels.overlay) ---@diagnostic disable-line: undefined-field
	else
		canvas:topLeft({ x = x, y = y })
		canvas:size({ w = width, h = OSD_HEIGHT })
	end

	-- Build and apply elements one-by-one (avoids table.unpack stack limit).
	local elements = buildElements(icon, percent, text, width)
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

--- Show an OSD notification, optionally playing a named system sound.
--- Suitable for external IPC calls via the global `notify(...)` helper.
--- @param icon string|nil       SVG icon name, glyph:<name>, or swatch:#RRGGBB
--- @param text string|nil       Text to display below the icon
--- @param soundName string|nil  System sound name, e.g. "Glass" or "Ping"
function M.notify(icon, text, soundName)
	M.show(icon, text or "")
	playNotificationSound(soundName)
end

--- Show an OSD notification whose text may include ANSI SGR styles.
--- @param icon string|nil
--- @param text string|nil
--- @param soundName string|nil
function M.notifyAnsi(icon, text, soundName)
	M.show(icon, { type = "ansiText", value = text or "" })
	playNotificationSound(soundName)
end

---------------------------------------------------------------------------
-- Compact top-right progress HUD (clipboard copy-feedback design §5)
---------------------------------------------------------------------------

local PROG_WIDTH = 260
local PROG_HEIGHT = 44
local PROG_MARGIN = 12
local PROG_PAD_H = 14
local PROG_ICON_SIZE = 22
local PROG_BAR_HEIGHT = 8
local PROG_BAR_SEGMENTS = 16
local PROG_PCT_WIDTH = 38
local PROG_IDLE_TIMEOUT = 15

local progressCanvas = nil
local progressWatchdog = nil

local function cancelProgressWatchdog()
	if progressWatchdog then
		progressWatchdog:stop()
		progressWatchdog = nil
	end
end

--- Show or update the compact top-right progress capsule.
---
--- Deliberately NOT the centered OSD: a progress indicator must not cover
--- the center of the screen the user is working on, and it must not blink
--- between ticks. Separate canvas from the main OSD so a completion toast
--- can appear the moment this hides without the two fighting over state.
--- It never auto-fades on update; it hides only via M.progressHide() or
--- the idle watchdog (no update for PROG_IDLE_TIMEOUT seconds -> a dead
--- driver can never leave a zombie capsule on screen).
---
--- @param icon string|nil     glyph:/swatch:/SVG name (resolveNamedIcon forms)
--- @param percent number      0-100
--- @param label string|nil    short context label, e.g. the origin host
function M.progress(icon, percent, label)
	local pct = math.max(0, math.min(100, percent or 0))
	local resolved = type(icon) == "string" and resolveNamedIcon(icon) or icon

	-- Top-right of the focused screen's usable frame (:frame() already
	-- excludes the menu bar, unlike the main OSD's :fullFrame()).
	local frame = targetScreen():frame()
	local x = frame.x + frame.w - PROG_WIDTH - PROG_MARGIN
	local y = frame.y + PROG_MARGIN

	if not progressCanvas then
		progressCanvas = hs.canvas.new({ x = x, y = y, w = PROG_WIDTH, h = PROG_HEIGHT })
		if not progressCanvas then return end
		progressCanvas:behavior( ---@diagnostic disable-line: undefined-field
			hs.canvas.windowBehaviors.canJoinAllSpaces
				+ hs.canvas.windowBehaviors.stationary
		)
		progressCanvas:level(hs.canvas.windowLevels.overlay) ---@diagnostic disable-line: undefined-field
	else
		progressCanvas:topLeft({ x = x, y = y })
	end

	local elements = {}
	local bw2 = BORDER_W / 2
	elements[#elements + 1] = {
		type = "rectangle",
		action = "strokeAndFill",
		frame = { x = bw2, y = bw2, w = PROG_WIDTH - BORDER_W, h = PROG_HEIGHT - BORDER_W },
		fillColor = BG_COLOR,
		strokeColor = BORDER_COLOR,
		strokeWidth = BORDER_W,
		roundedRectRadii = { xRadius = PROG_HEIGHT / 2, yRadius = PROG_HEIGHT / 2 },
	}

	-- Icon at the left edge (glyph is the only production shape; image/
	-- swatch handled for parity with resolveNamedIcon's other forms).
	local iconFrame = {
		x = PROG_PAD_H,
		y = (PROG_HEIGHT - PROG_ICON_SIZE) / 2,
		w = PROG_ICON_SIZE,
		h = PROG_ICON_SIZE,
	}
	if type(resolved) == "table" and resolved.type == "glyphIcon" then
		elements[#elements + 1] = {
			type = "text",
			frame = iconFrame,
			text = hs.styledtext.new(resolved.char, {
				font = { name = NERD_FONT_NAME, size = PROG_ICON_SIZE },
				color = BAR_ON,
				paragraphStyle = { alignment = "center" },
			}),
		}
	elseif type(resolved) == "table" and resolved.type == "swatchIcon" then
		elements[#elements + 1] = {
			type = "rectangle",
			action = "strokeAndFill",
			frame = iconFrame,
			fillColor = resolved.color,
			strokeColor = { white = 1, alpha = 0.65 },
			strokeWidth = 1,
			roundedRectRadii = { xRadius = 5, yRadius = 5 },
		}
	elseif resolved ~= nil and type(resolved) ~= "table" then
		elements[#elements + 1] = {
			type = "image",
			image = resolved,
			frame = iconFrame,
			imageScaling = "shrinkToFit",
			imageAlignment = "center",
		}
	end

	-- Segmented mini-bar between icon and percent label -- the main OSD's
	-- bar language, miniaturized.
	local barX = iconFrame.x + iconFrame.w + PROG_PAD_H / 2
	local barW = PROG_WIDTH - barX - PROG_PCT_WIDTH - PROG_PAD_H
	local barY = (PROG_HEIGHT - PROG_BAR_HEIGHT) / 2
	local segW = (barW - (PROG_BAR_SEGMENTS - 1) * BAR_GAP) / PROG_BAR_SEGMENTS
	for i = 1, PROG_BAR_SEGMENTS do
		local threshold = (i - 1) / PROG_BAR_SEGMENTS * 100
		elements[#elements + 1] = {
			type = "rectangle",
			action = "fill",
			frame = {
				x = barX + (i - 1) * (segW + BAR_GAP),
				y = barY,
				w = segW,
				h = PROG_BAR_HEIGHT,
			},
			fillColor = (pct > threshold) and BAR_ON or BAR_OFF,
			roundedRectRadii = { xRadius = BAR_RADIUS, yRadius = BAR_RADIUS },
		}
	end

	-- Right-aligned percent label. `label` (origin host) is intentionally
	-- unrendered at this size -- 260px is glyph + bar + percent territory;
	-- the completion toast names the host.
	elements[#elements + 1] = {
		type = "text",
		frame = { x = PROG_WIDTH - PROG_PCT_WIDTH - PROG_PAD_H + 4, y = (PROG_HEIGHT - 16) / 2, w = PROG_PCT_WIDTH, h = 16 },
		text = hs.styledtext.new(string.format("%d%%", pct), {
			font = { name = ".AppleSystemUIFont", size = 12 },
			color = BAR_ON,
			paragraphStyle = { alignment = "right" },
		}),
	}

	while progressCanvas:elementCount() > 0 do
		progressCanvas:removeElement(1)
	end
	for _, elem in ipairs(elements) do
		progressCanvas:insertElement(elem)
	end
	progressCanvas:alpha(1)
	progressCanvas:show()

	cancelProgressWatchdog()
	progressWatchdog = hs.timer.doAfter(PROG_IDLE_TIMEOUT, function()
		progressWatchdog = nil
		M.progressHide()
	end)
end

--- Immediately hide the progress HUD (no animation).
function M.progressHide()
	cancelProgressWatchdog()
	if progressCanvas then
		progressCanvas:hide()
	end
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
	M.progressHide()
	if progressCanvas then
		progressCanvas:delete()
		progressCanvas = nil
	end
	if tickSound then
		tickSound:stop()
		tickSound = nil
	end
	for _, snd in pairs(notificationSoundCache) do
		if snd then
			snd:stop()
		end
	end
	notificationSoundCache = {}
	tickSoundLoaded = false
end

return M
