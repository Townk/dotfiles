--- keybindings/init.lua
--- Unified keybinding engine: orchestrates modal keyboard shortcut overlay
--- and macOS system symbolic hotkeys from a single declarative configuration.
---
--- Usage:
---   local kb = require("keybindings")
---   kb.setup({
---     leader = { mods = kb.keys.mods.OG, key = "space" },
---     overlay = { maxHeight = "30%" },
---     disableSystemShortcuts = { kb.keys.sym.SCREENSHOT_SAVE },
---     keyEvents = {
---       {
---         app = "Google Chrome",
---         name = "Recent tab selector",
---         state = { selectorOpen = false },
---         rules = {
---           {
---             match = { event = "keyDown", modifiers = kb.keys.mods.C, key = "tab" },
---             keyStroke = { modifiers = kb.keys.mods.GS, key = "a" },
---             setState = { selectorOpen = true },
---             swallow = true,
---           },
---         },
---       },
---     },
---     bindings = {
---       { key = "up", mods = kb.keys.mods.CG, desc = "Mission Control",
---         action = kb.keys.sym.MISSION_CONTROL },
---       { key = "r", desc = "Reload", action = function() hs.reload() end },
---     },
---   })

---------------------------------------------------------------------------
-- Dependencies
---------------------------------------------------------------------------

local BindingTree      = require("keybindings.tree")
local Overlay          = require("keybindings.overlay")
local KeyEventsRouter  = require("keybindings.key_events_router")
local template         = require("keybindings.template")
local Dispatcher       = require("keybindings.dispatcher")
local systemShortcuts  = require("keybindings.system_shortcuts")
local dismissOnBlur    = require("system.dismiss-on-blur")

local Keybindings = {}

--- Unique id this overlay registers itself under with the shared
--- dismiss-on-blur module (see modules/system/dismiss-on-blur.lua).
local DISMISS_ON_BLUR_ID = "whichkey"

---------------------------------------------------------------------------
-- Keys: modifier shorthand and symbolic hotkey IDs
---------------------------------------------------------------------------

local mods_data = {
	C    = { "ctrl" },
	O    = { "alt" },
	G    = { "cmd" },
	S    = { "shift" },
	CO   = { "ctrl", "alt" },
	CG   = { "ctrl", "cmd" },
	CS   = { "ctrl", "shift" },
	OG   = { "alt", "cmd" },
	OS   = { "alt", "shift" },
	GS   = { "cmd", "shift" },
	COG  = { "ctrl", "alt", "cmd" },
	COS  = { "ctrl", "alt", "shift" },
	CGS  = { "ctrl", "cmd", "shift" },
	OGS  = { "alt", "cmd", "shift" },
	COGS = { "ctrl", "alt", "cmd", "shift" },
}

mods_data.HYPER = mods_data.COGS
mods_data.MEH   = mods_data.COS

local function normalizeMods(key)
	local order = { C = 1, O = 2, G = 3, S = 4 }
	local chars = {}
	for c in key:gmatch(".") do
		if order[c] then chars[#chars + 1] = c end
	end
	table.sort(chars, function(a, b) return order[a] < order[b] end)
	return table.concat(chars)
end

--- @class KeysTable
--- @field mods table  Modifier shorthand (e.g. keys.mods.CG → {"ctrl","cmd"})
--- @field sym  table  Symbolic hotkey IDs (e.g. keys.sym.MISSION_CONTROL → 32)
Keybindings.keys = {
	mods = setmetatable({}, {
		__index = function(_, key)
			return mods_data[normalizeMods(key)]
		end
	}),
	sym = {
		FOCUS_MENU_BAR = 7,
		FOCUS_DOCK = 8,
		FOCUS_NEXT_WINDOW = 9,
		FOCUS_WINDOW_TOOLBAR = 10,
		FOCUS_FLOATING_WINDOW = 11,
		TOGGLE_KEYBOARD_ACCESS = 12,
		TOGGLE_TAB_MOVES_FOCUS = 13,
		TOGGLE_ZOOM = 15,
		ZOOM_IN = 17,
		ZOOM_OUT = 19,
		INVERT_COLORS = 21,
		INCREASE_CONTRAST = 25,
		DECREASE_CONTRAST = 26,
		FOCUS_NEXT_WINDOW_IN_APP = 27,
		SCREENSHOT_SAVE = 28,
		SCREENSHOT_COPY = 29,
		SCREENSHOT_AREA_SAVE = 30,
		SCREENSHOT_AREA_COPY = 31,
		MISSION_CONTROL = 32,
		APP_WINDOWS = 33,
		MISSION_CONTROL_SLOW = 34,
		APP_WINDOWS_SLOW = 35,
		SHOW_DESKTOP = 36,
		SHOW_DESKTOP_SLOW = 37,
		FOCUS_WINDOW_DRAWER = 51,
		TOGGLE_DOCK_HIDING = 52,
		FOCUS_STATUS_MENUS = 57,
		TOGGLE_VOICEOVER = 59,
		PREV_INPUT_SOURCE = 60,
		NEXT_INPUT_SOURCE = 61,
		SHOW_SPOTLIGHT = 64,
		SHOW_FINDER_SEARCH = 65,
		MOVE_LEFT_SPACE = 79,
		MOVE_LEFT_SPACE_SLOW = 80,
		MOVE_RIGHT_SPACE = 81,
		MOVE_RIGHT_SPACE_SLOW = 82,
		SWITCH_TO_DESKTOP_1 = 118,
		SWITCH_TO_DESKTOP_2 = 119,
		SWITCH_TO_DESKTOP_3 = 120,
		SWITCH_TO_DESKTOP_4 = 121,
		SHOW_LAUNCHPAD = 160,
		SHOW_NOTIFICATION_CENTER = 163,
		TOGGLE_DO_NOT_DISTURB = 164,
		TOGGLE_DO_NOT_DISTURB_LEGACY = 175,
		SCREENSHOT_OPTIONS = 184,
	},
}

---------------------------------------------------------------------------
-- Key display formatting
---------------------------------------------------------------------------

--- Nerd Font symbols for modifier keys.
--- @type table<string, string>
local modifierSymbols = {
	cmd = "󰘳 ",
	ctrl = "󰘴 ",
	alt = "󰘵 ",
	shift = "󰘶 ",
}

--- Nerd Font / Unicode symbols for special keys.
--- @type table<string, string>
local keyDisplayNames = {
	space = "󱁐 ",
	tab = "󰌒 ",
	escape = "󱊷 ",
	delete = "󰌥 ",
	forwarddelete = "󰹿 ",
	["return"] = "󰌑 ",
	up = "↑",
	down = "↓",
	left = "←",
	right = "→",
}

--- Canonical order for displaying modifier symbols.
local MOD_ORDER = { "ctrl", "alt", "shift", "cmd" }

--- Format a key + modifiers for display in the overlay.
--- @param mods string[]  Array of modifier strings
--- @param key  string    Key name
--- @return string        Formatted display string (e.g. "󰘳 󰘶 A")
local function formatKeyLabel(mods, key)
	local parts = {}
	local modSet = {}
	for _, m in ipairs(mods) do
		modSet[string.lower(m)] = true
	end

	-- Shift+Tab renders as a dedicated backtab symbol
	if modSet["shift"] and string.lower(key) == "tab" then
		modSet["shift"] = nil
		for _, m in ipairs(MOD_ORDER) do
			if modSet[m] then
				table.insert(parts, modifierSymbols[m])
			end
		end
		table.insert(parts, "󰌓")
		return table.concat(parts, "")
	end

	for _, m in ipairs(MOD_ORDER) do
		if modSet[m] then
			table.insert(parts, modifierSymbols[m])
		end
	end
	local displayKey = keyDisplayNames[string.lower(key)] or string.upper(key)
	table.insert(parts, displayKey)
	return table.concat(parts, "")
end

---------------------------------------------------------------------------
-- Module state
---------------------------------------------------------------------------

--- @type KeybindingsState
local state = {
	root = nil,
	currentNode = nil,
	leaderNode = nil,
	overlayInstance = nil,
	keyHandler = nil,
	leaderHotkey = nil,
	globalTap = nil,
	globalBindings = {},
	timeoutTimer = nil,
	config = {},
	navigationStack = {},
	errorSound = nil,
	dismissBaselineWindow = nil, -- focused window captured when the overlay opened
}

---------------------------------------------------------------------------
-- System shortcuts integration
---------------------------------------------------------------------------

--- Recursively walk the binding tree and collect nodes with numeric actions.
--- @param node BindingNode
--- @param results SymbolicHotkeySpec[]
--- @private
local function collectSystemShortcuts(node, results)
	for _, child in pairs(node.children) do
		if type(child.action) == "number" then
			table.insert(results, {
				id = child.action,
				mods = child.mods,
				key = child.key,
			})
		end
		if child.children then
			collectSystemShortcuts(child, results)
		end
	end
end

--- Apply macOS system shortcuts: bindings with numeric actions + disabled shortcuts.
--- @param root BindingNode
--- @param disableIds number[]|nil
--- @private
local function applySystemShortcuts(root, disableIds)
	local specs = {}

	-- Collect disable specs
	if disableIds then
		for _, id in ipairs(disableIds) do
			table.insert(specs, { id = id, enabled = false })
		end
	end

	-- Collect reassignment specs from the binding tree
	collectSystemShortcuts(root, specs)

	if #specs > 0 then
		hs.printf("[keybindings] applying macOS system shortcuts…")
		systemShortcuts.apply(specs)
		hs.printf("[keybindings] done")
	end
end

---------------------------------------------------------------------------
-- Navigation helpers
---------------------------------------------------------------------------

--- Stop any active timeout timer and start a new one if configured.
--- @private
local function resetTimeout()
	if state.timeoutTimer then
		state.timeoutTimer:stop()
		state.timeoutTimer = nil
	end
	if state.config.timeout and state.config.timeout > 0 then
		state.timeoutTimer = hs.timer.doAfter(state.config.timeout, function()
			Keybindings.hide()
		end)
	end
end

--- Get the display label for a node's key.
--- @param node BindingNode
--- @return string
--- @private
local function nodeKeyLabel(node)
	return formatKeyLabel(node.mods or {}, node.key)
end

--- Walk the parent chain to build a breadcrumb trail string.
--- @param node BindingNode  Current node to build breadcrumb for
--- @return string           Breadcrumb like "icon » Key (desc)"
--- @private
local function buildBreadcrumb(node)
	if BindingTree.isRoot(node) then
		return "󰍜 Key bindings"
	end
	local chain = {}
	local current = node
	while current and not BindingTree.isRoot(current) do
		table.insert(chain, 1, current)
		current = current.parent
	end

	local parts = {}
	for i, n in ipairs(chain) do
		if i < #chain then
			local label = n.icon or nodeKeyLabel(n)
			table.insert(parts, label)
		else
			local keyLabel = nodeKeyLabel(n)
			if n.desc and n.desc ~= "" then
				table.insert(parts, keyLabel .. " (" .. n.desc .. ")")
			else
				table.insert(parts, keyLabel)
			end
		end
	end
	return table.concat(parts, " » ")
end

--- Transform a node's children into overlay entry format.
--- @param node BindingNode
--- @return table[]  Array of { keyLabel: string, desc: string, icon: string|nil, type: string }
--- @private
local function buildEntries(node)
	local children = BindingTree.getChildren(node)
	local entries = {}
	for _, child in ipairs(children) do
		table.insert(entries, {
			keyLabel = nodeKeyLabel(child),
			desc = child.desc or "",
			icon = child.icon,
			type = child.type,
		})
	end
	return entries
end

--- Render a node's children in the overlay and reset the timeout.
--- @param node       BindingNode
--- @param keepScroll? boolean  Preserve current scroll position
--- @private
local function showNode(node, keepScroll)
	state.currentNode = node
	local entries = buildEntries(node)
	local breadcrumb = buildBreadcrumb(node)
	state.overlayInstance:show(entries, breadcrumb, keepScroll)
	resetTimeout()
end

---------------------------------------------------------------------------
-- Dispatcher callbacks
---------------------------------------------------------------------------

--- Dispatcher callback: find a child of the current node matching a key press.
--- @param keyName string
--- @param flags   table
--- @return BindingNode|nil
--- @private
local function findChild(keyName, flags)
	if not state.currentNode then
		return nil
	end
	return BindingTree.findChild(state.currentNode, keyName, flags)
end

--- Dispatcher callback: handle a matched child node.
--- Groups navigate deeper; actions execute and dismiss; sticky actions execute and stay.
--- Numeric actions (system shortcuts) hide the overlay and pass the key through to macOS.
--- @param childNode BindingNode
--- @return boolean|nil  false to pass the key through to macOS
--- @private
local function onMatch(childNode)
	resetTimeout()
	if childNode.type == "group" then
		table.insert(state.navigationStack, state.currentNode)
		local ok, err = pcall(showNode, childNode)
		if not ok then
			hs.printf("keybindings: group render failed: %s", tostring(err))
			Keybindings.hide()
		end
	elseif childNode.type == "sticky" then
		if childNode.action then
			-- Sticky actions deliberately keep the overlay open across their
			-- own execution (see below) -- suppress dismiss-on-blur for that
			-- window so a future action that legitimately touches another
			-- window doesn't get treated as "focus stolen". None of today's
			-- sticky actions do this (window-resize/audio/input-source
			-- helpers only touch already-focused-window/CoreAudio/keyboard
			-- state), but this guards the general case.
			dismissOnBlur.suppress(DISMISS_ON_BLUR_ID, true)
			local fn = childNode.action --[[@as fun()]]
			local ok, err = pcall(fn)
			dismissOnBlur.suppress(DISMISS_ON_BLUR_ID, false)
			if not ok then
				hs.printf("keybindings: sticky action failed: %s", tostring(err))
			end
		end
		pcall(showNode, state.currentNode, true)
	else
		-- Action node: numeric actions pass through to macOS, functions execute
		Keybindings.hide()
		if type(childNode.action) == "number" then
			return false -- let the key event pass through to macOS
		elseif type(childNode.action) == "function" then
			local fn = childNode.action --[[@as fun()]]
			local ok, err = pcall(fn)
			if not ok then
				hs.printf("keybindings: action failed: %s", tostring(err))
			end
		end
	end
end

--- Dispatcher callback: close the overlay.
--- @private
local function onEscape()
	Keybindings.hide()
end

--- Dispatcher callback: navigate back one level in the navigation stack.
--- @private
local function onBackspace()
	resetTimeout()
	if #state.navigationStack > 0 then
		local parentNode = table.remove(state.navigationStack)
		showNode(parentNode)
	end
end

--- Dispatcher callback: scroll the overlay down.
--- @private
local function onScrollDown()
	resetTimeout()
	if state.overlayInstance then
		state.overlayInstance:scrollDown()
	end
end

--- Dispatcher callback: scroll the overlay up.
--- @private
local function onScrollUp()
	resetTimeout()
	if state.overlayInstance then
		state.overlayInstance:scrollUp()
	end
end

--- Dispatcher callback: handle an unmatched key press.
--- If it matches the leader node in the root, resets navigation to it.
--- Otherwise plays an error sound.
--- @param keyName string
--- @param flags   table
--- @private
local function onUnmatched(keyName, flags)
	resetTimeout()
	if state.leaderNode and BindingTree.findChild(state.root, keyName, flags) == state.leaderNode then
		state.navigationStack = { state.root }
		showNode(state.leaderNode)
	else
		if not state.errorSound then
			state.errorSound = hs.sound.getByName("Funk")
		end
		if state.errorSound then
			state.errorSound:stop()
			state.errorSound:play()
		end
	end
end

---------------------------------------------------------------------------
-- Global hotkey tap
---------------------------------------------------------------------------

--- Build and start the global hotkey eventtap.
--- Scans root-level children for modifier-based bindings and intercepts
--- their keyDown events via CGEventTap to bypass macOS system shortcut conflicts.
--- System shortcuts (numeric actions) are not intercepted — they pass through to macOS.
--- @private
local function setupGlobalTap()
	if state.globalTap then
		state.globalTap:stop()
		state.globalTap = nil
	end
	state.globalBindings = {}

	if not state.root then
		return
	end

	local children = BindingTree.getChildren(state.root)
	for _, child in ipairs(children) do
		if child.isGlobalHotkey and child.action then
			local nk = BindingTree.normalizeKey(child.mods, child.key)
			state.globalBindings[nk] = child
		end
	end

	if not next(state.globalBindings) then
		return
	end

	state.globalTap = hs.eventtap.new(
		{ hs.eventtap.event.types.keyDown },
		function(event)
			local keyCode = event:getKeyCode()
			local keyName = hs.keycodes.map[keyCode]
			if not keyName then
				return false
			end

			local flags = event:getFlags()
			local mods = BindingTree.flagsToMods(flags)
			if #mods == 0 then
				return false
			end

			local nk = BindingTree.normalizeKey(mods, keyName)
			local binding = state.globalBindings[nk]
			if binding then
				if type(binding.action) == "number" then
					-- System shortcut: let it pass through to macOS
					return false
				end
				local fn = binding.action --[[@as fun()]]
				local ok, err = pcall(fn)
				if not ok then
					hs.printf("keybindings: global hotkey action failed: %s", tostring(err))
				end
				return true
			end

			return false
		end
	)
	state.globalTap:start()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Configure and initialize the keybinding system.
--- Creates the binding tree, overlay, dispatcher, leader hotkey,
--- and applies macOS system shortcuts.
--- @param config KeybindingsConfig  Engine configuration
function Keybindings.setup(config)
	Keybindings.cleanup()

	state.config = config or {}
	state.root = BindingTree.newRoot()
	local overlayCfg = (state.config.overlay or {}) --[[@as OverlayConfig]]
	overlayCfg.template = template
	state.overlayInstance = Overlay.new(overlayCfg)

	state.keyHandler = Dispatcher.new({
		onMatch = onMatch,
		onEscape = onEscape,
		onBackspace = onBackspace,
		onScrollDown = onScrollDown,
		onScrollUp = onScrollUp,
		onUnmatched = onUnmatched,
		findChild = findChild,
	})

	if state.config.leader then
		state.leaderHotkey = hs.hotkey.bind(
			state.config.leader.mods or {},
			state.config.leader.key,
			Keybindings.show
		)
	end

	if state.config.bindings then
		Keybindings.register(state.config.bindings)
	end

	KeyEventsRouter.setup(state.config.keyEvents)

	-- Apply macOS system shortcuts (numeric actions + disabled shortcuts)
	applySystemShortcuts(state.root, state.config.disableSystemShortcuts)
end

--- Register keybindings into the tree.
--- Entries with `leader = true` are placed under the leader group node.
--- Root-level entries with modifiers are also registered as global hotkeys.
--- Can be called multiple times to add bindings incrementally.
--- @param bindings KeyBindingSpec[]  Array of binding spec tables
function Keybindings.register(bindings)
	if not state.root then
		state.root = BindingTree.newRoot()
	end

	for _, spec in ipairs(bindings) do
		if spec.leader and state.config.leader then
			local bindKey = spec.key or state.config.leader.key
			local bindMods = spec.mods or {}
			BindingTree.addBindings(state.root, {{
				key = bindKey,
				mods = bindMods,
				desc = spec.desc or "Leader",
				icon = spec.icon,
				group = spec.group or {},
			}})
			local nk = BindingTree.normalizeKey(bindMods, bindKey)
			state.leaderNode = state.root.children[nk]
		else
			BindingTree.addBindings(state.root, { spec })
		end
	end

	setupGlobalTap()
end

--- Open the overlay at the leader node (or root if no leader is configured).
--- Pauses global hotkeys while the overlay is active.
function Keybindings.show()
	if not state.root or not state.overlayInstance then
		return
	end
	-- Mutual exclusion between our own managed panels (e.g. the clipboard
	-- picker) -- see modules/system/dismiss-on-blur.lua's dismissOthers.
	dismissOnBlur.dismissOthers(DISMISS_ON_BLUR_ID)
	local targetNode
	if state.leaderNode then
		state.navigationStack = { state.root }
		targetNode = state.leaderNode
	else
		state.navigationStack = {}
		targetNode = state.root
	end
	if state.globalTap then
		state.globalTap:stop()
	end

	local ok, err = pcall(showNode, targetNode)
	if not ok then
		hs.printf("keybindings: overlay render failed: %s", tostring(err))
		Keybindings.hide()
		return
	end
	local tapOk, tapErr = pcall(function() state.keyHandler:start() end)
	if not tapOk then
		hs.printf("keybindings: eventtap start failed: %s", tostring(tapErr))
		Keybindings.hide()
		return
	end

	-- The overlay is nonactivating and never becomes the key window itself
	-- (see keybindings/overlay.lua's windowStyle), so unlike the clipboard
	-- picker, "expected" isn't "focus is mine" -- it's "focus hasn't moved
	-- since I opened", i.e. still whatever window was focused before the
	-- leader was pressed. Any deviation (a real app switch, or a
	-- non-activating launcher panel like Raycast stealing key-window status)
	-- dismisses the overlay -- see modules/system/dismiss-on-blur.lua.
	state.dismissBaselineWindow = hs.window.focusedWindow()
	dismissOnBlur.arm(DISMISS_ON_BLUR_ID, function(win)
		return win == state.dismissBaselineWindow
	end, Keybindings.hide)
end

--- Close the overlay and resume global hotkeys.
function Keybindings.hide()
	if state.timeoutTimer then
		state.timeoutTimer:stop()
		state.timeoutTimer = nil
	end
	if state.keyHandler then
		state.keyHandler:stop()
	end
	if state.overlayInstance then
		state.overlayInstance:hide()
	end
	state.currentNode = nil
	state.navigationStack = {}
	state.dismissBaselineWindow = nil
	dismissOnBlur.disarm(DISMISS_ON_BLUR_ID)

	if state.globalTap then
		state.globalTap:start()
	end
end

--- Release all resources: overlay, dispatcher, hotkeys, timers, and state.
function Keybindings.cleanup()
	Keybindings.hide()
	KeyEventsRouter.cleanup()

	if state.keyHandler then
		state.keyHandler:cleanup()
		state.keyHandler = nil
	end

	if state.overlayInstance then
		state.overlayInstance:cleanup()
		state.overlayInstance = nil
	end

	if state.leaderHotkey then
		state.leaderHotkey:delete()
		state.leaderHotkey = nil
	end

	if state.globalTap then
		state.globalTap:stop()
		state.globalTap = nil
	end
	state.globalBindings = {}

	state.root = nil
	state.currentNode = nil
	state.leaderNode = nil
	state.navigationStack = {}
end

return Keybindings
