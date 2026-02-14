--- streamdeck/renderer.lua
--- Image generation for Stream Deck+ buttons and LCD strip sections.
--- Uses shared hs.canvas instances for performance.

local M = {}

-- Default sizes (overridden at runtime via setSizes)
M.buttonSize = { w = 96, h = 96 }
M.stripSize = { w = 200, h = 100 }

-- Color palette (exported so config.lua can reference it)
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

-- ============================================================
-- BUTTON RENDERER
-- ============================================================

--- Generic icon-above-label button image.
--- @param icon string   Emoji or short string rendered large in the upper half
--- @param label string? Small label rendered in the lower third (nil to omit)
--- @param bgColor table? Fill colour for the background rectangle
--- @param iconColor table? Colour for the icon text
--- @param iconSize number? Font size for the icon (default 32)
--- @return hs.image
function M.renderButton(icon, label, bgColor, iconColor, iconSize)
	local c = getButtonCanvas()
	local w, h = M.buttonSize.w, M.buttonSize.h
	c:size({ w = w, h = h })

	local elements = {
		{
			type = "rectangle",
			frame = { x = 0, y = 0, w = w, h = h },
			fillColor = bgColor or M.colors.bg,
			roundedRectRadii = { xRadius = 8, yRadius = 8 },
		},
		{
			type = "text",
			frame = { x = 0, y = h * 0.1, w = w, h = h * 0.5 },
			text = styledText(icon or "", iconSize or 32, iconColor or M.colors.white, "center"),
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

--- Render a button from a pre-composed array of canvas elements.
--- Used by the composable layer pipeline — buttons produce their own element
--- arrays via layers, and this function stamps them onto a canvas.
--- @param elements table[]  Array of hs.canvas element tables
--- @param ctx table         { w: number, h: number }
--- @return hs.image
function M.renderFromElements(elements, ctx)
	local c = getButtonCanvas()
	c:size({ w = ctx.w, h = ctx.h })
	if #elements > 0 then
		c:replaceElements(table.unpack(elements))
	else
		c:replaceElements({
			type = "rectangle",
			frame = { x = 0, y = 0, w = ctx.w, h = ctx.h },
			fillColor = M.colors.bg,
		})
	end
	return c:imageFromCanvas()
end

--- Render an encoder LCD strip segment from a pre-composed array of canvas elements.
--- @param elements table[]  Array of hs.canvas element tables
--- @param ctx table         { w: number, h: number }
--- @return hs.image
function M.renderEncoderFromElements(elements, ctx)
	local c = getStripCanvas()
	c:size({ w = ctx.w, h = ctx.h })
	if #elements > 0 then
		c:replaceElements(table.unpack(elements))
	else
		c:replaceElements({
			type      = "rectangle",
			frame     = { x = 0, y = 0, w = ctx.w, h = ctx.h },
			fillColor = M.colors.bg,
		})
	end
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
