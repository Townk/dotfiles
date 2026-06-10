hs.printf("Hammerspoon loading…")
require("modules.system.bootstrap").init()

local actions = require("system.actions")
local apps = require("apps")
local audio = require("audio")
local clipboard = require("apps.clipboard")
local controls = require("system.controls")
local dock = require("system.dock")
local images = require("images")
local kb = require("keybindings")
local lifecycle = require("system.lifecycle")
local osd = require("osd")
local sd = require("streamdeck")
local windows = require("windows")
local windowDrag = require("windows.drag")

lifecycle.setup()
lifecycle.registerCleanup(audio.cleanup)
lifecycle.registerCleanup(osd.cleanup)
lifecycle.registerCleanup(sd.cleanup)
lifecycle.registerCleanup(images.clearCache)
lifecycle.registerCleanup(windowDrag.cleanup)
lifecycle.registerCleanup(dock.cleanup)

dock.setup()

-- Cmd+drag anywhere on a window to move it; plain Cmd+click is preserved
-- via replay so apps that use it (Ghostty URL opening, etc.) keep working.
windowDrag.setup({ mods = { "cmd" }, threshold = 5, debug = true })

kb.setup({
	leader = { mods = kb.keys.mods.OG, key = "space" },
	-- timeout = 5,
	overlay = {
		maxHeight = "30%",
	},
	disableSystemShortcuts = {
		kb.keys.sym.SCREENSHOT_SAVE,
		kb.keys.sym.SCREENSHOT_COPY,
		kb.keys.sym.SCREENSHOT_AREA_SAVE,
		kb.keys.sym.SCREENSHOT_AREA_COPY,
		kb.keys.sym.PREV_INPUT_SOURCE,
		kb.keys.sym.NEXT_INPUT_SOURCE,
		kb.keys.sym.SHOW_FINDER_SEARCH,
		kb.keys.sym.MOVE_LEFT_SPACE_SLOW,
		kb.keys.sym.MOVE_RIGHT_SPACE_SLOW,
		kb.keys.sym.SWITCH_TO_DESKTOP_1,
		kb.keys.sym.SWITCH_TO_DESKTOP_2,
		kb.keys.sym.SWITCH_TO_DESKTOP_3,
		kb.keys.sym.SWITCH_TO_DESKTOP_4,
	},
	keyEvents = {
		{
			app = "Google Chrome",
			name = "Recent tab selector",
			state = { selectorOpen = false },
			resetOn = { "deactivated" },
			rules = {
				{
					match = { event = "keyDown", modifiers = kb.keys.mods.C, key = "tab" },
					when = { state = { selectorOpen = false } },
					actions = {
						{ keyStroke = { modifiers = kb.keys.mods.GS, key = "a" } },
						{ setState = { selectorOpen = true } },
					},
					swallow = true,
				},
				{
					match = { event = "keyDown", modifiers = kb.keys.mods.C, key = "tab" },
					when = { state = { selectorOpen = true } },
					keyStroke = { key = "down" },
					swallow = true,
				},
				{
					match = { event = "keyDown", modifiers = kb.keys.mods.CS, key = "tab" },
					when = { state = { selectorOpen = false } },
					actions = {
						{ keyStroke = { modifiers = kb.keys.mods.GS, key = "a" } },
						{ setState = { selectorOpen = true } },
						{ keyStroke = { key = "up" } },
					},
					swallow = true,
				},
				{
					match = { event = "keyDown", modifiers = kb.keys.mods.CS, key = "tab" },
					when = { state = { selectorOpen = true } },
					keyStroke = { key = "up" },
					swallow = true,
				},
				{
					match = { event = "keyDown", key = "tab" },
					when = { state = { selectorOpen = true } },
					keyStroke = { key = "down" },
					swallow = true,
				},
				{
					match = { event = "keyDown", modifiers = kb.keys.mods.S, key = "tab" },
					when = { state = { selectorOpen = true } },
					keyStroke = { key = "up" },
					swallow = true,
				},
				{
					match = { event = "modifiersChanged" },
					when = {
						state = { selectorOpen = true },
						modifiers = { ctrl = false },
					},
					actions = {
						{ setState = { selectorOpen = false } },
						{ keyStroke = { key = "return" } },
					},
					swallow = false,
				},
			},
		},
	},
	bindings = {
		{
			leader = true, key = "space", desc = "Leader Bindings",
			group = {
				{
					key = "r", icon = "", desc = "Restart",
					group = {
						{ key = "r", icon = "", desc = "Hammerspoon Config", action = lifecycle.reload },
						{ key = "s", icon = "󰀻", desc = "Stream Deck", action = sd.reconnect },
						{ key = "m", icon = "", desc = "macOS", action = actions.systemRestart },
						{ key = "u", icon = "", desc = "Log out", action = actions.systemLogOut },
					},
				},
				{
					key = "w", icon = "󱂬", desc = "Windows",
					group = {
						{ key = "c", icon = "󰼀", desc = "Center window", action = windows.centerFocusedWindow },
						{
							key = "r", icon = "󰩨", desc = "Resize…",
							group = {
								{ key = "=",     icon = "󰁌", desc = "Increase outward",  action = windows.increaseOutward,     sticky = true },
								{ key = "-",     icon = "󰁍", desc = "Decrease inward",   action = windows.decreaseInward,      sticky = true },
								{ key = "up",    icon = "󰁝", desc = "Increase at top",    action = windows.increaseSizeAtTop,    sticky = true },
								{ key = "down",  icon = "󰁅", desc = "Increase at bottom", action = windows.increaseSizeAtBottom, sticky = true },
								{ key = "left",  icon = "󰁍", desc = "Increase at left",   action = windows.increaseSizeAtLeft,   sticky = true },
								{ key = "right", icon = "󰁌", desc = "Increase at right",  action = windows.increaseSizeAtRight,  sticky = true },
								{ key = "up",    mods = { "shift" }, icon = "󰁅", desc = "Decrease at top",    action = windows.decreaseSizeAtTop,    sticky = true },
								{ key = "down",  mods = { "shift" }, icon = "󰁝", desc = "Decrease at bottom", action = windows.decreaseSizeAtBottom, sticky = true },
								{ key = "left",  mods = { "shift" }, icon = "󰁌", desc = "Decrease at left",   action = windows.decreaseSizeAtLeft,   sticky = true },
								{ key = "right", mods = { "shift" }, icon = "󰁍", desc = "Decrease at right",  action = windows.decreaseSizeAtRight,  sticky = true },
							},
						},
					},
				},
				{
					key = "t", icon = "󰨙", desc = "Toggle",
					group = {
						{ key = "a", icon = "󰜟", desc = "Audio Output Device", action = actions.cycleOutputDevice, sticky = true, },
						{ key = "a", mods = { "shift" }, icon = "󰍬", desc = "Audio Input Device", action = actions.cycleInputDevice, sticky = true, },
						{ key = "i", icon = "󰥻", desc = "Input Source", action = actions.cycleInputSources, sticky = true, },
						{ key = "c", icon = "󰆍", desc = "Console", action = actions.hammerspoonConsole },
						{ key = "d", icon = "󰔎", desc = "Dark/Light mode", action = controls.toggleDarkMode },
						{ key = "f", icon = "󰪑", desc = "Do not disturb", action = controls.toggleDoNotDisturb },
					},
				},
				{
					key = "a", icon = "", desc = "Apps",
					group = {
            { key = "c", icon = "󰈊", desc = "Color picker (ColorSlurp)", action = apps.colorSlurpPickColor },
						{ key = "p", icon = "󰩷", desc = "Screen measurements (PixelSnap)", action = apps.pixelSnapFindDimensions },
						{ key = "s", icon = "", desc = "Screenshot (CleanShot X)", action = apps.cleanshotCaptureArea },
					},
				},
        {
          key = "s", icon = "", desc = "Search",
          group = {
            { key = "v", icon = "", desc = "Search for SVG logos", action = apps.raycastSearchSVG },
            { key = "u", icon = "󰻐", desc = "Search for Unicode symbols", action = apps.raycastSearchUnicode },
            { key = "e", icon = "󰞅", desc = "Search for Emojis", action = apps.raycastSearchEmoji },
            { key = "g", icon = "", desc = "Search for GitMoji symbols", action = apps.raycastSearchGitMoji },
            { key = "m", icon = "󰦆", desc = "Search for Material icons", action = apps.raycastSearchMaterialIcon },
          },
        },
				{
					key = "v", icon = "󰛐", desc = "View",
					group = {
						{ key = "i", icon = "󰲐", desc = "My IP information", action = apps.raycastViewMyIp },
						{ key = "s", icon = "", desc = "System Information", action = apps.raycastViewSystemInfo },
						{ key = "h", icon = "󰟀", desc = "Hardware Information", action = apps.raycastSystemMonitor },
					},
				},
			},
		},
		-- System shortcuts (numeric actions pass through to macOS)
		{ key = "up", mods = kb.keys.mods.CG, desc = "Mission Control", action = kb.keys.sym.MISSION_CONTROL },
		{ key = "down", mods = kb.keys.mods.CG, desc = "Application windows", action = kb.keys.sym.APP_WINDOWS },
		{ key = "up", mods = kb.keys.mods.OG, desc = "Notification Center", action = kb.keys.sym.SHOW_NOTIFICATION_CENTER },
		{ key = "down", mods = kb.keys.mods.OG, desc = "Show Desktop", action = kb.keys.sym.SHOW_DESKTOP },
		{ key = "right", mods = kb.keys.mods.OG, desc = "Spotlight search", action = kb.keys.sym.SHOW_SPOTLIGHT },
		{ key = "left", mods = kb.keys.mods.CG, desc = "Previous space", action = kb.keys.sym.MOVE_LEFT_SPACE },
		{ key = "left", mods = kb.keys.mods.OG, desc = "Show apps", action = kb.keys.sym.SHOW_LAUNCHPAD },
		{ key = "right", mods = kb.keys.mods.CG, desc = "Next space", action = kb.keys.sym.MOVE_RIGHT_SPACE },
		-- Hammerspoon actions (function actions handled by eventtap)
		{ key = "d", mods = kb.keys.mods.COG, icon = "󰭤", desc = "Describe selection", action = clipboard.defineSelection },
		{ key = "q", mods = kb.keys.mods.COG, icon = "󰅌", desc = "QR Code from selection", action = apps.raycastQRCodeFromSelection },
		{ key = "3", mods = kb.keys.mods.GS, desc = "Full screen Screenshot", action = apps.shottrCaptureScreen },
		{ key = "3", mods = kb.keys.mods.CGS, desc = "Content scrolling Screenshot", action = apps.shottrCaptureScrolling },
		{ key = "4", mods = kb.keys.mods.GS, desc = "Screen area Screenshot", action = apps.shottrCaptureArea },
		{ key = "4", mods = kb.keys.mods.CGS, desc = "OCR Screenshot", action = apps.shottrCaptureOCR },
	},
})

local Button = require("streamdeck.button").Button
local Encoder = require("streamdeck.encoder").Encoder
local p = require("streamdeck.presets")

sd.setup({
	brightness = 100,
	defaultProfile = "main",
	profiles = {
		{
			id = "main",
			name = "Main",
			pages = {
				{
					id = "home",
					name = "Home",
          encodersBackground = { image = "gradient-magenta-blue-noise", gap = 10 },
          inputs = {
            buttons = {
              [1] = Button.new(p.buttons.toggleFocus),
              [2] = Button.new(p.buttons.screenshot),
              [3] = Button.new(p.buttons.cycleDefaultAudioInput),
              [4] = Button.new(p.buttons.cycleDefaultAudioOutput),
              [5] = Button.new(p.buttons.mediaPreviousTrack),
              [6] = Button.new(p.buttons.mediaPlayPause),
              [7] = Button.new(p.buttons.mediaNextTrack),
              [8] = Button.new(p.buttons.lockScreen),
            },
            encoders = {
              [1] = Encoder.ValueBar(p.encoders.audioOutputVolume),
              [2] = Encoder.ValueBar(p.encoders.audioInputVolume),
              [3] = Encoder.ValueBar(p.encoders.screenBrightness),
              [4] = Encoder.ValueBar(p.encoders.streamDeckBrightness),
            },
          },
				},
			},
		},
	},
})

lifecycle.showReloaded()
