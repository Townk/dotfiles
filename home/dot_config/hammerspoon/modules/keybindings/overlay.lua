--- keybindings/overlay.lua
--- WebView-based overlay panel for the keybinding system.
--- Renders a styled list of keybinding entries using HTML/CSS
--- with macOS Tahoe aesthetic (rounded corners, translucent background).

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

--- @type OverlayConfigStyles
local DEFAULTS = {
	-- Webview placement
	position = "bottom_right",
	margin = 50,
	maxHeight = "70%",

	-- Scroll math (must match CSS: %%FONT_SIZE%%, %%PADDING_V%%, %%ENTRY_GAP%%)
	fontSize = 17,
	paddingV = 10,
	entryGap = 2,

	-- Content generation
	groupSuffix = " …",
}

---------------------------------------------------------------------------
-- Helpers (stateless)
---------------------------------------------------------------------------

--- @return hs.geometry  Full frame of the main screen
local function screenFrame()
	return hs.screen.mainScreen():fullFrame()
end

--- @return number  Device-pixel-to-point scale factor (e.g. 2.0 on Retina)
local function screenScale()
	local screen = hs.screen.mainScreen()
	local mode = screen:currentMode()
	return mode and mode.scale or 1
end

--- Resolve a maxHeight value to screen points.
--- Accepts: number (device px), "Npx" (device px), "N%" (screen %), or bare "N" (device px).
--- Returns nil on invalid input (caller should use a fallback).
--- @param value number|string
--- @return number|nil  Height in screen points, or nil if invalid
local function resolveMaxHeight(value)
	local sf = screenFrame()
	local scale = screenScale()

	if type(value) == "number" then
		if value <= 0 then
			hs.printf("keybindings: invalid maxHeight %s, must be > 0", tostring(value))
			return nil
		end
		return math.floor(value / scale)
	end

	if type(value) == "string" then
		local trimmed = value:match("^%s*(.-)%s*$")

		-- "N%" — percentage of screen height
		local pct = trimmed:match("^([%d%.]+)%%$")
		if pct then
			local n = tonumber(pct)
			if not n or n <= 0 then
				hs.printf("keybindings: invalid maxHeight %q, percentage must be > 0", value)
				return nil
			end
			n = math.min(n, 100)
			return math.floor(sf.h * n / 100)
		end

		-- "Npx" — device pixels
		local px = trimmed:match("^([%d%.]+)px$")
		if px then
			local n = tonumber(px)
			if not n or n <= 0 then
				hs.printf("keybindings: invalid maxHeight %q, pixel value must be > 0", value)
				return nil
			end
			return math.floor(n / scale)
		end

		-- Bare "N" — treat as device pixels
		local bare = tonumber(trimmed)
		if bare then
			if bare <= 0 then
				hs.printf("keybindings: invalid maxHeight %q, must be > 0", value)
				return nil
			end
			return math.floor(bare / scale)
		end

		hs.printf("keybindings: unrecognized maxHeight format %q, expected number, \"Npx\", or \"N%%\"", value)
		return nil
	end

	hs.printf("keybindings: invalid maxHeight type %s, expected number or string", type(value))
	return nil
end

--- Escape special HTML characters in a string.
--- @param str string|nil
--- @return string
local function escapeHtml(str)
	if not str then return "" end
	return (str:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--- CSS class names for each entry type. Falls back to "desc" for plain actions.
--- @type table<string, string>
local DESC_CLASS = {
	group       = "desc desc-group",
	sticky      = "desc desc-sticky",
}

--- Build HTML table rows for the visible binding entries.
--- @param entries table[]  Array of { keyLabel, desc, icon, type }
--- @param cfg     OverlayConfigStyles
--- @return string  Concatenated <tr> elements
local function buildTableRows(entries, cfg)
	local rows = {}
	for _, entry in ipairs(entries) do
		local descClass = DESC_CLASS[entry.type] or "desc"
		local descText = escapeHtml(entry.desc)
		if entry.type == "group" then
			descText = descText .. escapeHtml(cfg.groupSuffix)
		end

		local iconHtml
		if entry.icon and entry.icon ~= "" then
			iconHtml = string.format('<td class="icon">%s</td>', escapeHtml(entry.icon))
		else
			iconHtml = '<td class="icon"></td>'
		end

		table.insert(rows, string.format(
			'<tr><td class="key">%s</td>%s<td class="%s">%s</td></tr>',
			escapeHtml(entry.keyLabel),
			iconHtml,
			descClass,
			descText
		))
	end
	return table.concat(rows, "\n")
end

--- Build the footer hint bar HTML.
--- @param isScrollable boolean  Whether scroll shortcuts should be shown
--- @return string  HTML content for the footer div
local function buildFooter(isScrollable)
	local hints = {
		'<span><span class="footer-key">󱊷 </span> close</span>',
		'<span><span class="footer-key">󰁮 </span> back</span>',
	}
	if isScrollable then
		table.insert(hints, '<span><span class="footer-key">⌃D/⌃U</span> scroll</span>')
	end
	return table.concat(hints, "\n")
end

--- Compute the top-left position for the overlay on screen.
--- @param cfg      OverlayConfigStyles
--- @param overlayW number  Rendered overlay width
--- @param overlayH number  Rendered overlay height
--- @return table   { x: number, y: number }
local function computePosition(cfg, overlayW, overlayH)
	local sf = screenFrame()
	local positions = {
		bottom_right = {
			x = sf.x + sf.w - overlayW - cfg.margin,
			y = sf.y + sf.h - overlayH - cfg.margin,
		},
		bottom_left = {
			x = sf.x + cfg.margin,
			y = sf.y + sf.h - overlayH - cfg.margin,
		},
		top_right = {
			x = sf.x + sf.w - overlayW - cfg.margin,
			y = sf.y + cfg.margin,
		},
		top_left = {
			x = sf.x + cfg.margin,
			y = sf.y + cfg.margin,
		},
		center = {
			x = sf.x + (sf.w - overlayW) / 2,
			y = sf.y + (sf.h - overlayH) / 2,
		},
		center_top = {
			x = sf.x + (sf.w - overlayW) / 2,
			y = sf.y + cfg.margin,
		},
		center_bottom = {
			x = sf.x + (sf.w - overlayW) / 2,
			y = sf.y + sf.h - overlayH - cfg.margin,
		},
		middle_left = {
			x = sf.x + cfg.margin,
			y = sf.y + (sf.h - overlayH) / 2,
		},
		middle_right = {
			x = sf.x + sf.w - overlayW - cfg.margin,
			y = sf.y + (sf.h - overlayH) / 2,
		},
	}
	return positions[cfg.position] or positions.bottom_right
end

---------------------------------------------------------------------------
-- Overlay class
---------------------------------------------------------------------------

--- @class Overlay
local Overlay = {}
Overlay.__index = Overlay

--- Create a new Overlay instance.
--- @param config OverlayConfig  Configuration (must include `template`; rest merged with DEFAULTS)
--- @return Overlay
function Overlay.new(config)
	assert(config and config.template, "Overlay.new: config.template is required")

	local cfg = {}
	for k, v in pairs(DEFAULTS) do
		if config[k] ~= nil then
			cfg[k] = config[k]
		else
			cfg[k] = v
		end
	end

	local tmpl = config.template

	local self = setmetatable({
		cfg              = cfg,
		template         = tmpl,
		resolvedCss      = tmpl.resolveCSS(cfg),
		webview          = nil,
		ucc              = nil,
		scrollOffset     = 0,
		currentEntries   = {},
		currentBreadcrumb = nil,
	}, Overlay)

	return self
end

---------------------------------------------------------------------------
-- Private methods
---------------------------------------------------------------------------

--- Whether the overlay currently has a non-empty breadcrumb.
--- @return boolean
--- @private
function Overlay:_hasBreadcrumb()
	return self.currentBreadcrumb ~= nil and self.currentBreadcrumb ~= ""
end

--- Calculate how many binding rows fit in the overlay.
--- @param hasBreadcrumb boolean
--- @return number
--- @private
function Overlay:_computeMaxVisible(hasBreadcrumb)
	local sf = screenFrame()
	local maxH = resolveMaxHeight(self.cfg.maxHeight) or math.floor(sf.h * 0.7)
	local headerH = hasBreadcrumb and 40 or 0
	local footerH = 30
	local lineH = self.cfg.fontSize * 1.5 + self.cfg.entryGap * 2
	local available = maxH - self.cfg.paddingV * 2 - headerH - footerH
	return math.max(1, math.floor(available / lineH))
end

--- Create the webview if it doesn't exist yet.
--- @param maxH number  Maximum overlay height for this render pass
--- @private
function Overlay:_ensureWebview(maxH)
	if self.webview then return end

	self.ucc = hs.webview.usercontent.new("sizeReport")
	self.ucc:setCallback(function(msg)
		if not self.webview then return end
		local body = msg.body
		if body and body.w and body.h then
			local w = body.w
			local h = math.min(body.h, maxH)
			local pos = computePosition(self.cfg, w, h)
			self.webview:frame({ x = pos.x, y = pos.y, w = w, h = h })
			self.webview:show()
		end
	end)

	local initRect = { x = -2000, y = -2000, w = 800, h = maxH }
	-- Explicit, for the reason spelled out in clipboard-picker.lua: this
	-- overlay's inline script is what reports the rendered panel size back
	-- to Lua, so a webview that refuses content JavaScript leaves the panel
	-- sized by fallback rather than by its content.
	self.webview = hs.webview.new(initRect, { javaScriptEnabled = true }, self.ucc)
	self.webview:transparent(true)
	self.webview:windowStyle({ "borderless", "nonactivating" })
	self.webview:level(hs.drawing.windowLevels.overlay)
	self.webview:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
	self.webview:shadow(false)
	self.webview:allowTextEntry(false)
end

--- Build the HTML and push it to the webview.
--- @private
function Overlay:_render()
	local maxVisible = self:_computeMaxVisible(self:_hasBreadcrumb())
	local totalEntries = #self.currentEntries

	-- Determine scroll indicators
	local hasAbove = self.scrollOffset > 0
	local hasBelow = (self.scrollOffset + maxVisible) < totalEntries

	-- Slice the visible entries
	local visibleEntries = {}
	local endIdx = math.min(self.scrollOffset + maxVisible, totalEntries)
	for i = self.scrollOffset + 1, endIdx do
		table.insert(visibleEntries, self.currentEntries[i])
	end

	local isScrollable = totalEntries > maxVisible
	local html = self.template.buildHtml({
		resolvedCss  = self.resolvedCss,
		breadcrumb   = escapeHtml(self.currentBreadcrumb or ""),
		scrollTop    = hasAbove and '<div class="scroll-indicator scroll-indicator-top">▲</div>' or "",
		tableRows    = buildTableRows(visibleEntries, self.cfg),
		scrollBottom = hasBelow and '<div class="scroll-indicator scroll-indicator-bottom">▼</div>' or "",
		footer       = buildFooter(isScrollable),
	})

	local sf = screenFrame()
	local maxH = resolveMaxHeight(self.cfg.maxHeight) or math.floor(sf.h * 0.7)
	self:_ensureWebview(maxH)
	self.webview:html(html)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Display the overlay with the given entries and breadcrumb.
--- @param entries    table[]  Array of { keyLabel, desc, icon, type }
--- @param breadcrumb string   Breadcrumb trail text
--- @param keepScroll? boolean Preserve current scroll position (default: false)
function Overlay:show(entries, breadcrumb, keepScroll)
	self.currentEntries = entries or {}
	self.currentBreadcrumb = breadcrumb
	if not keepScroll then
		self.scrollOffset = 0
	end
	self:_render()
end

--- Hide the overlay without releasing resources.
function Overlay:hide()
	if self.webview then
		self.webview:hide()
	end
end

--- Scroll down by half a page and re-render.
function Overlay:scrollDown()
	local maxVisible = self:_computeMaxVisible(self:_hasBreadcrumb())
	local halfPage = math.max(1, math.floor(maxVisible / 2))
	local maxOffset = math.max(0, #self.currentEntries - maxVisible)
	self.scrollOffset = math.min(self.scrollOffset + halfPage, maxOffset)
	self:_render()
end

--- Scroll up by half a page and re-render.
function Overlay:scrollUp()
	local maxVisible = self:_computeMaxVisible(self:_hasBreadcrumb())
	local halfPage = math.max(1, math.floor(maxVisible / 2))
	self.scrollOffset = math.max(0, self.scrollOffset - halfPage)
	self:_render()
end

--- Release all resources (webview, user content controller, state).
function Overlay:cleanup()
	if self.webview then
		self.webview:delete()
		self.webview = nil
	end
	self.ucc = nil
	self.currentEntries = {}
	self.currentBreadcrumb = nil
	self.scrollOffset = 0
end

return Overlay
