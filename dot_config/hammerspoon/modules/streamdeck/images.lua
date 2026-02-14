--- streamdeck/images.lua
--- Canvas-based image generation for Stream Deck+ buttons and LCD strip sections.
--- Uses shared hs.canvas instances for performance.

local M = {}

-- Default sizes (overridden at runtime via setSizes)
M.buttonSize = { w = 96, h = 96 }
M.stripSize = { w = 200, h = 100 }

-- Color palette
M.colors = {
	bg = { hex = "#1a1a2e" },
	bgLight = { hex = "#16213e" },
	accent = { hex = "#0f3460" },
	primary = { hex = "#e94560" },
	green = { hex = "#00c853" },
	red = { hex = "#ff1744" },
	orange = { hex = "#ff9100" },
	blue = { hex = "#2979ff" },
	white = { white = 1, alpha = 1 },
	gray = { white = 0.6, alpha = 1 },
	dimGray = { white = 0.3, alpha = 1 },
	textPri = { white = 1, alpha = 1 },
	textSec = { white = 0.7, alpha = 1 },
}

-- ============================================================
-- SHARED CANVAS (one for buttons, one for strip sections)
-- ============================================================

local buttonCanvas = nil
local stripCanvas = nil

--- @return hs.canvas
local function getButtonCanvas()
	if not buttonCanvas then
		buttonCanvas = hs.canvas.new({
			x = 0,
			y = 0,
			w = M.buttonSize.w,
			h = M.buttonSize.h,
		}) --[[@as hs.canvas]]
	end
	return buttonCanvas
end

--- @return hs.canvas
local function getStripCanvas()
	if not stripCanvas then
		stripCanvas = hs.canvas.new({
			x = 0,
			y = 0,
			w = M.stripSize.w,
			h = M.stripSize.h,
		}) --[[@as hs.canvas]]
	end
	return stripCanvas
end

--- Call once after querying the real device for image dimensions.
function M.setSizes(buttonSize, stripSize)
	M.buttonSize = buttonSize
	M.stripSize = stripSize
	-- Invalidate existing canvases so they're recreated at the new size
	if buttonCanvas then
		buttonCanvas:delete()
		buttonCanvas = nil
	end
	if stripCanvas then
		stripCanvas:delete()
		stripCanvas = nil
	end
end

-- ============================================================
-- HELPERS
-- ============================================================

local function styledText(text, size, color, alignment)
	return hs.styledtext.new(text, {
		font = { name = ".AppleSystemUIFont", size = size },
		color = color or M.colors.textPri,
		paragraphStyle = { alignment = alignment or "center" },
	})
end

--- Append a rounded progress bar (track + fill) to an elements table.
local function addProgressBar(elements, x, y, w, h, percent, barColor)
	local radius = { xRadius = h / 2, yRadius = h / 2 }
	-- Track
	table.insert(elements, {
		type = "rectangle",
		frame = { x = x, y = y, w = w, h = h },
		fillColor = M.colors.dimGray,
		roundedRectRadii = radius,
	})
	-- Fill
	local pct = math.max(0, math.min(percent or 0, 100))
	local fillW = math.max(h, w * pct / 100)
	table.insert(elements, {
		type = "rectangle",
		frame = { x = x, y = y, w = fillW, h = h },
		fillColor = barColor or M.colors.blue,
		roundedRectRadii = radius,
	})
end

-- ============================================================
-- BUTTON IMAGE GENERATORS
-- ============================================================

--- Generic icon‑above‑label button image.
--- @param iconText string  Emoji or short string rendered large in the upper half
--- @param label    string? Small label rendered in the lower third (nil to omit)
--- @param bgColor  table?  Fill colour for the background rectangle
--- @param iconColor table? Colour for the icon text
--- @param iconSize number? Font size for the icon (default 32)
--- @return hs.image
function M.createButtonImage(iconText, label, bgColor, iconColor, iconSize)
	local c = getButtonCanvas()
	local w, h = M.buttonSize.w, M.buttonSize.h
	c:size({ w = w, h = h })

	local elements = {
		-- Background
		{
			type = "rectangle",
			frame = { x = 0, y = 0, w = w, h = h },
			fillColor = bgColor or M.colors.bg,
			roundedRectRadii = { xRadius = 8, yRadius = 8 },
		},
		-- Icon (upper portion)
		{
			type = "text",
			frame = { x = 0, y = h * 0.1, w = w, h = h * 0.5 },
			text = styledText(iconText or "", iconSize or 32, iconColor or M.colors.white, "center"),
		},
	}

	if label then
		table.insert(elements, {
			type = "text",
			frame = { x = 4, y = h * 0.62, w = w - 8, h = h * 0.35 },
			text = styledText(label, 11, M.colors.textSec, "center"),
		})
	end

	c:replaceElements(table.unpack(elements))
	return c:imageFromCanvas()
end

-- ---------- per‑button convenience functions ----------

function M.micMuteImage(muted)
	local icon = muted and "🔇" or "🎙"
	local bg = muted and M.colors.red or M.colors.green
	local label = muted and "Muted" or "Mic On"
	return M.createButtonImage(icon, label, bg, nil, 30)
end

function M.dndImage(enabled)
	local icon = enabled and "🌙" or "🔔"
	local bg = enabled and M.colors.accent or M.colors.bg
	local label = enabled and "Focus On" or "Focus"
	return M.createButtonImage(icon, label, bg, nil, 30)
end

function M.screenshotImage()
	return M.createButtonImage("📸", "Screenshot", M.colors.bgLight, nil, 30)
end

function M.lockImage()
	return M.createButtonImage("🔒", "Lock", M.colors.bgLight, nil, 30)
end

function M.prevTrackImage()
	return M.createButtonImage("⏮", "Prev", M.colors.bgLight, nil, 30)
end

function M.playPauseImage(playing)
	local icon = playing and "⏸" or "▶️"
	local label = playing and "Pause" or "Play"
	local bg = playing and M.colors.accent or M.colors.bgLight
	return M.createButtonImage(icon, label, bg, nil, 30)
end

function M.nextTrackImage()
	return M.createButtonImage("⏭", "Next", M.colors.bgLight, nil, 30)
end

function M.audioOutputImage(deviceName)
	local isHP = deviceName
		and (
			deviceName:lower():find("headphone")
			or deviceName:lower():find("airpod")
			or deviceName:lower():find("beats")
		)
	local icon = isHP and "🎧" or "🔊"
	local short = deviceName or "Audio"
	if #short > 10 then
		short = short:sub(1, 9) .. "…"
	end
	return M.createButtonImage(icon, short, M.colors.bgLight, nil, 30)
end

-- ============================================================
-- LCD STRIP IMAGE GENERATORS  (one per encoder section, ~200×100)
-- ============================================================

function M.volumeStrip(volume, muted)
	local c = getStripCanvas()
	local w, h = M.stripSize.w, M.stripSize.h
	c:size({ w = w, h = h })

	local barColor = muted and M.colors.red or M.colors.blue
	local volText = muted and "MUTED" or string.format("%d%%", math.floor(volume or 0))
	local icon = muted and "🔇" or "🔊"

	local elements = {
		{ type = "rectangle", frame = { x = 0, y = 0, w = w, h = h }, fillColor = M.colors.bg },
		{
			type = "text",
			frame = { x = 8, y = 6, w = w - 16, h = 24 },
			text = styledText(icon .. " Volume", 13, M.colors.textSec, "left"),
		},
		{
			type = "text",
			frame = { x = 8, y = 6, w = w - 16, h = 24 },
			text = styledText(volText, 13, M.colors.textPri, "right"),
		},
	}
	addProgressBar(elements, 10, 38, w - 20, 10, muted and 0 or (volume or 0), barColor)

	c:replaceElements(table.unpack(elements))
	return c:imageFromCanvas()
end

function M.inputVolumeStrip(volume, muted)
	local c = getStripCanvas()
	local w, h = M.stripSize.w, M.stripSize.h
	c:size({ w = w, h = h })

	local barColor = muted and M.colors.red or M.colors.green
	local volText = muted and "MUTED" or string.format("%d%%", math.floor(volume or 0))
	local icon = muted and "🔇" or "🎙"

	local elements = {
		{ type = "rectangle", frame = { x = 0, y = 0, w = w, h = h }, fillColor = M.colors.bg },
		{
			type = "text",
			frame = { x = 8, y = 6, w = w - 16, h = 24 },
			text = styledText(icon .. " Mic", 13, M.colors.textSec, "left"),
		},
		{
			type = "text",
			frame = { x = 8, y = 6, w = w - 16, h = 24 },
			text = styledText(volText, 13, M.colors.textPri, "right"),
		},
	}
	addProgressBar(elements, 10, 38, w - 20, 10, muted and 0 or (volume or 0), barColor)

	c:replaceElements(table.unpack(elements))
	return c:imageFromCanvas()
end

function M.nowPlayingStrip(artist, title)
	local c = getStripCanvas()
	local w, h = M.stripSize.w, M.stripSize.h
	c:size({ w = w, h = h })

	local hasTrack = artist and title and #title > 0
	local dTitle = hasTrack and title or "Not Playing"
	local dArtist = hasTrack and artist or ""
	if #dTitle > 22 then
		dTitle = dTitle:sub(1, 21) .. "…"
	end
	if #dArtist > 22 then
		dArtist = dArtist:sub(1, 21) .. "…"
	end

	local elements = {
		{ type = "rectangle", frame = { x = 0, y = 0, w = w, h = h }, fillColor = M.colors.bg },
		{
			type = "text",
			frame = { x = 8, y = 6, w = w - 16, h = 20 },
			text = styledText("♫ " .. dTitle, 12, hasTrack and M.colors.textPri or M.colors.dimGray, "left"),
		},
	}
	if hasTrack then
		table.insert(elements, {
			type = "text",
			frame = { x = 8, y = 28, w = w - 16, h = 18 },
			text = styledText(dArtist, 11, M.colors.textSec, "left"),
		})
	end

	c:replaceElements(table.unpack(elements))
	return c:imageFromCanvas()
end

function M.brightnessStrip(brightness)
	local c = getStripCanvas()
	local w, h = M.stripSize.w, M.stripSize.h
	c:size({ w = w, h = h })

	local brtText = string.format("%d%%", math.floor(brightness or 0))
	local elements = {
		{ type = "rectangle", frame = { x = 0, y = 0, w = w, h = h }, fillColor = M.colors.bg },
		{
			type = "text",
			frame = { x = 8, y = 6, w = w - 16, h = 24 },
			text = styledText("☀ Brightness", 13, M.colors.textSec, "left"),
		},
		{
			type = "text",
			frame = { x = 8, y = 6, w = w - 16, h = 24 },
			text = styledText(brtText, 13, M.colors.textPri, "right"),
		},
	}
	addProgressBar(elements, 10, 38, w - 20, 10, brightness or 0, M.colors.orange)

	c:replaceElements(table.unpack(elements))
	return c:imageFromCanvas()
end

function M.clockCpuStrip(timeStr, cpuPercent)
	local c = getStripCanvas()
	local w, h = M.stripSize.w, M.stripSize.h
	c:size({ w = w, h = h })

	local cpu = cpuPercent or 0
	local cpuText = string.format("CPU %d%%", math.floor(cpu))
	local cpuColor = cpu > 80 and M.colors.red or cpu > 50 and M.colors.orange or M.colors.green

	local elements = {
		{ type = "rectangle", frame = { x = 0, y = 0, w = w, h = h }, fillColor = M.colors.bg },
		{
			type = "text",
			frame = { x = 8, y = 4, w = w - 16, h = 28 },
			text = styledText(timeStr or "00:00", 18, M.colors.textPri, "center"),
		},
		{
			type = "text",
			frame = { x = 8, y = 30, w = w - 16, h = 18 },
			text = styledText(cpuText, 11, M.colors.textSec, "center"),
		},
	}
	addProgressBar(elements, 10, 52, w - 20, 6, cpu, cpuColor)

	c:replaceElements(table.unpack(elements))
	return c:imageFromCanvas()
end

-- ============================================================
-- CLEANUP
-- ============================================================

function M.cleanup()
	if buttonCanvas then
		buttonCanvas:delete()
		buttonCanvas = nil
	end
	if stripCanvas then
		stripCanvas:delete()
		stripCanvas = nil
	end
end

return M
