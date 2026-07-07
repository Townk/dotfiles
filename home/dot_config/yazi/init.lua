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

Status:children_add(function(self)
	local h = self._current.hovered
	if h and h.link_to then
		return " -> " .. tostring(h.link_to)
	else
		return ""
	end
end, 3300, Status.LEFT)

Status:children_add(function()
	local h = cx.active.current.hovered
	if h == nil or ya.target_family() ~= "unix" then
		return ""
	end

	return ui.Line {
		ui.Span(ya.user_name(h.cha.uid) or tostring(h.cha.uid)):fg("magenta"),
		":",
		ui.Span(ya.group_name(h.cha.gid) or tostring(h.cha.gid)):fg("magenta"),
		" ",
	}
end, 500, Status.RIGHT)

Header:children_add(function()
	if ya.target_family() ~= "unix" then
		return ""
	end
	return ui.Span(ya.user_name() .. "@" .. ya.host_name() .. ": "):fg("blue")
end, 500, Header.LEFT)

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
