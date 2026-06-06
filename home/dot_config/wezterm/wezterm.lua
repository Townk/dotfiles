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
	-- Propo (variable-width) variant: icon sizing/centering is baked into the
	-- font (build step 7b normalizes every icon to the curated md/oct box), so
	-- no WezTerm-side overflow clamp is needed — the only spill is harmless
	-- horizontal right-overflow.
	"Symbols Nerd Font",
	-- Emoji-presentation codepoints (🚀, VS16 sequences) resolve here:
	-- WezTerm's first shaping pass matches Apple Color Emoji as the
	-- emoji-presentation font.
	"Apple Color Emoji",
	-- Text-default emoji (♻ ✏ ❤ — Emoji_Presentation=No). WezTerm's first
	-- pass looks for a *text*-presentation font that has the glyph; without
	-- this entry it lands on Menlo below and paints them monochrome. Listing
	-- Apple Color Emoji again as a text-presentation font, ahead of Menlo,
	-- routes those to the colour Apple glyph too. Genuine symbols that
	-- Symbols Nerd Font carries (e.g. ⌘) still win — it's earlier, and the
	-- emoji codepoints were stripped from it at build time. (WezTerm has no
	-- per-codepoint font map, so this presentation override is the lever.)
	{ family = "Apple Color Emoji", assume_emoji_presentation = false },
	-- Menlo: kept as the broad text fallback — it uniquely carries ~177
	-- glyphs none of the fonts below have (Georgian Mtavruli, modifier
	-- letters, some Latin extended).
	"Menlo",
	-- Broad-coverage fillers for the glyph picker (symbols.db). WezTerm uses
	-- the FIRST fallback that has the glyph, so these sit after the curated
	-- fonts above (Nerd Font / emoji still win) with the universal Arial
	-- Unicode MS last. (Replaces the old "DengXian" entry, which wasn't
	-- installed and silently resolved to Helvetica — the reason CJK/Bopomofo
	-- rendered as tofu.)
	"Apple Symbols", -- technical / runic / misc symbols
	"STIX Two Math", -- 𝐀 math alphanumerics (bold/italic/script/fraktur/…)
	"Songti SC", -- CJK, Bopomofo, CJK/Kangxi radicals (DengXian replacement)
	"Euphemia UCAS", -- Canadian Aboriginal Syllabics
	"Hiragino Sans", -- Japanese kana extras
	"Noto Music", -- musical + Byzantine musical symbols (via font-noto-music)
	"Noto Sans Symbols 2", -- misc pictographic symbols
	"Noto Sans Math", -- remaining mathematical symbols
	"Arial Unicode MS", -- universal catch-all
	-- Iosevka: final backstop for the Unicode 16 "Symbols for Legacy Computing"
	-- box-drawings / circle fragments (1FBD0–1FBEF) that WezTerm doesn't draw
	-- natively and nothing earlier here covers. Last, so it only fills gaps
	-- (the 1FBCB cross-mark / 1FBCD chevron remain uncovered — Iosevka lacks
	-- those two; they stay dropped from the picker).
	"Iosevka",
})
config.font_size = 19
config.line_height = 1.15

config.command_palette_rows = 25
config.command_palette_font_size = 18
config.char_select_font_size = 18
config.unicode_version = 17

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

-- CMD+click on a file:// link inside Zellij opens it locally: directories in a
-- Yazi tab, images in a floating preview pane, text/code in an nvim tab (see
-- ~/.config/zellij/scripts/zellij-open). The clicked pane's foreground process is the Zellij
-- client; zellij-open resolves which session it's attached to and dispatches
-- there. Non-file links (and panes not running Zellij) fall through to WezTerm's
-- default open. Requires `osc8_hyperlinks true` in the Zellij config so file://
-- links survive to WezTerm.
wezterm.on("open-uri", function(_, pane, uri)
	if not uri:find("^file://") then
		return true
	end
	local info = pane and pane:get_foreground_process_info()
	local exe = info and info.argv and info.argv[1] or ""
	if not exe:find("zellij") then
		return true
	end
	local dims = pane:get_dimensions()
	wezterm.background_child_process({
		os.getenv("HOME") .. "/.config/zellij/scripts/zellij-open",
		tostring(info.pid),
		uri,
		tostring(dims and dims.cols or 0),
		tostring(dims and dims.viewport_rows or 0),
	})
	return false
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

-- Mouse bindings. Left/right clicks are intentionally left to WezTerm's
-- defaults: when Zellij has mouse reporting on, WezTerm forwards them to Zellij
-- automatically, and when it's off (scrollback, bare shell) the defaults give
-- native text selection plus the SHIFT+drag selection escape hatch.
config.mouse_bindings = {
	-- Middle-click pastes the system clipboard (select-to-copy fills it: pbcopy
	-- locally, OSC 52 → WezTerm from a remote Zellij over ssh). Injects the bytes
	-- into the focused pane, so it works through ssh too.
	--
	-- Zellij keeps SGR mouse reporting on, so WezTerm normally forwards the
	-- middle-click straight to Zellij and never matches this assignment. The
	-- `mouse_reporting = true` entry is what lets the paste fire while the app is
	-- capturing the mouse; the second entry covers panes where reporting is off
	-- (bare shell, scrollback). See https://wezterm.org/config/mouse.html.
	{
		event = { Down = { streak = 1, button = "Middle" } },
		mods = "NONE",
		mouse_reporting = true,
		action = wezterm.action.PasteFrom("Clipboard"),
	},
	{
		event = { Down = { streak = 1, button = "Middle" } },
		mods = "NONE",
		action = wezterm.action.PasteFrom("Clipboard"),
	},
	-- CMD+click opens the URL under the cursor. Same Zellij problem as the paste
	-- above: with mouse reporting on, the click goes to Zellij and WezTerm never
	-- sees it, so opening a link otherwise needs the SHIFT bypass. The
	-- `mouse_reporting = true` Up entry lets a plain CMD+click open the link while
	-- Zellij captures the mouse; the matching Down entry is Nop'd so Zellij never
	-- receives a stray CMD+down (the "bind Up only" gotcha in the WezTerm docs).
	-- The last entry covers panes where reporting is off (bare shell, scrollback).
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = "CMD",
		mouse_reporting = true,
		action = wezterm.action.OpenLinkAtMouseCursor,
	},
	{
		event = { Down = { streak = 1, button = "Left" } },
		mods = "CMD",
		mouse_reporting = true,
		action = wezterm.action.Nop,
	},
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = "CMD",
		action = wezterm.action.OpenLinkAtMouseCursor,
	},
}

-- and finally, return the configuration to wezterm
return config
