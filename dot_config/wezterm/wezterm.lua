-- Pull in the wezterm API

---@diagnostic disable:assign-type-mismatch
---@type Wezterm
local wezterm = require("wezterm")

local plugins_dir = wezterm.home_dir .. "/Projects/wezterm"

function get_plugin_path(plugin_name, github_repo)
	local local_path = plugins_dir .. "/" .. plugin_name
	local success = io.open(local_path .. "/plugin/init.lua", "r")
	if success then
		success:close()
		return "file://" .. local_path
	end
	return "https://github.com/" .. (github_repo or ("Townk/" .. plugin_name))
end

local smart_splits = wezterm.plugin.require("https://github.com/mrjones2014/smart-splits.nvim")
local statusbar = wezterm.plugin.require(get_plugin_path("statusbar.wezterm"))
local quick_launch = wezterm.plugin.require(get_plugin_path("quicklaunch.wezterm"))

---------------------------------------------------------------
-- Config initialization
---------------------------------------------------------------

-- This table will hold the configuration.
---@class Config
local config = {}

-- In newer versions of wezterm, use the config_builder which will
-- help provide clearer error messages
if wezterm.config_builder then
	config = wezterm.config_builder()
end

---------------------------------------------------------------
-- Mux setup
---------------------------------------------------------------

config.unix_domains = {
	{
		name = "macos",
	},
}

-- This causes `wezterm` to act as though it was started as
-- `wezterm connect unix` by default, connecting to the unix
-- domain on startup.
-- If you prefer to connect manually, leave out this line.
config.default_gui_startup_args = { "connect", "macos" }

---------------------------------------------------------------
-- Plugins config
---------------------------------------------------------------

statusbar.apply_to_config(config, {
	key_tables = {
		command = {
			color = "#e06c75",
		},
		search_mode = {
			color = "#61afef",
		},
		copy_mode = {
			label = "Visual",
			color = "#e5bf7b",
		},
		resize_panel_mode = {
			label = "Resize Pane",
			icon = "󰙖",
			color = "#c678dd",
		},
		scroll_mode = {
			label = "Scroll",
			icon = "󰹯",
			color = "#7B5BD6",
		},
	},
})

quick_launch.apply_to_config(config, {
	cache = statusbar.naming_cache,
	tools = {
		editor = "/opt/homebrew/bin/nvim",
    mise = "/opt/homebrew/bin/mise",
	},
})

smart_splits.apply_to_config(config, {
	-- directional keys to use in order of: left, down, up, right
	direction_keys = { "h", "j", "k", "l" },
	-- modifier keys to combine with direction_keys
	modifiers = {
		move = "CTRL", -- modifier to use for pane movement, e.g. CTRL+h to move left
		resize = "CTRL|SHIFT", -- modifier to use for pane resize, e.g. META+h to resize to the left
	},
})

smart_splits.apply_to_config(config, {
	-- directional keys to use in order of: left, down, up, right
	direction_keys = { "LeftArrow", "DownArrow", "UpArrow", "RightArrow" },
	-- modifier keys to combine with direction_keys
	modifiers = {
		move = "CTRL", -- modifier to use for pane movement, e.g. CTRL+h to move left
		resize = "CTRL|SHIFT", -- modifier to use for pane resize, e.g. META+h to resize to the left
	},
})

---------------------------------------------------------------
-- Appearances
---------------------------------------------------------------

-- For example, changing the color scheme:
config.color_scheme = "Catppuccin Mocha"
config.colors = {
	tab_bar = {
		background = "#1E1E2E",
		active_tab = {
			bg_color = "#656A83",
			fg_color = "#FFFFFF",
			intensity = "Bold",
		},
		inactive_tab = {
			bg_color = "#282C41",
			fg_color = "#9B9FC1",
		},
		inactive_tab_hover = {
			bg_color = "#1E1E2E",
			fg_color = "#9B9FC1",
			italic = true,
		},
		new_tab = {
			bg_color = "#282C41",
			fg_color = "#9B9FC1",
		},
		new_tab_hover = {
			bg_color = "#1E1E2E",
			fg_color = "#9B9FC1",
			italic = true,
		},
	},
	--   split = '#e5bf7b',
	--   scrollbar_thumb = '#524B3E',
	--   compose_cursor = '#3D434D',
	--   cursor_bg = '#61afef',
	--   selection_fg = '#2e2619',
	--   selection_bg = '#fffacd',
	--   copy_mode_active_highlight_bg = { Color = '#D19A66' },
	--   copy_mode_active_highlight_fg = { Color = '#353B45' },
	--   copy_mode_inactive_highlight_bg = { Color = '#E5C07B' },
	--   copy_mode_inactive_highlight_fg = { Color = '#353B45' },
}

config.inactive_pane_hsb = {
	saturation = 0.9,
	brightness = 0.8,
}

config.font = wezterm.font_with_fallback({
	{
		family = "JetBrains Mono",
		harfbuzz_features = { "calt=1", "clig=1", "liga=1" },
		weight = "DemiBold",
		stretch = "Expanded",
	},
	"Symbols Nerd Font",
	"Menlo",
	"DengXian",
})
config.font_size = 19
config.line_height = 1.15

config.command_palette_rows = 25
config.command_palette_font_size = 18
config.char_select_font_size = 18

config.initial_rows = 30
config.initial_cols = 150

config.front_end = "WebGpu"

config.enable_scroll_bar = true

config.window_decorations = "RESIZE"
-- Padding
config.window_padding = {
	left = "10px",
	right = "10px",
	top = "10px",
	bottom = "0",
}
config.window_background_opacity = 0.9
config.macos_window_background_blur = 20

config.cursor_blink_ease_in = "Constant"
config.cursor_blink_ease_out = "Constant"
config.default_cursor_style = "BlinkingBar"
config.cursor_thickness = "2px"
-- config.force_reverse_video_cursor = true

---------------------------------------------------------------
-- Behavior
---------------------------------------------------------------
config.scrollback_lines = 10000
config.warn_about_missing_glyphs = false
config.adjust_window_size_when_changing_font_size = false
config.switch_to_last_active_tab_when_closing_tab = true
config.native_macos_fullscreen_mode = false
config.pane_focus_follows_mouse = true

config.hyperlink_rules = {
	-- Linkify things that look like URLs
	-- This is actually the default if you don't specify any hyperlink_rules
	{
		regex = "\\b\\w+://(?:[\\w.-]+)\\.[a-z]{2,15}\\S*\\b",
		format = "$0",
	},

	-- match the URL with a PORT
	-- such 'http://localhost:3000/index.html'
	{
		regex = "\\b\\w+://(?:[\\w.-]+):\\d+\\S*\\b",
		format = "$0",
	},

	-- linkify email addresses
	{
		regex = "\\b\\w+@[\\w-]+(\\.[\\w-]+)+\\b",
		format = "mailto:$0",
	},

	-- file:// URI
	{
		regex = "\\bfile://\\S*\\b",
		format = "$0",
	},
}

wezterm.on("window-config-reloaded", function(window, _)
	window:toast_notification("wezterm", "Configuration reloaded!", nil, 4000)
end)

---------------------------------------------------------------
-- Key bindings
---------------------------------------------------------------

local function map_mouse(cfg, bindings)
	if not cfg["mouse_bindings"] then
		cfg.mouse_bindings = {}
	end
	for _, binding in ipairs(bindings) do
		table.insert(cfg.mouse_bindings, binding)
	end
end

local function map_keys(cfg, bindings)
	if not cfg["keys"] then
		cfg.keys = {}
	end
	for _, binding in ipairs(bindings) do
		table.insert(cfg.keys, binding)
	end
end

local function map_key_tables(cfg, table_name, bindings)
	if not cfg["key_tables"] then
		cfg.key_tables = {}
	end
	if not cfg.key_tables[table_name] then
		cfg.key_tables[table_name] = {}
	end
	for _, binding in ipairs(bindings) do
		table.insert(cfg.key_tables[table_name], binding)
	end
end

config.quick_select_alphabet = "colemak"
config.leader = { key = "w", mods = "ALT", timeout_milliseconds = 2000 }

-- Open URLs with CMD + Click
map_mouse(config, {
	-- Disable the default click behavior
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = "NONE",
		action = wezterm.action.CopyTo("Clipboard"),
	},
	-- Open URLs with CMD+Click
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = "CMD",
		action = wezterm.action.OpenLinkAtMouseCursor,
	},
	-- Disable the CMD-click down event to stop programs from seeing it when a URL is clicked
	{
		event = { Down = { streak = 1, button = "Left" } },
		mods = "CMD",
		action = wezterm.action.Nop,
	},
})

map_keys(config, {
	-- Vim-like binding: Horizontal split
	{
		mods = "LEADER",
		key = "v",
		action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }),
	},
	-- Vim-like binding: Vertical split
	{
		mods = "LEADER",
		key = "s",
		action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }),
	},
	-- Resize pane mode
	{
		mods = "LEADER",
		key = "r",
		action = wezterm.action.ActivateKeyTable({
			name = "resize_panel_mode",
			one_shot = false,
			timeout_milliseconds = 5000,
		}),
	},
	-- Rename current tab
	{
		mods = "LEADER",
		key = "n",
		action = wezterm.action.PromptInputLine({
			description = wezterm.format({
				{ Attribute = { Intensity = "Bold" } },
				{ Foreground = { Color = "#3FB1F5" } },
				{ Text = "Tab name" },
			}),
			prompt = "❯ ", -- Use thig when Wezterm nightly is merged to mainline
			action = wezterm.action_callback(function(window, _, line)
				if line then
					window:active_tab():set_title(line)
				end
			end),
		}),
	},
	-- Show built-in workspaces selector
	{
		mods = "LEADER",
		key = "W",
		action = wezterm.action.ShowLauncherArgs({
			title = "Workspaces",
			flags = "WORKSPACES",
		}),
	},
	-- Rename current workspace
	{
		mods = "LEADER",
		key = "w",
		action = wezterm.action.PromptInputLine({
			description = wezterm.format({
				{ Attribute = { Intensity = "Bold" } },
				{ Foreground = { Color = "#3FB1F5" } },
				{ Text = "Current workspace name" },
			}),
			prompt = "❯ ", -- Use thig when Wezterm nightly is merged to mainline
			action = wezterm.action_callback(function(_, _, line)
				if line then
					wezterm.mux.rename_workspace(wezterm.mux.get_active_workspace(), line)
				end
			end),
		}),
	},
	-- Go to a pane (prompt to which one)
	{
		mods = "LEADER",
		key = "g",
		action = wezterm.action.PaneSelect,
	},
	-- Use LEADER+x swap the active pane and another one
	{
		mods = "LEADER",
		key = "x",
		action = wezterm.action({
			PaneSelect = { mode = "SwapWithActiveKeepFocus" },
		}),
	},
	-- Use LEADER+z to enter zoom state
	{
		mods = "LEADER",
		key = "z",
		action = wezterm.action.TogglePaneZoomState,
	},
	-- LEADER-d activates the debug overlay
	{
		mods = "LEADER",
		key = "d",
		action = wezterm.action.ShowDebugOverlay,
	},
	-- LEADER-p activates the command palette
  {
      mods = "LEADER",
      key = "p",
      action = wezterm.action.ActivateCommandPalette,
  },
	-- Show tab navigator
	{
		mods = "LEADER",
		key = "t",
		action = wezterm.action.ShowTabNavigator,
	},
	{
		mods = "LEADER",
		key = "l",
		action = wezterm.action.ActivateKeyTable({
			name = "scroll_mode",
			one_shot = false,
			prevent_fallback = true,
		}),
	},

	-- MacOS App Settings
	{
		mods = "CMD",
		key = ",",
		action = quick_launch.action.OpenTab("wezterm-config"),
	},
	-- Show launcher menu
	{
		mods = "CMD|SHIFT",
		key = "T",
		action = quick_launch.action.OpenTab(),
	},
	-- Show launcher menu
	{
		mods = "CMD|SHIFT",
		key = "S",
		action = quick_launch.action.OpenPane(),
	},
	-- Show launcher menu
	{
		mods = "CMD|SHIFT",
		key = "P",
		action = quick_launch.action.OpenWorkspace(),
	},
	-- Move to another pane (next or previous)
	{
		mods = "CMD",
		key = "[",
		action = wezterm.action.ActivatePaneDirection("Prev"),
	},

	{
		mods = "CMD",
		key = "]",
		action = wezterm.action.ActivatePaneDirection("Next"),
	},
	-- Move to another tab (next or previous)
	{
		mods = "CMD|SHIFT",
		key = "{",
		action = wezterm.action.ActivateTabRelative(-1),
	},
	{
		mods = "CMD|SHIFT",
		key = "}",
		action = wezterm.action.ActivateTabRelative(1),
	},
	-- Use CMD+w to close the pane, CMD+SHIFT+w to close the tab
	{
		mods = "CMD",
		key = "w",
		action = wezterm.action.CloseCurrentPane({ confirm = true }),
	},
	{
		mods = "CMD|SHIFT",
		key = "w",
		action = wezterm.action.CloseCurrentTab({ confirm = true }),
	},
	{
		mods = "CMD|SHIFT|META",
		key = "w",
		action = quick_launch.action.CloseWorkspace(),
	},
	{
		mods = "CMD",
		key = "f",
		action = wezterm.action.Search("CurrentSelectionOrEmptyString"),
	},
	{
		mods = "CTRL|SHIFT",
		key = "f",
		action = wezterm.action.DisableDefaultAssignment,
	},
	{ key = "UpArrow", mods = "META|SHIFT", action = wezterm.action.ScrollToPrompt(-1) },
	{ key = "DownArrow", mods = "META|SHIFT", action = wezterm.action.ScrollToPrompt(1) },
})

-- Defines the keys that are active in our resize-pane mode.
-- Since we're likely to want to make multiple adjustments,
-- we made the activation one_shot=false. We therefore need
-- to define a key assignment for getting out of this mode.
-- 'resize_pane' here corresponds to the name="resize_pane" in
-- the key assignments above.
map_key_tables(config, "resize_panel_mode", {
	{ key = "LeftArrow", action = wezterm.action.AdjustPaneSize({ "Left", 1 }) },
	{ key = "h", action = wezterm.action.AdjustPaneSize({ "Left", 1 }) },

	{ key = "RightArrow", action = wezterm.action.AdjustPaneSize({ "Right", 1 }) },
	{ key = "l", action = wezterm.action.AdjustPaneSize({ "Right", 1 }) },

	{ key = "UpArrow", action = wezterm.action.AdjustPaneSize({ "Up", 1 }) },
	{ key = "k", action = wezterm.action.AdjustPaneSize({ "Up", 1 }) },

	{ key = "DownArrow", action = wezterm.action.AdjustPaneSize({ "Down", 1 }) },
	{ key = "j", action = wezterm.action.AdjustPaneSize({ "Down", 1 }) },

	-- Cancel the mode by pressing escape
	{ key = "Escape", action = "PopKeyTable" },
})

map_key_tables(config, "scroll_mode", {
	-- Cancel all modes by pressing Escape or Ctrl+C
	{
		key = "Escape",
		action = wezterm.action.Multiple({
			wezterm.action.ClearKeyTableStack,
			wezterm.action.ScrollToBottom,
		}),
	},
	{
		key = "c",
		mods = "CTRL",
		action = wezterm.action.Multiple({
			wezterm.action.ClearKeyTableStack,
			wezterm.action.ScrollToBottom,
		}),
	},
	-- Cancel the mode by pressing 'q'
	{
		key = "q",
		action = wezterm.action.Multiple({
			wezterm.action.PopKeyTable,
			wezterm.action.ScrollToBottom,
		}),
	},

	{ key = "UpArrow", action = wezterm.action.ScrollByLine(-1) },
	{ key = "DownArrow", action = wezterm.action.ScrollByLine(1) },
	{ key = "k", action = wezterm.action.ScrollByLine(-1) },
	{ key = "j", action = wezterm.action.ScrollByLine(1) },
	{ key = "y", mods = "CTRL", action = wezterm.action.ScrollByLine(-1) },
	{ key = "e", mods = "CTRL", action = wezterm.action.ScrollByLine(1) },

	{ key = "UpArrow", mods = "SHIFT", action = wezterm.action.ScrollByLine(-5) },
	{ key = "DownArrow", mods = "SHIFT", action = wezterm.action.ScrollByLine(5) },
	{ key = "K", mods = "SHIFT", action = wezterm.action.ScrollByLine(-5) },
	{ key = "J", mods = "SHIFT", action = wezterm.action.ScrollByLine(5) },

	{ key = "u", action = wezterm.action.ScrollByPage(-0.5) },
	{ key = "d", action = wezterm.action.ScrollByPage(0.5) },
	{ key = "b", action = wezterm.action.ScrollByPage(-1) },
	{ key = "f", action = wezterm.action.ScrollByPage(1) },

	{ key = "u", mods = "CTRL", action = wezterm.action.ScrollByPage(-0.5) },
	{ key = "d", mods = "CTRL", action = wezterm.action.ScrollByPage(0.5) },
	{ key = "b", mods = "CTRL", action = wezterm.action.ScrollByPage(-1) },
	{ key = "f", mods = "CTRL", action = wezterm.action.ScrollByPage(1) },

	{ key = "p", action = wezterm.action.ScrollToPrompt(-1) },
	{ key = "n", action = wezterm.action.ScrollToPrompt(1) },
	{ key = "{", action = wezterm.action.ScrollToPrompt(-1) },
	{ key = "}", action = wezterm.action.ScrollToPrompt(1) },

	{ key = "g", action = wezterm.action.ScrollToTop },
	{ key = "G", mods = "SHIFT", action = wezterm.action.ScrollToBottom },

	{ key = "z", action = wezterm.action.TogglePaneZoomState },

	{
		key = "v",
		action = wezterm.action.Multiple({
			wezterm.action.PopKeyTable,
			wezterm.action.ActivateCopyMode,
		}),
	},
	{
		key = "/",
		action = wezterm.action.Multiple({
			wezterm.action.ClearKeyTableStack,
			wezterm.action.Search("CurrentSelectionOrEmptyString"),
		}),
	},
})

for i = 1, 9 do
	-- leader + number to activate that tab
	table.insert(config.keys, {
		key = tostring(i),
		mods = "LEADER",
		action = wezterm.action.ActivateTab(i),
	})
end

-- and finally, return the configuration to wezterm
return config
