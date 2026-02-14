--- streamdeck/engine.lua
--- Event-driven runtime engine for Stream Deck+ composable components.
--- Calls instance methods on Button/Encoder objects, re-renders immediately
--- after callbacks, and supports per-input polling for inputs that need it.

local renderer = require("streamdeck.renderer")
local layers   = require("streamdeck.layers")
local controls = require("system.controls")

local M = {}

-- ============================================================
-- INTERNAL STATE
-- ============================================================

local deck = nil    -- hs.streamdeck device handle
local config = nil  -- StreamDeckConfig table

local activeProfileId = nil
local activePage = nil

-- Per-slot caches: [i] = { def: Button|Encoder, cachedState, cachedValue? }
local buttonSlots = {}
local encoderSlots = {}

-- Encoder press/turn state machine
local encoderHW = {
	pressed = {},
	turned = {},
}

-- Button long-press tracking
local buttonDownTime = {}

-- Per-input poll timers
local pollTimers = {}

local LONG_PRESS_THRESHOLD = 0.5 -- seconds

-- ============================================================
-- HELPERS
-- ============================================================

local function clamp(val, lo, hi)
	return math.max(lo, math.min(hi, val))
end

-- ============================================================
-- PROFILE / PAGE RESOLUTION
-- ============================================================

local function findProfile(cfg, profileId)
	for _, profile in ipairs(cfg.profiles) do
		if profile.id == profileId then
			return profile
		end
	end
	return cfg.profiles[1]
end

local function findPage(profile, pageId)
	for _, page in ipairs(profile.pages) do
		if page.id == pageId then
			return page
		end
	end
	return profile.pages[1]
end

local function resolveInput(pageInputs, fallbackInputs, inputType, index)
	local input = pageInputs[inputType] and pageInputs[inputType][index]
	if input == nil and fallbackInputs then
		input = fallbackInputs[inputType] and fallbackInputs[inputType][index]
	end
	return input
end

-- ============================================================
-- RENDERING
-- ============================================================

--- Render a button via its composable layer pipeline and push to hardware.
local function renderAndPushButton(i)
	if not deck then return end
	local slot = buttonSlots[i]
	if not slot or not slot.def then return end

	local state = slot.cachedState
	local ctx = { w = renderer.buttonSize.w, h = renderer.buttonSize.h }
	local elements = slot.def:render(state, ctx)
	local img = renderer.renderFromElements(elements, ctx)
	if img then
		deck:setButtonImage(i, img)
	end
end

--- Render an encoder via its layer pipeline and push to hardware.
local function renderAndPushEncoder(i)
	if not deck then return end
	local slot = encoderSlots[i]
	if not slot or not slot.def then return end

	local ctx = { w = renderer.stripSize.w, h = renderer.stripSize.h }
	local elements = slot.def:render(slot.cachedState, slot.cachedValue, ctx)
	local img = renderer.renderEncoderFromElements(elements, ctx)
	if img then
		deck:setScreenImage(i, img)
	end
end

-- ============================================================
-- STATE RESOLUTION & REFRESH
-- ============================================================

--- Re-resolve state for a button. Returns true if changed.
local function resolveButtonState(i)
	local slot = buttonSlots[i]
	if not slot or not slot.def then return false end

	local newState = slot.def:state()
	if newState ~= slot.cachedState then
		slot.cachedState = newState
		return true
	end
	return false
end

--- Re-resolve state+value for an encoder. Returns true if either changed.
local function resolveEncoderState(i)
	local slot = encoderSlots[i]
	if not slot or not slot.def then return false end

	local newState = slot.def:state()
	local newValue = slot.def:value()
	if newState ~= slot.cachedState or newValue ~= slot.cachedValue then
		slot.cachedState = newState
		slot.cachedValue = newValue
		return true
	end
	return false
end

--- Refresh a single button (resolve + render).
local function refreshButton(i)
	local slot = buttonSlots[i]
	if not slot or not slot.def then return end
	slot.cachedState = slot.def:state()
	renderAndPushButton(i)
end

--- Refresh a single encoder (resolve + render).
local function refreshEncoder(i)
	local slot = encoderSlots[i]
	if not slot or not slot.def then return end
	slot.cachedState = slot.def:state()
	slot.cachedValue = slot.def:value()
	renderAndPushEncoder(i)
end

--- Refresh all buttons and encoders (full redraw).
local function refreshAll()
	for i = 1, #buttonSlots do
		refreshButton(i)
	end
	for i = 1, #encoderSlots do
		refreshEncoder(i)
	end
end

-- ============================================================
-- REACTIVE UPDATES (controls.setOnChange)
-- ============================================================

local controlChangeTimer = nil

local function onControlChange(_setting)
	-- Defer ALL re-resolution (encoders + buttons) to avoid blocking the
	-- run loop during rapid knob turns.  The encoder that triggered this
	-- change is already re-rendered immediately by the turn handler; this
	-- path exists for *other* inputs (e.g. keyboard media keys changing
	-- volume should update the volume encoder LCD, or a mute toggle
	-- should update the mute button).
	--
	-- Some state providers are expensive (hs.host.cpuUsage for encoder 4,
	-- isMediaPlaying AppleScript for button 6) and would stall the run
	-- loop if called synchronously on every knob tick.
	if controlChangeTimer then
		controlChangeTimer:stop()
	end
	controlChangeTimer = hs.timer.doAfter(0.05, function()
		controlChangeTimer = nil
		for i = 1, #encoderSlots do
			if resolveEncoderState(i) then
				renderAndPushEncoder(i)
			end
		end
		for i = 1, #buttonSlots do
			if resolveButtonState(i) then
				renderAndPushButton(i)
			end
		end
	end)
end

-- ============================================================
-- PER-INPUT POLLING
-- ============================================================

local function stopPollTimers()
	for _, timer in ipairs(pollTimers) do
		timer:stop()
	end
	pollTimers = {}
end

local function startPollTimers()
	stopPollTimers()

	for i = 1, #buttonSlots do
		local slot = buttonSlots[i]
		if slot and slot.def and slot.def.poll then
			local interval = slot.def.poll
			local idx = i
			table.insert(pollTimers, hs.timer.doEvery(interval, function()
				if resolveButtonState(idx) then
					renderAndPushButton(idx)
				end
			end))
		end
	end

	for i = 1, #encoderSlots do
		local slot = encoderSlots[i]
		if slot and slot.def and slot.def.poll then
			local interval = slot.def.poll
			local idx = i
			table.insert(pollTimers, hs.timer.doEvery(interval, function()
				if resolveEncoderState(idx) then
					renderAndPushEncoder(idx)
				end
			end))
		end
	end
end

-- ============================================================
-- PAGE LOADING
-- ============================================================

local function loadPage(page, profile)
	activePage = page

	local fallback = profile and profile.fallback or nil

	-- Populate button slots
	buttonSlots = {}
	local maxButtons = 8
	if page.inputs and page.inputs.buttons then
		local cols, rows
		if deck then
			cols, rows = deck:buttonLayout()
		end
		cols = cols or 4
		rows = rows or 2
		local bgName, hInset, vInset
		if page.buttonsBackground then
			if type(page.buttonsBackground) == "table" then
				bgName = page.buttonsBackground.image
				hInset = page.buttonsBackground.horizontalInset or 0
				vInset = page.buttonsBackground.verticalInset or 0
			else
				bgName = page.buttonsBackground
				hInset = 0
				vInset = 0
			end
		end
		for i = 1, math.max(maxButtons, #page.inputs.buttons) do
			local def = resolveInput(page.inputs, fallback, "buttons", i)
			if def and bgName then
				local bgLayer = layers.buttonBackgroundSlice(bgName, i, cols, rows, hInset, vInset)
				def._layers = { bgLayer, table.unpack(def._layers) }
			end
			buttonSlots[i] = { def = def, cachedState = nil }
		end
	end

	-- Populate encoder slots
	encoderSlots = {}
	local maxEncoders = 4
	if page.inputs and page.inputs.encoders then
		local encBgName, encBgGap
		if page.encodersBackground then
			if type(page.encodersBackground) == "table" then
				encBgName = page.encodersBackground.image
				encBgGap  = page.encodersBackground.gap or 0
			else
				encBgName = page.encodersBackground
				encBgGap  = 0
			end
		end
		for i = 1, math.max(maxEncoders, #page.inputs.encoders) do
			local def = resolveInput(page.inputs, fallback, "encoders", i)
			if def and encBgName then
				local bgLayer = layers.encoderBackgroundSlice(encBgName, i, encBgGap)
				def._layers = def._layers and { bgLayer, table.unpack(def._layers) } or { bgLayer }
			end
			encoderSlots[i] = { def = def, cachedState = nil, cachedValue = nil }
		end
	end

	-- Initial full render
	refreshAll()

	-- Start per-input poll timers
	startPollTimers()
end

-- ============================================================
-- PAGE NAVIGATION
-- ============================================================

local function switchPage(targetId)
	if not targetId then return end
	local profile = findProfile(config, activeProfileId)
	local page = findPage(profile, targetId)
	if page then
		loadPage(page, profile)
	end
end

-- ============================================================
-- BUTTON CALLBACK (registered as device callback)
-- ============================================================

function M.buttonCallback(_device, buttonNumber, pressed)
	local slot = buttonSlots[buttonNumber]
	if not slot or not slot.def then return end

	if pressed then
		buttonDownTime[buttonNumber] = hs.timer.secondsSinceEpoch()
		return
	end

	-- Released
	local downTime = buttonDownTime[buttonNumber]
	buttonDownTime[buttonNumber] = nil
	local elapsed = downTime and (hs.timer.secondsSinceEpoch() - downTime) or 0
	local state = slot.def:state()

	if elapsed > LONG_PRESS_THRESHOLD then
		slot.def:onLongPress(state)
	else
		slot.def:onPress(state)
	end

	-- Immediate re-render: re-resolve state and push
	slot.cachedState = slot.def:state()
	renderAndPushButton(buttonNumber)
	onControlChange("button")
end

-- ============================================================
-- ENCODER CALLBACK (registered as device callback)
-- State machine: distinguishes press, turn, turn-while-pressed
-- ============================================================

function M.encoderCallback(_device, encoderNumber, pressed, turnedLeft, turnedRight)
	local slot = encoderSlots[encoderNumber]
	if not slot or not slot.def then return end

	local isPressed = encoderHW.pressed[encoderNumber] or false

	-- Press down
	if pressed and not isPressed then
		encoderHW.pressed[encoderNumber] = true
		encoderHW.turned[encoderNumber] = false
		if slot.def.beginSelecting then
			slot.def:beginSelecting()
			slot.cachedState = slot.def:state()
			slot.cachedValue = slot.def:value()
			renderAndPushEncoder(encoderNumber)
		end
		return
	end

	-- Turn (while pressed or not)
	if turnedLeft or turnedRight then
		local secondary = isPressed
		if isPressed then
			encoderHW.turned[encoderNumber] = true
		end

		local state = slot.def:state()
		local value = slot.def:value()

		if turnedRight then
			slot.def:onInc(state, value, secondary)
		else
			slot.def:onDec(state, value, secondary)
		end

		-- Immediate re-render: re-read state+value from the single source of truth
		-- (the controls module's optimistic state) rather than using a second
		-- optimistic value that would fight the OSD.
		slot.cachedState = slot.def:state()
		slot.cachedValue = slot.def:value()
		renderAndPushEncoder(encoderNumber)
		return
	end

	-- Release
	if not pressed and isPressed then
		encoderHW.pressed[encoderNumber] = false

		if slot.def.endSelecting then
			slot.def:endSelecting()
		end

		if not encoderHW.turned[encoderNumber] then
			local state = slot.def:state()
			local value = slot.def:value()
			slot.def:onPress(state, value)
		end

		slot.cachedState = slot.def:state()
		slot.cachedValue = slot.def:value()
		renderAndPushEncoder(encoderNumber)
		encoderHW.turned[encoderNumber] = false
	end
end

-- ============================================================
-- SCREEN CALLBACK (LCD strip touch events)
-- ============================================================

function M.screenCallback(_device, eventType, x1, y1, x2, y2)
	local stripWidth = 800

	-- Full-strip swipe for page navigation
	if eventType == "swipe" then
		local distance = math.abs((x2 or 0) - (x1 or 0))
		if distance > 400 and activePage then
			if (x2 or 0) > (x1 or 0) then
				switchPage(activePage.onSwipeRight)
			else
				switchPage(activePage.onSwipeLeft)
			end
			return
		end
	end

	-- Map touch position to encoder section
	local section = clamp(math.floor(x1 / (stripWidth / 4)) + 1, 1, 4)
	local slot = encoderSlots[section]
	if not slot or not slot.def then return end

	local state = slot.def:state()
	local value = slot.def:value()

	if eventType == "shortPress" then
		slot.def:onTouch(state, value)
		-- Immediate re-render
		slot.cachedState = slot.def:state()
		slot.cachedValue = slot.def:value()
		renderAndPushEncoder(section)

	elseif eventType == "longPress" then
		slot.def:onTouchLong(state, value)
		-- Immediate re-render
		slot.cachedState = slot.def:state()
		slot.cachedValue = slot.def:value()
		renderAndPushEncoder(section)

	elseif eventType == "swipe" then
		local direction = (x2 or 0) > (x1 or 0)
		if direction then
			slot.def:onInc(state, value, false)
		else
			slot.def:onDec(state, value, false)
		end
		slot.cachedState = slot.def:state()
		slot.cachedValue = slot.def:value()
		renderAndPushEncoder(section)
	end
end

-- ============================================================
-- SETUP / CLEANUP
-- ============================================================

--- Initialise the engine with a device handle and config.
function M.setup(device, cfg)
	deck = device
	config = cfg

	local profile = findProfile(config, config.defaultProfile)
	activeProfileId = profile.id

	local page = profile.pages[1]
	loadPage(page, profile)

	-- Register reactive updates from the controls system
	controls.setOnChange(onControlChange)
end

--- Tear down timers and unregister callbacks.
function M.cleanup()
	stopPollTimers()
	controls.setOnChange(nil)

	if controlChangeTimer then
		controlChangeTimer:stop()
		controlChangeTimer = nil
	end

	buttonSlots = {}
	encoderSlots = {}
	encoderHW = { pressed = {}, turned = {} }
	buttonDownTime = {}
	deck = nil
	config = nil
	activePage = nil
end

return M
