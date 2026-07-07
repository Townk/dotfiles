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
-- SSH agent: don't let wezterm hijack SSH_AUTH_SOCK
---------------------------------------------------------------
-- wezterm's multiplexer is always present (the GUI is a mux client; it
-- can't be turned off), and `mux_enable_ssh_agent` defaults to true.
-- That makes wezterm point SSH_AUTH_SOCK at a wezterm-managed symlink
-- (~/.local/share/wezterm/agent.<pid>) which tracks the most recently
-- active mux client. When that client exits the symlink goes stale and
-- ssh from detached/non-interactive shells breaks — seen reaching a
-- remote dev shell behind an SSH-certificate auth agent ("can't verify
-- ssh certificate" against a dead socket). Disabling it leaves
-- SSH_AUTH_SOCK untouched, so panes inherit the launchd/system agent the
-- GUI was started with — the same one the cert/secrets agents (and
-- 1Password) register their keys with.
config.mux_enable_ssh_agent = false

---------------------------------------------------------------
-- Appearances
---------------------------------------------------------------

-- `chezmoi-system` is generated from .chezmoidata/theme.yaml into
-- ~/.config/wezterm/colors/chezmoi-system.toml (a byte-faithful copy of wezterm's
-- built-in Catppuccin Mocha). The SSH-tint logic below overrides
-- colors.background per window on top of it.
config.color_scheme = "chezmoi-system"
-- tab_bar colors come from the single-source palette
-- (~/.config/theme/chezmoi-system.lua, generated from .chezmoidata/theme.yaml): base +
-- the extended.tab chrome. Loaded at config time; the literal fallbacks (the
-- current Mocha values) keep wezterm working if the bridge is ever missing.
local function load_palette()
	local ok, t = pcall(dofile, os.getenv("HOME") .. "/.config/theme/chezmoi-system.lua")
	if ok and type(t) == "table" and t.palette then
		return t
	end
	return nil
end
local theme = load_palette()
local pal = (theme and theme.palette) or {}
local tab = (theme and theme.extended and theme.extended.tab) or {}
config.colors = {
	tab_bar = {
		background = pal.base or "#1E1E2E",
		active_tab = {
			bg_color = tab.active_bg or "#656A83",
			fg_color = tab.active_fg or "#FFFFFF",
			intensity = "Bold",
		},
		inactive_tab = {
			bg_color = tab.bg or "#282C41",
			fg_color = tab.fg or "#9B9FC1",
		},
		inactive_tab_hover = {
			bg_color = pal.base or "#1E1E2E",
			fg_color = tab.fg or "#9B9FC1",
			italic = true,
		},
		new_tab = {
			bg_color = tab.bg or "#282C41",
			fg_color = tab.fg or "#9B9FC1",
		},
		new_tab_hover = {
			bg_color = pal.base or "#1E1E2E",
			fg_color = tab.fg or "#9B9FC1",
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
	-- Remaining broad-coverage fillers for the glyph picker (symbols.db).
	-- STIX/Noto donor rows are baked into Symbols Nerd Font; keep only the
	-- runtime fallbacks that still provide broad platform/script coverage.
	-- WezTerm uses the FIRST fallback that has the glyph, so these sit after
	-- the curated fonts above (Nerd Font / emoji still win) with the universal
	-- Arial Unicode MS last.
	"Apple Symbols", -- technical / runic / misc symbols
	"Songti SC", -- CJK, Bopomofo, CJK/Kangxi radicals (DengXian replacement)
	"Euphemia UCAS", -- Canadian Aboriginal Syllabics
	"Hiragino Sans", -- Japanese kana extras
	"Arial Unicode MS", -- universal catch-all
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

-- Named background-tint palette (name -> hex), applied per-window via
-- set_config_overrides in update-status. resolve-terminal-location returns one
-- of these NAMES (or "local" for no tint) from the session's ssh target: a
-- machine's explicit `color` in system-onboard's map, else its profile default,
-- else grey (see lib/terminal-location.zsh). We tint colors.background (not
-- window_background_gradient) so the shift shows behind terminal cells.
--
-- The palette is the SINGLE SOURCE OF TRUTH in tint-palette.toml, shared with
-- system-onboard's color set/list/validate. Parsed with a simple line matcher
-- (flat `name = "#hex"`) — no serde dependency — and falls back to a built-in
-- default if the file is missing/empty so WezTerm never breaks.
local function load_tint_palette()
	local default = {
		cyan = "#1c232f",
		blue = "#1d1f33",
		amber = "#2a241f",
		teal = "#16302b",
		purple = "#241c30",
		grey = "#2a2a32",
	}
	local file = io.open(os.getenv("HOME") .. "/.config/wezterm/tint-palette.toml", "r")
	if not file then
		return default
	end
	local palette = {}
	for line in file:lines() do
		local name, hex = line:match('^%s*([%w_-]+)%s*=%s*"(#%x+)"')
		if name and hex then
			palette[name] = hex
		end
	end
	file:close()
	if next(palette) == nil then
		return default
	end
	return palette
end

local terminal_tint_palette = load_tint_palette()

local resolve_terminal_location_helper =
	os.getenv("HOME") .. "/.config/zellij/scripts/resolve-terminal-location"

local function colors_equal(a, b)
	return a == b
end

local function background_override(overrides)
	return overrides.colors and overrides.colors.background
end

local function set_background_override(overrides, bg)
	if bg == nil then
		if overrides.colors then
			overrides.colors.background = nil
			if next(overrides.colors) == nil then
				overrides.colors = nil
			end
		end
		return
	end
	overrides.colors = overrides.colors or {}
	overrides.colors.background = bg
end

-- Dim the whole window's text when it loses focus — the window-wide analog of
-- config.inactive_pane_hsb (which only dims inactive panes *within* the focused
-- window). foreground_text_hsb.brightness scales all glyph brightness; we set it
-- to DIM_BRIGHTNESS on blur and clear it on focus. It's a separate override key
-- from the SSH colors.background tint, and both paths read-merge-write the same
-- overrides table (see apply_terminal_location_tint), so they compose without
-- clobbering each other. Idempotent: only calls set_config_overrides on an
-- actual state change, so the 250ms update-status tick stays cheap.
local DIM_BRIGHTNESS = 0.5

local function apply_focus_dim(window)
	local overrides = window:get_config_overrides() or {}
	local current = overrides.foreground_text_hsb
	if window:is_focused() then
		if current == nil then
			return
		end
		overrides.foreground_text_hsb = nil
	else
		if current and current.brightness == DIM_BRIGHTNESS then
			return
		end
		overrides.foreground_text_hsb = { hue = 1.0, saturation = 1.0, brightness = DIM_BRIGHTNESS }
	end
	window:set_config_overrides(overrides)
end

-- The location resolver is resolved ASYNCHRONOUSLY. It used to run inline via
-- wezterm.run_child_process, which is synchronous: the helper cold-spawns a zsh
-- and sources libs (~250ms; more for ssh panes), and update-status co-fires on
-- every window-focus change. That blocked the render thread on the focus tick —
-- invisible while it only gated the rarely-changing tint, but the focus-dim
-- below makes every focus switch a *visible* change, so the block surfaced as
-- dim lag. Now update-status never spawns inline: it reads the last resolved
-- value from a tiny per-pane cache file (cheap io) and kicks a background
-- refresh at most every LOC_TTL seconds. The tint lands at most one 250ms tick
-- after a cold resolve; the focus-dim repaints instantly.
local location_state_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state"))
	.. "/wezterm/loc-cache"
wezterm.background_child_process({ "mkdir", "-p", location_state_dir })

local LOC_TTL = 2 -- seconds between background refreshes per pane

-- Per-pane in-memory cache: key -> { location, spawned_at }. A plain Lua upvalue
-- (NOT wezterm.GLOBAL, which serializes stored values and mangles the timestamp
-- into a string), keyed by window:pane.
local terminal_location_cache = {}

local function location_cache_file(key)
	return location_state_dir .. "/" .. key:gsub("[^%w]", "_")
end

local function read_location_file(key)
	local file = io.open(location_cache_file(key), "r")
	if not file then
		return nil
	end
	local contents = file:read("*a") or ""
	file:close()
	local loc = contents:match("(%S+)")
	if loc and loc ~= "" then
		return loc
	end
	return nil
end

-- Fire-and-forget the helper, writing its stdout atomically (tmp + mv) to the
-- pane's cache file. Never blocks the caller. Paths here (helper under $HOME,
-- cache under the state dir) contain no shell metacharacters; pid is an integer.
local function spawn_location_refresh(key, pid)
	local file = location_cache_file(key)
	local cmd = string.format(
		"'%s' %d > '%s.tmp' 2>/dev/null && mv '%s.tmp' '%s'",
		resolve_terminal_location_helper,
		pid,
		file,
		file,
		file
	)
	wezterm.background_child_process({ "/bin/sh", "-c", cmd })
end

local function resolve_terminal_location_cached(window, pane)
	local key = tostring(window:window_id()) .. ":" .. tostring(pane:pane_id())
	local now = os.time()
	local existing = terminal_location_cache[key]
	local entry = existing or { location = "local", spawned_at = 0 }

	-- Pick up the freshest async result once we've spawned at least one refresh
	-- for this pane. Skipping the read on first sight avoids trusting a stale
	-- cache file left by a prior session that reused this pane id.
	if existing then
		local fresh = read_location_file(key)
		if fresh then
			entry.location = fresh
		end
	end

	if (now - entry.spawned_at) >= LOC_TTL then
		local info = pane:get_foreground_process_info()
		if info then
			spawn_location_refresh(key, info.pid)
			entry.spawned_at = now
		end
	end

	terminal_location_cache[key] = entry
	return entry.location
end

local function apply_terminal_location_tint(window, pane)
	local location = resolve_terminal_location_cached(window, pane)
	local overrides = window:get_config_overrides() or {}
	local desired = nil
	if location ~= "local" then
		desired = terminal_tint_palette[location] or terminal_tint_palette.grey
	end

	local current = background_override(overrides)
	if location == "local" then
		if current == nil then
			return
		end
		set_background_override(overrides, nil)
	else
		if colors_equal(current, desired) then
			return
		end
		set_background_override(overrides, desired)
	end
	window:set_config_overrides(overrides)
end

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

local write_fullscreen_state

-- `window-config-reloaded` fires on *every* config evaluation, including the
-- initial one as each window is created — which previously toasted on every new
-- window. We only want feedback when the config genuinely changed after a window
-- was already open. So snapshot the config file's bytes in wezterm.GLOBAL (which
-- persists across reloads, and is shared by every window/eval context in the GUI
-- process) and notify only when the snapshot differs from what we last saw. The
-- first evaluation of a fresh GUI process seeds the snapshot silently, so opening
-- windows stays quiet; an edit (auto-reload) or a manual reload after an edit
-- changes the bytes and fires exactly one notification — deduped across the
-- multiple windows/contexts that reload together — through our Hammerspoon OSD.
local notify_bin = os.getenv("HOME") .. "/.local/bin/notify"

local function read_config_signature()
	local file = io.open(wezterm.config_file, "r")
	if not file then
		return nil
	end
	local contents = file:read("*a")
	file:close()
	return contents
end

local function notify_config_reloaded()
	local signature = read_config_signature()
	if signature == nil then
		return
	end
	local previous = wezterm.GLOBAL.wezterm_config_signature
	wezterm.GLOBAL.wezterm_config_signature = signature
	-- nil: first eval of this GUI process → seed silently. Equal: a new window
	-- opening, or a redundant eval context for the same change → stay quiet.
	if previous == nil or previous == signature then
		return
	end
	wezterm.background_child_process({
		notify_bin,
		"--icon",
		"glyph:usr-wezterm",
		"--sound",
		"Tink",
		"WezTerm configuration reloaded",
	})
end

wezterm.on("window-config-reloaded", function(window, _)
	if write_fullscreen_state then
		write_fullscreen_state(window)
	end
	notify_config_reloaded()
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

-- Quick-launch "bring an existing session's window to the front". wezterm has
-- no CLI to raise a window, but the GUI's window:focus() does. quick-launch-
-- window passes the target WezTerm window id by renaming its workspace to
-- "__QL_FOCUS__=<id>"; the update-status handler below matches that prefix,
-- focuses the matching GUI window, and renames the workspace back. Same
-- osascript-free trick as the fullscreen bind, with the id carried in the
-- workspace name itself — no sidecar file to keep in sync.
local quick_launch_focus_pattern = "^__QL_FOCUS__=(%d+)$"

-- Mirror the window's fullscreen state to a file the zj-hud status bar polls
-- (zj-hud's WEZTERM_FULLSCREEN_SCRIPT reads it). The bar reveals its chrome
-- only in fullscreen, where WezTerm's own tab bar is hidden. The keybinding
-- toggles fullscreen via the workspace trick above and never tells the bar, so
-- this file is how the bar observes the real state. Written on change only.
local fullscreen_state_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/wezterm"
local fullscreen_state_path = fullscreen_state_dir .. "/fullscreen_state"
wezterm.background_child_process({ "mkdir", "-p", fullscreen_state_dir })
local last_fullscreen_written = nil

local function write_fullscreen_value(is_fullscreen)
	local value = is_fullscreen and "true\n" or "false\n"
	if value == last_fullscreen_written then
		return
	end
	local tmp_path = fullscreen_state_path .. ".tmp"
	local file = io.open(tmp_path, "w")
	if file then
		file:write(value)
		file:close()
		if os.rename(tmp_path, fullscreen_state_path) then
			last_fullscreen_written = value
		end
	end
end

write_fullscreen_state = function(window)
	write_fullscreen_value(window:get_dimensions().is_full_screen)
end

local function write_fullscreen_state_later(window)
	for _, delay in ipairs({ 0.05, 0.2, 0.5 }) do
		wezterm.time.call_after(delay, function()
			write_fullscreen_state(window)
		end)
	end
end

-- Config can be loaded before a GUI window object is safely available. Seed the
-- persisted value pessimistically; window events below overwrite it with the
-- real state as soon as WezTerm has a window to inspect.
write_fullscreen_value(false)

wezterm.on("update-status", function(window, pane)
	local workspace = window:active_workspace()
	if workspace == toggle_fullscreen_workspace then
		window:toggle_fullscreen()
		write_fullscreen_state_later(window)
		pcall(wezterm.mux.rename_workspace, toggle_fullscreen_workspace, last_real_workspace or "default")
		return
	end

	local focus_target = workspace:match(quick_launch_focus_pattern)
	if focus_target then
		for _, w in ipairs(wezterm.gui.gui_windows()) do
			if w:window_id() == tonumber(focus_target) then
				w:focus()
				break
			end
		end
		pcall(wezterm.mux.rename_workspace, workspace, last_real_workspace or "default")
		return
	end

	if workspace ~= "" then
		last_real_workspace = workspace
	end

	apply_terminal_location_tint(window, pane)
	apply_focus_dim(window)
	write_fullscreen_state(window)
end)

wezterm.on("window-resized", function(window, _pane)
	write_fullscreen_state(window)
end)

wezterm.on("window-focus-changed", function(window, _pane)
	apply_focus_dim(window)
	write_fullscreen_state(window)
end)

local function perform_zellij_keys(window, pane, keys)
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
end

local function send_zellij_keys(keys)
	return wezterm.action_callback(function(window, pane)
		perform_zellij_keys(window, pane, keys)
	end)
end

-- True when the focused pane is a Zellij client attached to a nested_zellij
-- session. The pane's foreground process is the Zellij client; nested-session-check
-- resolves which session it is on (live, so it tracks in-place swaps) and tests it
-- against the registry quick-launch maintains. Drives the Cmd+Shift+P /
-- Cmd+Shift+Alt+P split: inside a nested session those reach the local picker and
-- the remote picker respectively; elsewhere only Cmd+Shift+P is meaningful.
local function pane_session_is_nested(pane)
	local info = pane and pane:get_foreground_process_info()
	local exe = info and info.argv and info.argv[1] or ""
	if not exe:find("zellij") then
		return false
	end
	local helper = os.getenv("HOME") .. "/.config/zellij/scripts/nested-session-check"
	local call_ok, success = pcall(wezterm.run_child_process, { helper, tostring(info.pid) })
	return call_ok and success
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
	-- Ctrl+Shift+hjkl / arrows belong to Zellij (vim-navigator resize). WezTerm's
	-- defaults otherwise swallow them before they reach the terminal: h=HideApplication,
	-- k=ClearScrollback, l=ShowDebugOverlay, arrows=ActivatePaneDirection. Disabling
	-- lets them fall through. (Ctrl+Shift+j has no WezTerm default, so it already does.)
	{ key = "h", mods = "CTRL|SHIFT", action = wezterm.action.DisableDefaultAssignment },
	{ key = "k", mods = "CTRL|SHIFT", action = wezterm.action.DisableDefaultAssignment },
	{ key = "l", mods = "CTRL|SHIFT", action = wezterm.action.DisableDefaultAssignment },
	{ key = "LeftArrow", mods = "CTRL|SHIFT", action = wezterm.action.DisableDefaultAssignment },
	{ key = "RightArrow", mods = "CTRL|SHIFT", action = wezterm.action.DisableDefaultAssignment },
	{ key = "UpArrow", mods = "CTRL|SHIFT", action = wezterm.action.DisableDefaultAssignment },
	{ key = "DownArrow", mods = "CTRL|SHIFT", action = wezterm.action.DisableDefaultAssignment },
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
	-- `⌘⇧P`: Show the workspace/project picker. In a normal session that's the
	-- `⌥w o S` chord. In a nested session those keys are cleared and pass through
	-- to the remote, so instead send the kitty-protocol bytes for the local
	-- `Ctrl+Alt+Space` summon bound in the generated nested layout. We send the
	-- raw CSI-u sequence (`ESC [ 32;7 u`) rather than SendKey because WezTerm's
	-- SendKey mis-encodes the `Ctrl+Alt`+Space combination (Ctrl+Space collapses
	-- to NUL), so the synthesized keypress never matches Zellij's bind.
	{
		key = "p",
		mods = "CMD|SHIFT",
		action = wezterm.action_callback(function(window, pane)
			if pane_session_is_nested(pane) then
				window:perform_action(wezterm.action.SendString("\x1b[32;7u"), pane)
			else
				perform_zellij_keys(window, pane, {
					{ key = "w", mods = "ALT" },
					{ key = "o" },
					{ key = "S" },
				})
			end
		end),
	},
	-- `⌘⇧⌥P`: Only meaningful in a nested session — forward the *normal* picker
	-- chord (`⌥w o S`). Since the nested layout clears its own binds, those keys
	-- pass straight through to the REMOTE Zellij, opening the remote's own
	-- quick-launch. In a non-nested session there's no remote, so it's a no-op.
	{
		key = "p",
		mods = "CMD|SHIFT|ALT",
		action = wezterm.action_callback(function(window, pane)
			if pane_session_is_nested(pane) then
				perform_zellij_keys(window, pane, {
					{ key = "w", mods = "ALT" },
					{ key = "o" },
					{ key = "S" },
				})
			end
		end),
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
