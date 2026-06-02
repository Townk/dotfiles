--- keybindings/template.lua
--- Template engine singleton for the keybinding overlay.
--- Loads HTML/CSS templates from Assets/html/, caches them,
--- and resolves %%PLACEHOLDER%% substitutions at render time.

local TemplateEngine = {}

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

local ASSETS_DIR = hs.configdir .. "/Assets/html"
local CSS_TEMPLATE_FILE = ASSETS_DIR .. "/which-key-overlay.css"
local HTML_TEMPLATE_FILE = ASSETS_DIR .. "/which-key-overlay.html"

--- @type string|nil
local cssTemplateRaw = nil
--- @type string|nil
local htmlTemplateRaw = nil

---------------------------------------------------------------------------
-- Private helpers
---------------------------------------------------------------------------

--- Read the entire contents of a file into a string.
--- @param path string  Absolute path to the file
--- @return string|nil  File contents, or nil on failure
local function readFile(path)
	local f = io.open(path, "r")
	if not f then
		hs.printf("keybindings/template: failed to open %s", path)
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

--- Substitute all %%KEY%% placeholders in a template string.
--- @param tmpl string  Template with %%PLACEHOLDER%% markers
--- @param substitutions table<string, string|number>  Key-value pairs to substitute
--- @return string  Template with all matched placeholders resolved
local function substitute(tmpl, substitutions)
	return (tmpl:gsub("%%%%([%w_]+)%%%%", function(key)
		local val = substitutions[key]
		if val ~= nil then
			return tostring(val)
		end
		hs.printf("keybindings/template: unresolved placeholder %%%%%s%%%%", key)
		return ""
	end))
end

--- Load template files from disk if not already cached.
--- Asserts on failure so callers can assume non-nil strings.
--- @private
local function ensureTemplatesLoaded()
	if not cssTemplateRaw then
		cssTemplateRaw = readFile(CSS_TEMPLATE_FILE)
		assert(cssTemplateRaw, "keybindings/template: CSS template not found")
	end
	if not htmlTemplateRaw then
		htmlTemplateRaw = readFile(HTML_TEMPLATE_FILE)
		assert(htmlTemplateRaw, "keybindings/template: HTML template not found")
	end
end

---------------------------------------------------------------------------
-- Public API (OverlayTemplate interface)
---------------------------------------------------------------------------

--- Resolve the few CSS placeholders that must stay in sync with Lua scroll math.
--- @param cfg OverlayConfigStyles  The resolved overlay configuration
--- @return string                  CSS with all placeholders substituted
function TemplateEngine.resolveCSS(cfg)
	ensureTemplatesLoaded()
	local css = cssTemplateRaw --[[@as string]]
	return substitute(css, {
		FONT_SIZE = cfg.fontSize,
		PADDING_V = cfg.paddingV,
		ENTRY_GAP = cfg.entryGap,
	})
end

--- Build the complete HTML document for a render pass.
--- @param params OverlayRenderParams
--- @return string  Complete HTML document ready for webview
function TemplateEngine.buildHtml(params)
	ensureTemplatesLoaded()
	local tmpl = htmlTemplateRaw --[[@as string]]

	-- Replace the <link> tag with an inline <style> block
	local html = tmpl:gsub(
		'<link rel="stylesheet" href="%%%%WHICH_KEY_CSS_FILE%%%%">',
		"<style>\n" .. params.resolvedCss:gsub("%%", "%%%%") .. "\n</style>"
	)

	return substitute(html, {
		BREADCRUMB_CONTENT    = params.breadcrumb,
		SCROLL_TOP_CONTENT    = params.scrollTop,
		BINDING_TABLE_ROWS    = params.tableRows,
		SCROLL_BOTTOM_CONTENT = params.scrollBottom,
		FOOTER_CONTENT        = params.footer,
	})
end

--- Force reload of template files from disk.
function TemplateEngine.invalidateCache()
	cssTemplateRaw = nil
	htmlTemplateRaw = nil
end

return TemplateEngine --[[@as OverlayTemplate]]
