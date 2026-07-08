require("full-border"):setup()
require("folder-rules"):setup()
require("git"):setup()

-- Tag colors come from the single-source palette (~/.config/theme/chezmoi-system.lua,
-- generated from .chezmoidata/theme.yaml -> extended.tags). The literal
-- fallbacks (the current values) keep tags working if the bridge is missing.
local _theme_ok, _theme = pcall(dofile, os.getenv("HOME") .. "/.config/theme/chezmoi-system.lua")
local _tags = (_theme_ok and type(_theme) == "table" and _theme.extended and _theme.extended.tags) or {}
require("mactag"):setup {
	-- Keys used to add or remove tags
	keys = {
		r = "Red",
		o = "Orange",
		y = "Yellow",
		g = "Green",
		b = "Blue",
		p = "Purple",
	},
	-- Colors used to display tags (from theme.yaml extended.tags)
	colors = {
		Red    = _tags.red or "#ee7b70",
		Orange = _tags.orange or "#f5bd5c",
		Yellow = _tags.yellow or "#fbe764",
		Green  = _tags.green or "#91fc87",
		Blue   = _tags.blue or "#5fa3f8",
		Purple = _tags.purple or "#cb88f8",
	},
}

if os.getenv("NVIM") then
	require("toggle-pane"):entry("min-preview")
end

Status = Status
---@type th.Status

Header = Header
---@type TS.Heading

-- Status bar: replicate the Neovim lualine layout. Colours come from the
-- single-source palette (loaded above as `_theme`); literals are the
-- Catppuccin-Mocha fallback for when the bridge is missing.
local _pal = (_theme_ok and type(_theme) == "table" and _theme.palette) or {}
local _roles = (_theme_ok and type(_theme) == "table" and _theme.roles) or {}
local status_color = {
	bg = _pal.mantle or "#181825", -- dark bar (== nvim StatusLine bg)
	normal = _pal.blue or "#89b4fa", -- normal mode
	select = _pal.yellow or "#f9e2af", -- select (visual) mode
	unset = _pal.peach or "#fab387", -- unset (reversed visual) mode
	muted = _pal.overlay2 or "#9399b2", -- size / path / owner / counter
	link = (_roles.ui and _roles.ui.link) or "#89b4fa",
}

local HOME = os.getenv("HOME") or ""

-- Port of the Neovim utils/path.lua truncate_path: home -> ~, then shorten
-- middle path components one char at a time (left to right), marking shortened
-- ones with "…", always preserving the final filename.
local function truncate_path(path, max_len)
	local is_absolute = path:sub(1, 1) == "/"
	if HOME ~= "" and path:sub(1, #HOME) == HOME then
		path = "~" .. path:sub(#HOME + 1)
		is_absolute = false
	end
	if #path <= max_len then
		return path
	end

	local parts, original = {}, {}
	for part in path:gmatch("([^/]+)") do
		parts[#parts + 1] = part
		original[#original + 1] = part
	end

	local result = path
	local changed = false
	while #result > max_len do
		local abbreviated = false
		for i = 1, #parts - 1 do
			local min_len = parts[i]:sub(1, 1) == "." and 2 or 1
			if #parts[i] > min_len then
				parts[i] = parts[i]:sub(1, -2)
				abbreviated = true
				changed = true
				break
			end
		end
		if not abbreviated then
			break
		end
		result = table.concat(parts, "/")
	end

	if changed then
		local out = {}
		for i, part in ipairs(parts) do
			if i < #parts and original[i] and #part < #original[i] then
				out[i] = part .. "…"
			else
				out[i] = part
			end
		end
		result = table.concat(out, "/")
	end

	if is_absolute then
		result = "/" .. result
	end
	return result
end

-- Resolve a symlink to its canonical absolute target (like `readlink -f`) with
-- pure string logic: relative targets are joined to the link's parent, then
-- "." / ".." / duplicate slashes are collapsed. Intermediate symlink chains
-- aren't followed — that needs async fs calls unavailable during a sync redraw.
local function resolve_link(link, target)
	if target:sub(1, 1) ~= "/" then
		target = (link:match("^(.*)/[^/]*$") or "") .. "/" .. target
	end
	local parts = {}
	for seg in target:gmatch("[^/]+") do
		if seg == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		elseif seg ~= "." then
			parts[#parts + 1] = seg
		end
	end
	return "/" .. table.concat(parts, "/")
end

-- Mode -> accent colour (blue normal / yellow select / orange unset).
local function mode_color(m)
	if m.is_select then
		return status_color.select
	elseif m.is_unset then
		return status_color.unset
	end
	return status_color.normal
end

-- Left: colour-only mode indicator (lualine's ▎● glyphs).
function Status:mode()
	return ui.Line { ui.Span("▎●"):fg(mode_color(self._tab.mode)) }
end

-- Left: hovered file size, 2 cells after the mode.
function Status:length()
	local h = self._current.hovered
	local len = h and h.cha.len or 0
	return ui.Line { ui.Span("  " .. ya.readable_size(len)):fg(status_color.muted) }
end

-- Left: icon (or link glyph) + abbreviated full path, 2 cells after the size.
function Status:name()
	local h = self._current.hovered
	if not h then
		return ""
	end

	local target = tostring(h.url)
	local spans = { ui.Span("  ") }
	if h.link_to then
		spans[#spans + 1] = ui.Span("\u{10F0C1} "):fg(status_color.link)
		target = resolve_link(target, tostring(h.link_to))
	else
		local icon = h:icon()
		if icon then
			spans[#spans + 1] = ui.Span(icon.text .. " "):style(icon.style)
		end
	end

	local path = truncate_path(target, self._name_budget or 40)
	spans[#spans + 1] = ui.Span(ui.printable(path)):fg(status_color.muted)
	return ui.Line(spans)
end

-- Right: file ownership (user:group), 2 cells before the counter.
function Status:owner()
	local h = self._current.hovered
	if not h or ya.target_family() ~= "unix" then
		return ""
	end
	local user = ya.user_name(h.cha.uid) or tostring(h.cha.uid)
	local group = ya.group_name(h.cha.gid) or tostring(h.cha.gid)
	return ui.Line { ui.Span("  " .. user .. ":" .. group):fg(status_color.muted) }
end

-- Right: x/N counter as an inverted mode-coloured pill (mode colour as bg,
-- bar bg as fg), 2 uncoloured cells after the owner. Right-alignment flushes the
-- pill's trailing coloured cell to the screen edge.
function Status:position()
	local cursor = self._current.cursor
	local length = #self._current.files
	return ui.Line {
		ui.Span("  "),
		ui.Span(string.format(" %d/%d ", math.min(cursor + 1, length), length))
			:fg(status_color.bg)
			:bg(mode_color(self._tab.mode)),
	}
end

-- Right-hand order (left→right): chmod · owner · counter. Drops `percent`.
Status._right = {
	{ "perm", id = 4, order = 1000 },
	{ "owner", id = 5, order = 2000 },
	{ "position", id = 6, order = 3000 },
}

-- Paint the whole bar with the dark (mantle) background, and budget the path to
-- the width left after the right-hand block. Otherwise mirrors the preset.
function Status:redraw()
	local right = self:children_redraw(self.RIGHT)
	local right_width = right:width()

	local h = self._current.hovered
	local size = h and ya.readable_size(h.cha.len or 0) or ""
	-- mode(2) + gap(2) + size + gap(2) + icon(2) + trailing(1)
	local left_prefix = 2 + 2 + #size + 2 + 2 + 1
	self._name_budget = math.max(10, self._area.w - right_width - left_prefix)

	local left = self:children_redraw(self.LEFT)

	return {
		ui.Text(""):area(self._area):style(ui.Style():bg(status_color.bg)),
		ui.Line(left):area(self._area),
		ui.Line(right):area(self._area):align(ui.Align.RIGHT),
		table.unpack(ui.redraw(Progress:new(self._area, right_width))),
	}
end

Header:children_add(function()
	if ya.target_family() ~= "unix" then
		return ""
	end
	return ui.Span(" " .. (ya.user_name() .. "@" .. ya.host_name()):lower() .. "  "):fg("blue")
end, 500, Header.LEFT)

-- Current dir uses the same middle-component shortening as the status-bar path,
-- budgeted against the user@host prefix (leading + host + 2 trailing cells) and
-- the right-hand count, instead of the default right-to-left hard cut.
function Header:cwd()
	local prefix = 3 + #(ya.user_name() .. "@" .. ya.host_name())
	local max = self._area.w - (self._right_width or 0) - prefix
	if max <= 0 then
		return ""
	end
	local flags = self:flags()
	local path = truncate_path(tostring(self._current.cwd), math.max(1, max - #flags))
	return ui.Span(path .. flags):style(th.mgr.cwd)
end

-- nice-sidebar: Finder-style sticky sidebar in the parent column. Skipped in
-- tm scrub sessions (tm-gate owns that column and its own ratio) and in
-- embedded-nvim yazi (the float is too narrow to surrender a fixed column).
if not os.getenv("BKP_TM_SESSION") and not os.getenv("NVIM") then
	local _r = (_theme_ok and type(_theme) == "table" and _theme.roles) or {}
	local _ui = _r.ui or {}
	local _st = _r.state or {}
	local _tab = (_theme_ok and type(_theme) == "table" and _theme.extended and _theme.extended.tab) or {}
	require("nice-sidebar"):setup {
		dirs = {
			{ label = "Home", path = "~", icon = "󰠦" },
			{ label = "Desktop", path = "~/Desktop", icon = "󰇄" },
			{ label = "Depot", path = "~/Depot", icon = "󰀼" },
			{ label = "Download", path = "~/Downloads", icon = "󱑢" },
			{ label = "Documents", path = "~/Documents", icon = "󰈙" },
			{ label = "Notes", path = "~/Notes", icon = "󱓧" },
			{ label = "Pictures", path = "~/Pictures", icon = "󰋩" },
			{ label = "Projects", path = "~/Projects", icon = "󰃖" },
			{ label = "Videos", path = "~/Movies", icon = "󰿎" },
			{ label = "Music", path = "~/Music", icon = "󰝚" },
			{ label = "Public", path = "~/Public", icon = "" },
		},
		colors = {
			title = _ui.title,
			section = _st.info,
			separator = _ui.separator,
			selected_bg = _tab.active_bg,
			selected_fg = _tab.active_fg,
			selected_inactive_bg = _tab.bg,
			selected_inactive_fg = _tab.fg,
			cursor_bg = _tab.bg,
			cursor_fg = _tab.fg,
			-- staging panel tab bar: match Yazi's marker colours
			staged = "#f9e2af", -- marker_selected (light yellow)
			clipboard = "#a6e3a1", -- marker_copied (green)
			clipboard_cut = "#f38ba8", -- marker_cut (pink)
			tab_rule = "#7f849c", -- lighter gray than the separator
		},
	}
	-- Pane-click focus reclaim (blurring the sidebar or staging panel when the
	-- center/preview columns are clicked) is owned by the plugin itself now.
end
