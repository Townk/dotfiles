-- Pull in the wezterm API

---@diagnostic disable:assign-type-mismatch
---@type Wezterm
local wezterm = require("wezterm")

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
	"Apple Color Emoji",
	"Menlo",
	"DengXian",
})
config.font_size = 19
config.line_height = 1.15

config.command_palette_rows = 25
config.command_palette_font_size = 18
config.char_select_font_size = 18
config.use_cap_height_to_scale_fallback_fonts = true
config.unicode_version = 4

config.initial_rows = 30
config.initial_cols = 130

config.front_end = "WebGpu"

config.enable_scroll_bar = false

config.window_decorations = "RESIZE"
-- Padding
config.window_padding = {
	left = "10px",
	right = "10px",
	top = "10px",
	bottom = "0",
}
config.use_resize_increments = true
config.window_background_opacity = 1.0
config.enable_tab_bar = false

config.cursor_blink_ease_in = "Constant"
config.cursor_blink_ease_out = "Constant"
config.default_cursor_style = "BlinkingBar"
config.cursor_thickness = "2px"

---------------------------------------------------------------
-- Behavior
---------------------------------------------------------------
config.default_domain = "local"
config.scrollback_lines = 10000
config.warn_about_missing_glyphs = false
config.adjust_window_size_when_changing_font_size = false
config.switch_to_last_active_tab_when_closing_tab = true
config.native_macos_fullscreen_mode = false
config.pane_focus_follows_mouse = true
config.send_composed_key_when_left_alt_is_pressed = false
config.send_composed_key_when_right_alt_is_pressed = false
config.enable_kitty_keyboard = true
config.status_update_interval = 250

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

local toggle_fullscreen_workspace = "__TOGGLE_FULLSCREEN__"
local ok, active_workspace = pcall(wezterm.mux.get_active_workspace)
local last_real_workspace = nil
if ok and active_workspace ~= "" and active_workspace ~= toggle_fullscreen_workspace then
	last_real_workspace = active_workspace
end

wezterm.on("update-status", function(window, pane)
	local workspace = window:active_workspace()
	if workspace == toggle_fullscreen_workspace then
		window:toggle_fullscreen()
		pcall(wezterm.mux.rename_workspace, toggle_fullscreen_workspace, last_real_workspace or "default")
		return
	end

	if workspace ~= "" then
		last_real_workspace = workspace
	end
end)

local function send_zellij_keys(keys)
	return wezterm.action_callback(function(window, pane)
		for i, key in ipairs(keys) do
			local action = wezterm.action.SendKey(key)
			if i == 1 then
				window:perform_action(action, pane)
			else
				wezterm.time.call_after((i - 1) * 0.02, function()
					window:perform_action(action, pane)
				end)
			end
		end
	end)
end

---------------------------------------------------------------
-- Key bindings
---------------------------------------------------------------

-- Ensure no leader key is defined
config.leader = nil

config.keys = {
	-- Disabled standard keys
	{
		key = "u",
		mods = "CTRL|SHIFT",
		action = wezterm.action.DisableDefaultAssignment,
	},
	{
		key = "p",
		mods = "CTRL|SHIFT",
		action = wezterm.action.DisableDefaultAssignment,
	},
	{
		key = "Enter",
		mods = "ALT",
		action = wezterm.action.DisableDefaultAssignment,
	},
	-- `⌘,`: Open terminal emulator config file => `⌥w ,`
	{
		key = ",",
		mods = "CMD",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "," },
		}),
	},
	-- `⌘r` reloads the WezTerm configuration
	{
		key = "r",
		mods = "CMD",
		action = wezterm.action.ReloadConfiguration,
	},
	-- `⌘W`: Close current pane => `⌥w p x`
	{
		key = "w",
		mods = "CMD",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "p" },
			{ key = "x" },
		}),
	},
	-- `⇧⌘W`: Close current tab => `⌥w t x`
	{
		key = "w",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "t" },
			{ key = "x" },
		}),
	},
	-- `⌘↑`: Scroll back-buffer one line up => `⌥w l ↑`
	{
		key = "UpArrow",
		mods = "CMD",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "l" },
			{ key = "UpArrow" },
		}),
	},
	-- `⌘↓`: Scroll back-buffer one line down => `⌥w l ↓`
	{
		key = "DownArrow",
		mods = "CMD",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "l" },
			{ key = "DownArrow" },
		}),
	},
	-- `⌘k`: Scroll back-buffer one line up => `⌥w l k`
	{
		key = "k",
		mods = "CMD",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "l" },
			{ key = "k" },
		}),
	},
	-- `⌘j`: Scroll back-buffer one line down => `⌥w l j`
	{
		key = "j",
		mods = "CMD",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "l" },
			{ key = "j" },
		}),
	},
	-- `⇧⌘↑`: Scroll back-buffer back to previous prompt => `⌥w l p`
	{
		key = "UpArrow",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "l" },
			{ key = "p" },
		}),
	},
	-- `⇧⌘↓`: Scroll back-buffer forward to next prompt => `⌥w l n`
	{
		key = "DownArrow",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "l" },
			{ key = "n" },
		}),
	},
	-- `⇧⌘k`: Scroll back-buffer back to previous prompt => `⌥w l p`
	{
		key = "k",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "l" },
			{ key = "p" },
		}),
	},
	-- `⇧⌘j`: Scroll back-buffer forward to next prompt => `⌥w l n`
	{
		key = "j",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "l" },
			{ key = "n" },
		}),
	},
	-- `⌘f`: Start search mode on back-buffer => `⌥/`
	{
		key = "f",
		mods = "CMD",
		action = send_zellij_keys({
			{ key = "/", mods = "ALT" },
		}),
	},
	-- `⇧⌘f`: Edit back-buffer on configured editor => `⌥w l V`
	{
		key = "f",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "l" },
			{ key = "V" },
		}),
	},
	-- `⇧⌘c`: Copy current working directory to clipboard => `⌥w Y`
	{
		key = "c",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "Y" },
		}),
	},
	-- `⇧⌘⌥c`: Copy absolute path of current working directory to clipboard => `⌥w ⌥y`
	{
		key = "c",
		mods = "CMD|SHIFT|ALT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "y", mods = "ALT" },
		}),
	},
	-- `⌘t`: New tab => `⌥w t N`
	{
		key = "t",
		mods = "CMD",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "t" },
			{ key = "N" },
		}),
	},
	-- `⌘1`: Focus on tab 1 => `⌥w t 1`
	{
		key = "1",
		mods = "CMD",
		action = send_zellij_keys({ { key = "w", mods = "ALT" }, { key = "t" }, { key = "1" } }),
	},
	-- `⌘2`: Focus on tab 2 => `⌥w t 2`
	{
		key = "2",
		mods = "CMD",
		action = send_zellij_keys({ { key = "w", mods = "ALT" }, { key = "t" }, { key = "2" } }),
	},
	-- `⌘3`: Focus on tab 3 => `⌥w t 3`
	{
		key = "3",
		mods = "CMD",
		action = send_zellij_keys({ { key = "w", mods = "ALT" }, { key = "t" }, { key = "3" } }),
	},
	-- `⌘4`: Focus on tab 4 => `⌥w t 4`
	{
		key = "4",
		mods = "CMD",
		action = send_zellij_keys({ { key = "w", mods = "ALT" }, { key = "t" }, { key = "4" } }),
	},
	-- `⌘5`: Focus on tab 5 => `⌥w t 5`
	{
		key = "5",
		mods = "CMD",
		action = send_zellij_keys({ { key = "w", mods = "ALT" }, { key = "t" }, { key = "5" } }),
	},
	-- `⌘6`: Focus on tab 6 => `⌥w t 6`
	{
		key = "6",
		mods = "CMD",
		action = send_zellij_keys({ { key = "w", mods = "ALT" }, { key = "t" }, { key = "6" } }),
	},
	-- `⌘7`: Focus on tab 7 => `⌥w t 7`
	{
		key = "7",
		mods = "CMD",
		action = send_zellij_keys({ { key = "w", mods = "ALT" }, { key = "t" }, { key = "7" } }),
	},
	-- `⌘8`: Focus on tab 8 => `⌥w t 8`
	{
		key = "8",
		mods = "CMD",
		action = send_zellij_keys({ { key = "w", mods = "ALT" }, { key = "t" }, { key = "8" } }),
	},
	-- `⌘9`: Focus on tab 9 => `⌥w t 9`
	{
		key = "9",
		mods = "CMD",
		action = send_zellij_keys({ { key = "w", mods = "ALT" }, { key = "t" }, { key = "9" } }),
	},
	-- `⌘⇧P`: Show Project picker => `⌥w o S`
	{
		key = "p",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "o" },
			{ key = "S" },
		}),
	},
	-- `⌘⇧T`: Show new tab picker => `⌥w t T`
	{
		key = "t",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "t" },
			{ key = "T" },
		}),
	},
	-- `⌘⇧S`: Show new tab picker => `⌥w p P`
	{
		key = "s",
		mods = "CMD|SHIFT",
		action = send_zellij_keys({
			{ key = "w", mods = "ALT" },
			{ key = "p" },
			{ key = "P" },
		}),
	},
}

-- Add a mouse binding to pass clicks directly to Zellij
config.mouse_bindings = {
	-- This forces a left-click to bypass WezTerm and go straight to the terminal/Zellij
	{
		event = { Down = { streak = 1, button = "Left" } },
		mods = "NONE",
		action = wezterm.action.Nop,
	},
	-- This forces a right-click to bypass WezTerm and go straight to the terminal/Zellij
	{
		event = { Down = { streak = 1, button = "Right" } },
		mods = "NONE",
		action = wezterm.action.Nop,
	},
	-- This forces a middle-click to bypass WezTerm and go straight to the terminal/Zellij
	{
		event = { Down = { streak = 1, button = "Middle" } },
		mods = "NONE",
		action = wezterm.action.Nop,
	},
}

-- and finally, return the configuration to wezterm
return config
