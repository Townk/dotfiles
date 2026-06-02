--- streamdeck/layers.lua
--- Composable layer primitives for Stream Deck button rendering.
--- Each layer factory returns a layer function: (elements, state, ctx) → elements
--- where elements is an array of hs.canvas element tables, state is the resolved
--- button state, and ctx is { w, h } canvas dimensions.

local renderer = require("streamdeck.renderer")
local colors = renderer.colors

local M = {}

-- ============================================================
-- TEXT HELPERS
-- ============================================================

local function styledText(text, size, color, alignment)
	return hs.styledtext.new(text or "", {
		font = { name = ".AppleSystemUIFontBold", size = size },
		color = color or colors.textPri,
		paragraphStyle = { alignment = alignment or "center" },
	})
end

local function positionToFrame(position, ctx, pad)
	local w, h = ctx.w, ctx.h
	local labelH = math.floor(h * 0.25)
	local labelW = w - pad * 2

	local vert = (position and position.vertical) or "end"
	local y
	if vert == "start" then
		y = pad
	elseif vert == "center" then
		y = math.floor((h - labelH) / 2)
	else
		y = h - labelH - pad
	end

	local horiz = (position and position.horizontal) or "center"
	local alignment
	if horiz == "start" then
		alignment = "left"
	elseif horiz == "end" then
		alignment = "right"
	else
		alignment = "center"
	end

	return { x = pad, y = y, w = labelW, h = labelH }, alignment
end

-- ============================================================
-- STREAMDECK IMAGE CACHE
-- ============================================================

local SDICON_DIR  = hs.configdir .. "/Assets/icons/images"
local SVG_DIR     = hs.configdir .. "/Assets/icons/svg"
local BG_DIR      = hs.configdir .. "/Assets/backgrounds"
local sdiconCache  = {}
local svgCache     = {}
local appIconCache = {}
local bgCache      = {}

local function getSdIcon(name)
	local cached = sdiconCache[name]
	if cached == nil then
		local img = hs.image.imageFromPath(SDICON_DIR .. "/" .. name .. ".jpg")
		if img == nil then
			img = hs.image.imageFromPath(SDICON_DIR .. "/" .. name .. ".png")
		end
		sdiconCache[name] = img or false
		cached = sdiconCache[name]
	end
	return cached ~= false and cached or nil
end

local function getSvgIcon(name)
	local cached = svgCache[name]
	if cached == nil then
		local img = hs.image.imageFromPath(SVG_DIR .. "/" .. name .. ".svg")
		svgCache[name] = img or false
		cached = svgCache[name]
	end
	return cached ~= false and cached or nil
end

--- @param nameOrBundleID string
--- @return string|nil
local function resolveAppBundleID(nameOrBundleID)
	if nameOrBundleID:find("%.") then
		return nameOrBundleID
	end
	local paths = {
		"/Applications/" .. nameOrBundleID .. ".app",
		"/System/Applications/" .. nameOrBundleID .. ".app",
		"/Applications/Utilities/" .. nameOrBundleID .. ".app",
		"/System/Applications/Utilities/" .. nameOrBundleID .. ".app",
	}
	for _, path in ipairs(paths) do
		local info = hs.application.infoForBundlePath(path)
		if info and info.CFBundleIdentifier then
			return info.CFBundleIdentifier
		end
	end
	return nil
end

--- @param nameOrBundleID string  App name ("Safari") or bundle ID ("com.apple.Safari")
--- @return hs.image|nil
local function getAppIcon(nameOrBundleID)
	local cached = appIconCache[nameOrBundleID]
	if cached == nil then
		local bundleID = resolveAppBundleID(nameOrBundleID)
		local img = bundleID and hs.image.imageFromAppBundle(bundleID) or nil
		appIconCache[nameOrBundleID] = img or false
		cached = appIconCache[nameOrBundleID]
	end
	return cached ~= false and cached or nil
end

local function getBgImage(name)
	local cached = bgCache[name]
	if cached == nil then
		local img = hs.image.imageFromPath(BG_DIR .. "/" .. name .. ".png")
		if img == nil then
			img = hs.image.imageFromPath(BG_DIR .. "/" .. name .. ".jpg")
		end
		bgCache[name] = img or false
		cached = bgCache[name]
	end
	return cached ~= false and cached or nil
end

function M.clearIconCache()
	sdiconCache  = {}
	svgCache     = {}
	appIconCache = {}
	bgCache      = {}
end

-- ============================================================
-- IMAGE LAYER PRIMITIVE
-- ============================================================

--- Full-button image layer from a streamdeck icon file (jpg/png).
--- @param nameOrFn any  Icon filename without extension, function(state)->name,
---                      or {on="mic-on", off="mic-off"} toggle table.
--- @param opts? table   { padding: number? }  Inset from canvas edge (default 0).
--- @return fun(elements: table[], state: any, ctx: table): table[]
function M.image(nameOrFn, opts)
	return function(elements, state, ctx)
		local name = M.resolve(nameOrFn, state)
		if not name then return elements end
		local img = getSdIcon(name)
		if not img then return elements end
		local pad = (opts and opts.padding) or 0
		local ox = (opts and opts.offsetX) or 0
		local oy = (opts and opts.offsetY) or 0
		table.insert(elements, {
			type = "image",
			frame = { x = pad + ox, y = pad + oy, w = ctx.w - pad * 2, h = ctx.h - pad * 2 },
			image = img,
			imageScaling = "scaleToFit",
		})
		return elements
	end
end

--- Render an SVG with an optional tint or gradient applied as a mask,
--- composited in an isolated off-screen canvas so the color only touches
--- the SVG's own pixels regardless of what else is on the button canvas.
--- @param img hs.image
--- @param side number      Square pixel size
--- @param tint table|nil   Solid color
--- @param gradient table|nil  { colors, angle }
--- @return hs.image
local function renderTintedSvg(img, side, tint, gradient)
	local c = hs.canvas.new({ x = 0, y = 0, w = side, h = side })
	local frame = { x = 0, y = 0, w = side, h = side }
	local elements = {
		{
			type         = "image",
			frame        = frame,
			image        = img,
			imageScaling = "scaleToFit",
			imageAlpha   = 1,
		},
	}
	if gradient then
		table.insert(elements, {
			type               = "rectangle",
			frame              = frame,
			action             = "fill",
			fillGradient       = "linear",
			fillGradientColors = gradient.colors,
			fillGradientAngle  = gradient.angle or 0,
			compositeRule      = "sourceAtop",
		})
	elseif tint then
		table.insert(elements, {
			type          = "rectangle",
			frame         = frame,
			action        = "fill",
			fillColor     = tint,
			compositeRule = "sourceAtop",
		})
	end
	assert(c, "hs.canvas.new() returned nil")
	c:replaceElements(table.unpack(elements))
	local result = c:imageFromCanvas()
	c:delete()
	return result
end

--- Centered SVG icon overlay from Assets/icons/svg/.
--- Renders the SVG scaled to a square region centered on the button,
--- leaving room for a label at the bottom when combined with M.label.
--- @param nameOrFn any  SVG filename without extension, function(state)->name,
---                      or {on="notifications-paused", off="notifications-active"} toggle.
--- @param opts? table
---   size: number?      Icon square as fraction of canvas height (default 0.55).
---   tint: any?         Solid color table (or toggle) to paint over the SVG shape.
---   gradient: any?     Table (or toggle) for a linear gradient tint:
---                        { colors = { c1, c2, ... }, angle = number? }
---                      `colors` must have at least 2 entries; `angle` defaults to 0
---                      (0 = top→bottom, 90 = left→right in hs.canvas convention).
--- @return fun(elements: table[], state: any, ctx: table): table[]
function M.svgIcon(nameOrFn, opts)
	return function(elements, state, ctx)
		local name = M.resolve(nameOrFn, state)
		if not name then return elements end
		local img = getSvgIcon(name)
		if not img then return elements end
		local frac = (opts and opts.size) or 0.55
		local side = math.floor(ctx.h * frac)
		local ox = (opts and opts.offsetX) or 0
		local oy = (opts and opts.offsetY) or 0
		local x = math.floor((ctx.w - side) / 2) + ox
		local y = math.floor((ctx.h - side) / 2) + oy

		local tint     = opts and M.resolve(opts.tint, state)
		local gradient = opts and M.resolve(opts.gradient, state)

		local finalImg
		if tint or gradient then
			finalImg = renderTintedSvg(img, side, tint, gradient)
		else
			finalImg = img
		end

		table.insert(elements, {
			type         = "image",
			frame        = { x = x, y = y, w = side, h = side },
			image        = finalImg,
			imageScaling = "scaleToFit",
			imageAlpha   = 1,
		})

		return elements
	end
end

-- ============================================================
-- APP ICON LAYER
-- ============================================================

--- Centered application icon from the OS, looked up by app name or bundle ID.
--- Accepts "Safari", "Finder", etc. or "com.apple.Safari" style bundle IDs.
--- @param nameOrFn any  App name/bundle ID, function(state)->name, or {on, off} toggle.
--- @param opts? table
---   size: number?      Icon square as fraction of canvas height (default 0.55).
--- @return fun(elements: table[], state: any, ctx: table): table[]
function M.appIcon(nameOrFn, opts)
	return function(elements, state, ctx)
		local name = M.resolve(nameOrFn, state)
		if not name then return elements end
		local img = getAppIcon(name)
		if not img then return elements end
		local frac = (opts and opts.size) or 0.55
		local side = math.floor(ctx.h * frac)
		local ox = (opts and opts.offsetX) or 0
		local oy = (opts and opts.offsetY) or 0
		local x = math.floor((ctx.w - side) / 2) + ox
		local y = math.floor((ctx.h - side) / 2) + oy
		table.insert(elements, {
			type         = "image",
			frame        = { x = x, y = y, w = side, h = side },
			image        = img,
			imageScaling = "scaleToFit",
			imageAlpha   = 1,
		})
		return elements
	end
end

-- ============================================================
-- BUTTON BACKGROUND SLICE
-- ============================================================

--- Slice of a background image for one button cell in the grid.
--- The full image covers the entire button area (cols×rows cells with gaps).
--- This layer crops it to the correct cell by rendering the image offset so
--- only that button's region falls within the canvas bounds.
---
--- @param nameOrFn  any     Background filename (without extension), or function(state)->name
--- @param index     number  1-based button index (row-major)
--- @param cols      number  Number of button columns on the device
--- @param rows      number  Number of button rows on the device
--- @param hInset    number  Horizontal gap in pixels between button cells (0 if plain image)
--- @param vInset    number  Vertical gap in pixels between button cells (0 if plain image)
--- @return fun(elements: table[], state: any, ctx: table): table[]
function M.buttonBackgroundSlice(nameOrFn, index, cols, rows, hInset, vInset)
	local col = (index - 1) % cols
	local row = math.floor((index - 1) / cols)
	return function(elements, state, ctx)
		local name = M.resolve(nameOrFn, state)
		if not name then return elements end
		local img = getBgImage(name)
		if not img then return elements end
		local totalW  = cols * ctx.w + (cols - 1) * hInset
		local totalH  = rows * ctx.h + (rows - 1) * vInset
		local offsetX = -(col * (ctx.w + hInset))
		local offsetY = -(row * (ctx.h + vInset))
		table.insert(elements, {
			type         = "image",
			frame        = { x = offsetX, y = offsetY, w = totalW, h = totalH },
			image        = img,
			imageScaling = "scaleToFit",
			imageAlpha   = 1,
		})
		return elements
	end
end

-- ============================================================
-- ENCODER BACKGROUND SLICE
-- ============================================================

--- Slice of a wide background image for one encoder section of the LCD strip.
--- The full image spans all 4 encoder sections with optional gaps between them.
--- This layer crops it to the correct region by rendering the image offset left
--- so only the encoder's portion falls within the canvas bounds.
---
--- @param nameOrFn any  Background filename (without extension), or function(state)->name
--- @param encoderIndex number  1-based encoder position (1-4)
--- @param gap number?   Pixel gap between adjacent encoder sections (default 0)
--- @return fun(elements: table[], state: any, ctx: table): table[]
function M.encoderBackgroundSlice(nameOrFn, encoderIndex, gap)
	gap = gap or 0
	return function(elements, state, ctx)
		local name = M.resolve(nameOrFn, state)
		if not name then return elements end
		local img = getBgImage(name)
		if not img then return elements end
		local totalW = ctx.w * 4 + gap * 3
		local offsetX = -(encoderIndex - 1) * (ctx.w + gap)
		table.insert(elements, {
			type         = "image",
			frame        = { x = offsetX, y = 0, w = totalW, h = ctx.h },
			image        = img,
			imageScaling = "scaleToFit",
			imageAlpha   = 1,
		})
		return elements
	end
end

-- ============================================================
-- ENCODER LAYOUT
-- ============================================================
--
-- All encoder layer factories work from a computed layout rather than
-- hard-coded constants. Call computeEncoderLayout(ctx, opts) once in the
-- typed constructor (ValueBar, Icon, Text) and pass the result into each
-- layer factory so every element derives its position from the same source.
--
-- Default layout for a 200×100 canvas with padding=5, inset=5:
--
--   availableArea : Rect(5, 5, 190, 90)
--   titleRow      : top of availableArea, full width, height = titleFontSize + 4
--   bottomArea    : availableArea below titleRow
--   iconArea      : left 1/3 of bottomArea  (split layouts)
--   rightArea     : right 2/3 of bottomArea (split layouts)
--   bar           : anchored to bottom-right of availableArea, grows upward
--   progressValue : anchored to top of bar, grows upward, right-aligned

--- Default layout configuration values.
local ENC_DEFAULTS = {
	padding       = 10,   -- canvas edge → available area (all sides)
	inset         = 10,   -- gap between stacked elements within the area
	titleFontSize = 14,
	titleAnchor   = { horizontal = "start", vertical = "center" },
	badgeSize     = 16,
	iconSize      = 1.0, -- fraction of the column area's shorter dimension
	iconAnchor    = { horizontal = "start", vertical = "end" },
	barHeight     = 10,
	valueFontSize = 28,
}

--- Compute the complete encoder layout from canvas dimensions and user options.
--- Returns a flat table of named frames and scalar values used by every layer factory.
---
--- @param ctx        table   { w: number, h: number } — canvas dimensions
--- @param opts?      table   Partial EncoderLayoutOpts to override defaults
--- @return EncoderLayout
function M.computeEncoderLayout(ctx, opts)
	local pad           = (opts and opts.padding      ) or ENC_DEFAULTS.padding
	local inset         = (opts and opts.inset         ) or ENC_DEFAULTS.inset
	local titleFontSize = (opts and opts.titleFontSize ) or ENC_DEFAULTS.titleFontSize
	local badgeSize     = (opts and opts.badgeSize     ) or ENC_DEFAULTS.badgeSize
	local iconSize      = (opts and opts.iconSize      ) or ENC_DEFAULTS.iconSize
	local iconAnchor    = (opts and opts.iconAnchor    ) or ENC_DEFAULTS.iconAnchor
	local barHeight     = (opts and opts.barHeight     ) or ENC_DEFAULTS.barHeight
	local valueFontSize = (opts and opts.valueFontSize ) or ENC_DEFAULTS.valueFontSize

	-- Available area: canvas minus uniform padding
	local areaX = pad
	local areaY = pad
	local areaW = ctx.w - pad * 2
	local areaH = ctx.h - pad * 2

	-- Title row: anchored to top-left of available area.
	-- Height = font size + small leading so descenders aren't clipped.
	local titleH = titleFontSize + 4
	local titleFrame = { x = areaX, y = areaY, w = areaW, h = titleH }

	-- Badge: anchored to top-right corner of available area.
	-- x is computed so the right edge aligns with the right edge of availableArea.
	local badgeX = areaX + areaW - badgeSize
	local badgeY = areaY
	local badgeFrame = { x = badgeX, y = badgeY, w = badgeSize, h = badgeSize }

	-- Bottom area: below the title row, with inset gap.
	local bottomY = areaY + titleH + inset
	local bottomH = areaH - titleH - inset
	local bottomW = areaW

	-- Icon column: left 1/3 of the bottom area (split layouts).
	local iconColW = math.floor(bottomW / 3)
	local iconColX = areaX
	-- iconSize is a fraction of the column area's shorter dimension.
	local iconPx = math.floor(math.min(iconColW, bottomH) * iconSize)

	local iconAnchorH = iconAnchor.horizontal or "center"
	local iconAnchorV = iconAnchor.vertical   or "center"
	local iconX
	if iconAnchorH == "start" then
		iconX = iconColX
	elseif iconAnchorH == "end" then
		iconX = iconColX + iconColW - iconPx
	else
		iconX = iconColX + math.floor((iconColW - iconPx) / 2)
	end
	local iconY
	if iconAnchorV == "start" then
		iconY = bottomY
	elseif iconAnchorV == "end" then
		iconY = bottomY + bottomH - iconPx
	else
		iconY = bottomY + math.floor((bottomH - iconPx) / 2)
	end
	local iconFrame = { x = iconX, y = iconY, w = iconPx, h = iconPx }

	local iconFullFrame = {
		x = areaX,
		y = bottomY,
		w = bottomW,
		h = bottomH,
	}

	-- Right area: right 2/3 of the bottom area (split layouts).
	local rightX = areaX + iconColW
	local rightW = bottomW - iconColW

	-- Progress bar: anchored to the bottom-right of the available area, grows upward.
	-- Right edge aligns with right edge of available area; left edge aligns with rightX.
	local barY = areaY + areaH - barHeight
	local barX = rightX
	local barW = areaX + areaW - barX
	local barFrame = { x = barX, y = barY, w = barW, h = barHeight }

	-- Progress value: right-aligned, anchored so its bottom sits inset px above bar top.
	-- The text frame height = valueFontSize + 4 (same leading rule as title).
	-- The frame grows upward from (barY - inset).
	local valueH     = valueFontSize + 4
	local valueBottom = barY - inset
	local valueFrame = {
		x = rightX,
		y = valueBottom - valueH,
		w = rightW,
		h = valueH,
	}

	-- Description area: full right area, used by the Text encoder type.
	local descFrame = {
		x = rightX,
		y = bottomY,
		w = rightW,
		h = bottomH,
	}

	local titleAnchor = (opts and opts.titleAnchor) or ENC_DEFAULTS.titleAnchor

	return {
		-- scalars (needed by layer factories)
		titleFontSize  = titleFontSize,
		titleAnchor    = titleAnchor,
		badgeSize      = badgeSize,
		valueFontSize  = valueFontSize,
		iconAnchor     = iconAnchor,
		-- available area (padding-inset region inside the canvas)
		availableArea  = { x = areaX, y = areaY, w = areaW, h = areaH },
		-- frames
		titleFrame     = titleFrame,
		badgeFrame     = badgeFrame,
		iconFrame      = iconFrame,
		iconFullFrame  = iconFullFrame,
		barFrame       = barFrame,
		valueFrame     = valueFrame,
		descFrame      = descFrame,
	}
end

--- Title slot: full-width first row of the available area.
--- Horizontal and vertical alignment follow layout.titleAnchor.
--- @param titleOrFn any     String or resolver (state, value) → string
--- @param layout    EncoderLayout  Pre-computed layout from computeEncoderLayout()
--- @return fun(elements: table[], state: any, ctx: table, value: any): table[]
function M.encoderTitle(titleOrFn, layout)
	local anchor = layout.titleAnchor or {}
	local horiz = anchor.horizontal or "start"
	local vert  = anchor.vertical   or "center"

	local alignment = horiz == "end" and "right" or (horiz == "center" and "center" or "left")

	local f = layout.titleFrame
	local titleY
	if vert == "start" then
		titleY = f.y
	elseif vert == "end" then
		titleY = f.y + f.h - layout.titleFontSize - 4
	else
		titleY = f.y + math.floor((f.h - (layout.titleFontSize + 4)) / 2)
	end
	local frame = { x = f.x, y = titleY, w = f.w, h = layout.titleFontSize + 4 }

	return function(elements, state, _ctx, value)
		local title = M.resolve(titleOrFn, state, value)
		if not title then return elements end
		table.insert(elements, {
			type  = "text",
			frame = frame,
			text  = styledText(tostring(title), layout.titleFontSize, colors.white, alignment),
		})
		return elements
	end
end

--- Badge slot: small SVG image pinned to the top-right corner of the available area.
--- Its top-right corner is fixed; changing badgeSize grows the badge inward/downward.
--- @param nameOrFn any     SVG filename (without extension) or resolver → string
--- @param layout    EncoderLayout  Pre-computed layout from computeEncoderLayout()
--- @param opts?    table   { tint: any?, gradient: any? }
--- @return fun(elements: table[], state: any, ctx: table, value: any): table[]
function M.encoderBadge(nameOrFn, layout, opts)
	return function(elements, state, _ctx, value)
		local name = M.resolve(nameOrFn, state, value)
		if not name then return elements end
		local img = getSvgIcon(name)
		if not img then return elements end

		local tint     = opts and M.resolve(opts.tint, state, value)
		local gradient = opts and M.resolve(opts.gradient, state, value)
		local finalImg = (tint or gradient)
			and renderTintedSvg(img, layout.badgeSize, tint, gradient)
			or img

		table.insert(elements, {
			type         = "image",
			frame        = layout.badgeFrame,
			image        = finalImg,
			imageScaling = "scaleToFit",
			imageAlpha   = 1,
		})
		return elements
	end
end

--- Icon slot: SVG icon centered in the left-column area of the bottom section.
--- Used by ValueBar and Text encoder types (split layout).
--- @param nameOrFn any     SVG filename (without extension) or resolver → string
--- @param layout    EncoderLayout  Pre-computed layout from computeEncoderLayout()
--- @param opts?    table   { tint: any?, gradient: any? }
--- @return fun(elements: table[], state: any, ctx: table, value: any): table[]
function M.encoderIcon(nameOrFn, layout, opts)
	return function(elements, state, _ctx, value)
		local name = M.resolve(nameOrFn, state, value)
		if not name then return elements end
		local img = getSvgIcon(name)
		if not img then return elements end

		local tint     = opts and M.resolve(opts.tint, state, value)
		local gradient = opts and M.resolve(opts.gradient, state, value)
		local finalImg = (tint or gradient)
			and renderTintedSvg(img, layout.iconFrame.w, tint, gradient)
			or img

		table.insert(elements, {
			type         = "image",
			frame        = layout.iconFrame,
			image        = finalImg,
			imageScaling = "scaleToFit",
			imageAlpha   = 1,
		})
		return elements
	end
end

--- Full-bottom icon slot: SVG icon centered in the full bottom area (Icon encoder type).
--- @param nameOrFn any     SVG filename (without extension) or resolver → string
--- @param layout    EncoderLayout  Pre-computed layout from computeEncoderLayout()
--- @param opts?    table   { tint: any?, gradient: any? }
--- @return fun(elements: table[], state: any, ctx: table, value: any): table[]
function M.encoderIconFull(nameOrFn, layout, opts)
	return function(elements, state, _ctx, value)
		local name = M.resolve(nameOrFn, state, value)
		if not name then return elements end
		local img = getSvgIcon(name)
		if not img then return elements end

		local tint     = opts and M.resolve(opts.tint, state, value)
		local gradient = opts and M.resolve(opts.gradient, state, value)
		local finalImg = (tint or gradient)
			and renderTintedSvg(img, layout.iconFullFrame.w, tint, gradient)
			or img

		table.insert(elements, {
			type         = "image",
			frame        = layout.iconFullFrame,
			image        = finalImg,
			imageScaling = "scaleToFit",
			imageAlpha   = 1,
		})
		return elements
	end
end

--- Progress value slot: right-aligned text anchored so its bottom edge sits
--- exactly `inset` pixels above the top of the progress bar. Increasing the
--- font size grows the text upward, never shifting its bottom anchor.
--- Accepts a raw number (rendered as "N%") or an arbitrary string.
--- @param valueOrFn any    Number/string or resolver (state, value) → number|string
--- @param layout    EncoderLayout  Pre-computed layout from computeEncoderLayout()
--- @param colorOrFn any?  Text color or resolver. Defaults to white.
--- @return fun(elements: table[], state: any, ctx: table, value: any): table[]
function M.encoderProgressValue(valueOrFn, layout, colorOrFn)
	return function(elements, state, _ctx, value)
		local val   = M.resolve(valueOrFn, state, value)
		local color = colorOrFn and M.resolve(colorOrFn, state, value) or colors.white
		if val == nil then return elements end
		local text = type(val) == "number"
			and string.format("%d%%", math.floor(val))
			or tostring(val)
		table.insert(elements, {
			type  = "text",
			frame = layout.valueFrame,
			text  = styledText(text, layout.valueFontSize, color, "right"),
		})
		return elements
	end
end

--- Progress bar slot: thin outlined + filled rounded rect anchored to the
--- bottom-right of the available area, growing upward as height increases.
--- The outline is white; the fill colour represents progress.
--- @param pctOrFn   any   Number 0-100 or resolver (state, value) → number
--- @param layout    EncoderLayout  Pre-computed layout from computeEncoderLayout()
--- @param colorOrFn any?  Fill color or resolver. Defaults to white.
--- @return fun(elements: table[], state: any, ctx: table, value: any): table[]
function M.encoderProgressBar(pctOrFn, layout, colorOrFn)
	local STROKE = 2
	return function(elements, state, _ctx, value)
		local pct      = M.resolve(pctOrFn, state, value) or 0
		local barColor = colorOrFn and M.resolve(colorOrFn, state, value) or colors.white
		local f        = layout.barFrame
		local radius   = { xRadius = f.h / 3, yRadius = f.h / 3 }

		table.insert(elements, {
			type             = "rectangle",
			frame            = f,
			action           = "stroke",
			strokeColor      = colors.white,
			strokeWidth      = STROKE,
			roundedRectRadii = radius,
		})

		local pctClamped = math.max(0, math.min(pct, 100))
		if pctClamped > 0 then
			local fillW = math.max(f.h, f.w * pctClamped / 100)
			table.insert(elements, {
				type             = "rectangle",
				frame            = { x = f.x, y = f.y, w = fillW, h = f.h },
				action           = "fill",
				fillColor        = barColor,
				roundedRectRadii = radius,
			})
		end
		return elements
	end
end

--- Description slot: text spanning the right area of the bottom section.
--- Used by the Text encoder type.
--- @param textOrFn  any   String or resolver (state, value) → string
--- @param layout    EncoderLayout  Pre-computed layout from computeEncoderLayout()
--- @param colorOrFn any?  Text color or resolver. Defaults to white.
--- @return fun(elements: table[], state: any, ctx: table, value: any): table[]
function M.encoderDescription(textOrFn, layout, colorOrFn)
	return function(elements, state, _ctx, value)
		local text  = M.resolve(textOrFn, state, value)
		local color = colorOrFn and M.resolve(colorOrFn, state, value) or colors.white
		if not text then return elements end
		table.insert(elements, {
			type  = "text",
			frame = layout.descFrame,
			text  = styledText(tostring(text), 12, color, "left"),
		})
		return elements
	end
end

--- Stack picker overlay: large badge centered at top, active encoder title centered at bottom.
--- Rendered by EncoderStack instead of the normal sub-encoder layers while the knob is held.
--- Both elements are positioned within the available area defined by the layout.
--- @param badgeName string        SVG filename (without extension) for the stack badge
--- @param titleOrFn any           String or resolver (state, value) → string for the active encoder name
--- @param layout    EncoderLayout Pre-computed layout from computeEncoderLayout()
--- @return fun(elements: table[], state: any, ctx: table, value: any): table[]
function M.encoderStackPicker(badgeName, titleOrFn, layout)
	local BADGE_SIZE = 52
	local TITLE_SIZE = 21
	local TITLE_H    = TITLE_SIZE + 4
	local area       = layout.availableArea

	local badgeX = area.x + math.floor((area.w - BADGE_SIZE) / 2)
	local badgeY = area.y

	local titleFrame = { x = area.x, y = area.y + area.h - TITLE_H, w = area.w, h = TITLE_H }

	return function(elements, state, _ctx, value)
		local badgeImg = getSvgIcon(badgeName)
		if badgeImg then
			table.insert(elements, {
				type         = "image",
				frame        = { x = badgeX, y = badgeY, w = BADGE_SIZE, h = BADGE_SIZE },
				image        = badgeImg,
				imageScaling = "scaleToFit",
				imageAlpha   = 1,
			})
		end

		local title = M.resolve(titleOrFn, state, value)
		if title then
			table.insert(elements, {
				type  = "text",
				frame = titleFrame,
				text  = styledText(tostring(title), TITLE_SIZE, colors.white, "center"),
			})
		end

		return elements
	end
end

-- ============================================================
-- RESOLVE HELPER
-- ============================================================

--- Resolve a value that may be a literal, a function, or a toggle table.
--- Toggle tables have the shape { on = X, off = Y } and are resolved based
--- on the truthiness of the first argument.
--- @param field any        The value, function, or toggle table
--- @param ...  any         Arguments passed to functions; first arg used for toggle
--- @return any
function M.resolve(field, ...)
	if type(field) == "function" then
		return field(...)
	end
	if type(field) == "table" and (field.on ~= nil or field.off ~= nil) then
		local state = select(1, ...)
		return state and field.on or field.off
	end
	return field
end

-- ============================================================
-- LAYER PRIMITIVES
-- ============================================================

--- Solid color background rectangle filling the full canvas.
--- @param colorOrFn any  Color table, function(state)->color, or {on, off} toggle
--- @return fun(elements: table[], state: any, ctx: table): table[]
function M.background(colorOrFn)
	return function(elements, state, ctx)
		local color = M.resolve(colorOrFn, state)
		table.insert(elements, {
			type = "rectangle",
			frame = { x = 0, y = 0, w = ctx.w, h = ctx.h },
			fillColor = color or colors.bg,
			roundedRectRadii = { xRadius = 8, yRadius = 8 },
		})
		return elements
	end
end

--- Centered icon (emoji or text string).
--- @param iconOrFn any   Icon string, function(state)->string, or {on, off} toggle
--- @param opts? table    { size: number?, color: any? }
--- @return fun(elements: table[], state: any, ctx: table): table[]
function M.icon(iconOrFn, opts)
	return function(elements, state, ctx)
		local icon = M.resolve(iconOrFn, state)
		if not icon then return elements end
		local size = (opts and opts.size) or math.floor(ctx.h * 0.45)
		local color = (opts and opts.color) and M.resolve(opts.color, state) or colors.white
		local ox = (opts and opts.offsetX) or 0
		local oy = (opts and opts.offsetY) or 0
		table.insert(elements, {
			type = "text",
			frame = { x = 0 + ox, y = ctx.h * 0.08 + oy, w = ctx.w, h = ctx.h * 0.55 },
			text = styledText(icon, size, color, "center"),
		})
		return elements
	end
end

--- Label text at a configurable position.
--- @param textOrFn any   Label string, function(state)->string, or {on, off} toggle
--- @param opts? table    { position: {horizontal: string, vertical: string}?, padding: number?, size: number?, color: any? }
--- @return fun(elements: table[], state: any, ctx: table): table[]
function M.label(textOrFn, opts)
	return function(elements, state, ctx)
		local text = M.resolve(textOrFn, state)
		if not text then return elements end
		local pos  = opts and opts.position
		local pad  = (opts and opts.padding) or 4
		local size = (opts and opts.size) or 13
		local color = (opts and opts.color) and M.resolve(opts.color, state) or colors.textSec
		local ox = (opts and opts.offsetX) or 0
		local oy = (opts and opts.offsetY) or 0
		local frame, alignment = positionToFrame(pos, ctx, pad)
		frame.x = frame.x + ox
		frame.y = frame.y + oy
		table.insert(elements, {
			type = "text",
			frame = frame,
			text = styledText(text, size, color, alignment),
		})
		return elements
	end
end

--- Named-slot convenience that composes background + icon + label.
--- @param def table  { bgColor, icon, iconOpts, label, labelOpts }
--- @return fun(elements: table[], state: any, ctx: table): table[]
function M.standard(def)
	local bgLayer = M.background(def.bgColor or colors.bg)
	local iconLayer = def.icon and M.icon(def.icon, def.iconOpts) or nil
	local labelLayer = def.label and M.label(def.label, def.labelOpts) or nil

	return function(elements, state, ctx)
		elements = bgLayer(elements, state, ctx)
		if iconLayer then
			elements = iconLayer(elements, state, ctx)
		end
		if labelLayer then
			elements = labelLayer(elements, state, ctx)
		end
		return elements
	end
end

return M
